#!/bin/bash

################################################################################
# detector.sh - Nginx Detection & Configuration Analysis
################################################################################

# Nginx location patterns
NGINX_LOCATIONS=(
    "/etc/nginx/nginx.conf"
    "/usr/local/etc/nginx/nginx.conf"
    "/opt/nginx/conf/nginx.conf"
    "/usr/local/nginx/conf/nginx.conf"
)

SITE_CONFIGS=(
    "/etc/nginx/sites-enabled/"
    "/etc/nginx/conf.d/"
    "/usr/local/etc/nginx/servers/"
)

# wp-test locations
WP_TEST_NGINX="${HOME}/.wp-test/nginx"
WP_TEST_SITES="${HOME}/.wp-test/sites"

# Store detected instances as "type:name:path" entries
DETECTED_INSTANCES=()

################################################################################
# Detection Functions
################################################################################

add_instance() {
    local type="$1"
    local name="$2"
    local path="$3"
    DETECTED_INSTANCES+=("${type}:${name}:${path}")
}

get_instance_count() {
    echo "${#DETECTED_INSTANCES[@]}"
}

detect_system_nginx() {
    log_info "Checking for system nginx..."

    for conf in "${NGINX_LOCATIONS[@]}"; do
        if [ -f "$conf" ]; then
            log_success "Found system nginx: $conf"
            add_instance "system" "nginx" "$conf"

            if command -v nginx &>/dev/null; then
                local version=$(nginx -v 2>&1 | sed -n 's/.*nginx\/\([0-9.]*\).*/\1/p')
                log_info "  Version: $version"
            fi
            return 0
        fi
    done

    log_info "No system nginx found"
    return 1
}

detect_docker_nginx() {
    log_info "Checking for Docker nginx containers..."

    if ! command -v docker &>/dev/null; then
        log_info "Docker not installed"
        return 1
    fi

    # Check if Docker is running
    if ! docker info &>/dev/null; then
        log_info "Docker not running"
        return 1
    fi

    # Check for nginx containers
    local containers=$(docker ps --filter "ancestor=nginx" --format "{{.Names}}" 2>/dev/null)

    # Also check for wp-test-proxy specifically
    if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "wp-test-proxy"; then
        log_success "Found wp-test nginx-proxy container"
        add_instance "docker" "wp-test-proxy" "wp-test-proxy"
    fi

    if [ -n "$containers" ]; then
        while IFS= read -r container; do
            if [ "$container" != "wp-test-proxy" ]; then
                log_success "Found Docker nginx: $container"
                add_instance "docker" "$container" "$container"
            fi
        done <<< "$containers"
        return 0
    fi

    return 1
}

