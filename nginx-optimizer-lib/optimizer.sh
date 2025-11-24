#!/bin/bash

################################################################################
# optimizer.sh - Core Optimization Logic
################################################################################

# Track applied optimizations
declare -a APPLIED_OPTIMIZATIONS

################################################################################
# Main Optimization Function
################################################################################

apply_optimizations() {
    local target_site="$1"
    local specific_feature="$2"
    local exclude_feature="$3"

    log_info "Applying optimizations..."

    if [ "$DRY_RUN" = true ]; then
        log_warn "DRY RUN MODE - Showing what would be done"
    fi

    # Determine which features to apply
    local features=()

    if [ -n "$specific_feature" ]; then
        features=("$specific_feature")
    else
        features=("http3" "fastcgi-cache" "redis" "brotli" "security" "wordpress" "opcache")

        # Remove excluded feature
        if [ -n "$exclude_feature" ]; then
            local temp_features=()
            for feature in "${features[@]}"; do
                if [ "$feature" != "$exclude_feature" ] && [ -n "$feature" ]; then
                    temp_features+=("$feature")
                fi
            done
            features=("${temp_features[@]}")
        fi
    fi

    log_info "Features to apply: ${features[*]}"
    echo ""

    # Apply each feature
    for feature in "${features[@]}"; do
        case "$feature" in
            http3)
                optimize_http3 "$target_site"
                ;;
            fastcgi-cache)
                optimize_fastcgi_cache "$target_site"
                ;;
            redis)
                optimize_redis "$target_site"
                ;;
            brotli)
                optimize_brotli "$target_site"
                ;;
            security)
                optimize_security "$target_site"
                ;;
            wordpress)
                optimize_wordpress "$target_site"
                ;;
            opcache)
                optimize_opcache "$target_site"
                ;;
            *)
                log_warn "Unknown feature: $feature"
                ;;
        esac
    done

    echo ""
    log_info "Applied ${#APPLIED_OPTIMIZATIONS[@]} optimization(s)"

    # Show what was applied
    if [ ${#APPLIED_OPTIMIZATIONS[@]} -gt 0 ]; then
        echo ""
        echo "Applied Optimizations:"
        for opt in "${APPLIED_OPTIMIZATIONS[@]}"; do
            echo -e "  ${GREEN}✓${NC} $opt"
        done
    fi

    echo ""
}

################################################################################
# HTTP/3 (QUIC) Optimization
################################################################################

optimize_http3() {
    local target_site="$1"

    log_info "Optimizing: HTTP/3 (QUIC)..."

    # Check nginx version
    if command -v nginx &>/dev/null; then
        local version=$(nginx -v 2>&1 | sed -n 's/.*nginx\/\([0-9.]*\).*/\1/p')

        if ! awk -v ver="$version" 'BEGIN { if (ver >= 1.25) exit 0; else exit 1 }'; then
            log_warn "HTTP/3 requires nginx >= 1.25.0 (current: $version)"
            log_info "Consider upgrading nginx or compiling from source"
            return 1
        fi
    fi

    local template="${TEMPLATE_DIR}/http3-quic.conf"

    if [ ! -f "$template" ]; then
        create_http3_template
    fi

    # Apply to wp-test sites
    if [ -n "$target_site" ] && [ -d "$WP_TEST_SITES/$target_site" ]; then
        apply_http3_wp_test "$target_site"
    elif [ -z "$target_site" ]; then
        # Apply to all wp-test sites
        for site_dir in "$WP_TEST_SITES"/*; do
            if [ -d "$site_dir" ]; then
                local site=$(basename "$site_dir")
                apply_http3_wp_test "$site"
            fi
        done
    fi

    # Apply to system nginx
    if [ -f /etc/nginx/nginx.conf ]; then
        apply_http3_system
    fi

    APPLIED_OPTIMIZATIONS+=("HTTP/3 QUIC Support")
    log_success "HTTP/3 optimization complete"
}

create_http3_template() {
    cat > "${TEMPLATE_DIR}/http3-quic.conf" << 'EOF'
# HTTP/3 (QUIC) Configuration

# Enable HTTP/3 on port 443
listen 443 quic reuseport;
listen 443 ssl;

# Enable 0-RTT
ssl_early_data on;

# QUIC-specific settings
quic_retry on;

# Advertise HTTP/3 support
add_header Alt-Svc 'h3=":443"; ma=86400' always;

# Optional: Enable QUIC GSO (Generic Segmentation Offload) for better performance
# quic_gso on;

# HTTP/2 settings (fallback)
http2 on;
EOF

    log_info "Created HTTP/3 template"
}

apply_http3_wp_test() {
    local site="$1"

    log_info "Applying HTTP/3 to wp-test site: $site"

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would configure HTTP/3 for $site"
        return
    fi

    # Update vhost config
    local vhost_dir="${WP_TEST_NGINX}/vhost.d"
    local vhost_file="${vhost_dir}/${site}"

    mkdir -p "$vhost_dir"

    if [ ! -f "$vhost_file" ]; then
        cat > "$vhost_file" << 'EOF'
# HTTP/3 QUIC Configuration
include /etc/nginx/conf.d/http3-quic.conf;
EOF
    else
        if ! grep -q "http3-quic" "$vhost_file"; then
            echo "" >> "$vhost_file"
            echo "# HTTP/3 QUIC Configuration" >> "$vhost_file"
            echo "include /etc/nginx/conf.d/http3-quic.conf;" >> "$vhost_file"
        fi
    fi

    # Copy template to proxy config directory
    local proxy_conf_dir="${WP_TEST_NGINX}/conf.d"
    mkdir -p "$proxy_conf_dir"
    cp "${TEMPLATE_DIR}/http3-quic.conf" "$proxy_conf_dir/"

    log_success "HTTP/3 configured for $site"
}

apply_http3_system() {
    log_info "Applying HTTP/3 to system nginx"

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would configure HTTP/3 for system nginx"
        return
    fi

    # Add HTTP/3 configuration to main nginx.conf or site configs
    # This is a simplified version - production should be more careful
    local nginx_conf="/etc/nginx/nginx.conf"

    if grep -q "listen.*quic" "$nginx_conf"; then
        log_info "HTTP/3 already configured"
        return
    fi

    log_success "HTTP/3 configuration template ready"
    log_info "Manual step: Add HTTP/3 listen directives to your server blocks"
}

################################################################################
# FastCGI Cache Optimization
################################################################################

optimize_fastcgi_cache() {
    local target_site="$1"

    log_info "Optimizing: FastCGI Full-Page Cache..."

    local template="${TEMPLATE_DIR}/fastcgi-cache.conf"

    if [ ! -f "$template" ]; then
        create_fastcgi_cache_template
    fi

    # Create cache directory
    local cache_dir="/var/run/nginx-cache"

    if [ ! -d "$cache_dir" ]; then
        if [ "$DRY_RUN" = false ]; then
            log_info "Creating cache directory: $cache_dir"
            sudo mkdir -p "$cache_dir" 2>/dev/null || mkdir -p "$HOME/.nginx-cache"
            sudo chown -R www-data:www-data "$cache_dir" 2>/dev/null || true
        else
            log_info "[DRY RUN] Would create cache directory: $cache_dir"
        fi
    fi

    # Apply to wp-test sites
    if [ -n "$target_site" ] && [ -d "$WP_TEST_SITES/$target_site" ]; then
        apply_fastcgi_cache_wp_test "$target_site"
    elif [ -z "$target_site" ]; then
        for site_dir in "$WP_TEST_SITES"/*; do
            if [ -d "$site_dir" ]; then
                local site=$(basename "$site_dir")
                apply_fastcgi_cache_wp_test "$site"
            fi
        done
    fi

    APPLIED_OPTIMIZATIONS+=("FastCGI Full-Page Cache")
    log_success "FastCGI cache optimization complete"
}

create_fastcgi_cache_template() {
    cat > "${TEMPLATE_DIR}/fastcgi-cache.conf" << 'EOF'
# FastCGI Cache Configuration for WordPress

# Cache path
fastcgi_cache_path /var/run/nginx-cache levels=1:2 keys_zone=WORDPRESS:100m inactive=60m max_size=512m;
fastcgi_cache_key "$scheme$request_method$host$request_uri";
fastcgi_cache_use_stale error timeout invalid_header http_500;
fastcgi_ignore_headers Cache-Control Expires Set-Cookie;

# Default cache settings
fastcgi_cache_valid 200 60m;
fastcgi_cache_valid 404 10m;

# Cache bypass conditions
set $skip_cache 0;

# POST requests bypass cache
if ($request_method = POST) {
    set $skip_cache 1;
}

# URLs with query strings bypass cache (except common tracking params)
if ($query_string != "") {
    set $skip_cache 1;
}

# Don't cache URIs containing these
if ($request_uri ~* "/wp-admin/|/xmlrpc.php|wp-.*.php|/feed/|index.php|sitemap(_index)?.xml") {
    set $skip_cache 1;
}

# Don't cache logged-in users or recent commenters
if ($http_cookie ~* "comment_author|wordpress_[a-f0-9]+|wp-postpass|wordpress_no_cache|wordpress_logged_in") {
    set $skip_cache 1;
}

# WooCommerce specific
if ($request_uri ~* "/cart/|/checkout/|/my-account/|/wc-api/|/addons/") {
    set $skip_cache 1;
}

if ($http_cookie ~* "woocommerce_items_in_cart|woocommerce_cart_hash|wp_woocommerce_session") {
    set $skip_cache 1;
}

# EDD (Easy Digital Downloads)
if ($request_uri ~* "/checkout/|/purchase-confirmation/|/purchase-history/") {
    set $skip_cache 1;
}

if ($http_cookie ~* "edd_items_in_cart") {
    set $skip_cache 1;
}

# Apply cache bypass
fastcgi_cache_bypass $skip_cache;
fastcgi_no_cache $skip_cache;

# Add cache status header (useful for debugging)
add_header X-FastCGI-Cache $upstream_cache_status;
EOF

    log_info "Created FastCGI cache template"
}

apply_fastcgi_cache_wp_test() {
    local site="$1"

    log_info "Applying FastCGI cache to: $site"

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would configure FastCGI cache for $site"
        return
    fi

    local vhost_file="${WP_TEST_NGINX}/vhost.d/${site}"

    mkdir -p "$(dirname "$vhost_file")"

    if ! grep -q "fastcgi_cache" "$vhost_file" 2>/dev/null; then
        cat >> "$vhost_file" << 'EOF'

# FastCGI Cache Configuration
include /etc/nginx/conf.d/fastcgi-cache.conf;

# Enable cache for PHP
location ~ \.php$ {
    fastcgi_cache WORDPRESS;
}
EOF
    fi

    # Copy template
    cp "${TEMPLATE_DIR}/fastcgi-cache.conf" "${WP_TEST_NGINX}/conf.d/"

    log_success "FastCGI cache configured for $site"
}

################################################################################
# Redis Optimization
################################################################################

optimize_redis() {
    local target_site="$1"

    log_info "Optimizing: Redis Object Cache..."

    if ! command -v docker &>/dev/null; then
        log_warn "Docker not installed, skipping Redis setup"
        return 1
    fi

    if [ -n "$target_site" ] && [ -d "$WP_TEST_SITES/$target_site" ]; then
        apply_redis_wp_test "$target_site"
    elif [ -z "$target_site" ]; then
        for site_dir in "$WP_TEST_SITES"/*; do
            if [ -d "$site_dir" ]; then
                local site=$(basename "$site_dir")
                apply_redis_wp_test "$site"
            fi
        done
    fi

    APPLIED_OPTIMIZATIONS+=("Redis Object Cache")
    log_success "Redis optimization complete"
}

apply_redis_wp_test() {
    local site="$1"
    local compose_file="$WP_TEST_SITES/$site/docker-compose.yml"

    if [ ! -f "$compose_file" ]; then
        log_warn "docker-compose.yml not found for $site"
        return 1
    fi

    log_info "Adding Redis to: $site"

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would add Redis container to $site"
        return
    fi

    # Check if Redis already exists
    if grep -q "redis:" "$compose_file"; then
        log_info "Redis already configured for $site"
        return
    fi

    # Add Redis service to docker-compose.yml
    cat >> "$compose_file" << EOF

  redis:
    image: redis:alpine
    container_name: redis-${site}
    command: redis-server --maxmemory 256mb --maxmemory-policy allkeys-lru
    networks:
      - default
EOF

    log_success "Redis configured for $site"
    log_info "Next steps:"
    log_info "  1. Restart containers: cd $WP_TEST_SITES/$site && docker-compose up -d"
    log_info "  2. Install Redis Object Cache plugin in WordPress"
    log_info "  3. Add to wp-config.php:"
    log_info "     define('WP_REDIS_HOST', 'redis');"
    log_info "     define('WP_REDIS_PORT', 6379);"
}

################################################################################
# Brotli Compression Optimization
################################################################################

optimize_brotli() {
    local target_site="$1"

    log_info "Optimizing: Brotli + Zopfli Compression..."

    # Check if Brotli module is available
    if ! check_brotli_module; then
        log_warn "Brotli module not available"

        if [ "$FORCE" = true ] || ask_yes_no "Compile nginx with Brotli module?"; then
            if type -t compile_nginx_with_brotli &>/dev/null; then
                compile_nginx_with_brotli
            else
                log_error "Compiler library not loaded"
                return 1
            fi
        else
            log_info "Skipping Brotli optimization"
            return 1
        fi
    fi

    local template="${TEMPLATE_DIR}/compression.conf"

    if [ ! -f "$template" ]; then
        create_compression_template
    fi

    # Apply compression config
    apply_compression_config "$target_site"

    APPLIED_OPTIMIZATIONS+=("Brotli + Gzip Compression")
    log_success "Compression optimization complete"
}

check_brotli_module() {
    if command -v nginx &>/dev/null; then
        if nginx -V 2>&1 | grep -q "http_brotli"; then
            return 0
        fi
    fi

    return 1
}

create_compression_template() {
    cat > "${TEMPLATE_DIR}/compression.conf" << 'EOF'
# Compression Configuration

# Brotli dynamic compression
brotli on;
brotli_comp_level 6;
brotli_types
    text/plain
    text/css
    text/xml
    text/javascript
    application/json
    application/javascript
    application/x-javascript
    application/xml
    application/xml+rss
    application/vnd.ms-fontobject
    application/x-font-ttf
    font/opentype
    image/svg+xml
    image/x-icon;

# Brotli static pre-compressed files
brotli_static on;

# Gzip fallback for older browsers
gzip on;
gzip_vary on;
gzip_comp_level 6;
gzip_min_length 1000;
gzip_proxied any;

# Note: gzip_types may already be defined in your main nginx config or proxy.conf
# Comment out or remove this section if you see "duplicate MIME type" warnings
# Uncomment only the additional types not already in your config
# gzip_types
#     text/plain
#     text/css
#     text/xml
#     text/javascript
#     application/json
#     application/javascript
#     application/x-javascript
#     application/xml
#     application/xml+rss
#     application/vnd.ms-fontobject
#     application/x-font-ttf
#     font/opentype
#     image/svg+xml
#     image/x-icon;

gzip_disable "msie6";
EOF

    log_info "Created compression template"
}

apply_compression_config() {
    local target_site="$1"

    log_info "Applying compression configuration..."

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would configure compression"
        return
    fi

    # Apply to wp-test
    if [ -d "$WP_TEST_NGINX" ]; then
        cp "${TEMPLATE_DIR}/compression.conf" "${WP_TEST_NGINX}/conf.d/"
        log_success "Compression configured for wp-test"
    fi

    # Apply to system nginx
    if [ -f /etc/nginx/nginx.conf ]; then
        local nginx_conf_d="/etc/nginx/conf.d"
        if [ -d "$nginx_conf_d" ]; then
            sudo cp "${TEMPLATE_DIR}/compression.conf" "$nginx_conf_d/" 2>/dev/null || true
            log_success "Compression configured for system nginx"
        fi
    fi
}

################################################################################
# Security Headers & Rate Limiting
################################################################################

optimize_security() {
    local target_site="$1"

    log_info "Optimizing: Security Headers & Rate Limiting..."

    local template="${TEMPLATE_DIR}/security-headers.conf"

    if [ ! -f "$template" ]; then
        create_security_template
    fi

    apply_security_config "$target_site"

    APPLIED_OPTIMIZATIONS+=("Security Headers & Rate Limiting")
    log_success "Security optimization complete"
}

create_security_template() {
    cat > "${TEMPLATE_DIR}/security-headers.conf" << 'EOF'
# Security Headers Configuration

# Rate limiting zones
limit_req_zone $binary_remote_addr zone=wp_login:10m rate=15r/m;
limit_req_zone $binary_remote_addr zone=wp_general:10m rate=30r/m;
limit_conn_zone $binary_remote_addr zone=conn_limit:10m;

# Security headers
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;

# CSP for frontend (less strict)
add_header Content-Security-Policy "default-src 'self' 'unsafe-inline' 'unsafe-eval' https: data: 'unsafe-hashes';" always;

# Rate limit wp-login.php
location = /wp-login.php {
    limit_req zone=wp_login burst=5 nodelay;
    fastcgi_pass unix:/var/run/php/php-fpm.sock;
    include fastcgi_params;
}

# General PHP rate limiting
location ~ \.php$ {
    limit_req zone=wp_general burst=10 nodelay;
    limit_conn conn_limit 10;
}
EOF

    log_info "Created security headers template"
}

apply_security_config() {
    local target_site="$1"

    log_info "Applying security configuration..."

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would configure security headers"
        return
    fi

    # Apply to wp-test
    if [ -d "$WP_TEST_NGINX" ]; then
        cp "${TEMPLATE_DIR}/security-headers.conf" "${WP_TEST_NGINX}/conf.d/"
        log_success "Security configured for wp-test"
    fi
}

################################################################################
# WordPress Exclusions
################################################################################

optimize_wordpress() {
    local target_site="$1"

    log_info "Optimizing: WordPress-Specific Exclusions..."

    local template="${TEMPLATE_DIR}/wordpress-exclusions.conf"

    if [ ! -f "$template" ]; then
        create_wordpress_exclusions_template
    fi

    apply_wordpress_config "$target_site"

    # Auto-detect WooCommerce
    if detect_woocommerce "$target_site"; then
        log_info "WooCommerce detected, applying specific rules..."
        apply_woocommerce_rules "$target_site"
    fi

    APPLIED_OPTIMIZATIONS+=("WordPress Security Exclusions")
    log_success "WordPress optimization complete"
}

create_wordpress_exclusions_template() {
    cat > "${TEMPLATE_DIR}/wordpress-exclusions.conf" << 'EOF'
# WordPress Security Exclusions

# Deny access to sensitive files
location ~* /(\.|wp-config\.php|readme\.html|license\.txt) {
    deny all;
}

# Disable XML-RPC
location = /xmlrpc.php {
    deny all;
    access_log off;
    log_not_found off;
}

# Protect wp-includes
location ~* /wp-includes/.*\.php$ {
    deny all;
}

# Protect wp-content uploads from PHP execution
location ~* /wp-content/uploads/.*\.php$ {
    deny all;
}

# Block access to hidden files
location ~ /\. {
    deny all;
    access_log off;
    log_not_found off;
}

# Block access to WordPress config files
location ~* /(wp-config|xmlrpc)\.php$ {
    deny all;
}

# Allow only specific HTTP methods
if ($request_method !~ ^(GET|POST|HEAD|PUT|DELETE|OPTIONS)$) {
    return 444;
}
EOF

    log_info "Created WordPress exclusions template"
}

apply_wordpress_config() {
    local target_site="$1"

    log_info "Applying WordPress exclusions..."

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would configure WordPress exclusions"
        return
    fi

    if [ -d "$WP_TEST_NGINX" ]; then
        cp "${TEMPLATE_DIR}/wordpress-exclusions.conf" "${WP_TEST_NGINX}/conf.d/"
        log_success "WordPress exclusions configured"
    fi
}

detect_woocommerce() {
    local site="$1"

    if [ -z "$site" ]; then
        return 1
    fi

    local wp_dir="$WP_TEST_SITES/$site/wordpress"

    if [ -d "$wp_dir/wp-content/plugins/woocommerce" ]; then
        return 0
    fi

    return 1
}

apply_woocommerce_rules() {
    local site="$1"

    log_info "Applying WooCommerce-specific cache rules..."

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would configure WooCommerce rules"
        return
    fi

    # WooCommerce rules are already in fastcgi-cache.conf
    log_success "WooCommerce rules applied"
}

################################################################################
# PHP OpCache Optimization
################################################################################

optimize_opcache() {
    local target_site="$1"

    log_info "Optimizing: PHP OpCache..."

    local template="${TEMPLATE_DIR}/opcache.ini"

    if [ ! -f "$template" ]; then
        create_opcache_template
    fi

    apply_opcache_config "$target_site"

    APPLIED_OPTIMIZATIONS+=("PHP OpCache (Balanced Mode)")
    log_success "OpCache optimization complete"
}

create_opcache_template() {
    cat > "${TEMPLATE_DIR}/opcache.ini" << 'EOF'
; PHP OpCache Configuration (Balanced Mode)

[opcache]
opcache.enable=1
opcache.enable_cli=1
opcache.memory_consumption=384
opcache.interned_strings_buffer=64
opcache.max_accelerated_files=10000

; Balanced mode: Check for changes every 60 seconds
opcache.revalidate_freq=60
opcache.validate_timestamps=1

opcache.save_comments=1
opcache.fast_shutdown=1
opcache.huge_code_pages=1

; JIT (PHP 8.0+)
opcache.jit_buffer_size=128M
opcache.jit=1255

; Monitoring
opcache.enable_file_override=1
EOF

    log_info "Created OpCache template (Balanced mode)"
}

apply_opcache_config() {
    local target_site="$1"

    log_info "Applying OpCache configuration..."

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would configure OpCache"
        return
    fi

    # Find PHP version
    if command -v php &>/dev/null; then
        local php_version=$(php -v | head -1 | sed -n 's/^PHP \([0-9]\.[0-9]\).*/\1/p')

        if [ -n "$php_version" ]; then
            local php_conf_dir="/etc/php/${php_version}/fpm/conf.d"

            if [ -d "$php_conf_dir" ]; then
                sudo cp "${TEMPLATE_DIR}/opcache.ini" "${php_conf_dir}/99-opcache-optimized.ini" 2>/dev/null || {
                    log_warn "Could not copy to system PHP config (permissions)"
                    cp "${TEMPLATE_DIR}/opcache.ini" "${DATA_DIR}/opcache.ini"
                    log_info "OpCache config saved to: ${DATA_DIR}/opcache.ini"
                    log_info "Manual step: Copy to ${php_conf_dir}/99-opcache-optimized.ini"
                }

                log_success "OpCache configured for PHP ${php_version}"
                log_info "Restart PHP-FPM to apply changes"
            else
                log_warn "PHP config directory not found: $php_conf_dir"
            fi
        fi
    else
        log_warn "PHP not found in PATH"
    fi
}

################################################################################
# Helper Functions
################################################################################

ask_yes_no() {
    local prompt="$1"

    if [ "$FORCE" = true ]; then
        return 0
    fi

    read -rp "$prompt (y/N): " response

    if [[ "$response" =~ ^[Yy]$ ]]; then
        return 0
    fi

    return 1
}
