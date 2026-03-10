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

    # Must be within allowed directories (includes Homebrew paths and sites-available)
    case "$resolved" in
        /etc/nginx/*) return 0 ;;
        /usr/local/etc/nginx/*) return 0 ;;
        /opt/homebrew/etc/nginx/*) return 0 ;;
        "$HOME"/.wp-test/*) return 0 ;;
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
# Environment Detection Helpers (DRY)
# Note: has_system_nginx, has_wptest_sites, has_docker_wptest are in lib/core/templates.sh
################################################################################

# Get the nginx sites-enabled directory (cross-platform)
get_nginx_sites_dir() {
    for dir in /etc/nginx/sites-enabled /usr/local/etc/nginx/sites-enabled /opt/homebrew/etc/nginx/sites-enabled; do
        if [ -d "$dir" ]; then
            echo "$dir"
            return 0
        fi
    done
    # Fallback to servers/ on Homebrew
    for dir in /usr/local/etc/nginx/servers /opt/homebrew/etc/nginx/servers; do
        if [ -d "$dir" ]; then
            echo "$dir"
            return 0
        fi
    done
    return 1
}

# Get the nginx conf.d directory (cross-platform)
get_nginx_confd_dir() {
    for dir in /etc/nginx/conf.d /usr/local/etc/nginx/conf.d /opt/homebrew/etc/nginx/conf.d; do
        if [ -d "$dir" ]; then
            echo "$dir"
            return 0
        fi
    done
    return 1
}

# Get the nginx snippets directory (cross-platform)
get_nginx_snippets_dir() {
    for dir in /etc/nginx/snippets /usr/local/etc/nginx/snippets /opt/homebrew/etc/nginx/snippets; do
        if [ -d "$dir" ]; then
            echo "$dir"
            return 0
        fi
    done
    return 1
}

# Get list of system nginx sites (basenames only, cross-platform)
get_system_sites() {
    if has_system_nginx; then
        local sites_dir
        sites_dir=$(get_nginx_sites_dir)
        if [ -n "$sites_dir" ] && [ -d "$sites_dir" ]; then
            for f in "$sites_dir"/*; do
                [ -f "$f" ] && basename "$f"
            done
        fi
    fi
}

# Get list of wp-test sites
get_wptest_sites() {
    if has_wptest_sites; then
        for d in "$WP_TEST_SITES"/*; do
            [ -d "$d" ] && basename "$d"
        done
    fi
}

################################################################################
# Template Management Helpers (DRY)
################################################################################

# Ensure template exists, create if needed
# Usage: ensure_template "feature.conf" create_function_name
# Returns: 0 if template exists/created, 1 on failure
ensure_template() {
    local template_name="$1"
    local create_func="$2"
    local template_path="${TEMPLATE_DIR}/${template_name}"

    if [ ! -f "$template_path" ]; then
        if type -t "$create_func" &>/dev/null; then
            "$create_func"
            return $?
        else
            log_to_file "ERROR" "Template creator function not found: $create_func"
            return 1
        fi
    fi
    return 0
}

# Deploy template to nginx conf.d (cross-platform)
# Usage: deploy_template_to_confd "feature.conf"
deploy_template_to_confd() {
    local template_name="$1"
    local source="${TEMPLATE_DIR}/${template_name}"

    # Get cross-platform conf.d path
    local confd_dir
    confd_dir=$(get_nginx_confd_dir)
    if [ -z "$confd_dir" ]; then
        log_to_file "ERROR" "Cannot find nginx conf.d directory"
        return 1
    fi

    local dest="${confd_dir}/${template_name}"

    if [ ! -f "$source" ]; then
        log_to_file "ERROR" "Template not found: $source"
        return 1
    fi

    if [ "$DRY_RUN" = true ]; then
        ui_step_path "Would deploy template" "conf.d/${template_name}"
        return 0
    fi

    # Ensure conf.d exists
    if [ ! -d "$confd_dir" ]; then
        if [ -w "$(dirname "$confd_dir")" ]; then
            mkdir -p "$confd_dir"
        else
            sudo mkdir -p "$confd_dir"
        fi
    fi

    # Smart sudo: only use if directory not writable
    if [ -w "$confd_dir" ]; then
        if cp "$source" "$dest" 2>/dev/null; then
            ui_step_path "Deployed template" "conf.d/${template_name}"
            log_to_file "SUCCESS" "Deployed $template_name to $dest"
            return 0
        fi
    else
        if sudo cp "$source" "$dest" 2>/dev/null; then
            ui_step_path "Deployed template" "conf.d/${template_name}"
            log_to_file "SUCCESS" "Deployed $template_name to $dest"
            return 0
        fi
    fi

    log_to_file "ERROR" "Failed to deploy $template_name to $dest"
    return 1
}

# Deploy template to wp-test nginx conf.d
# Usage: deploy_template_to_wptest "feature.conf"
deploy_template_to_wptest() {
    local template_name="$1"
    local source="${TEMPLATE_DIR}/${template_name}"
    local dest="${WP_TEST_NGINX}/conf.d/${template_name}"

    if [ ! -f "$source" ]; then
        return 1
    fi

    mkdir -p "$(dirname "$dest")" 2>/dev/null

    if [ "$DRY_RUN" = true ]; then
        ui_step_path "Would deploy template" "wp-test/conf.d/${template_name}"
        return 0
    fi

    if cp "$source" "$dest" 2>/dev/null; then
        ui_step_path "Deployed template" "wp-test/conf.d/${template_name}"
        return 0
    fi
    return 1
}

################################################################################
# Logging Helper (file-only, no terminal spam)
################################################################################

log_to_file() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*" >> "${LOG_FILE:-/dev/null}"
}

################################################################################
# Cross-Platform Compatibility Helpers
################################################################################

# Copy file permissions from source to destination (cross-platform)
# Works on both BSD (macOS) and GNU (Linux) systems
copy_file_permissions() {
    local src="$1"
    local dst="$2"

    [ ! -f "$src" ] && return 1
    [ ! -f "$dst" ] && return 1

    if [[ "$(uname)" == "Darwin" ]]; then
        # BSD stat format
        local mode
        mode=$(stat -f '%A' "$src" 2>/dev/null)
        [ -n "$mode" ] && chmod "$mode" "$dst" 2>/dev/null
    else
        # Try GNU --reference first, fallback to stat -c
        if ! chmod --reference="$src" "$dst" 2>/dev/null; then
            local mode
            mode=$(stat -c '%a' "$src" 2>/dev/null)
            [ -n "$mode" ] && chmod "$mode" "$dst" 2>/dev/null
        fi
    fi
}

# Copy file ownership from source to destination (cross-platform)
# Requires appropriate privileges (sudo)
copy_file_ownership() {
    local src="$1"
    local dst="$2"

    [ ! -f "$src" ] && return 1
    [ ! -f "$dst" ] && return 1

    if [[ "$(uname)" == "Darwin" ]]; then
        # BSD stat format
        local owner group
        owner=$(stat -f '%Su' "$src" 2>/dev/null)
        group=$(stat -f '%Sg' "$src" 2>/dev/null)
        [ -n "$owner" ] && [ -n "$group" ] && chown "${owner}:${group}" "$dst" 2>/dev/null
    else
        # Try GNU --reference first, fallback to stat -c
        if ! chown --reference="$src" "$dst" 2>/dev/null; then
            local owner group
            owner=$(stat -c '%U' "$src" 2>/dev/null)
            group=$(stat -c '%G' "$src" 2>/dev/null)
            [ -n "$owner" ] && [ -n "$group" ] && chown "${owner}:${group}" "$dst" 2>/dev/null
        fi
    fi
}

# Cross-platform sed -i (in-place edit)
# Usage: sed_i 's/old/new/' file
# Usage: sed_i --sudo 's/old/new/' file
sed_i() {
    local use_sudo=""
    if [[ "$1" == "--sudo" ]]; then
        use_sudo="sudo"
        shift
    fi
    if [[ "$(uname)" == "Darwin" ]]; then
        $use_sudo sed -i '' "$@"
    else
        $use_sudo sed -i "$@"
    fi
}

# Create temp file with secure permissions (mode 600)
# Usage: secure_mktemp [template]
secure_mktemp() {
    local template="${1:-/tmp/nginx-opt.XXXXXX}"
    local old_umask
    old_umask=$(umask)
    umask 077  # Secure: owner read/write only
    local temp_file
    temp_file=$(mktemp "$template")
    umask "$old_umask"  # Restore original umask
    echo "$temp_file"
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
    temp_file=$(secure_mktemp "${target_dir}/.nginx-opt.XXXXXX")

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
        copy_file_permissions "$target_path" "$temp_file" 2>/dev/null || true
        copy_file_ownership "$target_path" "$temp_file" 2>/dev/null || true
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
    temp_file=$(secure_mktemp "${target_dir}/.nginx-opt-txn.XXXXXX")

    # Copy original if it exists
    if [ -f "$original_path" ]; then
        cp "$original_path" "$temp_file"
        copy_file_permissions "$original_path" "$temp_file" 2>/dev/null || true
        if command -v chown &>/dev/null; then
            copy_file_ownership "$original_path" "$temp_file" 2>/dev/null || true
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

    # Delete all temp files (check if array has elements)
    if [ "${#TRANSACTION_TEMPS[@]}" -gt 0 ]; then
        for temp in "${TRANSACTION_TEMPS[@]}"; do
            rm -f "$temp"
        done
    fi

    # Clear transaction state
    TRANSACTION_FILES=()
    TRANSACTION_TEMPS=()
    TRANSACTION_ACTIVE=false

    log_to_file "INFO" "Transaction rolled back"
}

################################################################################
# State Tracking (persistent record of applied optimizations)
################################################################################

STATE_FILE="${DATA_DIR}/state.json"

# Save applied feature state to persistent JSON file
# Usage: save_applied_state "feature_id" "site_name" "backup_timestamp"
save_applied_state() {
    local feature_id="$1"
    local site_name="${2:-all}"
    local backup_ts="${3:-}"
    local timestamp
    timestamp=$(date '+%Y%m%d-%H%M%S')

    # Build new entry
    local entry
    entry=$(printf '{"feature":"%s","site":"%s","timestamp":"%s","backup":"%s"}' \
        "$feature_id" "$site_name" "$timestamp" "$backup_ts")

    if [ ! -f "$STATE_FILE" ]; then
        # Create new state file
        printf '{"applied":[%s]}\n' "$entry" > "$STATE_FILE"
    else
        # Append to existing applied array
        # Remove trailing }], add new entry, close array
        local existing
        existing=$(cat "$STATE_FILE")
        # Remove duplicate: same feature+site
        local filtered
        if command -v jq &>/dev/null; then
            filtered=$(echo "$existing" | jq -c \
                --arg fid "$feature_id" --arg site "$site_name" \
                '.applied = [.applied[] | select(.feature != $fid or .site != $site)]')
            echo "$filtered" | jq -c ".applied += [$entry]" > "$STATE_FILE"
        else
            # No jq: rebuild with grep/sed
            # Remove old entry for same feature+site, append new
            local temp_state
            temp_state=$(secure_mktemp)
            # Extract existing entries, filter out matching feature+site
            local entries=""
            local line
            while IFS= read -r line; do
                # Skip lines matching this feature+site combo
                if echo "$line" | grep -q "\"feature\":\"${feature_id}\"" && \
                   echo "$line" | grep -q "\"site\":\"${site_name}\""; then
                    continue
                fi
                if [ -n "$entries" ]; then
                    entries="${entries},${line}"
                else
                    entries="$line"
                fi
            done < <(_parse_state_entries)
            if [ -n "$entries" ]; then
                printf '{"applied":[%s,%s]}\n' "$entries" "$entry" > "$temp_state"
            else
                printf '{"applied":[%s]}\n' "$entry" > "$temp_state"
            fi
            mv "$temp_state" "$STATE_FILE"
        fi
    fi
}

# Load applied state - outputs entries one per line
# Usage: _parse_state_entries
_parse_state_entries() {
    [ ! -f "$STATE_FILE" ] && return 0
    if command -v jq &>/dev/null; then
        jq -c '.applied[]' "$STATE_FILE" 2>/dev/null
    else
        # Fallback: extract JSON objects from applied array
        sed 's/.*\[//;s/\].*//' "$STATE_FILE" | tr ',' '\n' | grep '{'
    fi
}

