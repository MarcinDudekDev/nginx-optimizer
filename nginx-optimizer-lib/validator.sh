#!/bin/bash

################################################################################
# validator.sh - Testing & Validation Functions
################################################################################

# Timeout for nginx operations (seconds)
NGINX_TIMEOUT=30

################################################################################
# Timeout Wrapper
################################################################################

run_with_timeout() {
    local timeout_sec="$1"
    shift

    # Try 'timeout' command (GNU coreutils)
    if command -v timeout &>/dev/null; then
        timeout "$timeout_sec" "$@"
        return $?
    fi

    # Fallback: run without timeout (log warning)
    log_warn "timeout command not available, running without timeout"
    "$@"
}

################################################################################
# Configuration Testing
################################################################################

test_nginx_config() {
    local target_site="$1"

    log_info "Testing nginx configuration..."

    # Test system nginx
    if command -v nginx &>/dev/null; then
        log_info "Testing system nginx..."

        if run_with_timeout $NGINX_TIMEOUT nginx -t 2>&1 | tee -a "$LOG_FILE"; then
            log_success "System nginx configuration is valid"
        else
            log_error "System nginx configuration test failed"
            return 1
        fi
    fi

    # Test Docker nginx containers
    if command -v docker &>/dev/null; then
        local containers
        containers=$(docker ps --filter "ancestor=nginx" --format "{{.Names}}" 2>/dev/null)

        if [ -n "$containers" ]; then
            while IFS= read -r container; do
                log_info "Testing Docker nginx: $container..."

                if run_with_timeout $NGINX_TIMEOUT docker exec "$container" nginx -t 2>&1 | tee -a "$LOG_FILE"; then
                    log_success "Docker nginx ($container) configuration is valid"
                else
                    log_error "Docker nginx ($container) configuration test failed"
                    return 1
                fi
            done <<< "$containers"
        fi
    fi

    # Test wp-test proxy
    if docker ps --format "{{.Names}}" | grep -q "wp-test-proxy"; then
        log_info "Testing wp-test nginx-proxy..."

        if run_with_timeout $NGINX_TIMEOUT docker exec wp-test-proxy nginx -t 2>&1 | tee -a "$LOG_FILE"; then
            log_success "wp-test nginx-proxy configuration is valid"
        else
            log_error "wp-test nginx-proxy configuration test failed"
            return 1
        fi
    fi

    log_success "All nginx configurations are valid"
    return 0
}

################################################################################
# HTTP Response Testing
################################################################################

test_http_response() {
    local url="$1"
    local expected_status="${2:-200}"

    log_info "Testing HTTP response: $url"

    local response
    response=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)

    if [ "$response" = "$expected_status" ]; then
        log_success "HTTP $response OK"
        return 0
    else
        log_warn "HTTP $response (expected $expected_status)"
        return 1
    fi
}

test_header_present() {
    local url="$1"
    local header_name="$2"

    log_info "Checking for header: $header_name"

    local header
    header=$(curl -sI "$url" 2>/dev/null | grep -i "^${header_name}:")

    if [ -n "$header" ]; then
        log_success "Header found: $header"
        return 0
    else
        log_warn "Header not found: $header_name"
        return 1
    fi
}

test_http3_support() {
    local domain="$1"

    log_info "Testing HTTP/3 support..."

    # Check for Alt-Svc header
    local alt_svc
    alt_svc=$(curl -sI "https://$domain" 2>/dev/null | grep -i "alt-svc:")

    if echo "$alt_svc" | grep -q "h3"; then
        log_success "HTTP/3 advertised: $alt_svc"
        return 0
    else
        log_warn "HTTP/3 not advertised"
        return 1
    fi
}

test_cache_functionality() {
    local url="$1"

    log_info "Testing cache functionality..."

    # First request (MISS)
    log_info "Request 1: Should be cache MISS"
    local cache1
    cache1=$(curl -sI "$url" 2>/dev/null | grep -i "x-fastcgi-cache:")
    echo "  $cache1"

    # Second request (should be HIT)
    sleep 1
    log_info "Request 2: Should be cache HIT"
    local cache2
    cache2=$(curl -sI "$url" 2>/dev/null | grep -i "x-fastcgi-cache:")
    echo "  $cache2"

    if echo "$cache2" | grep -q "HIT"; then
        log_success "Cache is working (got HIT)"
        return 0
    else
        log_warn "Cache may not be working properly"
        return 1
    fi
}

