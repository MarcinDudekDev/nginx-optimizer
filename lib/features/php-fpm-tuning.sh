#!/bin/bash
################################################################################
# features/php-fpm-tuning.sh - PHP-FPM RAM-Aware Tuning
################################################################################
# Tunes PHP-FPM pm.max_children and process manager settings based on
# available system RAM. This is the #1 cause of OOM on WordPress VPSes:
# each PHP worker consumes 30-60MB, and the default max_children is often
# too high for the available RAM.
#
# The math lives in ONE place — sysinfo_ram_budget_php() / sysinfo_fpm_max_children()
# in lib/core/sysinfo.sh. This module only reads those values so the two can
# never drift apart. In outline:
#   usable  = total_ram - opcache SHM - fastcgi keys_zone   (this tool's own
#             fixed shared allocations, which no per-worker figure covers)
#   php_ram = usable * 50%   (rest: MySQL ~20%, OS ~15%, nginx/Redis ~15%)
#   max_children = min(php_ram / avg_worker_size, cores * 10), bounded 3..200
#
# With thanks to easyinstallvps RAM-tier approach -- https://github.com/sugan0927/easyinstallvps
################################################################################

# Ensure registry is loaded
if ! type -t feature_register &>/dev/null; then
    echo "Error: registry.sh must be sourced before feature modules" >&2
    return 1
fi

################################################################################
# Feature Definition
################################################################################

# shellcheck disable=SC2034  # FEATURE_* vars consumed by feature_register() in registry.sh
FEATURE_ID="php-fpm-tuning"
# shellcheck disable=SC2034
FEATURE_DISPLAY="PHP-FPM Tuning (RAM-aware)"
# shellcheck disable=SC2034
FEATURE_DETECT_PATTERN="pm\\.max_children"
# shellcheck disable=SC2034
FEATURE_SCOPE="global"
# shellcheck disable=SC2034
FEATURE_TEMPLATE=""
# shellcheck disable=SC2034
FEATURE_TEMPLATE_CONTEXT=""
# shellcheck disable=SC2034
FEATURE_ALIASES="fpm,php-fpm,php-workers"
# shellcheck disable=SC2034
FEATURE_NGINX_MIN_VERSION=""
# shellcheck disable=SC2034
FEATURE_PREREQ_CHECK=""

################################################################################
# Custom Detection Logic
################################################################################

# Detect PHP-FPM pool configuration
# Args: $1 = config_file, $2 = site_name (optional)
# Returns: 0 if FPM config found, 1 if not
feature_detect_custom_php_fpm_tuning() {
    # shellcheck disable=SC2034  # config_file part of detection API
    local config_file="$1"
    # shellcheck disable=SC2034  # site_name reserved for API compatibility
    local site_name="${2:-}"

    local pool_file
    pool_file=$(_fpm_find_pool_config)

    if [[ -n "$pool_file" ]] && [[ -f "$pool_file" ]]; then
        # shellcheck disable=SC2034  # LAST_DIRECTIVE_SOURCE consumed by registry.sh
        LAST_DIRECTIVE_SOURCE="$pool_file"
        return 0
    fi

    return 1
}

################################################################################
# Custom Apply Logic
################################################################################

