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

# Store detected instances (simple arrays for compatibility)
NGINX_INSTANCES=()
OPTIMIZATION_STATUS=()

################################################################################
# Detection Functions
################################################################################

detect_system_nginx() {
    log_info "Checking for system nginx..."

    for conf in "${NGINX_LOCATIONS[@]}"; do
        if [ -f "$conf" ]; then
            log_success "Found system nginx: $conf"
            NGINX_INSTANCES["system"]="$conf"

            if command -v nginx &>/dev/null; then
                local version=$(nginx -v 2>&1 | grep -oP 'nginx/\K[0-9.]+')
                log_info "  Version: $version"

                # Check if HTTP/3 capable
                if awk -v ver="$version" 'BEGIN { if (ver >= 1.25) exit 0; else exit 1 }'; then
                    log_success "  HTTP/3 capable (>= 1.25.0)"
                else
                    log_warn "  HTTP/3 requires nginx >= 1.25.0"
                fi
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

    local containers=$(docker ps --filter "ancestor=nginx" --format "{{.Names}}" 2>/dev/null)

    if [ -n "$containers" ]; then
        while IFS= read -r container; do
            log_success "Found Docker nginx: $container"
            NGINX_INSTANCES["docker_${container}"]="$container"
        done <<< "$containers"
        return 0
    else
        log_info "No Docker nginx containers found"
        return 1
    fi
}

detect_wp_test_sites() {
    log_info "Checking for wp-test sites..."

    if [ ! -d "$WP_TEST_SITES" ]; then
        log_info "No wp-test sites directory found"
        return 1
    fi

    local site_count=0
    for site_dir in "$WP_TEST_SITES"/*; do
        if [ -d "$site_dir" ]; then
            local domain=$(basename "$site_dir")
            log_success "Found wp-test site: $domain"
            NGINX_INSTANCES["wp_test_${domain}"]="$site_dir"
            ((site_count++))
        fi
    done

    if [ $site_count -eq 0 ]; then
        log_info "No wp-test sites found"
        return 1
    fi

    log_success "Found $site_count wp-test site(s)"
    return 0
}

detect_nginx_instances() {
    local target_site="$1"

    log_info "Scanning for nginx installations..."
    echo ""

    if [ -n "$target_site" ]; then
        # Check if it's a wp-test site
        if [ -d "$WP_TEST_SITES/$target_site" ]; then
            NGINX_INSTANCES["wp_test_${target_site}"]="$WP_TEST_SITES/$target_site"
            log_success "Target site found: $target_site"
        else
            log_error "Site not found: $target_site"
            exit 1
        fi
    else
        # Detect all
        detect_system_nginx
        detect_docker_nginx
        detect_wp_test_sites
    fi

    echo ""
    if [ ${#NGINX_INSTANCES[@]} -eq 0 ]; then
        log_warn "No nginx installations detected"
        exit 1
    fi
}

list_nginx_instances() {
    detect_nginx_instances ""

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "Detected NGINX Installations:"
    echo "═══════════════════════════════════════════════════════════"

    for key in "${!NGINX_INSTANCES[@]}"; do
        echo "  • $key: ${NGINX_INSTANCES[$key]}"
    done
    echo ""
}

################################################################################
# Configuration Analysis Functions
################################################################################

check_http3_enabled() {
    local config_file="$1"

    if [ ! -f "$config_file" ]; then
        return 1
    fi

    if grep -q "listen.*quic" "$config_file" 2>/dev/null; then
        return 0
    fi

    return 1
}

check_fastcgi_cache_enabled() {
    local config_file="$1"

    if [ ! -f "$config_file" ]; then
        return 1
    fi

    if grep -q "fastcgi_cache_path" "$config_file" 2>/dev/null; then
        return 0
    fi

    return 1
}

check_brotli_enabled() {
    local config_file="$1"

    if [ ! -f "$config_file" ]; then
        return 1
    fi

    if grep -q "brotli on" "$config_file" 2>/dev/null; then
        return 0
    fi

    # Check if module is loaded
    if grep -q "ngx_http_brotli" "$config_file" 2>/dev/null; then
        return 0
    fi

    return 1
}

check_security_headers() {
    local config_file="$1"

    if [ ! -f "$config_file" ]; then
        return 1
    fi

    if grep -q "Strict-Transport-Security" "$config_file" 2>/dev/null; then
        return 0
    fi

    return 1
}

check_rate_limiting() {
    local config_file="$1"

    if [ ! -f "$config_file" ]; then
        return 1
    fi

    if grep -q "limit_req_zone" "$config_file" 2>/dev/null; then
        return 0
    fi

    return 1
}

check_wordpress_exclusions() {
    local config_file="$1"

    if [ ! -f "$config_file" ]; then
        return 1
    fi

    if grep -q "xmlrpc" "$config_file" 2>/dev/null; then
        return 0
    fi

    return 1
}

check_redis_configured() {
    local site_dir="$1"

    # Check for Redis container in docker-compose.yml
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

    log_info "Analyzing: $instance_name"

    local optimizations=()

    if check_http3_enabled "$config_file"; then
        optimizations+=("✓ HTTP/3 QUIC")
    else
        optimizations+=("✗ HTTP/3 QUIC")
    fi

    if check_fastcgi_cache_enabled "$config_file"; then
        optimizations+=("✓ FastCGI Cache")
    else
        optimizations+=("✗ FastCGI Cache")
    fi

    if check_brotli_enabled "$config_file"; then
        optimizations+=("✓ Brotli Compression")
    else
        optimizations+=("✗ Brotli Compression")
    fi

    if check_security_headers "$config_file"; then
        optimizations+=("✓ Security Headers")
    else
        optimizations+=("✗ Security Headers")
    fi

    if check_rate_limiting "$config_file"; then
        optimizations+=("✓ Rate Limiting")
    else
        optimizations+=("✗ Rate Limiting")
    fi

    if check_wordpress_exclusions "$config_file"; then
        optimizations+=("✓ WordPress Exclusions")
    else
        optimizations+=("✗ WordPress Exclusions")
    fi

    # Print results
    for opt in "${optimizations[@]}"; do
        if [[ "$opt" == ✓* ]]; then
            echo -e "    ${GREEN}${opt}${NC}"
        else
            echo -e "    ${YELLOW}${opt}${NC}"
        fi
    done

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
        analyze_config_file "$vhost_conf" "VHost Config"
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

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "Configuration Analysis:"
    echo "═══════════════════════════════════════════════════════════"
    echo ""

    for key in "${!NGINX_INSTANCES[@]}"; do
        local value="${NGINX_INSTANCES[$key]}"

        if [[ "$key" == wp_test_* ]]; then
            local site_name=$(echo "$key" | sed 's/^wp_test_//')
            analyze_wp_test_site "$site_name" "$value"
        elif [[ "$key" == "system" ]]; then
            analyze_config_file "$value" "System Nginx"
        elif [[ "$key" == docker_* ]]; then
            log_info "Docker container: $value"
            echo -e "    ${YELLOW}⚠ Manual inspection required${NC}"
            echo ""
        fi
    done
}

show_status() {
    local target_site="$1"

    detect_nginx_instances "$target_site"
    analyze_optimizations "$target_site"

    echo "═══════════════════════════════════════════════════════════"
    echo "Legend:"
    echo -e "  ${GREEN}✓${NC} = Enabled"
    echo -e "  ${YELLOW}✗${NC} = Missing"
    echo "═══════════════════════════════════════════════════════════"
}