detect_wp_test_sites() {
    log_info "Checking for wp-test sites..."

    if [ ! -d "$WP_TEST_SITES" ]; then
        log_info "No wp-test sites directory found"
        return 1
    fi

    local site_count=0
    for site_dir in "$WP_TEST_SITES"/*; do
        if [ -d "$site_dir" ] && [ "$(basename "$site_dir")" != ".DS_Store" ]; then
            local domain=$(basename "$site_dir")
            log_success "Found wp-test site: $domain"
            add_instance "wp_test" "$domain" "$site_dir"
            ((site_count++))
        fi
    done

    if [ $site_count -eq 0 ]; then
        log_info "No wp-test sites found"
        return 1
    fi

    # Also check for wp-test nginx config
    if [ -f "$WP_TEST_NGINX/proxy.conf" ]; then
        log_success "Found wp-test nginx config: $WP_TEST_NGINX/proxy.conf"
        add_instance "wp_test_nginx" "proxy" "$WP_TEST_NGINX/proxy.conf"
    fi

    log_success "Found $site_count wp-test site(s)"
    return 0
}

detect_nginx_instances() {
    local target_site="$1"

    log_info "Scanning for nginx installations..."
    echo ""

    # Reset instances array
    DETECTED_INSTANCES=()

    if [ -n "$target_site" ]; then
        # Check if it's a wp-test site
        if [ -d "$WP_TEST_SITES/$target_site" ]; then
            add_instance "wp_test" "$target_site" "$WP_TEST_SITES/$target_site"
            log_success "Target site found: $target_site"
        else
            log_error "Site not found: $target_site"
            exit 1
        fi
    else
        # Detect all (ignore return codes - we accumulate instances)
        detect_system_nginx || true
        detect_docker_nginx || true
        detect_wp_test_sites || true
    fi

    echo ""
    local count=$(get_instance_count)
    if [ "$count" -eq 0 ]; then
        log_warn "No nginx installations detected"
        return 1
    fi

    log_success "Detected $count nginx instance(s)"
    return 0
}

list_nginx_instances() {
    detect_nginx_instances ""

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "Detected NGINX Installations:"
    echo "═══════════════════════════════════════════════════════════"

    for entry in "${DETECTED_INSTANCES[@]}"; do
        local type=$(echo "$entry" | cut -d: -f1)
        local name=$(echo "$entry" | cut -d: -f2)
        local path=$(echo "$entry" | cut -d: -f3-)
        echo "  • [$type] $name: $path"
    done
    echo ""
}

################################################################################
# Configuration Analysis Functions
################################################################################

# Cache for compiled nginx config (to avoid multiple calls to nginx -T)
COMPILED_CONFIG=""

get_compiled_config() {
    if [ -z "$COMPILED_CONFIG" ]; then
        if command -v nginx &>/dev/null; then
            COMPILED_CONFIG=$(nginx -T 2>/dev/null || echo "")
        fi
    fi
    echo "$COMPILED_CONFIG"
}

check_http3_enabled() {
    local config_file="$1"
    local compiled=$(get_compiled_config)

    # Check compiled config first (most reliable)
    if [ -n "$compiled" ] && echo "$compiled" | grep -q "listen.*quic"; then
        return 0
    fi

    # Fallback to file check
    if [ -f "$config_file" ] && grep -q "listen.*quic" "$config_file" 2>/dev/null; then
        return 0
    fi

    return 1
}

check_fastcgi_cache_enabled() {
    local config_file="$1"
    local compiled=$(get_compiled_config)

    # Check compiled config first
    if [ -n "$compiled" ] && echo "$compiled" | grep -q "fastcgi_cache_path"; then
        return 0
    fi

    # Fallback to file check
    if [ -f "$config_file" ] && grep -q "fastcgi_cache_path" "$config_file" 2>/dev/null; then
        return 0
    fi

    return 1
}

check_brotli_enabled() {
    local config_file="$1"
    local compiled=$(get_compiled_config)

    # Check compiled config first
    if [ -n "$compiled" ] && echo "$compiled" | grep -q "brotli on"; then
        return 0
    fi

    # Fallback to file check
    if [ -f "$config_file" ] && grep -q "brotli on" "$config_file" 2>/dev/null; then
        return 0
    fi

    # Check if wp-test-proxy uses brotli-enabled image
    if command -v docker &>/dev/null; then
        if docker ps --filter "name=wp-test-proxy" --format "{{.Image}}" 2>/dev/null | grep -q "brotli"; then
            return 0
        fi
    fi

    return 1
}

check_security_headers() {
    local config_file="$1"
    local compiled=$(get_compiled_config)

    # Check compiled config first
    if [ -n "$compiled" ] && echo "$compiled" | grep -q "Strict-Transport-Security"; then
        return 0
    fi

    # Fallback to file check
    if [ -f "$config_file" ] && grep -q "Strict-Transport-Security" "$config_file" 2>/dev/null; then
        return 0
    fi

    return 1
}

check_rate_limiting() {
    local config_file="$1"
    local compiled=$(get_compiled_config)

    # Check compiled config first
    if [ -n "$compiled" ] && echo "$compiled" | grep -q "limit_req_zone"; then
        return 0
    fi

    # Fallback to file check
    if [ -f "$config_file" ] && grep -q "limit_req_zone" "$config_file" 2>/dev/null; then
        return 0
    fi

    return 1
}

check_wordpress_exclusions() {
    local config_file="$1"
    local compiled=$(get_compiled_config)

    # Check compiled config first
    if [ -n "$compiled" ] && echo "$compiled" | grep -q "xmlrpc"; then
        return 0
    fi

    # Fallback to file check
    if [ -f "$config_file" ] && grep -q "xmlrpc" "$config_file" 2>/dev/null; then
        return 0
    fi

    return 1
}

check_gzip_enabled() {
    local config_file="$1"
    local compiled=$(get_compiled_config)

    # Check compiled config first
    if [ -n "$compiled" ] && echo "$compiled" | grep -q "gzip on"; then
        return 0
    fi

    # Fallback to file check
    if [ -f "$config_file" ] && grep -q "gzip on" "$config_file" 2>/dev/null; then
        return 0
    fi

    return 1
}

check_redis_configured() {
    local site_dir="$1"

    local compose_file="${site_dir}/docker-compose.yml"

    if [ ! -f "$compose_file" ]; then
        return 1
    fi

    if grep -q "redis:" "$compose_file" 2>/dev/null; then
        return 0
    fi

    return 1
}

analyze_config_file() {
    local config_file="$1"
    local instance_name="$2"

    log_info "Analyzing: $instance_name ($config_file)"

    if check_http3_enabled "$config_file"; then
        echo -e "    ${GREEN}✓ HTTP/3 QUIC${NC}"
    else
        echo -e "    ${YELLOW}✗ HTTP/3 QUIC${NC}"
    fi

    if check_fastcgi_cache_enabled "$config_file"; then
        echo -e "    ${GREEN}✓ FastCGI Cache${NC}"
    else
        echo -e "    ${YELLOW}✗ FastCGI Cache${NC}"
    fi

    if check_brotli_enabled "$config_file"; then
        echo -e "    ${GREEN}✓ Brotli Compression${NC}"
    else
        echo -e "    ${YELLOW}✗ Brotli Compression${NC}"
    fi

    if check_gzip_enabled "$config_file"; then
        echo -e "    ${GREEN}✓ Gzip Compression${NC}"
    else
        echo -e "    ${YELLOW}✗ Gzip Compression${NC}"
    fi

    if check_security_headers "$config_file"; then
        echo -e "    ${GREEN}✓ Security Headers${NC}"
    else
        echo -e "    ${YELLOW}✗ Security Headers${NC}"
    fi

    if check_rate_limiting "$config_file"; then
        echo -e "    ${GREEN}✓ Rate Limiting${NC}"
    else
        echo -e "    ${YELLOW}✗ Rate Limiting${NC}"
    fi

    if check_wordpress_exclusions "$config_file"; then
        echo -e "    ${GREEN}✓ WordPress Exclusions${NC}"
    else
        echo -e "    ${YELLOW}✗ WordPress Exclusions${NC}"
    fi

    echo ""
}

analyze_wp_test_site() {
    local site_name="$1"
    local site_dir="$2"

    log_info "Analyzing wp-test site: $site_name"

    # Check nginx proxy config
    local proxy_conf="${WP_TEST_NGINX}/proxy.conf"
    if [ -f "$proxy_conf" ]; then
        analyze_config_file "$proxy_conf" "Proxy Config"
    fi

    # Check vhost config
    local vhost_conf="${WP_TEST_NGINX}/vhost.d/${site_name}"
    if [ -f "$vhost_conf" ]; then
        analyze_config_file "$vhost_conf" "VHost Config ($site_name)"
    else
        log_info "  No custom vhost config for $site_name"
    fi

    # Check Redis
    if check_redis_configured "$site_dir"; then
        echo -e "    ${GREEN}✓ Redis Configured${NC}"
    else
        echo -e "    ${YELLOW}✗ Redis Not Configured${NC}"
    fi

    # Check for docker-compose
    if [ -f "${site_dir}/docker-compose.yml" ]; then
        echo -e "    ${GREEN}✓ Docker Compose Found${NC}"
    fi

    echo ""
}

analyze_optimizations() {
    local target_site="$1"

    # Reset compiled config cache for fresh analysis
    COMPILED_CONFIG=""

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "Configuration Analysis:"
    echo "═══════════════════════════════════════════════════════════"
    echo ""

    for entry in "${DETECTED_INSTANCES[@]}"; do
        local type=$(echo "$entry" | cut -d: -f1)
        local name=$(echo "$entry" | cut -d: -f2)
        local path=$(echo "$entry" | cut -d: -f3-)

        case "$type" in
            wp_test)
                analyze_wp_test_site "$name" "$path"
                ;;
            wp_test_nginx)
                analyze_config_file "$path" "wp-test nginx ($name)"
                ;;
            system)
                analyze_config_file "$path" "System Nginx"
                ;;
            docker)
                log_info "Docker container: $name"
                echo -e "    ${YELLOW}⚠ Manual inspection required for Docker containers${NC}"
                echo ""
                ;;
        esac
    done
}

show_status() {
    local target_site="$1"

    detect_nginx_instances "$target_site"
    analyze_optimizations "$target_site"

    echo "═══════════════════════════════════════════════════════════"
    echo "Legend:"
    echo -e "  ${GREEN}✓${NC} = Enabled"
    echo -e "  ${YELLOW}✗${NC} = Missing (can be optimized)"
    echo "═══════════════════════════════════════════════════════════"
}