test_compression() {
    local url="$1"

    log_info "Testing compression..."

    # Check for Brotli
    local brotli
    brotli=$(curl -sI -H "Accept-Encoding: br" "$url" 2>/dev/null | grep -i "content-encoding:")

    if echo "$brotli" | grep -q "br"; then
        log_success "Brotli compression enabled"
    else
        # Check for gzip
        local gzip
        gzip=$(curl -sI -H "Accept-Encoding: gzip" "$url" 2>/dev/null | grep -i "content-encoding:")

        if echo "$gzip" | grep -q "gzip"; then
            log_success "Gzip compression enabled"
        else
            log_warn "No compression detected"
            return 1
        fi
    fi

    return 0
}

test_security_headers() {
    local url="$1"

    log_info "Testing security headers..."

    local headers=(
        "Strict-Transport-Security"
        "X-Frame-Options"
        "X-Content-Type-Options"
        "X-XSS-Protection"
    )

    local passed=0
    local total=${#headers[@]}

    for header in "${headers[@]}"; do
        if test_header_present "$url" "$header"; then
            ((passed++))
        fi
    done

    log_info "Security headers: $passed/$total passed"

    if [ $passed -eq $total ]; then
        log_success "All security headers present"
        return 0
    else
        log_warn "Some security headers missing"
        return 1
    fi
}

################################################################################
# WordPress-Specific Tests
################################################################################

test_wordpress_exclusions() {
    local domain="$1"

    log_info "Testing WordPress exclusions..."

    # Test xmlrpc.php (should be denied)
    log_info "Testing xmlrpc.php block..."
    local xmlrpc_status
    xmlrpc_status=$(curl -s -o /dev/null -w "%{http_code}" "https://$domain/xmlrpc.php" 2>/dev/null)

    if [ "$xmlrpc_status" = "403" ] || [ "$xmlrpc_status" = "404" ]; then
        log_success "xmlrpc.php blocked (HTTP $xmlrpc_status)"
    else
        log_warn "xmlrpc.php not blocked (HTTP $xmlrpc_status)"
    fi

    # Test wp-config.php access (should be denied)
    log_info "Testing wp-config.php protection..."
    local wpconfig_status
    wpconfig_status=$(curl -s -o /dev/null -w "%{http_code}" "https://$domain/wp-config.php" 2>/dev/null)

    if [ "$wpconfig_status" = "403" ] || [ "$wpconfig_status" = "404" ]; then
        log_success "wp-config.php protected (HTTP $wpconfig_status)"
    else
        log_error "wp-config.php accessible! (HTTP $wpconfig_status)"
    fi
}

################################################################################
# Rate Limiting Tests
################################################################################

test_rate_limiting() {
    local url="$1"
    local requests="${2:-20}"

    log_info "Testing rate limiting ($requests requests)..."

    local blocked=0
    local status

    for _ in $(seq 1 $requests); do
        status=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)

        if [ "$status" = "429" ] || [ "$status" = "503" ]; then
            blocked=$((blocked + 1))
        fi
    done

    if [ $blocked -gt 0 ]; then
        log_success "Rate limiting active ($blocked/$requests blocked)"
        return 0
    else
        log_warn "Rate limiting not detected"
        return 1
    fi
}

################################################################################
# SSL/TLS Tests
################################################################################

test_ssl_configuration() {
    local domain="$1"

    log_info "Testing SSL/TLS configuration..."

    # Test SSL connection
    if ! curl -sI "https://$domain" &>/dev/null; then
        log_error "SSL connection failed"
        return 1
    fi

    log_success "SSL connection successful"

    # Check certificate
    local cert_info
    cert_info=$(openssl s_client -connect "$domain:443" -servername "$domain" </dev/null 2>/dev/null | openssl x509 -noout -dates 2>/dev/null)

    if [ -n "$cert_info" ]; then
        log_info "Certificate info:"
        echo "$cert_info" | tee -a "$LOG_FILE"
    fi

    return 0
}

################################################################################
# Comprehensive Site Test
################################################################################

comprehensive_site_test() {
    local domain="$1"
    local url="https://$domain"

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "Comprehensive Site Test: $domain"
    echo "═══════════════════════════════════════════════════════════"
    echo ""

    # Basic connectivity
    test_http_response "$url" 200

    # SSL
    test_ssl_configuration "$domain"

    # HTTP/3
    test_http3_support "$domain"

    # Security headers
    test_security_headers "$url"

    # Compression
    test_compression "$url"

    # Cache
    test_cache_functionality "$url"

    # WordPress exclusions
    test_wordpress_exclusions "$domain"

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    log_info "Test complete"
}

################################################################################
# Health Check
################################################################################