# Get list of applied features for a site
# Usage: get_applied_features [site_name]
# Prints: feature_id per line
get_applied_features() {
    local site_filter="${1:-}"
    [ ! -f "$STATE_FILE" ] && return 0
    if command -v jq &>/dev/null; then
        if [ -n "$site_filter" ]; then
            jq -r --arg site "$site_filter" \
                '.applied[] | select(.site == $site) | .feature' "$STATE_FILE" 2>/dev/null
        else
            jq -r '.applied[].feature' "$STATE_FILE" 2>/dev/null
        fi
    else
        # Fallback: grep-based parsing
        _parse_state_entries | while IFS= read -r entry; do
            if [ -n "$site_filter" ]; then
                if echo "$entry" | grep -q "\"site\":\"${site_filter}\""; then
                    echo "$entry" | sed 's/.*"feature":"\([^"]*\)".*/\1/'
                fi
            else
                echo "$entry" | sed 's/.*"feature":"\([^"]*\)".*/\1/'
            fi
        done
    fi
}

# Load full state as JSON (for JSON output mode)
# Usage: load_applied_state
# Prints: full state JSON
load_applied_state() {
    if [ -f "$STATE_FILE" ]; then
        cat "$STATE_FILE"
    else
        echo '{"applied":[]}'
    fi
}