# Apply RAM-aware PHP-FPM tuning
# Args: $1 = target_site (optional, ignored for global feature)
# Returns: 0 on success, 1 on failure
feature_apply_custom_php_fpm_tuning() {
    # shellcheck disable=SC2034  # target_site reserved for global features
    local target_site="${1:-}"

    if type -t log_to_file &>/dev/null; then
        log_to_file "INFO" "Applying PHP-FPM Tuning (RAM-aware)..."
    fi

    # Check if PHP-FPM is available
    if ! command -v php &>/dev/null; then
        if type -t apply_log &>/dev/null; then
            apply_log WARN "PHP not found — skipping FPM tuning"
        fi
        return 1
    fi

    # Find pool config
    local pool_file
    pool_file=$(_fpm_find_pool_config)

    if [[ -z "$pool_file" ]]; then
        if type -t apply_log &>/dev/null; then
            apply_log WARN "Cannot find PHP-FPM pool config (www.conf)"
        fi
        return 1
    fi

    # Calculate tuned values — all sizing math is shared, see lib/core/sysinfo.sh
    local ram_mb cores max_children start min spare max_spare
    local avg_worker_mb php_ram_mb opcache_mb keys_zone_mb ram_based cpu_cap

    if ! type -t sysinfo_fpm_max_children &>/dev/null || [[ -z "${SYSINFO_AVG_WORKER_MB:-}" ]]; then
        if type -t apply_log &>/dev/null; then
            apply_log WARN "sysinfo helpers unavailable — cannot size PHP-FPM safely"
        fi
        return 1
    fi

    ram_mb=$(sysinfo_ram_mb)
    cores=$(sysinfo_cpu_cores)
    # Read the shared constant with NO local fallback: a `:-40` default here would
    # let this module explain the number using a different per-worker figure than
    # sysinfo_fpm_max_children() actually used — a silent divergence producing a
    # plausible-looking result. If the constant is missing, the guard above already
    # bailed.
    avg_worker_mb="$SYSINFO_AVG_WORKER_MB"
    max_children=$(sysinfo_fpm_max_children)

    # Recomputed only to explain the number in the dry-run output
    php_ram_mb=$(sysinfo_ram_budget_php)
    opcache_mb=$(sysinfo_opcache_memory)
    keys_zone_mb=$(sysinfo_fastcgi_keys_zone)
    keys_zone_mb="${keys_zone_mb%m}"
    ram_based=$(( php_ram_mb / avg_worker_mb ))
    cpu_cap=$(( cores * 10 ))
    [[ $cpu_cap -lt 3 ]] && cpu_cap=3

    # The 3-worker floor overrides the budget on boxes too small to pay for it.
    # Emitting that config silently would be the exact lie this budget work set
    # out to remove.
    if sysinfo_fpm_floor_binds && type -t apply_log &>/dev/null; then
        apply_log WARN "PHP-FPM over-committed by $(sysinfo_fpm_overcommit_mb)MB: ${ram_mb}MB cannot pay for the 3-worker minimum (budget covers ${ram_based}). Applying the floor anyway so PHP can serve — but this box is under-specced for WordPress + MySQL."
    fi

    # Process manager settings (dynamic mode)
    start=$(( max_children / 4 ))
    min=$(( max_children / 8 ))
    spare=$(( max_children / 4 ))
    max_spare=$(( max_children / 2 ))

    # Ensure minimums
    [[ $start -lt 2 ]] && start=2
    [[ $min -lt 1 ]] && min=1
    [[ $spare -lt 1 ]] && spare=1
    [[ $max_spare -lt 2 ]] && max_spare=2

    if [ "${DRY_RUN:-false}" = true ]; then
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Would tune" "$pool_file"
            ui_step_path "  pm" "dynamic"
            ui_step_path "  pm.max_children" "${max_children} (RAM: (${ram_mb}-${opcache_mb} opcache-${keys_zone_mb} zone)×${SYSINFO_PHP_RAM_PCT:-50}%=${php_ram_mb}MB/${avg_worker_mb}MB=${ram_based}, CPU: ${cores}×10=${cpu_cap}, using lower)"
            ui_step_path "  pm.start_servers" "$start"
            ui_step_path "  pm.min_spare_servers" "$min"
            ui_step_path "  pm.max_spare_servers" "$max_spare"
        fi
        return 0
    fi

    # Backup original
    local SUDO=""
    if [[ ! -w "$pool_file" ]]; then
        SUDO="sudo"
    fi
    $SUDO cp "$pool_file" "${pool_file}.before-tuning"

    # Apply tuning with sed
    # Use a temp file approach for safe atomic replacement
    local temp_file
    temp_file=$(mktemp)
    cat "$pool_file" > "$temp_file"

    # Replace or add pm directives
    _fpm_set_directive "$temp_file" "pm" "dynamic"
    _fpm_set_directive "$temp_file" "pm.max_children" "$max_children"
    _fpm_set_directive "$temp_file" "pm.start_servers" "$start"
    _fpm_set_directive "$temp_file" "pm.min_spare_servers" "$min"
    _fpm_set_directive "$temp_file" "pm.max_spare_servers" "$max_spare"

    # Add process idle timeout (kills idle workers after 10s, freeing RAM)
    _fpm_set_directive "$temp_file" "pm.process_idle_timeout" "10s"

    # Add max requests (recycle workers after 500 requests to prevent memory leaks)
    _fpm_set_directive "$temp_file" "pm.max_requests" "500"

    # Apply
    $SUDO cp "$temp_file" "$pool_file"
    rm -f "$temp_file"

    if type -t ui_step_path &>/dev/null; then
        ui_step_path "Tuned PHP-FPM" "max_children=${max_children} (${php_ram_mb}MB for PHP / ${avg_worker_mb}MB per worker)"
    fi

    # Suggest restart
    if type -t apply_log &>/dev/null; then
        apply_log INFO "Restart PHP-FPM to apply: sudo systemctl reload php*-fpm"
    fi

    if type -t log_to_file &>/dev/null; then
        log_to_file "SUCCESS" "PHP-FPM tuned: max_children=${max_children} (was backed up)"
    fi

    return 0
}

