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
RUN NGINX_VERSION=$(nginx -v 2>&1 | sed -n 's/.*nginx\/\([0-9.]*\).*/\1/p') && \
    wget http://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz && \
    tar -xzf nginx-${NGINX_VERSION}.tar.gz

# Configure and build nginx with Brotli
RUN NGINX_VERSION=$(nginx -v 2>&1 | sed -n 's/.*nginx\/\([0-9.]*\).*/\1/p') && \
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

################################################################################
# Safe Docker Compose YAML Manipulation
################################################################################

safe_add_docker_service() {
    local compose_file="$1"
    local service_name="$2"
    local service_definition="$3"

    if [ ! -f "$compose_file" ]; then
        log_error "Compose file not found: $compose_file"
        return 1
    fi

    log_info "Safely adding service '$service_name' to docker-compose.yml"

    # Backup original file
    local backup_file
    backup_file="${compose_file}.backup-$(date +%Y%m%d-%H%M%S)"
    cp "$compose_file" "$backup_file"
    log_info "Backup created: $backup_file"

    # Try yq first (preferred method)
    if command -v yq &>/dev/null; then
        log_info "Using yq for YAML manipulation"

        # Check if service already exists
        if yq eval ".services.${service_name}" "$compose_file" | grep -qv "null"; then
            log_warn "Service '$service_name' already exists in $compose_file"
            rm "$backup_file"
            return 0
        fi

        # Add service using yq
        echo "$service_definition" | yq eval ".services.${service_name} = ." -i "$compose_file"

    # Try Python yaml module as fallback
    elif command -v python3 &>/dev/null && python3 -c "import yaml" 2>/dev/null; then
        log_info "Using Python yaml module"

        python3 << PYEOF
import yaml
import sys

try:
    with open('$compose_file', 'r') as f:
        compose = yaml.safe_load(f) or {}

    if 'services' not in compose:
        compose['services'] = {}

    if '$service_name' in compose['services']:
        print("Service '$service_name' already exists", file=sys.stderr)
        sys.exit(0)

    # Parse service definition
    service_def = yaml.safe_load('''$service_definition''')
    compose['services']['$service_name'] = service_def

    with open('$compose_file', 'w') as f:
        yaml.dump(compose, f, default_flow_style=False, sort_keys=False)

    sys.exit(0)
except Exception as e:
    print(f"Python YAML manipulation failed: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF

        if [ $? -ne 0 ]; then
            log_error "Python YAML manipulation failed, falling back to bash"
            cp "$backup_file" "$compose_file"
        fi

    # Fallback to careful bash parsing
    else
        log_warn "Neither yq nor Python yaml available, using bash fallback"

        # Check if service already exists with proper YAML parsing
        if grep -q "^[[:space:]]*${service_name}:" "$compose_file"; then
            log_warn "Service '$service_name' already exists in $compose_file"
            rm "$backup_file"
            return 0
        fi

        # Check if services section exists
        if ! grep -q "^services:" "$compose_file"; then
            log_error "No 'services:' section found in $compose_file"
            rm "$backup_file"
            return 1
        fi

        # Ensure file ends with newline
        if [ -n "$(tail -c 1 "$compose_file")" ]; then
            echo "" >> "$compose_file"
        fi

        # Add service definition with proper indentation
        cat >> "$compose_file" << EOF

  ${service_name}:
$(echo "$service_definition" | sed 's/^/    /')
EOF
    fi

    # Validate the resulting YAML with docker-compose
    if command -v docker-compose &>/dev/null; then
        log_info "Validating docker-compose.yml syntax"

        if docker-compose -f "$compose_file" config -q 2>/dev/null; then
            log_success "YAML validation passed"
            rm "$backup_file"
            return 0
        else
            log_error "YAML validation failed, restoring backup"
            cp "$backup_file" "$compose_file"
            log_error "Backup file preserved at: $backup_file"
            return 1
        fi
    elif command -v docker &>/dev/null && docker compose version &>/dev/null; then
        log_info "Validating docker-compose.yml syntax (docker compose v2)"

        if docker compose -f "$compose_file" config -q 2>/dev/null; then
            log_success "YAML validation passed"
            rm "$backup_file"
            return 0
        else
            log_error "YAML validation failed, restoring backup"
            cp "$backup_file" "$compose_file"
            log_error "Backup file preserved at: $backup_file"
            return 1
        fi
    else
        log_warn "docker-compose not available, skipping validation"
        log_warn "Backup preserved at: $backup_file"
    fi

    return 0
}

verify_docker_volume_mount() {
    local container_name="$1"
    local host_path="$2"
    local container_path="$3"

    if [ -z "$container_name" ] || [ -z "$host_path" ] || [ -z "$container_path" ]; then
        log_error "verify_docker_volume_mount: missing arguments"
        return 1
    fi

    # Check if container exists and is running
    if ! docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
        log_warn "Container '$container_name' is not running"
        return 1
    fi

    # Check if path is mounted by inspecting container
    if docker inspect "$container_name" --format '{{range .Mounts}}{{.Source}}:{{.Destination}}{{"\n"}}{{end}}' | \
       grep -q "${host_path}:${container_path}"; then
        log_info "Volume mount verified: $host_path -> $container_path"
        return 0
    else
        log_warn "Volume mount NOT found: $host_path -> $container_path"
        log_info "Container mounts:"
        docker inspect "$container_name" --format '{{range .Mounts}}  {{.Source}} -> {{.Destination}}{{"\n"}}{{end}}'
        return 1
    fi
}

verify_path_accessible_in_container() {
    local container_name="$1"
    local container_path="$2"

    if [ -z "$container_name" ] || [ -z "$container_path" ]; then
        log_error "verify_path_accessible_in_container: missing arguments"
        return 1
    fi

    # Check if container exists and is running
    if ! docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
        log_warn "Container '$container_name' is not running"
        return 1
    fi

    # Check if path exists in container
    if docker exec "$container_name" test -d "$container_path" 2>/dev/null; then
        log_info "Path accessible in container: $container_path"
        return 0
    else
        log_warn "Path NOT accessible in container: $container_path"
        return 1
    fi
}
