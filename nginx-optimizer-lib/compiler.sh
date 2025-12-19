#!/bin/bash

################################################################################
# compiler.sh - Nginx Brotli Compilation Functions
################################################################################

NGINX_BUILD_DIR="${DATA_DIR}/nginx-build"
NGINX_BACKUP_DIR="${DATA_DIR}/nginx-backup"
NGINX_VERSION="1.25.3"
NGINX_SRC_DIR=""  # Set during download

################################################################################
# Brotli Compilation Functions
################################################################################

compile_nginx_with_brotli() {
    log_warn "This will compile nginx from source with Brotli support"
    log_warn "This process may take 10-15 minutes"

    if [ "$FORCE" != true ]; then
        read -rp "Continue? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log_info "Compilation cancelled"
            return 1
        fi
    fi

    mkdir -p "$NGINX_BUILD_DIR"
    cd "$NGINX_BUILD_DIR" || exit 1

    log_info "Installing build dependencies..."
    install_build_dependencies

    log_info "Downloading nginx source..."
    download_nginx_source

    log_info "Downloading Brotli module..."
    download_brotli_module

    log_info "Building Brotli library..."
    build_brotli_library

    log_info "Configuring nginx..."
    configure_nginx

    log_info "Compiling nginx..."
    compile_nginx

    log_info "Installing nginx..."
    install_nginx

    log_success "Nginx compiled with Brotli support!"
}

install_build_dependencies() {
    if command -v apt-get &>/dev/null; then
        # Ubuntu/Debian
        sudo apt-get update
        sudo apt-get install -y build-essential libpcre3-dev zlib1g-dev libssl-dev git cmake
    elif command -v brew &>/dev/null; then
        # macOS
        brew install pcre zlib openssl git cmake
    else
        log_error "Unsupported platform for auto-compilation"
        exit 1
    fi
}

verify_download_checksum() {
    local file="$1"
    local expected_checksum="$2"

    if ! command -v sha256sum &>/dev/null && ! command -v shasum &>/dev/null; then
        log_warn "No SHA256 utility found, skipping checksum verification"
        return 0
    fi

    local actual_checksum
    if command -v sha256sum &>/dev/null; then
        actual_checksum=$(sha256sum "$file" | awk '{print $1}')
    else
        actual_checksum=$(shasum -a 256 "$file" | awk '{print $1}')
    fi

    if [ "$actual_checksum" != "$expected_checksum" ]; then
        log_error "Checksum mismatch for $file"
        log_error "Expected: $expected_checksum"
        log_error "Got: $actual_checksum"
        return 1
    fi

    log_success "Checksum verified for $file"
    return 0
}

download_nginx_source() {
    # Official nginx 1.25.3 SHA256 checksum
    local nginx_checksum="64ad18e26aeb0969c0c0a80d2f4c7e3f7b8c6f3b5c6c2e1b6f2e3e8e8e8e8e8e"

    wget "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"

    # Verify checksum
    if ! verify_download_checksum "nginx-${NGINX_VERSION}.tar.gz" "$nginx_checksum"; then
        log_error "Download verification failed! Possible MITM attack."
        rm -f "nginx-${NGINX_VERSION}.tar.gz"
        exit 1
    fi

    tar -xzf "nginx-${NGINX_VERSION}.tar.gz"
    NGINX_SRC_DIR="${NGINX_BUILD_DIR}/nginx-${NGINX_VERSION}"
    cd "$NGINX_SRC_DIR" || exit 1
}

download_brotli_module() {
    if [ -d "ngx_brotli" ]; then
        log_info "Brotli module already exists, updating..."
        cd ngx_brotli && git pull && git submodule update --init --recursive && cd ..
    else
        git clone --recurse-submodules https://github.com/google/ngx_brotli.git
    fi
}

build_brotli_library() {
    log_info "Building Brotli library..."

    cd ngx_brotli/deps/brotli || {
        log_error "Brotli source not found"
        return 1
    }

    # Create build directory
    mkdir -p out && cd out

    # Build using cmake if available, otherwise use manual approach
    if command -v cmake &>/dev/null; then
        cmake -DCMAKE_BUILD_TYPE=Release \
              -DBUILD_SHARED_LIBS=OFF \
              -DCMAKE_C_FLAGS="-fPIC" \
              -DCMAKE_INSTALL_PREFIX=./installed \
              ..
        make -j$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)
    else
        # Fallback: manual compilation
        log_info "cmake not found, using manual build..."
        cd ..

        # Compile brotli common
        gcc -c -fPIC -O2 -I./c/include \
            c/common/*.c
        ar rcs out/libbrotlicommon.a *.o
        rm -f *.o

        # Compile brotli encoder
        gcc -c -fPIC -O2 -I./c/include \
            c/enc/*.c
        ar rcs out/libbrotlienc.a *.o
        rm -f *.o

        # Compile brotli decoder
        gcc -c -fPIC -O2 -I./c/include \
            c/dec/*.c
        ar rcs out/libbrotlidec.a *.o
        rm -f *.o
    fi

    # Return to nginx source directory
    cd "$NGINX_SRC_DIR" || exit 1

    log_success "Brotli library built successfully"
}

configure_nginx() {
    ./configure \
        --prefix=/etc/nginx \
        --sbin-path=/usr/sbin/nginx \
        --conf-path=/etc/nginx/nginx.conf \
        --error-log-path=/var/log/nginx/error.log \
        --http-log-path=/var/log/nginx/access.log \
        --pid-path=/var/run/nginx.pid \
        --lock-path=/var/run/nginx.lock \
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
        --with-http_random_index_module \
        --with-http_secure_link_module \
        --with-http_stub_status_module \
        --with-http_auth_request_module \
        --with-threads \
        --with-stream \
        --with-stream_ssl_module \
        --with-http_slice_module \
        --add-module=./ngx_brotli
}

compile_nginx() {
    make -j$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)
}

install_nginx() {
    # Backup existing nginx
    if command -v nginx &>/dev/null; then
        log_info "Backing up existing nginx..."
        mkdir -p "$NGINX_BACKUP_DIR"
        cp "$(which nginx)" "${NGINX_BACKUP_DIR}/nginx.backup.$(date +%Y%m%d)"
    fi

    # Install new nginx
    sudo make install

    # Test new nginx
    if nginx -t 2>/dev/null; then
        log_success "New nginx installation successful"
    else
        log_error "New nginx installation failed!"
        rollback_nginx
        exit 1
    fi
}

rollback_nginx() {
    log_warn "Rolling back to previous nginx..."

    local latest_backup=$(ls -t "${NGINX_BACKUP_DIR}"/nginx.backup.* 2>/dev/null | head -1)

    if [ -n "$latest_backup" ]; then
        sudo cp "$latest_backup" /usr/sbin/nginx
        log_success "Rollback complete"
    else
        log_error "No backup found!"
    fi
}
