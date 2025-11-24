#!/bin/bash

################################################################################
# backup.sh - Backup & Restore Management
################################################################################

# Current backup directory (set during backup creation)
CURRENT_BACKUP_DIR=""

################################################################################
# Backup Functions
################################################################################

create_backup() {
    local target_site="$1"
    local timestamp=$(date +%Y%m%d-%H%M%S)

    if [ -n "$CUSTOM_BACKUP_DIR" ]; then
        CURRENT_BACKUP_DIR="$CUSTOM_BACKUP_DIR"
    else
        CURRENT_BACKUP_DIR="${BACKUP_DIR}/${timestamp}"
    fi

    mkdir -p "$CURRENT_BACKUP_DIR"

    log_info "Creating backup: $CURRENT_BACKUP_DIR"

    # Backup system nginx
    if [ -d /etc/nginx ]; then
        log_info "Backing up system nginx config..."
        mkdir -p "${CURRENT_BACKUP_DIR}/nginx"
        rsync -a /etc/nginx/ "${CURRENT_BACKUP_DIR}/nginx/" 2>/dev/null || true
    fi

    if [ -d /usr/local/etc/nginx ]; then
        log_info "Backing up homebrew nginx config..."
        mkdir -p "${CURRENT_BACKUP_DIR}/nginx-homebrew"
        rsync -a /usr/local/etc/nginx/ "${CURRENT_BACKUP_DIR}/nginx-homebrew/" 2>/dev/null || true
    fi

    # Backup wp-test nginx
    if [ -d "$WP_TEST_NGINX" ]; then
        log_info "Backing up wp-test nginx config..."
        mkdir -p "${CURRENT_BACKUP_DIR}/wp-test-nginx"
        rsync -a "$WP_TEST_NGINX/" "${CURRENT_BACKUP_DIR}/wp-test-nginx/" 2>/dev/null || true
    fi

    # Backup specific wp-test site
    if [ -n "$target_site" ] && [ -d "$WP_TEST_SITES/$target_site" ]; then
        log_info "Backing up wp-test site: $target_site..."
        mkdir -p "${CURRENT_BACKUP_DIR}/wp-test-sites/${target_site}"
        rsync -a "$WP_TEST_SITES/$target_site/" "${CURRENT_BACKUP_DIR}/wp-test-sites/${target_site}/" 2>/dev/null || true
    fi

    # Backup PHP configs
    if [ -d /etc/php ]; then
        log_info "Backing up PHP configs..."
        mkdir -p "${CURRENT_BACKUP_DIR}/php"
        rsync -a /etc/php/ "${CURRENT_BACKUP_DIR}/php/" 2>/dev/null || true
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

    cat > "$metadata_file" << EOF
{
    "timestamp": "$(date '+%Y-%m-%d %H:%M:%S')",
    "nginx_version": "$nginx_version",
    "php_version": "$php_version",
    "target_site": "${TARGET_SITE:-all}",
    "hostname": "$(hostname)",
    "user": "$(whoami)"
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

# Restore system nginx
if [ -d "$BACKUP_DIR/nginx" ] && [ -d /etc/nginx ]; then
    echo "Restoring system nginx..."
    rsync -a "$BACKUP_DIR/nginx/" /etc/nginx/
fi

if [ -d "$BACKUP_DIR/nginx-homebrew" ] && [ -d /usr/local/etc/nginx ]; then
    echo "Restoring homebrew nginx..."
    rsync -a "$BACKUP_DIR/nginx-homebrew/" /usr/local/etc/nginx/
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

    # Restore system nginx
    if [ -d "$backup_path/nginx" ] && [ -d /etc/nginx ]; then
        log_info "Restoring system nginx..."
        rsync -a "$backup_path/nginx/" /etc/nginx/
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

    local backup_count=$(ls -1 "$BACKUP_DIR" | wc -l)

    if [ "$backup_count" -le "$keep_count" ]; then
        log_info "No cleanup needed ($backup_count backups)"
        return
    fi

    # Remove oldest backups
    local to_remove=$((backup_count - keep_count))

    ls -1t "$BACKUP_DIR" | tail -$to_remove | while read -r old_backup; do
        log_info "Removing old backup: $old_backup"
        rm -rf "${BACKUP_DIR}/${old_backup}"
    done

    log_success "Cleanup complete"
}

list_backups() {
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "Available Backups:"
    echo "═══════════════════════════════════════════════════════════"

    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
        echo "  No backups found"
        echo ""
        return
    fi

    for backup in $(ls -1t "$BACKUP_DIR"); do
        local metadata_file="${BACKUP_DIR}/${backup}/backup-metadata.json"

        echo "  Backup: $backup"

        if [ -f "$metadata_file" ]; then
            local timestamp=$(jq -r '.timestamp' "$metadata_file" 2>/dev/null || echo "unknown")
            local nginx_ver=$(jq -r '.nginx_version' "$metadata_file" 2>/dev/null || echo "unknown")
            local target=$(jq -r '.target_site' "$metadata_file" 2>/dev/null || echo "unknown")

            echo "    Time: $timestamp"
            echo "    Nginx: $nginx_ver"
            echo "    Target: $target"
        fi

        # Show size
        local size=$(du -sh "${BACKUP_DIR}/${backup}" 2>/dev/null | cut -f1)
        echo "    Size: $size"

        echo ""
    done

    echo "═══════════════════════════════════════════════════════════"
    echo "Restore with: nginx-optimizer rollback <backup-name>"
    echo "═══════════════════════════════════════════════════════════"
}
