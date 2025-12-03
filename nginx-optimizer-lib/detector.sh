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

# Cache for nginx -T output (expensive operation)
NGINX_COMPILED_CONFIG=""
NGINX_CONFIG_CACHED=false

################################################################################
# Input Validation Functions
################################################################################

validate_site_name() {
    local name="$1"
    # Only allow alphanumeric, dots, hyphens, and underscores
    if [[ ! "$name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        log_error "Invalid site name '$name': contains illegal characters"
        log_error "Site names can only contain: a-z, A-Z, 0-9, dots, hyphens, underscores"
        return 1
    fi
    # Prevent path traversal attempts
    if [[ "$name" == *".."* ]] || [[ "$name" == "/"* ]]; then
        log_error "Invalid site name '$name': path traversal not allowed"
        return 1
    fi
    return 0
}

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
        # Validate site name to prevent path traversal
        if ! validate_site_name "$target_site"; then
            exit 1
        fi
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

# Get cached nginx -T output (runs once, reuses thereafter)
get_nginx_compiled_config() {
    if [ "$NGINX_CONFIG_CACHED" = false ]; then
        if command -v nginx &>/dev/null; then
            NGINX_COMPILED_CONFIG=$(nginx -T 2>/dev/null || echo "")
        fi
        NGINX_CONFIG_CACHED=true
    fi
    echo "$NGINX_COMPILED_CONFIG"
}

# Reset nginx config cache (call at start of new analysis)
reset_nginx_config_cache() {
    NGINX_COMPILED_CONFIG=""
    NGINX_CONFIG_CACHED=false
}

# Check compiled nginx config using cached output (performance optimization)
check_nginx_compiled() {
    local pattern="$1"
    local config
    config=$(get_nginx_compiled_config)
    if [ -n "$config" ]; then
        if echo "$config" | grep -q "$pattern"; then
            return 0
        fi
    fi
    return 1
}

# Analyze nginx config inside a Docker container using docker exec
analyze_docker_container() {
    local container="$1"

    if [ -z "$container" ]; then
        log_error "Container name required"
        return 1
    fi

    # Check if container is running
    if ! docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^${container}$"; then
        log_warn "Container '$container' is not running"
        return 1
    fi

    log_info "Analyzing Docker container: $container"

    # Try to get nginx config from container
    local config
    config=$(docker exec "$container" nginx -T 2>/dev/null) || {
        log_warn "  Could not retrieve nginx config from container"
        echo -e "    ${YELLOW}⚠ nginx -T failed in container${NC}"
        return 1
    }

    # Check each optimization
    if echo "$config" | grep -qiE "listen.*quic|http3"; then
        echo -e "    ${GREEN}✓ HTTP/3 QUIC${NC}"
    else
        echo -e "    ${YELLOW}✗ HTTP/3 QUIC${NC}"
    fi

    if echo "$config" | grep -qi "fastcgi_cache"; then
        echo -e "    ${GREEN}✓ FastCGI Cache${NC}"
    else
        echo -e "    ${YELLOW}✗ FastCGI Cache${NC}"
    fi

    if echo "$config" | grep -qi "brotli"; then
        echo -e "    ${GREEN}✓ Brotli Compression${NC}"
    else
        echo -e "    ${YELLOW}✗ Brotli Compression${NC}"
    fi

    if echo "$config" | grep -qi "gzip on"; then
        echo -e "    ${GREEN}✓ Gzip Compression${NC}"
    else
        echo -e "    ${YELLOW}✗ Gzip Compression${NC}"
    fi

    if echo "$config" | grep -qi "Strict-Transport-Security"; then
        echo -e "    ${GREEN}✓ Security Headers (HSTS)${NC}"
    else
        echo -e "    ${YELLOW}✗ Security Headers (HSTS)${NC}"
    fi

    if echo "$config" | grep -qi "limit_req"; then
        echo -e "    ${GREEN}✓ Rate Limiting${NC}"
    else
        echo -e "    ${YELLOW}✗ Rate Limiting${NC}"
    fi

    echo ""
    return 0
}

check_http3_enabled() {
    local config_file="$1"

    # Check compiled config first (most reliable)
    if check_nginx_compiled "listen.*quic"; then
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

    # Check compiled config first
    if check_nginx_compiled "fastcgi_cache_path"; then
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

    # Check compiled config first
    if check_nginx_compiled "brotli on"; then
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

    # Check compiled config first
    if check_nginx_compiled "Strict-Transport-Security"; then
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

    # Check compiled config first
    if check_nginx_compiled "limit_req_zone"; then
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

    # Check compiled config first
    if check_nginx_compiled "xmlrpc"; then
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

    # Check compiled config first
    if check_nginx_compiled "gzip on"; then
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
        increment_score 1
    else
        echo -e "    ${YELLOW}✗ HTTP/3 QUIC${NC}"
        increment_score 0
    fi

    if check_fastcgi_cache_enabled "$config_file"; then
        echo -e "    ${GREEN}✓ FastCGI Cache${NC}"
        increment_score 1
    else
        echo -e "    ${YELLOW}✗ FastCGI Cache${NC}"
        increment_score 0
    fi

    if check_brotli_enabled "$config_file"; then
        echo -e "    ${GREEN}✓ Brotli Compression${NC}"
        increment_score 1
    else
        echo -e "    ${YELLOW}✗ Brotli Compression${NC}"
        increment_score 0
    fi

    if check_gzip_enabled "$config_file"; then
        echo -e "    ${GREEN}✓ Gzip Compression${NC}"
        increment_score 1
    else
        echo -e "    ${YELLOW}✗ Gzip Compression${NC}"
        increment_score 0
    fi

    if check_security_headers "$config_file"; then
        echo -e "    ${GREEN}✓ Security Headers${NC}"
        increment_score 1
    else
        echo -e "    ${YELLOW}✗ Security Headers${NC}"
        increment_score 0
    fi

    if check_rate_limiting "$config_file"; then
        echo -e "    ${GREEN}✓ Rate Limiting${NC}"
        increment_score 1
    else
        echo -e "    ${YELLOW}✗ Rate Limiting${NC}"
        increment_score 0
    fi

    if check_wordpress_exclusions "$config_file"; then
        echo -e "    ${GREEN}✓ WordPress Exclusions${NC}"
        increment_score 1
    else
        echo -e "    ${YELLOW}✗ WordPress Exclusions${NC}"
        increment_score 0
    fi

    echo ""
}

# Track already analyzed config files to avoid redundant analysis
declare -a ANALYZED_FILES=()

is_already_analyzed() {
    local file="$1"
    # Handle empty array case for set -u compatibility
    if [ ${#ANALYZED_FILES[@]} -eq 0 ]; then
        return 1
    fi
    for analyzed in "${ANALYZED_FILES[@]}"; do
        if [ "$analyzed" = "$file" ]; then
            return 0
        fi
    done
    return 1
}

mark_as_analyzed() {
    local file="$1"
    ANALYZED_FILES+=("$file")
}

reset_analyzed_files() {
    ANALYZED_FILES=()
}

analyze_wp_test_site() {
    local site_name="$1"
    local site_dir="$2"

    log_info "Analyzing wp-test site: $site_name"

    # Check nginx proxy config (only analyze once across all sites)
    local proxy_conf="${WP_TEST_NGINX}/proxy.conf"
    if [ -f "$proxy_conf" ]; then
        if is_already_analyzed "$proxy_conf"; then
            log_info "  (Proxy config already analyzed above)"
        else
            analyze_config_file "$proxy_conf" "Shared Proxy Config"
            mark_as_analyzed "$proxy_conf"
        fi
    fi

    # Check vhost config (unique per site)
    local vhost_conf="${WP_TEST_NGINX}/vhost.d/${site_name}"
    if [ -f "$vhost_conf" ]; then
        analyze_config_file "$vhost_conf" "VHost Config ($site_name)"
    else
        log_info "  No custom vhost config for $site_name"
    fi

    # Check Redis
    if check_redis_configured "$site_dir"; then
        echo -e "    ${GREEN}✓ Redis Configured${NC}"
        increment_score 1
    else
        echo -e "    ${YELLOW}✗ Redis Not Configured${NC}"
        increment_score 0
    fi

    # Check for docker-compose
    if [ -f "${site_dir}/docker-compose.yml" ]; then
        echo -e "    ${GREEN}✓ Docker Compose Found${NC}"
    fi

    echo ""
}

analyze_optimizations() {
    local target_site="$1"

    # Reset tracking for new analysis
    reset_score
    reset_analyzed_files

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
                analyze_docker_container "$name" || {
                    log_warn "Could not analyze Docker container: $name"
                    echo ""
                }
                ;;
        esac
    done

    # Show optimization score summary
    echo "═══════════════════════════════════════════════════════════"
    echo "Optimization Score:"
    echo -n "  "
    show_optimization_score "$SCORE_ENABLED" "$SCORE_TOTAL"
    echo ""
    echo "Legend:"
    echo -e "  ${GREEN}✓${NC} = Enabled"
    echo -e "  ${YELLOW}✗${NC} = Missing (can be optimized)"
    echo "═══════════════════════════════════════════════════════════"
}

# Global score counters
SCORE_ENABLED=0
SCORE_TOTAL=0

reset_score() {
    SCORE_ENABLED=0
    SCORE_TOTAL=0
}

increment_score() {
    local enabled=$1
    SCORE_TOTAL=$((SCORE_TOTAL + 1))
    if [ "$enabled" = "1" ]; then
        SCORE_ENABLED=$((SCORE_ENABLED + 1))
    fi
}

show_optimization_score() {
    local enabled_count=$1
    local total_count=$2
    local bar_width=10

    if [ "$total_count" -eq 0 ]; then
        echo -e "${YELLOW}No optimizations checked${NC}"
        return
    fi

    local percent=$(( (enabled_count * 100 + total_count / 2) / total_count ))
    local filled=$(( (enabled_count * bar_width) / total_count ))
    local full_block="█"
    local empty_block="░"
    local bar=""

    for ((i = 0; i < bar_width; i++)); do
        if (( i < filled )); then
            bar+=$full_block
        else
            bar+=$empty_block
        fi
    done

    local color
    if (( percent >= 80 )); then
        color=$GREEN
    elif (( percent >= 50 )); then
        color=$YELLOW
    else
        color=$RED
    fi

    echo -e "${color}[${bar}] ${enabled_count}/${total_count} (${percent}%)${NC}"
}

show_status() {
    local target_site="$1"

    reset_score
    detect_nginx_instances "$target_site"
    analyze_optimizations "$target_site"

    echo "═══════════════════════════════════════════════════════════"
    echo "Optimization Score:"
    echo -n "  "
    show_optimization_score "$SCORE_ENABLED" "$SCORE_TOTAL"
    echo ""
    echo "Legend:"
    echo -e "  ${GREEN}✓${NC} = Enabled"
    echo -e "  ${YELLOW}✗${NC} = Missing (can be optimized)"
    echo "═══════════════════════════════════════════════════════════"
}
