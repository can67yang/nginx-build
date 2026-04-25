#!/bin/bash
set -euo pipefail

# ============================================================
# nginx + BoringSSL Build Script
# Targets: Debian 12/13, Ubuntu 22.04+
# ============================================================

NGINX_VERSION="${NGINX_VERSION:-1.30.0}"
BORINGSSL_COMMIT="${BORINGSSL_COMMIT:-main}"
JOBS="${JOBS:-$(nproc)}"
PREFIX="${PREFIX:-/etc/nginx}"

WORK_DIR="/tmp/nginx-build"
SRC_DIR="$WORK_DIR/src"
INSTALL_DIR="$WORK_DIR/install"
ARTIFACT_DIR="$WORK_DIR/artifact"

# Detect OS info
. /etc/os-release
OS_ID="${ID:-unknown}"
OS_VERSION="${VERSION_ID:-unknown}"
OS_ARCH="$(uname -m)"

log() { echo "[*] $*" >&2; }
err() { echo "[!] $*" >&2; exit 1; }

# Create directories
rm -rf "$INSTALL_DIR" "$ARTIFACT_DIR"
mkdir -p "$SRC_DIR" "$INSTALL_DIR" "$ARTIFACT_DIR"

# ----------------------------------------------------------
# 1) Install build dependencies
# ----------------------------------------------------------
install_deps() {
    log "Installing build dependencies..."

    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \
        ca-certificates \
        wget \
        curl \
        build-essential \
        golang-go \
        cmake \
        ninja-build \
        libpcre2-dev \
        zlib1g-dev \
        libssl-dev \
        libxslt1-dev \
        libgd-dev \
        libgeoip-dev \
        libmaxminddb-dev \
        perl \
        git \
        tar \
        xz-utils \
        pkg-config \
        dpkg-dev \
        || err "Failed to install core dependencies"

    # Extra tools needed
    apt-get install -y -qq --no-install-recommends \
        libedit-dev \
        libxml2-dev \
        xxd \
        time \
        2>/dev/null || true
}

install_deps

# ----------------------------------------------------------
# 2) Build BoringSSL (static libs)
# ----------------------------------------------------------
build_boringssl() {
    local bssl_src="$SRC_DIR/boringssl"
    local bssl_build="$SRC_DIR/boringssl-build"

    log "Building BoringSSL (commit: $BORINGSSL_COMMIT)..."

    if [ ! -d "$bssl_src" ]; then
        git clone --depth 1 https://boringssl.googlesource.com/boringssl "$bssl_src"
    fi

    cd "$bssl_src"
    git fetch --depth 1 origin "$BORINGSSL_COMMIT"
    git -c advice.detachedHead=false checkout "$BORINGSSL_COMMIT"

    rm -rf "$bssl_build"
    mkdir "$bssl_build" && cd "$bssl_build"

    cmake -GNinja \
        -DBUILD_SHARED_LIBS=0 \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS="-fPIC -Wno-error=array-bounds" \
        -DCMAKE_CXX_FLAGS="-fPIC -Wno-error=array-bounds" \
        -DBUILD_TESTING=OFF \
        "$bssl_src"
    ninja -j"$JOBS"

    BSSL_INCLUDE="$bssl_src/include"

    # Locate built libraries (path varies across BoringSSL versions)
    BSSL_LIB_SSL="$(find "$bssl_build" -name libssl.a -type f 2>/dev/null | head -1)" || true
    BSSL_LIB_CRYPTO="$(find "$bssl_build" -name libcrypto.a -type f 2>/dev/null | head -1)" || true
    [ -n "$BSSL_LIB_SSL" ] || err "libssl.a not found in $bssl_build"
    [ -n "$BSSL_LIB_CRYPTO" ] || err "libcrypto.a not found in $bssl_build"
    BSSL_LIB_SSL="$(dirname "$BSSL_LIB_SSL")"
    BSSL_LIB_CRYPTO="$(dirname "$BSSL_LIB_CRYPTO")"

    log "BoringSSL built successfully"
}

build_boringssl