################################################################################
# Custom Remove Logic
################################################################################

# Remove PHP-FPM tuning written by feature_apply_custom_php_fpm_tuning.
#
# Apply keeps a pristine copy at ${pool}.before-tuning — restoring it is the
# clean remove. If that backup is gone but the pool still carries our
# signature (uncommented pm.process_idle_timeout / pm.max_requests — stock
# www.conf only ships them commented), the pm.* lines this tool manages are
# commented back out so FPM falls back to its compiled defaults — and only
# after writing a fresh ${pool}.remove-bak. A live pool is never rewritten
# without a backup.
# Args: $1 = target_site (optional, ignored for global feature)
# Returns: 0 on success, 1 if nothing was applied
feature_remove_custom_php_fpm_tuning() {
    # shellcheck disable=SC2034  # target_site reserved for API compatibility (global feature)
    local target_site="${1:-}"

    local pool_file=""
    if type -t _fpm_find_pool_config &>/dev/null; then
        pool_file=$(_fpm_find_pool_config)
    fi

    local before_bak="${pool_file}.before-tuning"
    local has_before=false has_marker=false
    if [[ -n "$pool_file" ]] && [[ -f "$before_bak" ]]; then
        has_before=true
    fi
    if [[ -n "$pool_file" ]] && [[ -f "$pool_file" ]] && \
       grep -qE '^[[:space:]]*pm\.(process_idle_timeout|max_requests)[[:space:]]*=' "$pool_file" 2>/dev/null; then
        has_marker=true
    fi

    if [[ "$has_before" == false ]] && [[ "$has_marker" == false ]]; then
        if [ "${DRY_RUN:-false}" = true ]; then
            return 0
        fi
        if type -t log_info &>/dev/null; then
            log_info "PHP-FPM tuning not applied — nothing to remove"
        fi
        return 1
    fi

    if [ "${DRY_RUN:-false}" = true ]; then
        if type -t ui_step_path &>/dev/null; then
            if [[ "$has_before" == true ]]; then
                ui_step_path "Would restore" "$before_bak"
            else
                ui_step_path "Would comment out pm.* tuning in" "$pool_file"
            fi
        fi
        return 0
    fi

    local SUDO=""
    [[ ! -w "$pool_file" ]] && SUDO="sudo"

    if [[ "$has_before" == true ]]; then
        if $SUDO cp "$before_bak" "$pool_file"; then
            $SUDO rm -f "$before_bak"
            if type -t ui_step_path &>/dev/null; then
                ui_step_path "Restored" "PHP-FPM pool from ${before_bak}"
            fi
            return 0
        fi
        return 1
    fi

    # Backup missing but our signature is present: back up the live pool
    # BEFORE touching it, then comment out the directives this tool manages.
    if ! $SUDO cp "$pool_file" "${pool_file}.remove-bak"; then
        return 1
    fi
    $SUDO sed -i.rmback \
        -e 's|^[[:space:]]*pm[[:space:]]*=|; &|' \
        -e 's|^[[:space:]]*pm\.max_children[[:space:]]*=|; &|' \
        -e 's|^[[:space:]]*pm\.start_servers[[:space:]]*=|; &|' \
        -e 's|^[[:space:]]*pm\.min_spare_servers[[:space:]]*=|; &|' \
        -e 's|^[[:space:]]*pm\.max_spare_servers[[:space:]]*=|; &|' \
        -e 's|^[[:space:]]*pm\.process_idle_timeout[[:space:]]*=|; &|' \
        -e 's|^[[:space:]]*pm\.max_requests[[:space:]]*=|; &|' \
        "$pool_file" 2>/dev/null || \
        $SUDO sed -i '' \
        -e 's|^[[:space:]]*pm[[:space:]]*=|; &|' \
        -e 's|^[[:space:]]*pm\.max_children[[:space:]]*=|; &|' \
        -e 's|^[[:space:]]*pm\.start_servers[[:space:]]*=|; &|' \
        -e 's|^[[:space:]]*pm\.min_spare_servers[[:space:]]*=|; &|' \
        -e 's|^[[:space:]]*pm\.max_spare_servers[[:space:]]*=|; &|' \
        -e 's|^[[:space:]]*pm\.process_idle_timeout[[:space:]]*=|; &|' \
        -e 's|^[[:space:]]*pm\.max_requests[[:space:]]*=|; &|' \
        "$pool_file" 2>/dev/null
    $SUDO rm -f "${pool_file}.rmback" 2>/dev/null

    if type -t ui_step_path &>/dev/null; then
        ui_step_path "Reverted PHP-FPM tuning" "${pool_file} (backup: ${pool_file}.remove-bak)"
    fi
    if type -t log_to_file &>/dev/null; then
        log_to_file "INFO" "PHP-FPM tuning commented out; pre-remove copy kept at ${pool_file}.remove-bak"
    fi

    return 0
}