health_check_sites() {
    local target_site="$1"

    log_info "Running post-optimization health check..."

    local failed=0
    local checked=0

    # Check wp-test sites
    if [ -d "$WP_TEST_SITES" ]; then
        for site_dir in "$WP_TEST_SITES"/*; do
            if [ -d "$site_dir" ]; then
                local domain
                domain=$(basename "$site_dir")

                # Skip if targeting specific site and this isn't it
                if [ -n "$target_site" ] && [ "$domain" != "$target_site" ]; then
                    continue
                fi

                ((checked++))
                local url="https://${domain}"

                # Use -k to allow self-signed certs (common in dev)
                local status
                status=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 "$url" 2>/dev/null)

                if [ "$status" = "200" ] || [ "$status" = "301" ] || [ "$status" = "302" ]; then
                    log_success "  $domain: HTTP $status OK"
                else
                    log_error "  $domain: HTTP $status FAILED"
                    ((failed++))
                fi
            fi
        done
    fi

    if [ $checked -eq 0 ]; then
        log_info "No sites to health check"
        return 0
    fi

    if [ $failed -gt 0 ]; then
        log_error "Health check failed: $failed/$checked sites not responding"
        log_warn "Consider running: nginx-optimizer rollback"
        return 1
    fi

    log_success "Health check passed: $checked/$checked sites responding"
    return 0
}

################################################################################
# Reload Functions
################################################################################

reload_nginx() {
    log_info "Reloading nginx..."

    # System nginx
    if command -v nginx &>/dev/null; then
        if command -v systemctl &>/dev/null; then
            if systemctl reload nginx 2>&1 | tee -a "$LOG_FILE"; then
                log_success "System nginx reloaded"
            else
                log_error "Failed to reload system nginx"
                return 1
            fi
        elif command -v service &>/dev/null; then
            if service nginx reload 2>&1 | tee -a "$LOG_FILE"; then
                log_success "System nginx reloaded"
            else
                log_error "Failed to reload system nginx"
                return 1
            fi
        else
            if nginx -s reload 2>&1 | tee -a "$LOG_FILE"; then
                log_success "System nginx reloaded"
            else
                log_error "Failed to reload system nginx"
                return 1
            fi
        fi
    fi

    # Docker containers
    if command -v docker &>/dev/null; then
        # Reload wp-test proxy
        if docker ps --format "{{.Names}}" | grep -q "wp-test-proxy"; then
            log_info "Reloading wp-test nginx-proxy..."
            if docker exec wp-test-proxy nginx -s reload 2>&1 | tee -a "$LOG_FILE"; then
                log_success "wp-test nginx-proxy reloaded"
            else
                log_error "Failed to reload wp-test nginx-proxy"
            fi
        fi

        # Reload other nginx containers
        local containers
        containers=$(docker ps --filter "ancestor=nginx" --format "{{.Names}}" 2>/dev/null)

        if [ -n "$containers" ]; then
            while IFS= read -r container; do
                log_info "Reloading Docker nginx: $container..."
                if docker exec "$container" nginx -s reload 2>&1 | tee -a "$LOG_FILE"; then
                    log_success "Docker nginx ($container) reloaded"
                else
                    log_error "Failed to reload Docker nginx ($container)"
                fi
            done <<< "$containers"
        fi
    fi

    return 0
}

restart_php_fpm() {
    log_info "Restarting PHP-FPM..."

    # Find PHP version
    if command -v systemctl &>/dev/null; then
        local php_services
        php_services=$(systemctl list-units --type=service | grep 'php.*fpm' | awk '{print $1}')

        if [ -n "$php_services" ]; then
            while IFS= read -r service; do
                log_info "Restarting $service..."
                if systemctl restart "$service" 2>&1 | tee -a "$LOG_FILE"; then
                    log_success "PHP-FPM restarted: $service"
                else
                    log_error "Failed to restart: $service"
                fi
            done <<< "$php_services"
        else
            log_info "No PHP-FPM services found"
        fi
    fi
}

validate_and_reload() {
    local target_site="$1"

    log_info "Validating configuration and reloading..."

    # Test configuration first
    if ! test_nginx_config "$target_site"; then
        log_error "Configuration test failed! Not reloading."
        log_error "Rolling back to previous configuration..."

        if [ -n "$CURRENT_BACKUP_DIR" ]; then
            restore_backup "$(basename "$CURRENT_BACKUP_DIR")"
        fi

        exit 1
    fi

    # Reload nginx
    reload_nginx

    # Restart PHP-FPM if OpCache was modified
    restart_php_fpm

    # Run health check after reload
    health_check_sites "$target_site"

    log_success "Validation and reload complete"
}