# ----------------------------------------------------------
# 3) Download & extract nginx source
# ----------------------------------------------------------
download_nginx() {
    log "Downloading nginx $NGINX_VERSION..."
    cd "$SRC_DIR"

    if [ ! -f "nginx-$NGINX_VERSION.tar.gz" ]; then
        wget -q "https://nginx.org/download/nginx-$NGINX_VERSION.tar.gz" \
            || err "Failed to download nginx $NGINX_VERSION"
    fi

    local nginx_src="$SRC_DIR/nginx-$NGINX_VERSION"
    if [ ! -d "$nginx_src" ]; then
        tar xzf "nginx-$NGINX_VERSION.tar.gz" -C "$SRC_DIR"
    fi

    echo "$nginx_src"
}

NGINX_SRC=$(download_nginx)

# ----------------------------------------------------------
# 4) Configure & build nginx with BoringSSL
# ----------------------------------------------------------
build_nginx() {
    log "Configuring nginx $NGINX_VERSION with BoringSSL..."

    cd "$NGINX_SRC"

    # Debug: verify BoringSSL paths
    log "BSSL_INCLUDE=$BSSL_INCLUDE"
    ls "$BSSL_INCLUDE/openssl/ssl.h" >&2 || err "BoringSSL header not found at $BSSL_INCLUDE/openssl/ssl.h"

    ./configure \
        --prefix="$PREFIX" \
        --sbin-path="/usr/sbin/nginx" \
        --modules-path="/usr/lib/nginx/modules" \
        --conf-path="$PREFIX/conf/nginx.conf" \
        --error-log-path=/var/log/nginx/error.log \
        --http-log-path=/var/log/nginx/access.log \
        --pid-path=/var/run/nginx.pid \
        --lock-path=/var/run/nginx.lock \
        --user=nginx \
        --group=nginx \
        --with-threads \
        --with-file-aio \
        --with-pcre-jit \
        --with-http_ssl_module \
        --with-http_v2_module \
        --with-http_v3_module \
        --with-http_realip_module \
        --with-http_addition_module \
        --with-http_sub_module \
        --with-http_dav_module \
        --with-http_flv_module \
        --with-http_mp4_module \
        --with-http_gunzip_module \
        --with-http_gzip_static_module \
        --with-http_auth_request_module \
        --with-http_random_index_module \
        --with-http_secure_link_module \
        --with-http_slice_module \
        --with-http_stub_status_module \
        --with-mail \
        --with-mail_ssl_module \
        --with-stream \
        --with-stream_ssl_module \
        --with-stream_realip_module \
        --with-stream_geoip_module \
        --with-http_geoip_module \
        --with-http_image_filter_module \
        --with-http_xslt_module \
        --with-cc-opt="-I$BSSL_INCLUDE -O2 -fstack-protector-strong -Wformat -Werror=format-security -Wno-stringop-truncation" \
        --with-ld-opt="-L$BSSL_LIB_SSL -L$BSSL_LIB_CRYPTO -lssl -lcrypto -lstdc++ -lpthread -ldl -lresolv"

    log "Building nginx (jobs: $JOBS)..."
    make -j"$JOBS"
    make install DESTDIR="$INSTALL_DIR"

    log "nginx built successfully"
    local nginx_bin=$(find "$INSTALL_DIR" -name nginx -type f 2>/dev/null | head -1) || true
    if [ -n "$nginx_bin" ]; then
        "$nginx_bin" -V 2>&1 || true
    fi
}

build_nginx

