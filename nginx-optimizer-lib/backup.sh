#!/bin/bash

################################################################################
# backup.sh - Backup & Restore Management
################################################################################

# Current backup directory (set during backup creation)
CURRENT_BACKUP_DIR=""

################################################################################
# Helper Functions
################################################################################

# Get directory modification time (cross-platform)
# Returns epoch timestamp on stdout
get_dir_mtime() {
    local dir="$1"
    local mtime

    # Try BSD stat first (macOS)
    mtime=$(stat -f '%m' "$dir" 2>/dev/null)
    if [ $? -eq 0 ]; then
        echo "$mtime"
        return 0
    fi

    # Try GNU stat (Linux)
    mtime=$(stat -c '%Y' "$dir" 2>/dev/null)
    if [ $? -eq 0 ]; then
        echo "$mtime"
        return 0
    fi

    # Fallback to epoch 0
    echo "0"
}

################################################################################
# Backup Functions
################################################################################

create_backup() {
    local target_site="$1"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)

    if [ -n "$CUSTOM_BACKUP_DIR" ]; then
        CURRENT_BACKUP_DIR="$CUSTOM_BACKUP_DIR"
    else
        CURRENT_BACKUP_DIR="${BACKUP_DIR}/${timestamp}"
    fi

    mkdir -p "$CURRENT_BACKUP_DIR"

    log_info "Creating backup: $CURRENT_BACKUP_DIR"

    local backup_failed=false

    # Backup system nginx (all possible paths)
    local system_nginx_backed_up=false

    if [ -d /etc/nginx ]; then
        log_info "Backing up system nginx config (/etc/nginx)..."
        mkdir -p "${CURRENT_BACKUP_DIR}/nginx"
        if rsync -a /etc/nginx/ "${CURRENT_BACKUP_DIR}/nginx/" 2>/dev/null; then
            system_nginx_backed_up=true
        else
            log_warn "Could not backup /etc/nginx (permission denied?)"
        fi
    fi

    if [ -d /usr/local/etc/nginx ]; then
        log_info "Backing up homebrew nginx config (Intel)..."
        mkdir -p "${CURRENT_BACKUP_DIR}/nginx-homebrew-intel"
        if rsync -a /usr/local/etc/nginx/ "${CURRENT_BACKUP_DIR}/nginx-homebrew-intel/" 2>/dev/null; then
            system_nginx_backed_up=true
        else
            log_warn "Could not backup /usr/local/etc/nginx"
        fi
    fi

    if [ -d /opt/homebrew/etc/nginx ]; then
        log_info "Backing up homebrew nginx config (Apple Silicon)..."
        mkdir -p "${CURRENT_BACKUP_DIR}/nginx-homebrew-arm"
        if rsync -a /opt/homebrew/etc/nginx/ "${CURRENT_BACKUP_DIR}/nginx-homebrew-arm/" 2>/dev/null; then
            system_nginx_backed_up=true
        else
            log_warn "Could not backup /opt/homebrew/etc/nginx"
        fi
    fi

    # CRITICAL: If --system-only mode and no system nginx backed up, fail
    if [ "${SYSTEM_ONLY:-false}" = true ] && [ "$system_nginx_backed_up" = false ]; then
        log_error "CRITICAL: Failed to backup system nginx config in --system-only mode"
        backup_failed=true
    fi

    # Backup wp-test nginx (critical for wp-test sites)
    if [ -d "$WP_TEST_NGINX" ]; then
        log_info "Backing up wp-test nginx config..."
        mkdir -p "${CURRENT_BACKUP_DIR}/wp-test-nginx"
        if ! rsync -a "$WP_TEST_NGINX/" "${CURRENT_BACKUP_DIR}/wp-test-nginx/"; then
            log_error "CRITICAL: Failed to backup wp-test nginx config"
            backup_failed=true
        fi
    fi

    # Backup specific wp-test site (critical if specified)
    if [ -n "$target_site" ] && [ -d "$WP_TEST_SITES/$target_site" ]; then
        log_info "Backing up wp-test site: $target_site..."
        mkdir -p "${CURRENT_BACKUP_DIR}/wp-test-sites/${target_site}"
        if ! rsync -a "$WP_TEST_SITES/$target_site/" "${CURRENT_BACKUP_DIR}/wp-test-sites/${target_site}/"; then
            log_error "CRITICAL: Failed to backup wp-test site: $target_site"
            backup_failed=true
        fi
    fi

    # Backup all docker-compose.yml files from wp-test sites
    if [ -d "$WP_TEST_SITES" ]; then
        log_info "Backing up docker-compose.yml files from wp-test sites..."
        mkdir -p "${CURRENT_BACKUP_DIR}/docker-compose-files"
        local compose_count=0
        for site_dir in "$WP_TEST_SITES"/*; do
            if [ -d "$site_dir" ] && [ -f "$site_dir/docker-compose.yml" ]; then
                local site_name
                site_name=$(basename "$site_dir")
                cp "$site_dir/docker-compose.yml" "${CURRENT_BACKUP_DIR}/docker-compose-files/${site_name}.yml"
                compose_count=$((compose_count + 1))
            fi
        done
        if [ $compose_count -gt 0 ]; then
            log_info "Backed up $compose_count docker-compose.yml files"
        fi
    fi

    # Backup PHP configs (non-critical)
    if [ -d /etc/php ]; then
        log_info "Backing up PHP configs..."
        mkdir -p "${CURRENT_BACKUP_DIR}/php"
        if ! rsync -a /etc/php/ "${CURRENT_BACKUP_DIR}/php/" 2>/dev/null; then
            log_warn "Could not backup /etc/php (permission denied?)"
        fi
    fi

    # Fail if critical backups failed
    if [ "$backup_failed" = true ]; then
        log_error "Backup failed - aborting optimization"
        return 1
    fi

    # Create metadata file
    create_backup_metadata

    # Create restore script
    create_restore_script

    log_success "Backup created: ${CURRENT_BACKUP_DIR}"
    log_info "Rollback command: nginx-optimizer rollback $(basename "$CURRENT_BACKUP_DIR")"
}

create_backup_metadata() {
    local metadata_file="${CURRENT_BACKUP_DIR}/backup-metadata.json"

    # Get nginx version if available
    local nginx_version="unknown"
    if command -v nginx &>/dev/null; then
        nginx_version=$(nginx -v 2>&1 | sed -n 's/.*nginx\/\([0-9.]*\).*/\1/p')
    fi

    # Get PHP version if available
    local php_version="unknown"
    if command -v php &>/dev/null; then
        php_version=$(php -v | head -1 | sed -n 's/^PHP \([0-9.]*\).*/\1/p')
    fi

    # Count backed up docker-compose files
    local compose_count=0
    if [ -d "${CURRENT_BACKUP_DIR}/docker-compose-files" ]; then
        compose_count=$(ls -1 "${CURRENT_BACKUP_DIR}/docker-compose-files" 2>/dev/null | wc -l)
    fi

    cat > "$metadata_file" << EOF
{
    "timestamp": "$(date '+%Y-%m-%d %H:%M:%S')",
    "nginx_version": "$nginx_version",
    "php_version": "$php_version",
    "target_site": "${TARGET_SITE:-all}",
    "hostname": "$(hostname)",
    "user": "$(whoami)",
    "docker_compose_files_backed_up": $compose_count
}
EOF

    log_info "Metadata saved: $metadata_file"
}