################################################################################
# Helper Functions
################################################################################

# Find PHP-FPM pool configuration file (www.conf)
# Prints: path to pool config, or empty
_fpm_find_pool_config() {
    # Try PHP version detection first
    local php_version=""
    if command -v php &>/dev/null; then
        php_version=$(php -v 2>/dev/null | head -1 | sed -n 's/^PHP \([0-9]\.[0-9]\).*/\1/p')
    fi

    # Search common locations (version-specific first, then generic)
    local search_paths=()
    if [[ -n "$php_version" ]]; then
        search_paths+=(
            "/etc/php/${php_version}/fpm/pool.d/www.conf"
            "/etc/php/${php_version}/fpm/php-fpm.d/www.conf"
        )
    fi
    search_paths+=(
        "/etc/php-fpm.d/www.conf"
        "/usr/local/etc/php-fpm.d/www.conf"
        "/opt/homebrew/etc/php-fpm.d/www.conf"
    )
    # Also search for any PHP version's pool config
    local versioned_conf
    for versioned_conf in /etc/php/*/fpm/pool.d/www.conf; do
        if [[ -f "$versioned_conf" ]]; then
            search_paths+=("$versioned_conf")
        fi
    done

    for path in "${search_paths[@]}"; do
        if [[ -f "$path" ]]; then
            echo "$path"
            return 0
        fi
    done

    return 1
}

# Set a directive in a PHP-FPM pool config file
# Handles: existing directive (uncommented or commented), or appending new
# Args: $1 = file, $2 = directive name, $3 = value
_fpm_set_directive() {
    local file="$1"
    local directive="$2"
    local value="$3"

    # Escape dots for regex
    local escaped_directive
    escaped_directive=$(printf '%s' "$directive" | sed 's/\./\\./g')

    if grep -qE "^[[:space:]]*;?[[:space:]]*${escaped_directive}[[:space:]]*=" "$file" 2>/dev/null; then
        # Replace existing (whether commented or uncommented)
        sed -i.bak "s|^[[:space:]]*;*[[:space:]]*${escaped_directive}[[:space:]]*=.*|${directive} = ${value}|" "$file" 2>/dev/null || \
            sed -i '' "s|^[[:space:]]*;*[[:space:]]*${escaped_directive}[[:space:]]*=.*|${directive} = ${value}|" "$file" 2>/dev/null
        rm -f "${file}.bak" 2>/dev/null
    else
        # Append after [www] section header (or at end)
        echo "${directive} = ${value}" >> "$file"
    fi
}

################################################################################
# Register Feature
################################################################################

feature_register