# ----------------------------------------------------------
# 5) Package artifacts
# ----------------------------------------------------------
package() {
    local pkg_name="nginx-boringssl"
    local pkg_ver="${NGINX_VERSION}-1"
    local arch="amd64"
    local deb_file="${pkg_name}_${pkg_ver}_${arch}.deb"

    log "Packaging $deb_file..."

    # --- Create DEBIAN control directory ---
    mkdir -p "$INSTALL_DIR/DEBIAN"

    # Generate dependency list from the built binary
    local depends=""
    if command -v dpkg-shlibdeps >/dev/null 2>&1; then
        depends=$(dpkg-shlibdeps -O "$INSTALL_DIR/usr/sbin/nginx" 2>/dev/null \
            | grep -oP 'shlibs:Depends=\K.*' \
            | sed 's/,/\n/g' \
            | sed 's/^[[:space:]]*//' \
            | sort -u \
            | paste -sd ', ') || true
    fi
    [ -z "$depends" ] && depends="libc6, libpcre2-8-0, zlib1g"

    # control file
    cat > "$INSTALL_DIR/DEBIAN/control" <<CONTROL
Package: nginx-boringssl
Version: $pkg_ver
Architecture: $arch
Maintainer: nginx-boringssl builder <builder@localhost>
Depends: $depends
Section: httpd
Priority: optional
Homepage: https://nginx.org
Description: nginx ${NGINX_VERSION} with BoringSSL (HTTP/3, ECH)
 Custom build of nginx with BoringSSL for HTTP/3 (QUIC) and ECH.
 Built for ${OS_ID} ${OS_VERSION} (${OS_ARCH}).
CONTROL

    # conffiles
    cat > "$INSTALL_DIR/DEBIAN/conffiles" <<'CONFFILES'
/etc/nginx/conf/nginx.conf
CONFFILES

    # postinst — create nginx user & dirs, enable service
    cat > "$INSTALL_DIR/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e

case "$1" in
    configure)
        if ! getent group nginx >/dev/null 2>&1; then
            addgroup --system nginx
        fi
        if ! getent passwd nginx >/dev/null 2>&1; then
            adduser --system --disabled-login --ingroup nginx \
                --home /var/cache/nginx --no-create-home \
                --shell /sbin/nologin nginx
        fi
        mkdir -p /var/log/nginx /var/cache/nginx
        chown -R nginx:nginx /var/log/nginx /var/cache/nginx
        if command -v systemctl >/dev/null 2>&1; then
            systemctl daemon-reload
            systemctl enable nginx || true
        fi
        ;;
    abort-upgrade|abort-remove|abort-deconfigure)
        ;;
    *)
        ;;
esac
POSTINST
    chmod 755 "$INSTALL_DIR/DEBIAN/postinst"

    # postrm — cleanup on purge
    cat > "$INSTALL_DIR/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
set -e
case "$1" in
    purge)
        if getent passwd nginx >/dev/null 2>&1; then userdel nginx; fi
        if getent group nginx >/dev/null 2>&1; then groupdel nginx; fi
        rm -rf /var/log/nginx /var/cache/nginx
        ;;
    remove|upgrade|disappear|abort-install|abort-upgrade) ;;
    *) ;;
esac
POSTRM
    chmod 755 "$INSTALL_DIR/DEBIAN/postrm"

    # --- systemd service ---
    mkdir -p "$INSTALL_DIR/lib/systemd/system"
    cat > "$INSTALL_DIR/lib/systemd/system/nginx.service" <<'SERVICE'
[Unit]
Description=nginx - high performance web server
Documentation=https://nginx.org/en/docs/
After=network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/var/run/nginx.pid
ExecStartPre=/usr/sbin/nginx -t -q -g 'daemon on; master_process on;'
ExecStart=/usr/sbin/nginx -g 'daemon on; master_process on;'
ExecReload=/usr/sbin/nginx -s reload
ExecStop=-/sbin/start-stop-daemon --quiet --stop --retry QUIT/5 --pidfile /var/run/nginx.pid
TimeoutStopSec=5
KillMode=mixed

[Install]
WantedBy=multi-user.target
SERVICE

    # --- Build .deb ---
    dpkg-deb --build -Zxz "$INSTALL_DIR" "$ARTIFACT_DIR/$deb_file"

    cd "$ARTIFACT_DIR"
    sha256sum "$deb_file" > "${deb_file}.sha256"

    log "Artifacts:"
    ls -lh "$ARTIFACT_DIR/"
}

package

echo ""
echo "============================================"
echo "  Build Complete!"
echo "  nginx $NGINX_VERSION + BoringSSL"
echo "  Target: ${OS_ID} ${OS_VERSION} (${OS_ARCH})"
echo "  Artifacts: $ARTIFACT_DIR/"
echo "============================================"