create_restore_script() {
    local restore_script="${CURRENT_BACKUP_DIR}/restore.sh"

    cat > "$restore_script" << 'EOF'
#!/bin/bash

# Auto-generated restore script
set -e

BACKUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Restoring from backup: $BACKUP_DIR"

# Restore system nginx (all paths)
if [ -d "$BACKUP_DIR/nginx" ] && [ -d /etc/nginx ]; then
    echo "Restoring system nginx (/etc/nginx)..."
    sudo rsync -a "$BACKUP_DIR/nginx/" /etc/nginx/
fi

if [ -d "$BACKUP_DIR/nginx-homebrew-intel" ] && [ -d /usr/local/etc/nginx ]; then
    echo "Restoring homebrew nginx (Intel)..."
    rsync -a "$BACKUP_DIR/nginx-homebrew-intel/" /usr/local/etc/nginx/
fi

if [ -d "$BACKUP_DIR/nginx-homebrew-arm" ] && [ -d /opt/homebrew/etc/nginx ]; then
    echo "Restoring homebrew nginx (Apple Silicon)..."
    rsync -a "$BACKUP_DIR/nginx-homebrew-arm/" /opt/homebrew/etc/nginx/
fi

# Legacy support for old backup format
if [ -d "$BACKUP_DIR/nginx-homebrew" ]; then
    if [ -d /usr/local/etc/nginx ]; then
        echo "Restoring legacy homebrew nginx..."
        rsync -a "$BACKUP_DIR/nginx-homebrew/" /usr/local/etc/nginx/
    elif [ -d /opt/homebrew/etc/nginx ]; then
        echo "Restoring legacy homebrew nginx to Apple Silicon..."
        rsync -a "$BACKUP_DIR/nginx-homebrew/" /opt/homebrew/etc/nginx/
    fi
fi

# Restore wp-test nginx
if [ -d "$BACKUP_DIR/wp-test-nginx" ]; then
    echo "Restoring wp-test nginx..."
    rsync -a "$BACKUP_DIR/wp-test-nginx/" "$HOME/.wp-test/nginx/"
fi

# Restore wp-test sites
if [ -d "$BACKUP_DIR/wp-test-sites" ]; then
    echo "Restoring wp-test sites..."
    rsync -a "$BACKUP_DIR/wp-test-sites/" "$HOME/.wp-test/sites/"
fi

# Restore docker-compose files
if [ -d "$BACKUP_DIR/docker-compose-files" ]; then
    echo "Restoring docker-compose.yml files..."
    for compose_file in "$BACKUP_DIR/docker-compose-files"/*.yml; do
        if [ -f "$compose_file" ]; then
            site_name=$(basename "$compose_file" .yml)
            target_dir="$HOME/.wp-test/sites/$site_name"
            if [ -d "$target_dir" ]; then
                echo "  Restoring docker-compose.yml for $site_name"
                cp "$compose_file" "$target_dir/docker-compose.yml"
            else
                echo "  Warning: Site directory not found for $site_name"
            fi
        fi
    done
fi

# Restore PHP configs
if [ -d "$BACKUP_DIR/php" ] && [ -d /etc/php ]; then
    echo "Restoring PHP configs..."
    rsync -a "$BACKUP_DIR/php/" /etc/php/
fi

# Test and reload nginx
echo "Testing nginx configuration..."
if command -v nginx &>/dev/null; then
    if nginx -t 2>/dev/null; then
        echo "Configuration valid, reloading..."
        if command -v systemctl &>/dev/null; then
            systemctl reload nginx
        else
            nginx -s reload
        fi
        echo "✓ Restore complete!"
    else
        echo "✗ Configuration test failed!"
        exit 1
    fi
else
    echo "✓ Restore complete (nginx not found, skipping reload)"
fi
EOF

    chmod +x "$restore_script"
    log_info "Restore script created: $restore_script"
}

restore_backup() {
    local backup_timestamp="$1"

    if [ -z "$backup_timestamp" ]; then
        log_error "No backup timestamp provided"
        exit 1
    fi

    local backup_path="${BACKUP_DIR}/${backup_timestamp}"

    if [ ! -d "$backup_path" ]; then
        log_error "Backup not found: $backup_path"
        log_info "Available backups:"
        ls -1 "$BACKUP_DIR" | tail -10
        exit 1
    fi

    log_warn "About to restore backup from: $backup_timestamp"

    if [ "$FORCE" != true ]; then
        read -rp "Are you sure you want to restore this backup? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log_info "Restore cancelled"
            exit 0
        fi
    fi

    log_info "Restoring backup..."

    # Execute the restore script
    local restore_script="${backup_path}/restore.sh"

    if [ -f "$restore_script" ]; then
        bash "$restore_script"
    else
        # Manual restore
        manual_restore "$backup_path"
    fi

    log_success "Backup restored successfully!"
}

manual_restore() {
    local backup_path="$1"

    log_info "Performing manual restore..."

    # Stop nginx first (if running)
    if command -v systemctl &>/dev/null && systemctl is-active --quiet nginx; then
        log_info "Stopping nginx..."
        systemctl stop nginx || true
    fi

    # Restore system nginx (all paths)
    if [ -d "$backup_path/nginx" ] && [ -d /etc/nginx ]; then
        log_info "Restoring system nginx (/etc/nginx)..."
        sudo rsync -a "$backup_path/nginx/" /etc/nginx/
    fi

    if [ -d "$backup_path/nginx-homebrew-intel" ] && [ -d /usr/local/etc/nginx ]; then
        log_info "Restoring homebrew nginx (Intel)..."
        rsync -a "$backup_path/nginx-homebrew-intel/" /usr/local/etc/nginx/
    fi

    if [ -d "$backup_path/nginx-homebrew-arm" ] && [ -d /opt/homebrew/etc/nginx ]; then
        log_info "Restoring homebrew nginx (Apple Silicon)..."
        rsync -a "$backup_path/nginx-homebrew-arm/" /opt/homebrew/etc/nginx/
    fi

    # Legacy: Handle old backup format (nginx-homebrew)
    if [ -d "$backup_path/nginx-homebrew" ]; then
        if [ -d /usr/local/etc/nginx ]; then
            log_info "Restoring legacy homebrew nginx..."
            rsync -a "$backup_path/nginx-homebrew/" /usr/local/etc/nginx/
        elif [ -d /opt/homebrew/etc/nginx ]; then
            log_info "Restoring legacy homebrew nginx to Apple Silicon..."
            rsync -a "$backup_path/nginx-homebrew/" /opt/homebrew/etc/nginx/
        fi
    fi

    # Restore wp-test nginx
    if [ -d "$backup_path/wp-test-nginx" ]; then
        log_info "Restoring wp-test nginx..."
        rsync -a "$backup_path/wp-test-nginx/" "$WP_TEST_NGINX/"
    fi

    # Restore wp-test sites
    if [ -d "$backup_path/wp-test-sites" ]; then
        log_info "Restoring wp-test sites..."
        rsync -a "$backup_path/wp-test-sites/" "$WP_TEST_SITES/"
    fi

    # Restore PHP configs
    if [ -d "$backup_path/php" ] && [ -d /etc/php ]; then
        log_info "Restoring PHP configs..."
        rsync -a "$backup_path/php/" /etc/php/
    fi

    # Test configuration
    if command -v nginx &>/dev/null; then
        if nginx -t 2>/dev/null; then
            log_success "Configuration test passed"
            # Start nginx
            if command -v systemctl &>/dev/null; then
                systemctl start nginx
            fi
        else
            log_error "Configuration test failed!"
            exit 1
        fi
    fi
}

cleanup_old_backups() {
    local keep_count=${1:-10}

    log_info "Cleaning up old backups (keeping last $keep_count)..."

    # Count backups safely
    local backup_count=0
    while IFS= read -r -d '' _; do
        ((backup_count++))
    done < <(find "$BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d -print0)

    if [ "$backup_count" -le "$keep_count" ]; then
        log_info "No cleanup needed ($backup_count backups)"
        return
    fi

    # Remove oldest (sort by mtime, skip newest keep_count)
    # Portable stat-based approach (BSD/GNU compatible)
    local -a backups_with_mtime=()
    for dir in "$BACKUP_DIR"/*/; do
        [ -d "$dir" ] || continue
        local mtime
        mtime=$(get_dir_mtime "$dir")
        backups_with_mtime+=("$mtime $dir")
    done

    # Sort by mtime (oldest first), remove old backups
    local delete_count=$((backup_count - keep_count))
    printf '%s\n' "${backups_with_mtime[@]}" | \
        sort -n | \
        head -n "$delete_count" | \
        while IFS=' ' read -r mtime backup_path; do
            log_info "Removing old backup: $(basename "$backup_path")"
            rm -rf "$backup_path"
        done

    log_success "Cleanup complete"
}

