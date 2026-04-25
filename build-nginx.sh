#!/bin/bash
set -euo pipefail

# ============================================================
# nginx + BoringSSL Build Script
# Targets: Debian 12/13, Ubuntu 22.04+
# ============================================================

NGINX_VERSION="${NGINX_VERSION:-1.30.0}"
BORINGSSL_COMMIT="${BORINGSSL_COMMIT:-master}"
JOBS="${JOBS:-$(nproc)}"
PREFIX="${PREFIX:-/opt/nginx}"

WORK_DIR="/tmp/nginx-build"
SRC_DIR="$WORK_DIR/src"
INSTALL_DIR="$WORK_DIR/install"
ARTIFACT_DIR="$WORK_DIR/artifact"

# Detect OS info
. /etc/os-release
OS_ID="${ID:-unknown}"
OS_VERSION="${VERSION_ID:-unknown}"
OS_ARCH="$(uname -m)"

log() { echo "[*] $*"; }
err() { echo "[!] $*" >&2; exit 1; }

# Create directories
rm -rf "$INSTALL_DIR" "$ARTIFACT_DIR"
mkdir -p "$SRC_DIR" "$INSTALL_DIR" "$ARTIFACT_DIR"

# ----------------------------------------------------------
# 1) Install build dependencies
# ----------------------------------------------------------
install_deps() {
    log "Installing build dependencies..."

    # Map codenames for Debian
    OS_CODENAME="${VERSION_CODENAME:-}"

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
        libxslt1-dev \
        libgd-dev \
        libgeoip-dev \
        libmaxminddb-dev \
        perl \
        git \
        tar \
        xz-utils \
        pkg-config \
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
        -DCMAKE_C_FLAGS="-fPIC" \
        -DCMAKE_CXX_FLAGS="-fPIC" \
        "$bssl_src"
    ninja -j"$JOBS"

    BSSL_INCLUDE="$bssl_src/include"
    BSSL_LIB_SSL="$bssl_build/ssl"
    BSSL_LIB_CRYPTO="$bssl_build/crypto"

    # Verify libs exist
    [ -f "$BSSL_LIB_SSL/libssl.a" ] || err "libssl.a not found"
    [ -f "$BSSL_LIB_CRYPTO/libcrypto.a" ] || err "libcrypto.a not found"

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

    ./configure \
        --prefix="$PREFIX" \
        --sbin-path="$PREFIX/sbin/nginx" \
        --modules-path="$PREFIX/modules" \
        --conf-path="$PREFIX/conf/nginx.conf" \
        --error-log-path=/var/log/nginx/error.log \
        --http-log-path=/var/log/nginx/access.log \
        --pid-path=/var/run/nginx.pid \
        --lock-path=/var/run/nginx.lock \
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
        --with-ld-opt="-L$BSSL_LIB_SSL -L$BSSL_LIB_CRYPTO -lssl -lcrypto -lpthread -ldl -lresolv"

    log "Building nginx (jobs: $JOBS)..."
    make -j"$JOBS"
    make install DESTDIR="$INSTALL_DIR"

    log "nginx built successfully"
    "$INSTALL_DIR/$PREFIX/sbin/nginx" -V 2>&1 || true
}

build_nginx

# ----------------------------------------------------------
# 5) Package artifacts
# ----------------------------------------------------------
package() {
    local pkg_name="nginx-${NGINX_VERSION}-${OS_ID}${OS_VERSION}-${OS_ARCH}-boringssl"
    local pkg_file="${pkg_name}.tar.gz"

    log "Packaging $pkg_file..."

    cd "$INSTALL_DIR"
    tar czf "$ARTIFACT_DIR/$pkg_file" \
        --transform "s|^\.|$pkg_name|" \
        .

    cd "$ARTIFACT_DIR"
    sha256sum "$pkg_file" > "${pkg_file}.sha256"

    # Also copy the binary directly for convenience
    cp "$INSTALL_DIR/$PREFIX/sbin/nginx" "$ARTIFACT_DIR/nginx-${NGINX_VERSION}-boringssl"

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
