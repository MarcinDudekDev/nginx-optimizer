#!/bin/bash

################################################################################
# optimizer.sh - Core Optimization Logic
################################################################################

# Track applied optimizations (initialized empty for set -u compatibility)
declare -a APPLIED_OPTIMIZATIONS=()

reset_applied_optimizations() {
    APPLIED_OPTIMIZATIONS=()
}

# Get human-readable display name for a feature
get_feature_display_name() {
    local feature="$1"
    case "$feature" in
        http3|quic) echo "HTTP/3 (QUIC)" ;;
        fastcgi-cache|fastcgi|cache) echo "FastCGI Full-Page Cache" ;;
        redis) echo "Redis Object Cache" ;;
        brotli|compression) echo "Brotli Compression" ;;
        security|headers) echo "Security Headers" ;;
        wordpress|wp) echo "WordPress Exclusions" ;;
        opcache|php) echo "PHP OpCache" ;;
        www-ssl|www) echo "WWW + SSL Redirect" ;;
        *) echo "$feature" ;;
    esac
}

################################################################################
# Security: Path and File Validation
################################################################################

# Validate nginx config paths to prevent directory traversal
validate_nginx_config_path() {
    local path="$1"
    local resolved
    resolved=$(realpath "$path" 2>/dev/null)

    # Must resolve successfully
    [[ -z "$resolved" ]] && return 1

    # Must be within allowed directories
    case "$resolved" in
        /etc/nginx/*|/usr/local/etc/nginx/*|"$HOME"/.wp-test/*) return 0 ;;
        *) return 1 ;;
    esac
}

# Check if config file is safe to modify (not symlink to outside nginx dirs)
is_safe_config_file() {
    local file="$1"

    # Must exist
    [[ ! -e "$file" ]] && return 1

    # If regular file, check path
    if [[ -f "$file" ]] && [[ ! -L "$file" ]]; then
        validate_nginx_config_path "$file"
        return $?
    fi

    # If symlink, resolve and validate target
    if [[ -L "$file" ]]; then
        local target
        target=$(readlink -f "$file" 2>/dev/null)
        [[ -z "$target" ]] && return 1

        # Target must be regular file
        [[ ! -f "$target" ]] && return 1

        # Validate target path
        validate_nginx_config_path "$target"
        return $?
    fi

    # Not a regular file or symlink
    return 1
}

################################################################################
# Atomic File Operations & Transaction Helpers
################################################################################

# Transaction state tracking
declare -a TRANSACTION_FILES=()
declare -a TRANSACTION_TEMPS=()
TRANSACTION_ACTIVE=false

# Atomic write: write to temp file in same dir, then atomically mv
# Usage: atomic_write_file <target_path> <content_or_source_file>
atomic_write_file() {
    local target_path="$1"
    local source="$2"

    # Create temp file in same directory as target (ensures same filesystem)
    local target_dir
    target_dir=$(dirname "$target_path")
    local temp_file
    temp_file=$(mktemp "${target_dir}/.nginx-opt.XXXXXX")

    # Copy content to temp file
    if [ -f "$source" ]; then
        # Source is a file, copy it
        cp "$source" "$temp_file"
    else
        # Source is content, write it
        echo "$source" > "$temp_file"
    fi

    # Preserve permissions if target exists
    if [ -f "$target_path" ]; then
        chmod --reference="$target_path" "$temp_file" 2>/dev/null || \
        chown --reference="$target_path" "$temp_file" 2>/dev/null || true
    fi

    # Atomic move (POSIX guarantees atomicity on same filesystem)
    mv "$temp_file" "$target_path"
}

# Start transaction: prepare to modify multiple files atomically
transaction_start() {
    TRANSACTION_FILES=()
    TRANSACTION_TEMPS=()
    TRANSACTION_ACTIVE=true
}

# Add file to transaction: creates temp copy
# Usage: transaction_add_file <original_path>
transaction_add_file() {
    local original_path="$1"

    if [ ! "$TRANSACTION_ACTIVE" = true ]; then
        log_error "No active transaction. Call transaction_start first."
        return 1
    fi

    # Create temp file in same directory
    local target_dir
    target_dir=$(dirname "$original_path")
    local temp_file
    temp_file=$(mktemp "${target_dir}/.nginx-opt-txn.XXXXXX")

    # Copy original if it exists
    if [ -f "$original_path" ]; then
        cp "$original_path" "$temp_file"
        chmod --reference="$original_path" "$temp_file" 2>/dev/null || true
        if command -v chown &>/dev/null; then
            chown --reference="$original_path" "$temp_file" 2>/dev/null || true
        fi
    fi

    # Track this file
    TRANSACTION_FILES+=("$original_path")
    TRANSACTION_TEMPS+=("$temp_file")

    # Return temp file path
    echo "$temp_file"
}

# Commit transaction: atomically move all temp files to originals
transaction_commit() {
    if [ ! "$TRANSACTION_ACTIVE" = true ]; then
        log_error "No active transaction to commit"
        return 1
    fi

    local count=${#TRANSACTION_FILES[@]}

    # Atomically move all files
    for ((i=0; i<count; i++)); do
        local original="${TRANSACTION_FILES[$i]}"
        local temp="${TRANSACTION_TEMPS[$i]}"

        if [ -f "$temp" ]; then
            mv "$temp" "$original"
        fi
    done

    # Clear transaction state
    TRANSACTION_FILES=()
    TRANSACTION_TEMPS=()
    TRANSACTION_ACTIVE=false

    return 0
}

# Rollback transaction: delete all temp files, abort changes
transaction_rollback() {
    if [ ! "$TRANSACTION_ACTIVE" = true ]; then
        return 0
    fi

    # Delete all temp files
    for temp in "${TRANSACTION_TEMPS[@]}"; do
        rm -f "$temp"
    done

    # Clear transaction state
    TRANSACTION_FILES=()
    TRANSACTION_TEMPS=()
    TRANSACTION_ACTIVE=false

    log_info "Transaction rolled back"
}

################################################################################
# Cache Management
################################################################################

purge_cached_templates() {
    log_info "Purging cached templates to ensure fresh configuration..."

    # List of dynamically generated templates that should be refreshed
    local templates=(
        "compression.conf"
        "security-headers.conf"
        "security-http.conf"
        "fastcgi-cache.conf"
        "http3-quic.conf"
        "wordpress-exclusions.conf"
        "opcache.ini"
    )

    local purged=0
    for template in "${templates[@]}"; do
        local template_path="${TEMPLATE_DIR}/${template}"
        if [ -f "$template_path" ]; then
            # Don't purge if template is referenced by includes in sites-enabled
            if [ -d "/etc/nginx/sites-enabled" ]; then
                if grep -rq "include.*${template}" /etc/nginx/sites-enabled/ 2>/dev/null; then
                    log_info "Keeping $template (in use by sites-enabled)"
                    continue
                fi
            fi
            rm -f "$template_path"
            purged=$((purged + 1))
        fi
    done

    if [ $purged -gt 0 ]; then
        log_info "Purged $purged cached template(s)"
    else
        log_info "No cached templates to purge"
    fi
}

ensure_referenced_templates() {
    # If includes exist in sites-enabled but templates don't, recreate them
    if [ ! -d "/etc/nginx/sites-enabled" ]; then
        return
    fi

    # Check for security-headers.conf references
    if grep -rq "include.*security-headers.conf" /etc/nginx/sites-enabled/ 2>/dev/null; then
        if [ ! -f "${TEMPLATE_DIR}/security-headers.conf" ]; then
            log_info "Recreating security-headers.conf (referenced by includes)"
            create_security_template
        fi
    fi

    # Check for wordpress-exclusions.conf references
    if grep -rq "include.*wordpress-exclusions.conf" /etc/nginx/sites-enabled/ 2>/dev/null; then
        if [ ! -f "${TEMPLATE_DIR}/wordpress-exclusions.conf" ]; then
            log_info "Recreating wordpress-exclusions.conf (referenced by includes)"
            create_wordpress_exclusions_template
        fi
    fi
}

################################################################################
# Server Block Injection
################################################################################

inject_server_includes() {
    local include_file="$1"
    local include_name="$2"
    local sites_dir="/etc/nginx/sites-enabled"

    if [ ! -d "$sites_dir" ]; then
        log_warn "No sites-enabled directory found at $sites_dir"
        return 1
    fi

    # Phase 1: Collect files to modify
    local -a files_to_modify=()
    for site_conf in "$sites_dir"/*; do
        [ -f "$site_conf" ] || continue

        # SECURITY: Validate file is safe to modify
        if ! is_safe_config_file "$site_conf"; then
            log_warn "Skipping unsafe config file: $(basename "$site_conf")"
            continue
        fi

        # SECURITY FIX: Check for exact include directive (anchored regex)
        # Use proper regex to avoid false positives
        if grep -qE "^[[:space:]]*include[[:space:]]+[^#]*${include_name}[[:space:]]*;" "$site_conf" 2>/dev/null; then
            log_info "Already included in: $(basename "$site_conf")"
            continue
        fi

        # SECURITY FIX: Check if file contains UNCOMMENTED server block
        # Skip commented lines to prevent injection into comments
        if ! grep -vE '^[[:space:]]*#' "$site_conf" 2>/dev/null | grep -q "server[[:space:]]*{"; then
            log_info "No uncommented server block in: $(basename "$site_conf")"
            continue
        fi

        files_to_modify+=("$site_conf")
    done

    if [ ${#files_to_modify[@]} -eq 0 ]; then
        log_info "No new injections needed"
        return 0
    fi

    # Phase 2: Start transaction and prepare all changes
    transaction_start

    local -a temp_files=()
    for site_conf in "${files_to_modify[@]}"; do
        # Add to transaction
        local temp_file
        temp_file=$(transaction_add_file "$site_conf")
        temp_files+=("$temp_file")

        # SECURITY FIX: Use awk to inject after first UNCOMMENTED server block
        # This prevents injection into commented sections
        awk -v include_line="    include ${include_file};" '
        BEGIN { injected = 0 }
        {
            line = $0
            print line

            # Skip commented lines
            if (line ~ /^[[:space:]]*#/) next

            # Inject after first uncommented "server {"
            if (!injected && line ~ /server[[:space:]]*\{/) {
                print include_line
                injected = 1
            }
        }' "$site_conf" > "${temp_file}.new"
        mv "${temp_file}.new" "$temp_file"
    done

    # Phase 3: Validate with nginx -t (if possible)
    # First commit to temp location for testing
    local validation_failed=false
    if command -v nginx &>/dev/null && [ -n "${files_to_modify[0]}" ]; then
        # Create backup copies for validation test
        for ((i=0; i<${#files_to_modify[@]}; i++)); do
            local original="${files_to_modify[$i]}"
            local temp="${temp_files[$i]}"
            sudo cp "$original" "${original}.txn-backup" 2>/dev/null || true
            sudo cp "$temp" "$original" 2>/dev/null || true
        done

        # Test nginx config
        if ! sudo nginx -t 2>&1 | grep -q "test is successful"; then
            log_error "nginx -t validation failed, rolling back changes"
            validation_failed=true

            # Restore backups
            for original in "${files_to_modify[@]}"; do
                sudo mv "${original}.txn-backup" "$original" 2>/dev/null || true
            done
        else
            # Restore backups (we'll commit properly below)
            for original in "${files_to_modify[@]}"; do
                sudo mv "${original}.txn-backup" "$original" 2>/dev/null || true
            done
        fi
    fi

    # Phase 4: Commit or rollback
    if [ "$validation_failed" = true ]; then
        transaction_rollback
        return 1
    fi

    # Commit transaction - atomically move all temp files
    local injected=0
    for ((i=0; i<${#files_to_modify[@]}; i++)); do
        local original="${files_to_modify[$i]}"
        local temp="${temp_files[$i]}"

        # Atomic move with sudo if needed
        if sudo mv "$temp" "$original" 2>/dev/null; then
            log_success "Injected into: $(basename "$original")"
            injected=$((injected + 1))
        else
            log_error "Failed to commit: $(basename "$original")"
        fi
    done

    transaction_commit

    if [ $injected -gt 0 ]; then
        log_info "Injected into $injected server block(s)"
    fi

    return 0
}

################################################################################
# Main Optimization Function
################################################################################

apply_optimizations() {
    local target_site="$1"
    local specific_feature="$2"
    local exclude_feature="$3"

    # Reset tracking
    reset_applied_optimizations

    # Show header if UI functions available
    if type -t ui_header &>/dev/null; then
        ui_header

        if [ "$DRY_RUN" = true ]; then
            ui_warn_box "DRY RUN MODE - No changes will be made"
        fi
        ui_blank
    else
        log_info "Applying optimizations..."
        if [ "$DRY_RUN" = true ]; then
            log_warn "DRY RUN MODE - Showing what would be done"
        fi
    fi

    # Show target info
    local site_count=0
    if [ -n "$target_site" ]; then
        site_count=1
    elif [ -d "$WP_TEST_SITES" ]; then
        site_count=$(find "$WP_TEST_SITES" -maxdepth 1 -type d ! -name "$(basename "$WP_TEST_SITES")" 2>/dev/null | wc -l | tr -d ' ')
    fi

    if type -t ui_context &>/dev/null; then
        if [ -n "$specific_feature" ]; then
            ui_context "Optimizing" "$(get_feature_display_name "$specific_feature")"
        else
            ui_context "Optimizing" "All features"
        fi
        ui_context "Target" "${target_site:-All sites} (${site_count} found)"
    else
        if [ -n "$target_site" ]; then
            log_info "Target: ${target_site}"
        else
            log_info "Target: All sites"
        fi
    fi

    # Preparation phase
    if type -t ui_section &>/dev/null; then
        ui_section "Preparing..."
    fi

    # Purge cached templates to avoid stale config issues
    local purged_count
    purged_count=$(purge_cached_templates 2>&1 | grep -oE '[0-9]+' | tail -1 || echo "0")
    if type -t ui_step &>/dev/null; then
        ui_step "Prerequisites satisfied"
        if [ "${purged_count:-0}" -gt 0 ]; then
            ui_step "Cached templates purged" "${purged_count} files"
        fi
    fi

    # Ensure templates exist if referenced by includes in sites-enabled
    ensure_referenced_templates

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

    # Show features section
    if type -t ui_section &>/dev/null; then
        if [ -n "$specific_feature" ]; then
            ui_section "Applying $(get_feature_display_name "$specific_feature")..."
        else
            ui_section "Applying optimizations..."
        fi
    else
        log_info "Features to apply: ${features[*]}"
        echo ""
    fi

    # Apply each feature (with common aliases)
    for feature in "${features[@]}"; do
        case "$feature" in
            http3|quic)
                optimize_http3 "$target_site"
                ;;
            fastcgi-cache|fastcgi|cache)
                optimize_fastcgi_cache "$target_site"
                ;;
            redis)
                optimize_redis "$target_site"
                ;;
            brotli|compression)
                optimize_brotli "$target_site"
                ;;
            security|headers)
                optimize_security "$target_site"
                ;;
            wordpress|wp)
                optimize_wordpress "$target_site"
                ;;
            opcache|php)
                optimize_opcache "$target_site"
                ;;
            www-ssl|www)
                optimize_www_ssl "$target_site"
                ;;
            *)
                log_warn "Unknown feature: $feature"
                log_info "Valid features: http3, fastcgi-cache, redis, brotli, security, wordpress, opcache, www-ssl"
                ;;
        esac
    done

    # Summary
    local applied_count=0
    if [ ${#APPLIED_OPTIMIZATIONS[@]} -gt 0 ] 2>/dev/null; then
        applied_count=${#APPLIED_OPTIMIZATIONS[@]}
    fi

    ui_blank

    if [ "$applied_count" -gt 0 ] && type -t ui_success_box &>/dev/null; then
        # Build summary lines
        local summary_lines=()
        summary_lines+=("Applied ${applied_count} optimization(s):")
        for opt in "${APPLIED_OPTIMIZATIONS[@]}"; do
            summary_lines+=("  ${UI_BULLET:-•} $opt")
        done
        summary_lines+=("")
        # Shorten log path for display
        local short_log="${LOG_FILE/#$HOME/~}"
        summary_lines+=("Log: ${short_log}")

        ui_success_box "Optimization complete" "${summary_lines[@]}"
    else
        log_info "Applied ${applied_count} optimization(s)"

        # Show what was applied
        if [ "$applied_count" -gt 0 ]; then
            echo ""
            echo "Applied Optimizations:"
            for opt in "${APPLIED_OPTIMIZATIONS[@]}"; do
                echo -e "  ${GREEN}✓${NC} $opt"
            done
        fi
        echo ""
    fi
}

################################################################################
# HTTP/3 (QUIC) Optimization
################################################################################

optimize_http3() {
    local target_site="$1"

    log_info "Optimizing: HTTP/3 (QUIC)..."

    # Check nginx version
    if command -v nginx &>/dev/null; then
        local version
        version=$(nginx -v 2>&1 | sed -n 's/.*nginx\/\([0-9.]*\).*/\1/p')

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
                local site
                site=$(basename "$site_dir")
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

    # Check if this is a local development environment
    if [[ "$site" =~ \.(loc|local|test|localhost)$ ]]; then
        log_warn "HTTP/3 configured but browsers block it with self-signed certs"
        log_info "HTTP/3 will work in production with CA-signed certificates"
        log_info "Local development will use HTTP/2 (this is expected)"
    fi
}

