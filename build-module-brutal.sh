#!/bin/bash
set -euo pipefail

# ============================================================
# brutal-nginx Dynamic Module Builder
# Builds ngx_http_tcp_brutal_module.so standalone against the
# same nginx + BoringSSL build used by build-nginx.sh.
# The .so is placed alongside the .deb — NOT inside it.
#
# Usage:
#   # Run AFTER build-nginx.sh completes (in the same container):
#   ./build-module-brutal.sh
#
# Output: /tmp/nginx-build/artifact/ngx_http_tcp_brutal_module.so
# ============================================================

NGINX_VERSION="${NGINX_VERSION:-1.30.0}"
JOBS="${JOBS:-$(nproc)}"

WORK_DIR="/tmp/nginx-build"
SRC_DIR="$WORK_DIR/src"
ARTIFACT_DIR="$WORK_DIR/artifact"

log() { echo "[*] $*" >&2; }
err() { echo "[!] $*" >&2; exit 1; }

# ----------------------------------------------------------
# 1) Verify existing build artifacts
# ----------------------------------------------------------
log "Checking for existing nginx + BoringSSL build..."

BSSL_INCLUDE="$SRC_DIR/boringssl/include"
[ -d "$BSSL_INCLUDE" ] || err "BoringSSL include not found at $BSSL_INCLUDE. Run build-nginx.sh first."

BSSL_LIB_SSL="$(find "$SRC_DIR/boringssl-build" -name libssl.a -type f 2>/dev/null | head -1)" || true
BSSL_LIB_CRYPTO="$(find "$SRC_DIR/boringssl-build" -name libcrypto.a -type f 2>/dev/null | head -1)" || true
[ -n "$BSSL_LIB_SSL" ] || err "libssl.a not found. Run build-nginx.sh first."
[ -n "$BSSL_LIB_CRYPTO" ] || err "libcrypto.a not found. Run build-nginx.sh first."
BSSL_LIB_SSL="$(dirname "$BSSL_LIB_SSL")"
BSSL_LIB_CRYPTO="$(dirname "$BSSL_LIB_CRYPTO")"

log "  BoringSSL include: $BSSL_INCLUDE"
log "  BoringSSL lib dir: $BSSL_LIB_SSL"

# ----------------------------------------------------------
# 2) Extract a fresh nginx source tree for the module build
#    (so we do NOT contaminate the main nginx build objects)
# ----------------------------------------------------------
NGINX_TARBALL="$SRC_DIR/nginx-$NGINX_VERSION.tar.gz"
MODULE_NGINX_DIR="$WORK_DIR/nginx-brutal-build"

[ -f "$NGINX_TARBALL" ] || err "nginx tarball not found at $NGINX_TARBALL"

rm -rf "$MODULE_NGINX_DIR"
log "Extracting nginx $NGINX_VERSION for module compilation..."
tar xzf "$NGINX_TARBALL" -C "$WORK_DIR"
mv "$WORK_DIR/nginx-$NGINX_VERSION" "$MODULE_NGINX_DIR"

# ----------------------------------------------------------
# 3) Clone / update brutal-nginx source
# ----------------------------------------------------------
BRUTAL_DIR="$WORK_DIR/brutal-nginx"
if [ -d "$BRUTAL_DIR/.git" ]; then
    log "Updating brutal-nginx..."
    cd "$BRUTAL_DIR" && git pull --ff-only
else
    log "Cloning brutal-nginx..."
    rm -rf "$BRUTAL_DIR"
    git clone --depth 1 https://github.com/sduoduo233/brutal-nginx.git "$BRUTAL_DIR"
fi

# ----------------------------------------------------------
# 4) Configure nginx with the dynamic module
#    --with-compat ensures the .so loads even if the main
#    nginx binary was configured with slightly different flags
# ----------------------------------------------------------
log "Configuring nginx with brutal-nginx module..."

cd "$MODULE_NGINX_DIR"
./configure \
    --with-compat \
    --add-dynamic-module="$BRUTAL_DIR" \
    --with-cc-opt="-I$BSSL_INCLUDE -O2 -fstack-protector-strong -Wformat -Werror=format-security" \
    --with-ld-opt="-L$BSSL_LIB_SSL -L$BSSL_LIB_CRYPTO -lssl -lcrypto -lstdc++ -lpthread -ldl -lresolv"

# ----------------------------------------------------------
# 5) Build ONLY the dynamic module .so (not the full nginx)
# ----------------------------------------------------------
log "Building ngx_http_tcp_brutal_module.so (jobs: $JOBS)..."
make modules -j"$JOBS"

# ----------------------------------------------------------
# 6) Stage the .so artifact (NOT included in the .deb)
# ----------------------------------------------------------
SO_SRC="$MODULE_NGINX_DIR/objs/ngx_http_tcp_brutal_module.so"
if [ -f "$SO_SRC" ]; then
    mkdir -p "$ARTIFACT_DIR"
    cp "$SO_SRC" "$ARTIFACT_DIR/ngx_http_tcp_brutal_module.so"
    log "Module built successfully!"
    ls -lh "$ARTIFACT_DIR/ngx_http_tcp_brutal_module.so"
else
    err "Module compilation failed — $SO_SRC not found."
fi

# Verify it's a valid shared object
if command -v file &>/dev/null; then
    file "$ARTIFACT_DIR/ngx_http_tcp_brutal_module.so" >&2
fi

log "Done. The .so is at: $ARTIFACT_DIR/ngx_http_tcp_brutal_module.so"
log "Copy it to your target machine and load it in nginx.conf:"
log "  load_module /path/to/ngx_http_tcp_brutal_module.so;"
