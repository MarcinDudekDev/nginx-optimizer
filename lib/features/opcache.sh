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
    php_version=$(php -v 2>/dev/null | head -1 | sed -n 's/^PHP \([0-9]\.[0-9]\).*/\1/p')

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
        if type -t log_warn &>/dev/null; then
            log_warn "PHP not found in PATH"
        fi
        return 1
    fi

    # Ensure template exists
    if ! _opcache_ensure_template; then
        if type -t log_error &>/dev/null; then
            log_error "Failed to create OpCache template"
        fi
        return 1
    fi

    # Deploy configuration
    _opcache_deploy_config

    if type -t log_to_file &>/dev/null; then
        log_to_file "SUCCESS" "OpCache configuration applied"
    fi

    return 0
}

################################################################################
# Helper Functions
################################################################################

# Ensure OpCache template exists
_opcache_ensure_template() {
    local template_dir="${TEMPLATE_DIR:-nginx-optimizer-templates}"
    local template="${template_dir}/opcache.ini"

    if [ -f "$template" ]; then
        return 0
    fi

    if [ "${DRY_RUN:-false}" = true ]; then
        return 0
    fi

    # Create template
    mkdir -p "$template_dir" 2>/dev/null
    cat > "$template" << 'EOF'
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

    if type -t log_to_file &>/dev/null; then
        log_to_file "INFO" "Created OpCache template (Balanced mode)"
    fi

    return 0
}

# Deploy OpCache configuration to PHP config directory
_opcache_deploy_config() {
    local template_dir="${TEMPLATE_DIR:-nginx-optimizer-templates}"
    local template="${template_dir}/opcache.ini"

    if [ "${DRY_RUN:-false}" = true ]; then
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Would configure" "PHP OpCache"
        fi
        return 0
    fi

    # Find PHP version
    local php_version
    php_version=$(php -v 2>/dev/null | head -1 | sed -n 's/^PHP \([0-9]\.[0-9]\).*/\1/p')

    if [ -z "$php_version" ]; then
        if type -t log_warn &>/dev/null; then
            log_warn "Could not determine PHP version"
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

    local deployed=false
    for php_conf_dir in "${php_conf_dirs[@]}"; do
        if [ -d "$php_conf_dir" ]; then
            local dest="${php_conf_dir}/99-opcache-optimized.ini"

            # Try with sudo first
            if sudo cp "$template" "$dest" 2>/dev/null; then
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
        cp "$template" "${data_dir}/opcache.ini"

        if type -t log_warn &>/dev/null; then
            log_warn "Could not copy to system PHP config (permissions)"
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
