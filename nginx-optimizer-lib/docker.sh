#!/bin/bash

################################################################################
# docker.sh - Custom Nginx Docker Image Builder
################################################################################

DOCKER_BUILD_DIR="${DATA_DIR}/docker-build"
CUSTOM_IMAGE_NAME="nginx-optimizer"
CUSTOM_IMAGE_TAG="http3-brotli"

################################################################################
# Docker Image Building Functions
################################################################################

build_custom_nginx_image() {
    log_info "Building custom nginx Docker image with HTTP/3 and Brotli..."

    if ! command -v docker &>/dev/null; then
        log_error "Docker not installed"
        return 1
    fi

    mkdir -p "$DOCKER_BUILD_DIR"

    create_nginx_dockerfile

    log_info "Building Docker image..."

    cd "$DOCKER_BUILD_DIR" || exit 1

    if docker build -t "${CUSTOM_IMAGE_NAME}:${CUSTOM_IMAGE_TAG}" -t "${CUSTOM_IMAGE_NAME}:latest" . 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Docker image built successfully"
        log_info "Image: ${CUSTOM_IMAGE_NAME}:${CUSTOM_IMAGE_TAG}"

        # Test the image
        test_docker_image
    else
        log_error "Docker build failed"
        return 1
    fi
}

create_nginx_dockerfile() {
    local dockerfile="${DOCKER_BUILD_DIR}/Dockerfile"

    cat > "$dockerfile" << 'EOF'
FROM nginx:alpine

# Install build dependencies
RUN apk add --no-cache --virtual .build-deps \
    gcc \
    libc-dev \
    make \
    openssl-dev \
    pcre-dev \
    zlib-dev \
    linux-headers \
    libxslt-dev \
    gd-dev \
    geoip-dev \
    perl-dev \
    libedit-dev \
    mercurial \
    bash \
    alpine-sdk \
    findutils \
    git

# Download and build ngx_brotli
WORKDIR /tmp
RUN git clone --recurse-submodules https://github.com/google/ngx_brotli.git

# Get nginx source matching the base image version
RUN NGINX_VERSION=$(nginx -v 2>&1 | grep -oP 'nginx/\K[0-9.]+') && \
    wget http://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz && \
    tar -xzf nginx-${NGINX_VERSION}.tar.gz

# Configure and build nginx with Brotli
RUN NGINX_VERSION=$(nginx -v 2>&1 | grep -oP 'nginx/\K[0-9.]+') && \
    cd nginx-${NGINX_VERSION} && \
    ./configure \
        --prefix=/etc/nginx \
        --sbin-path=/usr/sbin/nginx \
        --modules-path=/usr/lib/nginx/modules \
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
        --with-http_gunzip_module \
        --with-http_gzip_static_module \
        --with-http_stub_status_module \
        --with-threads \
        --with-stream \
        --with-stream_ssl_module \
        --add-dynamic-module=/tmp/ngx_brotli && \
    make && \
    make install

# Clean up
RUN apk del .build-deps && \
    rm -rf /tmp/*

# Copy Brotli modules
RUN cp /usr/lib/nginx/modules/*.so /etc/nginx/modules/ || true

# Expose ports
EXPOSE 80 443 443/udp

# Health check
HEALTHCHECK --interval=30s --timeout=3s \
    CMD wget --quiet --tries=1 --spider http://localhost/ || exit 1

CMD ["nginx", "-g", "daemon off;"]
EOF

    log_info "Dockerfile created: $dockerfile"
}

test_docker_image() {
    log_info "Testing Docker image..."

    # Start test container
    local test_container="nginx-optimizer-test"

    docker run -d --name "$test_container" \
        -p 8888:80 \
        "${CUSTOM_IMAGE_NAME}:${CUSTOM_IMAGE_TAG}" &>/dev/null

    sleep 2

    # Test nginx -t
    if docker exec "$test_container" nginx -t 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Nginx configuration test passed"
    else
        log_error "Nginx configuration test failed"
        docker rm -f "$test_container" &>/dev/null
        return 1
    fi

    # Test HTTP response
    if curl -s http://localhost:8888 &>/dev/null; then
        log_success "HTTP response test passed"
    else
        log_warn "HTTP response test failed (container might still be starting)"
    fi

    # Check for Brotli module
    if docker exec "$test_container" nginx -V 2>&1 | grep -q "brotli"; then
        log_success "Brotli module detected"
    else
        log_warn "Brotli module not detected"
    fi

    # Cleanup
    docker rm -f "$test_container" &>/dev/null

    log_success "Docker image test complete"
}

update_wp_test_with_custom_image() {
    local site="$1"

    log_info "Updating wp-test site to use custom image: $site"

    local compose_file="$WP_TEST_SITES/$site/docker-compose.yml"

    if [ ! -f "$compose_file" ]; then
        log_error "docker-compose.yml not found for $site"
        return 1
    fi

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would update docker-compose.yml to use custom image"
        return
    fi

    # Backup compose file
    cp "$compose_file" "${compose_file}.backup"

    # Update nginx image (if using nginx service)
    if grep -q "image: nginx" "$compose_file"; then
        sed -i.bak "s|image: nginx.*|image: ${CUSTOM_IMAGE_NAME}:${CUSTOM_IMAGE_TAG}|" "$compose_file"
        log_success "Updated $site to use custom nginx image"
    else
        log_info "Site doesn't use nginx image directly"
    fi
}

push_docker_image() {
    local registry="$1"

    if [ -z "$registry" ]; then
        log_error "Registry not specified"
        log_info "Usage: push_docker_image <registry>"
        log_info "Example: push_docker_image docker.io/username"
        return 1
    fi

    log_info "Tagging image for registry: $registry"

    docker tag "${CUSTOM_IMAGE_NAME}:${CUSTOM_IMAGE_TAG}" \
        "${registry}/${CUSTOM_IMAGE_NAME}:${CUSTOM_IMAGE_TAG}"

    docker tag "${CUSTOM_IMAGE_NAME}:latest" \
        "${registry}/${CUSTOM_IMAGE_NAME}:latest"

    log_info "Pushing to registry..."

    docker push "${registry}/${CUSTOM_IMAGE_NAME}:${CUSTOM_IMAGE_TAG}"
    docker push "${registry}/${CUSTOM_IMAGE_NAME}:latest"

    log_success "Image pushed to registry"
}