apply_http3_system() {
    log_info "Applying HTTP/3 to system nginx"

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would configure HTTP/3 for system nginx"
        return
    fi

    # Auto-inject HTTP/3 into server blocks
    if [ -d "/etc/nginx/sites-enabled" ]; then
        log_info "Auto-injecting HTTP/3 into server blocks..."

        # Check if ANY config already has reuseport on quic (can only be set once globally)
        local reuseport_exists=false
        if grep -r "quic.*reuseport\|reuseport.*quic" /etc/nginx/sites-enabled/ 2>/dev/null | grep -qv '^\s*#'; then
            reuseport_exists=true
            log_info "reuseport already configured, new sites will use plain quic"
        fi

        local first_site=true
        for site_conf in /etc/nginx/sites-enabled/*; do
            [ -f "$site_conf" ] || continue

            # Skip if already has HTTP/3
            if grep -q "listen.*quic" "$site_conf" 2>/dev/null; then
                log_info "Already has HTTP/3: $(basename "$site_conf")"
                continue
            fi

            # Skip if no UNCOMMENTED SSL configured (HTTP/3 requires SSL)
            # Use grep to find uncommented listen 443 ssl lines
            if ! grep -v '^\s*#' "$site_conf" 2>/dev/null | grep -q "listen.*443.*ssl"; then
                log_info "No SSL config, skipping: $(basename "$site_conf")"
                continue
            fi

            # Determine quic directive (reuseport only if not already used anywhere)
            local quic_directive quic_directive_v6
            if [ "$first_site" = true ] && [ "$reuseport_exists" = false ]; then
                quic_directive="listen 443 quic reuseport;"
                quic_directive_v6="listen [::]:443 quic reuseport;"
                first_site=false
            else
                quic_directive="listen 443 quic;"
                quic_directive_v6="listen [::]:443 quic;"
            fi

            # Use awk to inject HTTP/3 after SSL listen directives
            # Handle both IPv4 and IPv6 listen directives
            # Skip commented lines

            # Backup this specific file first
            local file_backup="${site_conf}.http3bak"
            sudo cp "$site_conf" "$file_backup"

            # Create temp file with injections
            sudo awk -v quic="$quic_directive" -v quic_v6="$quic_directive_v6" '
            {
                line = $0
                print line

                # Skip commented lines
                if (line ~ /^[[:space:]]*#/) next

                # After "listen 443 ssl" (IPv4), add quic
                if (line ~ /listen[[:space:]]+443[[:space:]]+ssl/ && line !~ /\[::\]/) {
                    print "    " quic
                    print "    add_header Alt-Svc '\''h3=\":443\"; ma=86400'\'' always;"
                }
                # After "listen [::]:443 ssl" (IPv6), add quic for IPv6
                else if (line ~ /listen[[:space:]]+\[::\]:443[[:space:]]+ssl/) {
                    print "    " quic_v6
                }
            }' "$site_conf" | sudo tee "${site_conf}.tmp" > /dev/null

            sudo mv "${site_conf}.tmp" "$site_conf"

            # Test this specific config
            if nginx -t 2>&1 | grep -q "test failed\|emerg"; then
                log_error "HTTP/3 injection failed for $(basename "$site_conf"), restoring..."
                sudo mv "$file_backup" "$site_conf"
                continue
            fi

            sudo rm -f "$file_backup"
            log_success "HTTP/3 injected into: $(basename "$site_conf")"
        done
    else
        log_success "HTTP/3 configuration template ready"
        log_info "Manual step: Add HTTP/3 listen directives to your server blocks"
    fi
}

################################################################################
# FastCGI Cache Optimization
################################################################################

optimize_fastcgi_cache() {
    local target_site="$1"

    # Log to file (detailed)
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Optimizing: FastCGI Full-Page Cache..." >> "${LOG_FILE:-/dev/null}"

    local template="${TEMPLATE_DIR}/fastcgi-cache.conf"

    if [ ! -f "$template" ]; then
        create_fastcgi_cache_template
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Created cache template" "fastcgi-cache.conf"
        fi
    fi

    # Create cache directory
    local cache_dir="/var/run/nginx-cache"

    if [ ! -d "$cache_dir" ]; then
        if [ "$DRY_RUN" = false ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Creating cache directory: $cache_dir" >> "${LOG_FILE:-/dev/null}"
            sudo mkdir -p "$cache_dir" 2>/dev/null || mkdir -p "$HOME/.nginx-cache"
            sudo chown -R www-data:www-data "$cache_dir" 2>/dev/null || true
            if type -t ui_step_path &>/dev/null; then
                ui_step_path "Created cache directory" "$cache_dir"
            fi
        else
            if type -t ui_step_path &>/dev/null; then
                ui_step_path "Would create cache dir" "$cache_dir"
            fi
        fi
    fi

    # Apply to wp-test sites
    local sites_updated=0
    if [ -n "$target_site" ] && [ -d "$WP_TEST_SITES/$target_site" ]; then
        apply_fastcgi_cache_wp_test "$target_site"
        sites_updated=1
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Configured site" "$target_site"
        fi
    elif [ -z "$target_site" ]; then
        for site_dir in "$WP_TEST_SITES"/*; do
            if [ -d "$site_dir" ]; then
                local site
                site=$(basename "$site_dir")
                apply_fastcgi_cache_wp_test "$site"
                ((sites_updated++))
                if type -t ui_step_path &>/dev/null; then
                    ui_step_path "Configured site" "$site"
                fi
            fi
        done
    fi

    APPLIED_OPTIMIZATIONS+=("FastCGI Full-Page Cache")
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [SUCCESS] FastCGI cache optimization complete" >> "${LOG_FILE:-/dev/null}"
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

    # Log to file only (UI handled by parent)
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Created FastCGI cache template" >> "${LOG_FILE:-/dev/null}"
}

apply_fastcgi_cache_wp_test() {
    local site="$1"

    # Log to file only (UI handled by parent function)
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Applying FastCGI cache to: $site" >> "${LOG_FILE:-/dev/null}"

    if [ "$DRY_RUN" = true ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DRY RUN] Would configure FastCGI cache for $site" >> "${LOG_FILE:-/dev/null}"
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
                local site
                site=$(basename "$site_dir")
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

    # Use safe YAML manipulation function
    local redis_definition="image: redis:alpine
container_name: redis-${site}
command: redis-server --maxmemory 256mb --maxmemory-policy allkeys-lru
networks:
  - default"

    if safe_add_docker_service "$compose_file" "redis" "$redis_definition"; then
        log_success "Redis configured for $site"
        log_info "Next steps:"
        log_info "  1. Restart containers: cd $WP_TEST_SITES/$site && docker-compose up -d"
        log_info "  2. Install Redis Object Cache plugin in WordPress"
        log_info "  3. Add to wp-config.php:"
        log_info "     define('WP_REDIS_HOST', 'redis');"
        log_info "     define('WP_REDIS_PORT', 6379);"
    else
        log_error "Failed to add Redis service to docker-compose.yml"
        return 1
    fi
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
        # Check for ngx_brotli module (compiled from source)
        if nginx -V 2>&1 | grep -qi "brotli"; then
            return 0
        fi
    fi

    return 1
}

create_compression_template() {
    cat > "${TEMPLATE_DIR}/compression.conf" << 'EOF'
# Brotli Compression Configuration
# Note: Gzip is typically already configured in nginx.conf

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

# Brotli static pre-compressed files (serve .br files if available)
brotli_static on;
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
    # Determine which CSP to use based on --strict-csp flag or STRICT_CSP env var
    local use_strict_csp="${STRICT_CSP:-false}"

    # Create STRICT CSP template (proper security without unsafe-*)
    cat > "${TEMPLATE_DIR}/csp-strict.conf" << 'EOF'
# Strict Content Security Policy (Recommended for new sites)
# WARNING: This may break sites that rely on inline scripts/styles
# Test thoroughly before deploying to production

add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data: https:; font-src 'self'; connect-src 'self'; frame-ancestors 'self';" always;
EOF

    # Create LEGACY CSP template (permissive for compatibility)
    cat > "${TEMPLATE_DIR}/csp-legacy.conf" << 'EOF'
# Legacy Content Security Policy (Permissive for compatibility)
# WARNING: Using 'unsafe-inline', 'unsafe-eval', and 'unsafe-hashes' together
# defeats the purpose of CSP and provides minimal XSS protection.
#
# This is provided for legacy compatibility only. For new sites, use csp-strict.conf
# To use strict CSP: Set STRICT_CSP=true or use --strict-csp flag

add_header Content-Security-Policy "default-src 'self' 'unsafe-inline' 'unsafe-eval' https: data: 'unsafe-hashes';" always;
EOF

    # Choose which CSP to include in main security-headers.conf
    local csp_include="csp-legacy.conf"
    if [ "$use_strict_csp" = "true" ]; then
        csp_include="csp-strict.conf"
        log_info "Using STRICT CSP (proper XSS protection)"
    else
        log_warn "Using LEGACY CSP with unsafe-* directives (weak XSS protection)"
        log_info "For better security, use: STRICT_CSP=true or --strict-csp flag"
        log_info "Test strict CSP first: include ${TEMPLATE_DIR}/csp-strict.conf;"
    fi

    # Full template for wp-test (inside server blocks)
    cat > "${TEMPLATE_DIR}/security-headers.conf" << EOF
# Security Headers Configuration (for server context)

# Rate limiting zones (must be in http context - add to main config)
# limit_req_zone \$binary_remote_addr zone=wp_login:10m rate=15r/m;
# limit_req_zone \$binary_remote_addr zone=wp_general:10m rate=30r/m;
# limit_conn_zone \$binary_remote_addr zone=conn_limit:10m;

# Security headers
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;

# Content Security Policy
# Choose between strict (secure) or legacy (compatible):
# include ${TEMPLATE_DIR}/csp-strict.conf;  # Recommended for new sites
include ${TEMPLATE_DIR}/${csp_include};      # Current selection
EOF

    # HTTP context template for system nginx (conf.d)
    cat > "${TEMPLATE_DIR}/security-http.conf" << 'EOF'
# Security Configuration - HTTP Context
# Place in /etc/nginx/conf.d/

# Rate limiting zones
limit_req_zone $binary_remote_addr zone=wp_login:10m rate=15r/m;
limit_req_zone $binary_remote_addr zone=wp_general:10m rate=30r/m;
limit_conn_zone $binary_remote_addr zone=conn_limit:10m;
EOF

    log_info "Created security headers templates (strict + legacy CSP)"
}

apply_security_config() {
    local target_site="$1"

    log_info "Applying security configuration..."

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would configure security headers"
        return
    fi

    # Apply to wp-test - use consolidated vhost default template
    # nginx-proxy includes EITHER site-specific OR default, not both
    # So we: 1) Deploy default template, 2) Update site-specific files to include default
    if [ -d "$WP_TEST_NGINX" ]; then
        local vhost_dir="${WP_TEST_NGINX}/vhost.d"
        local vhost_default="${vhost_dir}/default"
        local consolidated_template="${TEMPLATE_DIR}/wp-test-vhost-default.conf"

        mkdir -p "$vhost_dir"

        # Deploy consolidated template to default
        if [ -f "$consolidated_template" ]; then
            cp "$consolidated_template" "$vhost_default"
            log_success "Security template deployed to vhost.d/default"
        else
            log_warn "Consolidated template not found, using fallback"
            cp "${TEMPLATE_DIR}/security-headers.conf" "${WP_TEST_NGINX}/conf.d/"
        fi

        # Update site-specific files to include default
        # nginx-proxy uses site-specific file INSTEAD of default if it exists
        local filename
        local temp_file
        for site_file in "$vhost_dir"/*; do
            [ -f "$site_file" ] || continue
            filename=$(basename "$site_file")

            # Skip default, default_location, and hidden files
            [[ "$filename" == "default" ]] && continue
            [[ "$filename" == "default_location" ]] && continue
            [[ "$filename" == .* ]] && continue
            [[ -d "$site_file" ]] && continue

            # Check if already includes default
            if grep -q "include.*/vhost.d/default" "$site_file" 2>/dev/null; then
                log_info "Site $filename already includes default"
                continue
            fi

            # Add include directive at the beginning
            log_info "Updating $filename to include default..."
            temp_file=$(mktemp)
            echo "# Include default security headers" > "$temp_file"
            echo "include /etc/nginx/vhost.d/default;" >> "$temp_file"
            echo "" >> "$temp_file"
            cat "$site_file" >> "$temp_file"
            mv "$temp_file" "$site_file"
            log_success "Updated $filename"
        done

        log_success "Security configured for wp-test"
    fi

    # Apply to system nginx
    if [ -f /etc/nginx/nginx.conf ]; then
        # Deploy rate limiting zones to conf.d (http context)
        local nginx_conf_d="/etc/nginx/conf.d"
        if [ -d "$nginx_conf_d" ]; then
            sudo cp "${TEMPLATE_DIR}/security-http.conf" "$nginx_conf_d/" 2>/dev/null || true
            log_success "Rate limiting zones configured for system nginx"
        fi

        # Auto-inject security headers into server blocks
        if [ -d "/etc/nginx/sites-enabled" ]; then
            log_info "Auto-injecting security headers into server blocks..."
            inject_server_includes "${TEMPLATE_DIR}/security-headers.conf" "security-headers.conf"
        fi
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

    # Apply to wp-test (works because proxy handles server context)
    if [ -d "$WP_TEST_NGINX" ]; then
        cp "${TEMPLATE_DIR}/wordpress-exclusions.conf" "${WP_TEST_NGINX}/conf.d/"
        log_success "WordPress exclusions configured for wp-test"
    fi

    # For system nginx: auto-inject into server blocks
    if [ -f /etc/nginx/nginx.conf ]; then
        if [ -d "/etc/nginx/sites-enabled" ]; then
            log_info "Auto-injecting WordPress exclusions into server blocks..."
            inject_server_includes "${TEMPLATE_DIR}/wordpress-exclusions.conf" "wordpress-exclusions.conf"
        else
            # Fallback to manual instructions if no sites-enabled
            log_info "WordPress exclusions template created at: ${TEMPLATE_DIR}/wordpress-exclusions.conf"
            log_info "Include this file in your server blocks: include ${TEMPLATE_DIR}/wordpress-exclusions.conf;"
        fi
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
        local php_version
        php_version=$(php -v | head -1 | sed -n 's/^PHP \([0-9]\.[0-9]\).*/\1/p')

        if [ -n "$php_version" ]; then
            local php_conf_dir
            php_conf_dir="/etc/php/${php_version}/fpm/conf.d"

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
# WWW/SSL Fix
################################################################################

optimize_www_ssl() {
    local target_site="$1"

    log_info "Optimizing: WWW in SSL blocks..."

    # Process each site config
    for site_conf in /etc/nginx/sites-enabled/*; do
        [ -f "$site_conf" ] || continue

        local config_name
        config_name=$(basename "$site_conf")

        # Skip if targeting specific site and this isn't it
        if [ -n "$target_site" ] && [[ "$config_name" != *"$target_site"* ]]; then
            continue
        fi

        # Skip if no SSL
        if ! grep -v '^\s*#' "$site_conf" 2>/dev/null | grep -q "listen.*443.*ssl"; then
            continue
        fi

        # Extract base domain from SSL server block (tracking brace depth)
        local base_domain
        base_domain=$(awk '
            /^[[:space:]]*server[[:space:]]*\{/ && !in_server { in_server=1; depth=1; block=""; next }
            in_server && /\{/ { depth++ }
            in_server && /\}/ { depth-- }
            in_server { block = block $0 "\n" }
            in_server && depth == 0 {
                if (block ~ /listen.*443.*ssl/) {
                    # Extract first non-www domain from server_name
                    n = split(block, lines, "\n")
                    for (i=1; i<=n; i++) {
                        if (lines[i] ~ /server_name/) {
                            gsub(/server_name[[:space:]]+/, "", lines[i])
                            gsub(/;.*/, "", lines[i])
                            split(lines[i], domains, " ")
                            for (j=1; j<=length(domains); j++) {
                                if (domains[j] !~ /^www\./ && domains[j] != "") {
                                    print domains[j]
                                    exit
                                }
                            }
                        }
                    }
                }
                in_server=0
            }
        ' "$site_conf")

        [ -z "$base_domain" ] && continue

        # Check if www redirect exists on port 80 (indicates www should work)
        if ! grep -v '^\s*#' "$site_conf" 2>/dev/null | grep -q "server_name.*www\\.${base_domain}"; then
            continue
        fi

        # Check if SSL block already has www (using same brace-depth logic)
        local ssl_block
        ssl_block=$(awk '
            /^[[:space:]]*server[[:space:]]*\{/ && !in_server { in_server=1; depth=1; block=""; next }
            in_server && /\{/ { depth++ }
            in_server && /\}/ { depth-- }
            in_server { block = block $0 "\n" }
            in_server && depth == 0 {
                if (block ~ /listen.*443.*ssl/) print block
                in_server=0
            }
        ' "$site_conf" 2>/dev/null)

        if echo "$ssl_block" | grep -q "server_name.*www\\.${base_domain}"; then
            log_info "Already has www in SSL: $config_name"
            continue
        fi

        if [ "$DRY_RUN" = true ]; then
            log_info "[DRY RUN] $config_name:"
            log_info "  Change: server_name $base_domain;"
            log_info "      To: server_name $base_domain www.$base_domain;"
            APPLIED_OPTIMIZATIONS+=("WWW in SSL: $base_domain (dry-run)")
            continue
        fi

        log_info "Adding www.$base_domain to SSL block in: $config_name"

        # Backup before modifying
        local backup_file="${site_conf}.wwwbak"
        sudo cp "$site_conf" "$backup_file"

        # Use sed to add www to server_name in SSL blocks
        # This is safe because we've verified the pattern exists
        sudo sed -i "s/server_name ${base_domain};/server_name ${base_domain} www.${base_domain};/g" "$site_conf"

        # Test config
        if nginx -t 2>&1 | grep -q "test failed\|emerg"; then
            log_error "Config test failed after modification, restoring: $config_name"
            sudo mv "$backup_file" "$site_conf"
            continue
        fi

        sudo rm -f "$backup_file"
        log_success "Added www.$base_domain to SSL block: $config_name"
        APPLIED_OPTIMIZATIONS+=("WWW in SSL: $base_domain")
    done

    if [ ${#APPLIED_OPTIMIZATIONS[@]} -gt 0 ] 2>/dev/null; then
        log_success "WWW/SSL optimization complete"
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