list_backups() {
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "Available Backups:"
    echo "═══════════════════════════════════════════════════════════"

    if [ ! -d "$BACKUP_DIR" ]; then
        echo "  No backups found"
        echo ""
        return
    fi

    # Check if any backups exist
    local has_backups=false
    while IFS= read -r -d '' _; do
        has_backups=true
        break
    done < <(find "$BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d -print0)

    if [ "$has_backups" = false ]; then
        echo "  No backups found"
        echo ""
        return
    fi

    # List backups sorted by modification time (newest first)
    # Portable stat-based approach (BSD/GNU compatible)
    local -a backups_with_mtime=()
    for dir in "$BACKUP_DIR"/*/; do
        [ -d "$dir" ] || continue
        local mtime
        mtime=$(get_dir_mtime "$dir")
        backups_with_mtime+=("$mtime $dir")
    done

    printf '%s\n' "${backups_with_mtime[@]}" | \
        sort -rn | \
        while IFS=' ' read -r mtime backup_path; do
            local backup
            backup=$(basename "$backup_path")
            local metadata_file="${backup_path}/backup-metadata.json"

            echo "  Backup: $backup"

            if [ -f "$metadata_file" ]; then
                local timestamp
                local nginx_ver
                local target
                timestamp=$(jq -r '.timestamp' "$metadata_file" 2>/dev/null || echo "unknown")
                nginx_ver=$(jq -r '.nginx_version' "$metadata_file" 2>/dev/null || echo "unknown")
                target=$(jq -r '.target_site' "$metadata_file" 2>/dev/null || echo "unknown")

                echo "    Time: $timestamp"
                echo "    Nginx: $nginx_ver"
                echo "    Target: $target"
            fi

            # Show size
            local size
            size=$(du -sh "$backup_path" 2>/dev/null | cut -f1)
            echo "    Size: $size"

            echo ""
        done

    echo "═══════════════════════════════════════════════════════════"
    echo "Restore with: nginx-optimizer rollback <backup-name>"
    echo "═══════════════════════════════════════════════════════════"
}

