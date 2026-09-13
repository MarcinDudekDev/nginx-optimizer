#!/bin/bash
################################################################################
# features/opcache.sh - PHP OpCache
################################################################################
# Feature module with custom detection and apply logic for PHP configuration.
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
FEATURE_ID="opcache"
# shellcheck disable=SC2034
FEATURE_DISPLAY="PHP OpCache"
# shellcheck disable=SC2034
FEATURE_DETECT_PATTERN="opcache.enable=1"
# shellcheck disable=SC2034
FEATURE_SCOPE="global"
# shellcheck disable=SC2034
FEATURE_TEMPLATE="opcache.ini"
# shellcheck disable=SC2034
FEATURE_TEMPLATE_CONTEXT=""
# shellcheck disable=SC2034
FEATURE_ALIASES="php"
# shellcheck disable=SC2034
FEATURE_NGINX_MIN_VERSION=""
# shellcheck disable=SC2034
FEATURE_PREREQ_CHECK=""

################################################################################
# Custom Detection
################################################################################

# Detect if OpCache is enabled in PHP configuration
# Args: $1 = config_file (unused), $2 = site_name (unused)
# Returns: 0 if enabled, 1 if not
# Sets: LAST_DIRECTIVE_SOURCE
feature_detect_custom_opcache() {
    # shellcheck disable=SC2034  # config_file reserved for API compatibility
    local config_file="$1"
    # shellcheck disable=SC2034  # site_name reserved for API compatibility
    local site_name="$2"

    # Check if PHP is available
    if ! command -v php &>/dev/null; then
        return 1
    fi

    # Get PHP version
    local php_version
    php_version=$(php -v 2>/dev/null | head -1 | sed -n 's/^PHP \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')

    if [ -z "$php_version" ]; then
        return 1
    fi

    # Check common PHP config locations
    local php_conf_dirs=(
        "/etc/php/${php_version}/fpm/conf.d"
        "/etc/php/${php_version}/cli/conf.d"
        "/etc/php.d"
        "/usr/local/etc/php/${php_version}/conf.d"
    )

    for conf_dir in "${php_conf_dirs[@]}"; do
        if [ -d "$conf_dir" ]; then
            # Check for opcache config files
            for conf_file in "$conf_dir"/*opcache*.ini; do
                if [ -f "$conf_file" ]; then
                    if grep -q "opcache.enable=1\|opcache.enable = 1" "$conf_file" 2>/dev/null; then
                        # shellcheck disable=SC2034  # LAST_DIRECTIVE_SOURCE consumed by registry.sh
                        LAST_DIRECTIVE_SOURCE="$conf_file"
                        return 0
                    fi
                fi
            done
        fi
    done

    # Check if opcache is loaded via php -m
    if php -m 2>/dev/null | grep -iq "opcache"; then
        # shellcheck disable=SC2034  # LAST_DIRECTIVE_SOURCE consumed by registry.sh
        LAST_DIRECTIVE_SOURCE="php.ini"
        return 0
    fi

    return 1
}

################################################################################
# Custom Apply
################################################################################

# Apply OpCache configuration
# Args: $1 = target_site (unused for global scope)
# Returns: 0 on success, 1 on failure
feature_apply_custom_opcache() {
    # shellcheck disable=SC2034  # target_site reserved for global features
    local target_site="${1:-}"

    if type -t log_to_file &>/dev/null; then
        log_to_file "INFO" "Applying PHP OpCache configuration..."
    fi

    # Check if PHP is available
    if ! command -v php &>/dev/null; then
        if type -t apply_log &>/dev/null; then
            apply_log WARN "PHP not found in PATH"
        fi
        return 1
    fi

    # Deploy configuration (content is generated per RAM tier)
    _opcache_deploy_config

    if type -t log_to_file &>/dev/null; then
        log_to_file "SUCCESS" "OpCache configuration applied"
    fi

    return 0
}

################################################################################
# Helper Functions
################################################################################

# Render the OpCache ini content, sized for the detected RAM tier
# Prints: full ini file content on stdout
_opcache_render_config() {
    # RAM-aware sizing (falls back to tier-5 values if sysinfo is unavailable)
    local mem=256 strings=32 max_files=16230 huge=0

    if type -t sysinfo_opcache_memory &>/dev/null; then
        mem=$(sysinfo_opcache_memory)
        strings=$(sysinfo_opcache_interned_strings)
        max_files=$(sysinfo_opcache_max_files)
        huge=$(sysinfo_opcache_huge_pages)
    fi

    cat << EOF
; PHP OpCache Configuration (RAM-tuned)
; Generated by nginx-optimizer with detected system resources.
;
; OpCache has three INDEPENDENT hard ceilings and NO eviction policy. When any
; one of them is hit, new files are simply never cached - they recompile on
; every request, forever, with no log line, no counter and no restart fired.
; A store can show a 99% "hit rate" while recompiling ~1200 files per page view.
;
; The ceilings belong to the PHP-FPM POOL, not to one site: production,
; staging, dev and every neighbouring vhost under the same FPM master share
; one buffer. Values below are sized for the sum, not for a single site.
;
; Verify with opcache_get_status() through FPM (NOT wp-cli - the CLI has its
; own separate cache): cache_full must be false, num_cached_keys must stay
; below max_cached_keys, and the misses counter must stop climbing on a warm
; site. Do not trust hit rate - it is a vanity metric here.

[opcache]
opcache.enable=1

; Shared opcode buffer. interned_strings_buffer below is carved OUT of this
; value, not added to it: effective opcode budget = memory - interned strings.
; One plugin-equipped WooCommerce store measures ~99MB of pure opcode.
opcache.memory_consumption=${mem}

; Deduplicated class/function names, literals and docblocks, shared across all
; workers. When full, new strings stop being interned and duplicate into every
; worker's PRIVATE memory instead. One equipped store measures ~22MB.
opcache.interned_strings_buffer=${strings}

; Hash-table slots. THE CONFIGURED VALUE IS ROUNDED UP to the next prime from
; a fixed table: 1979, 3907, 7963, 16229, 32531, 65407. So 10000 and 16229 are
; the SAME configuration, and 16230 is the first value that buys more slots.
; This is the ceiling that binds first: a modern WooCommerce store is large in
; FILE COUNT (~5200 slots equipped), not in megabytes.
opcache.max_accelerated_files=${max_files}

; Pick up plugin/theme updates without a mandatory FPM reload. 60s of
; staleness is the right trade for WordPress, which self-updates.
opcache.validate_timestamps=1
opcache.revalidate_freq=60

; Required for ecosystem safety: PHP attributes, docblock consumers and some
; autoloaders in the plugin ecosystem break without comments. Never set 0.
opcache.save_comments=1

; Short-circuits file_exists()/is_file()/is_readable() against the opcode
; cache - WordPress makes many such probes. Safe ONLY because
; validate_timestamps=1 above bounds staleness to revalidate_freq seconds.
opcache.enable_file_override=1

; Make the silent failure mode audible: level 2 logs cache restarts and
; force-restart events, which no hosting dashboard will ever show you.
opcache.log_verbosity_level=2

; JIT is off by default - PHP 8.x itself ships opcache.jit=disable.
; WordPress/WooCommerce is I/O and DB bound, so JIT measures at noise level,
; while tracing JIT has a segfault history under plugin code. jit_buffer_size
; is a SEPARATE shared allocation on top of memory_consumption.
opcache.jit=disable

; Huge code pages: enabled only when the kernel advertises [always]/[madvise].
; On an unsupported build PHP warns on EVERY process start, flooding the log.
opcache.huge_code_pages=${huge}

; --- Deliberately not set ---------------------------------------------------
; opcache.fast_shutdown         - removed in PHP 7.2, absent from PHP 8.x.
; opcache.enable_cli            - this file is deployed to fpm/conf.d only.
; opcache.max_wasted_percentage - default is already 5. A restart fires only
;     when the buffer is BOTH out of space AND past the threshold, so waste
;     can sit high on a healthy buffer with nothing happening. The real remedy
;     after bulk plugin updates is opcache_reset() or an FPM reload.
; opcache.file_update_protection - default is already 2.
; opcache.preload               - poor fit for dynamic WP plugin stacks.
; opcache.restrict_api          - left empty so opcache_get_status() stays
;     callable. Blocking it is what makes this failure mode undiagnosable.
; opcache.validate_permission   - set 1 only on multi-user shared hosting.
EOF
}

# Deploy OpCache configuration to PHP config directory
_opcache_deploy_config() {
    local content
    content=$(_opcache_render_config)

    if [ "${DRY_RUN:-false}" = true ]; then
        if type -t ui_step_path &>/dev/null; then
            local mem="?" max_files="?"
            if type -t sysinfo_opcache_memory &>/dev/null; then
                mem=$(sysinfo_opcache_memory)
                max_files=$(sysinfo_opcache_max_files)
            fi
            ui_step_path "Would configure" "PHP OpCache (${mem}MB buffer, ${max_files} files)"
        fi
        return 0
    fi

    # Find PHP version
    local php_version
    php_version=$(php -v 2>/dev/null | head -1 | sed -n 's/^PHP \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')

    if [ -z "$php_version" ]; then
        if type -t apply_log &>/dev/null; then
            apply_log WARN "Could not determine PHP version"
        fi
        return 1
    fi

    # Try common PHP config directories
    local php_conf_dirs=(
        "/etc/php/${php_version}/fpm/conf.d"
        "/etc/php/${php_version}/cli/conf.d"
        "/etc/php.d"
        "/usr/local/etc/php/${php_version}/conf.d"
    )

    # NOTE: this loop breaks on the first successful write, which on Debian is
    # fpm/conf.d. That is deliberate - the CLI has its own separate OpCache and
    # is not what we are tuning. Do not add CLI-scoped directives to the ini.
    local deployed=false
    for php_conf_dir in "${php_conf_dirs[@]}"; do
        if [ -d "$php_conf_dir" ]; then
            local dest="${php_conf_dir}/99-opcache-optimized.ini"

            # Write directly when the conf.d dir is writable; elevate only if not
            if printf '%s\n' "$content" | smart_write "$dest" >/dev/null 2>&1; then
                if type -t ui_step_path &>/dev/null; then
                    ui_step_path "Configured OpCache" "PHP ${php_version}"
                fi
                if type -t log_to_file &>/dev/null; then
                    log_to_file "SUCCESS" "OpCache configured for PHP ${php_version}"
                    log_to_file "INFO" "Restart PHP-FPM to apply changes"
                fi
                deployed=true
                break
            fi
        fi
    done

    # Fallback: save to data directory with instructions
    if [ "$deployed" = false ]; then
        local data_dir="${DATA_DIR:-$HOME/.nginx-optimizer}"
        mkdir -p "$data_dir" 2>/dev/null
        printf '%s\n' "$content" > "${data_dir}/opcache.ini"

        if type -t apply_log &>/dev/null; then
            apply_log WARN "Could not copy to system PHP config (permissions)"
        fi
        if type -t log_to_file &>/dev/null; then
            log_to_file "INFO" "OpCache config saved to: ${data_dir}/opcache.ini"
            log_to_file "INFO" "Manual step: Copy to /etc/php/${php_version}/fpm/conf.d/99-opcache-optimized.ini"
        fi
    fi

    return 0
}

################################################################################
# Register Feature
################################################################################

feature_register
