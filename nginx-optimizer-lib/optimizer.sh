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
# Environment Detection Helpers (DRY)
################################################################################

# Check if system nginx is installed and has sites-enabled
has_system_nginx() {
    [ -d "/etc/nginx/sites-enabled" ] && [ -n "$(ls -A /etc/nginx/sites-enabled 2>/dev/null)" ]
}

# Check if wp-test sites exist
has_wptest_sites() {
    [ -d "$WP_TEST_SITES" ] && [ -n "$(ls -A "$WP_TEST_SITES" 2>/dev/null)" ]
}

# Check if Docker wp-test proxy is running
has_docker_wptest() {
    command -v docker &>/dev/null && docker ps --format "{{.Names}}" 2>/dev/null | grep -q "wp-test-proxy"
}

# Get list of system nginx sites (basenames only)
get_system_sites() {
    if has_system_nginx; then
        for f in /etc/nginx/sites-enabled/*; do
            [ -f "$f" ] && basename "$f"
        done
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

# Deploy template to /etc/nginx/conf.d/ (system nginx)
# Usage: deploy_template_to_confd "feature.conf"
deploy_template_to_confd() {
    local template_name="$1"
    local source="${TEMPLATE_DIR}/${template_name}"
    local dest="/etc/nginx/conf.d/${template_name}"

    if [ ! -f "$source" ]; then
        log_to_file "ERROR" "Template not found: $source"
        return 1
    fi

    if [ "$DRY_RUN" = true ]; then
        ui_step_path "Would deploy template" "conf.d/${template_name}"
        return 0
    fi

    if sudo cp "$source" "$dest" 2>/dev/null; then
        ui_step_path "Deployed template" "conf.d/${template_name}"
        log_to_file "SUCCESS" "Deployed $template_name to $dest"
        return 0
    else
        log_to_file "ERROR" "Failed to deploy $template_name to $dest"
        return 1
    fi
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

    # Show target info - count sites from all sources
    local site_count=0
    if [ -n "$target_site" ]; then
        site_count=1
    else
        # Count wp-test sites
        if [ -d "$WP_TEST_SITES" ]; then
            site_count=$(find "$WP_TEST_SITES" -maxdepth 1 -type d ! -name "$(basename "$WP_TEST_SITES")" 2>/dev/null | wc -l | tr -d ' ')
        fi
        # Count system nginx sites
        if [ -d "/etc/nginx/sites-enabled" ]; then
            local sys_count
            sys_count=$(find /etc/nginx/sites-enabled -maxdepth 1 -type f -o -type l 2>/dev/null | wc -l | tr -d ' ')
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

    # Ensure templates exist if referenced by includes in sites-enabled
    ensure_referenced_templates

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
            if type -t ui_step &>/dev/null; then
                ui_step "$display_name applied"
            else
                log_success "$display_name applied"
            fi
        else
            if type -t log_warn &>/dev/null; then
                log_warn "Failed to apply $display_name"
            fi
        fi
    done < <(feature_list)

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
# Registry-Based Optimization
################################################################################

# Apply features using the registry system
# Args: $1 = target_site, $2 = specific_feature (optional), $3 = exclude_feature (optional)
# Returns: 0 on success
optimize_all_with_registry() {
    local target_site="${1:-}"
    local specific_feature="${2:-}"
    local exclude_feature="${3:-}"

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
        log_info "Applying optimizations via registry..."
        if [ "$DRY_RUN" = true ]; then
            log_warn "DRY RUN MODE - Showing what would be done"
        fi
    fi

    # Show target info
    if type -t ui_context &>/dev/null; then
        if [ -n "$specific_feature" ]; then
            # Resolve feature display name
            local resolved_id
            resolved_id=$(feature_get_by_alias "$specific_feature" 2>/dev/null)
            local display_name
            if [ -n "$resolved_id" ]; then
                display_name=$(feature_get "$resolved_id" "display" 2>/dev/null)
            fi
            ui_context "Optimizing" "${display_name:-$specific_feature}"
        else
            ui_context "Optimizing" "All registered features"
        fi
        ui_context "Target" "${target_site:-All sites}"
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

    # Purge cached templates
    local purged_count
    purged_count=$(purge_cached_templates 2>&1 | grep -oE '[0-9]+' | tail -1 || echo "0")
    if type -t ui_step &>/dev/null; then
        ui_step "Prerequisites satisfied"
        if [ "${purged_count:-0}" -gt 0 ]; then
            ui_step "Cached templates purged" "${purged_count} files"
        fi
    fi

    # Ensure referenced templates exist
    ensure_referenced_templates

    # Show features section
    if type -t ui_section &>/dev/null; then
        ui_section "Applying optimizations..."
    fi

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
            if type -t ui_step &>/dev/null; then
                ui_step "$display_name applied"
            else
                log_success "$display_name applied"
            fi
        else
            if type -t log_warn &>/dev/null; then
                log_warn "Failed to apply $display_name"
            fi
        fi
    done < <(feature_list)

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

    return 0
}

# Legacy optimize_* functions removed - now using feature_apply() via registry

################################################################################
# Helper Functions
################################################################################

# Placeholder kept for compatibility - actual optimization via feature modules
_legacy_functions_removed() {
    # optimize_http3, optimize_fastcgi_cache, optimize_redis, optimize_brotli,
    # optimize_security, optimize_wordpress, optimize_opcache, optimize_www_ssl
    # All now implemented in lib/features/*.sh and applied via feature_apply()
    :
}

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
