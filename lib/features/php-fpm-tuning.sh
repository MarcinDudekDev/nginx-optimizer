#!/bin/bash
################################################################################
# features/php-fpm-tuning.sh - PHP-FPM RAM-Aware Tuning
################################################################################
# Tunes PHP-FPM pm.max_children and process manager settings based on
# available system RAM. This is the #1 cause of OOM on WordPress VPSes:
# each PHP worker consumes 30-60MB, and the default max_children is often
# too high for the available RAM.
#
# The math: available_ram_for_php = total_ram * 0.5 (leaving room for
# nginx, MySQL, Redis, OS). max_children = available / avg_worker_size.
#
# Inspired by easyinstallvps RAM-tier approach.
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
        if type -t log_warn &>/dev/null; then
            log_warn "PHP not found — skipping FPM tuning"
        fi
        return 1
    fi

    # Find pool config
    local pool_file
    pool_file=$(_fpm_find_pool_config)

    if [[ -z "$pool_file" ]]; then
        if type -t log_warn &>/dev/null; then
            log_warn "Cannot find PHP-FPM pool config (www.conf)"
        fi
        return 1
    fi

    # Calculate tuned values
    local ram_mb max_children start min spare max_spare avg_worker_mb
    if type -t sysinfo_ram_mb &>/dev/null; then
        ram_mb=$(sysinfo_ram_mb)
    else
        ram_mb=2048
    fi

    # Average PHP worker memory: 40MB is a safe estimate for WordPress
    # (ranges 25-80MB depending on plugins; 40MB is median)
    avg_worker_mb=40

    # Budget 50% of RAM for PHP-FPM (rest: OS ~15%, MySQL ~20%, nginx+Redis ~15%)
    local php_ram_mb=$(( ram_mb / 2 ))
    local ram_based=$(( php_ram_mb / avg_worker_mb ))

    # CPU core cap: prevent more workers than cores can serve efficiently
    # WordPress/WooCommerce is mixed CPU + I/O; 10x cores is a practical ceiling
    local cores cpu_cap
    if type -t sysinfo_cpu_cores &>/dev/null; then
        cores=$(sysinfo_cpu_cores)
    else
        cores=1
    fi
    cpu_cap=$(( cores * 10 ))
    [[ $cpu_cap -lt 3 ]] && cpu_cap=3

    # Use the lower of RAM-based and CPU-based limits
    if [[ $ram_based -lt $cpu_cap ]]; then
        max_children=$ram_based
    else
        max_children=$cpu_cap
    fi

    # Sanity bounds
    if [[ $max_children -lt 3 ]]; then
        max_children=3
    elif [[ $max_children -gt 200 ]]; then
        max_children=200
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
            ui_step_path "  pm.max_children" "${max_children} (RAM: ${ram_mb}MB×50%/${avg_worker_mb}MB=${ram_based}, CPU: ${cores}×10=${cpu_cap}, using lower)"
            ui_step_path "  pm.start_servers" "$start"
            ui_step_path "  pm.min_spare_servers" "$min"
            ui_step_path "  pm.max_spare_servers" "$max_spare"
        fi
        return 0
    fi

    # Backup original
    local use_sudo=""
    if [[ ! -w "$pool_file" ]]; then
        use_sudo="sudo"
    fi
    $use_sudo cp "$pool_file" "${pool_file}.before-tuning"

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
    $use_sudo cp "$temp_file" "$pool_file"
    rm -f "$temp_file"

    if type -t ui_step_path &>/dev/null; then
        ui_step_path "Tuned PHP-FPM" "max_children=${max_children} (${ram_mb}MB × 50% / ${avg_worker_mb}MB)"
    fi

    # Suggest restart
    if type -t log_info &>/dev/null; then
        log_info "Restart PHP-FPM to apply: sudo systemctl reload php*-fpm"
    fi

    if type -t log_to_file &>/dev/null; then
        log_to_file "SUCCESS" "PHP-FPM tuned: max_children=${max_children} (was backed up)"
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