# Clear state entries for features that were rolled back
# Usage: clear_state_for_rollback
clear_state_for_rollback() {
    if [ -f "$STATE_FILE" ]; then
        # Reset to empty - rollback restores everything
        printf '{"applied":[]}\n' > "$STATE_FILE"
        log_to_file "INFO" "State file cleared after rollback"
    fi
}

################################################################################
# Cache Management
################################################################################

purge_cached_templates() {
    # NOTE: This function is disabled during optimization because deleting
    # templates before applying them makes no sense. Templates are now
    # managed by the feature modules themselves.
    #
    # Previously this would delete security-headers.conf etc. right before
    # the security feature tried to use them, causing failures.

    log_to_file "INFO" "Template purge skipped (managed by feature modules)"
    return 0
}

################################################################################
# Server Block Injection
################################################################################

inject_server_includes() {
    local include_file="$1"
    local include_name="$2"
    local sites_dir

    # Cross-platform sites directory detection
    sites_dir=$(get_nginx_sites_dir)
    if [ -z "$sites_dir" ] || [ ! -d "$sites_dir" ]; then
        return 1
    fi

    # Phase 1: Collect files to modify
    local -a files_to_modify=()
    for site_conf in "$sites_dir"/*; do
        [ -f "$site_conf" ] || continue

        # SECURITY: Validate file is safe to modify
        if ! is_safe_config_file "$site_conf"; then
            log_to_file "WARN" "Skipping unsafe config file: $(basename "$site_conf")"
            continue
        fi

        # SECURITY FIX: Check for exact include directive (anchored regex)
        # Use proper regex to avoid false positives
        if grep -qE "^[[:space:]]*include[[:space:]]+[^#]*${include_name}[[:space:]]*;" "$site_conf" 2>/dev/null; then
            # Already included - skip silently
            continue
        fi

        # Skip if site already has inline protection (avoid duplicate location blocks)
        if [[ "$include_name" == *"wordpress"* ]] && grep -qE "location[[:space:]]*=[[:space:]]*/xmlrpc\.php" "$site_conf" 2>/dev/null; then
            # Already has protection - skip silently
            continue
        fi

        # SECURITY FIX: Check if file contains UNCOMMENTED server block
        # Skip commented lines to prevent injection into comments
        if ! grep -vE '^[[:space:]]*#' "$site_conf" 2>/dev/null | grep -q "server[[:space:]]*{"; then
            # No server block - skip silently
            continue
        fi

        # Resolve symlinks to get actual file path
        local real_path
        real_path=$(realpath "$site_conf" 2>/dev/null) || real_path="$site_conf"
        files_to_modify+=("$real_path")
    done

    if [ ${#files_to_modify[@]} -eq 0 ]; then
        # No new injections needed - return silently
        return 0
    fi

    # Phase 2: Start transaction and prepare all changes
    transaction_start

    local -a temp_files=()
    for site_conf in "${files_to_modify[@]}"; do
        # Add to transaction (files_to_modify now contains resolved paths)
        local temp_file
        temp_file=$(transaction_add_file "$site_conf")
        temp_files+=("$temp_file")

        # Inject include directive into server block
        # Strategy: prefer after "listen 443 ssl", fallback to after "server_name"
        awk -v include_line="    include ${include_file};" '
        BEGIN { injected = 0 }
        {
            line = $0
            print line

            # Skip commented lines
            if (line ~ /^[[:space:]]*#/) next

            # Prefer: inject after "listen 443 ssl" (targets SSL blocks)
            if (!injected && line ~ /listen[[:space:]]+443[[:space:]]+ssl/) {
                print include_line
                injected = 1
            }

            # Fallback: inject after "server_name" (for non-SSL configs behind proxies)
            if (!injected && line ~ /^[[:space:]]*server_name[[:space:]]/) {
                print include_line
                injected = 1
            }
        }' "$site_conf" > "${temp_file}.new"
        mv "${temp_file}.new" "$temp_file"
    done

    # Phase 3: Validate with nginx -t (if possible)
    # First commit to temp location for testing
    local validation_failed=false

    # Determine if we need sudo (check if first file is writable)
    local use_sudo=false
    if [ -n "${files_to_modify[0]}" ] && [ ! -w "${files_to_modify[0]}" ]; then
        use_sudo=true
    fi

    if command -v nginx &>/dev/null && [ -n "${files_to_modify[0]}" ]; then
        # Create backup directory outside sites-enabled (nginx would include .txn-backup files!)
        local backup_dir
        backup_dir=$(mktemp -d)

        # Create backup copies for validation test
        local -a backup_files=()
        for ((i=0; i<${#files_to_modify[@]}; i++)); do
            local original="${files_to_modify[$i]}"
            local temp="${temp_files[$i]}"
            local backup_file
            backup_file="${backup_dir}/$(basename "$original")"
            backup_files+=("$backup_file")

            if [ "$use_sudo" = true ]; then
                sudo cp "$original" "$backup_file" 2>/dev/null || true
                sudo cp "$temp" "$original" 2>/dev/null || true
            else
                cp "$original" "$backup_file" 2>/dev/null || true
                cp "$temp" "$original" 2>/dev/null || true
            fi
        done

        # Test nginx config (check exit code, not output)
        if nginx -t 2>/dev/null; then
            # Validation passed - restore backups (we'll commit properly below)
            for ((i=0; i<${#files_to_modify[@]}; i++)); do
                local original="${files_to_modify[$i]}"
                local backup_file="${backup_files[$i]}"
                if [ "$use_sudo" = true ]; then
                    sudo cp "$backup_file" "$original" 2>/dev/null || true
                else
                    cp "$backup_file" "$original" 2>/dev/null || true
                fi
            done
        else
            local nginx_test_output
            nginx_test_output=$(nginx -t 2>&1)
            log_error "nginx -t validation failed, rolling back changes"
            log_to_file "DEBUG" "nginx -t output: $nginx_test_output"
            validation_failed=true

            # Restore backups
            for ((i=0; i<${#files_to_modify[@]}; i++)); do
                local original="${files_to_modify[$i]}"
                local backup_file="${backup_files[$i]}"
                if [ "$use_sudo" = true ]; then
                    sudo cp "$backup_file" "$original" 2>/dev/null || true
                else
                    cp "$backup_file" "$original" 2>/dev/null || true
                fi
            done
        fi

        # Cleanup backup directory
        rm -rf "$backup_dir"
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

        # Atomic move (try without sudo first)
        if [ "$use_sudo" = true ]; then
            if sudo mv "$temp" "$original" 2>/dev/null; then
                injected=$((injected + 1))
            else
                log_to_file "ERROR" "Failed to commit: $(basename "$original")"
            fi
        else
            if mv "$temp" "$original" 2>/dev/null; then
                injected=$((injected + 1))
            else
                log_to_file "ERROR" "Failed to commit: $(basename "$original")"
            fi
        fi
    done

    transaction_commit

    # Show single summary line using UI
    if [ $injected -gt 0 ]; then
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Injected into" "sites-enabled/* (${injected} files)"
        fi
        log_to_file "SUCCESS" "Injected into $injected server block(s)"
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

    # Show target info - count sites from all sources
    local site_count=0
    if [ -n "$target_site" ]; then
        site_count=1
    else
        # Count wp-test sites (skip if --system-only)
        if [ "${SYSTEM_ONLY:-false}" != true ] && [ -d "$WP_TEST_SITES" ]; then
            site_count=$(find "$WP_TEST_SITES" -maxdepth 1 -type d ! -name "$(basename "$WP_TEST_SITES")" 2>/dev/null | wc -l | tr -d ' ')
        fi
        # Count system nginx sites (cross-platform)
        local sites_dir
        if type -t get_nginx_sites_dir &>/dev/null; then
            sites_dir=$(get_nginx_sites_dir)
        fi
        if [ -n "$sites_dir" ] && [ -d "$sites_dir" ]; then
            local sys_count
            sys_count=$(find "$sites_dir" -maxdepth 1 -type f -o -type l 2>/dev/null | wc -l | tr -d ' ')
            site_count=$((site_count + sys_count))
        fi
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

    # Show features section header
    if type -t ui_section &>/dev/null; then
        if [ -n "$specific_feature" ]; then
            ui_section "Applying $(get_feature_display_name "$specific_feature")..."
        else
            ui_section "Applying optimizations..."
        fi
    else
        log_info "Applying optimizations..."
        echo ""
    fi

    # NEW: Use registry-based optimization instead of case statement loop
    # Resolve specific feature to ID if provided
    local resolved_specific_id=""
    if [ -n "$specific_feature" ]; then
        resolved_specific_id=$(feature_get_by_alias "$specific_feature" 2>/dev/null)
        if [ -z "$resolved_specific_id" ]; then
            log_warn "Feature '$specific_feature' not found in registry"
            return 1
        fi
    fi

    # Resolve exclude feature to ID if provided
    local resolved_exclude_id=""
    if [ -n "$exclude_feature" ]; then
        resolved_exclude_id=$(feature_get_by_alias "$exclude_feature" 2>/dev/null)
        if [ -z "$resolved_exclude_id" ]; then
            log_warn "Feature '$exclude_feature' not found in registry"
            return 1
        fi
    fi

    # Start transaction for non-dry-run operations
    if [ "$DRY_RUN" = false ] && [ "${CHECK_MODE:-false}" = false ]; then
        transaction_start
    fi

    # Loop through all registered features
    local feature_id
    while IFS= read -r feature_id; do
        [ -z "$feature_id" ] && continue

        # Apply filters
        if [ -n "$resolved_specific_id" ] && [ "$feature_id" != "$resolved_specific_id" ]; then
            continue
        fi

        if [ -n "$resolved_exclude_id" ] && [ "$feature_id" = "$resolved_exclude_id" ]; then
            continue
        fi

        # Get feature display name
        local display_name
        display_name=$(feature_get "$feature_id" "display" 2>/dev/null)
        [ -z "$display_name" ] && display_name="$feature_id"

        # Show progress
        if type -t ui_step &>/dev/null; then
            ui_step "Applying $display_name..."
        else
            log_info "Applying $display_name..."
        fi

        # Apply feature via registry
        if feature_apply "$feature_id" "$target_site"; then
            APPLIED_OPTIMIZATIONS+=("$display_name")
            # Persist to state file (get backup timestamp from CURRENT_BACKUP_DIR)
            local backup_ts=""
            if [ -n "${CURRENT_BACKUP_DIR:-}" ]; then
                backup_ts=$(basename "$CURRENT_BACKUP_DIR")
            fi
            save_applied_state "$feature_id" "${target_site:-all}" "$backup_ts"
            if type -t ui_step &>/dev/null; then
                ui_step "$display_name applied"
            else
                log_success "$display_name applied"
            fi
        else
            if type -t ui_step_fail &>/dev/null; then
                ui_step_fail "$display_name" "failed"
            else
                log_warn "Failed to apply $display_name"
            fi
        fi
    done < <(feature_list)

    # Commit transaction if active
    if [ "$DRY_RUN" = false ] && [ "${CHECK_MODE:-false}" = false ] && [ "${TRANSACTION_ACTIVE:-false}" = true ]; then
        transaction_commit
    fi

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
