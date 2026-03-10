#!/bin/bash
################################################################################
# features/brotli.sh - Brotli Compression
################################################################################
# Declarative feature module for nginx-optimizer.
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
FEATURE_ID="brotli"
# shellcheck disable=SC2034
FEATURE_DISPLAY="Compression"
# shellcheck disable=SC2034
FEATURE_DETECT_PATTERN="brotli on"
# shellcheck disable=SC2034
FEATURE_SCOPE="global"
# shellcheck disable=SC2034
FEATURE_TEMPLATE="compression.conf"
# shellcheck disable=SC2034
FEATURE_TEMPLATE_CONTEXT="http"
# shellcheck disable=SC2034
FEATURE_ALIASES="compression"
# shellcheck disable=SC2034
FEATURE_NGINX_MIN_VERSION=""
# shellcheck disable=SC2034
FEATURE_PREREQ_CHECK=""

################################################################################
# Custom Detect Logic
################################################################################

# Custom detection: Check if compression is enabled (brotli or gzip)
# Args: $1 = config_file, $2 = site_name (optional)
# Returns: 0 if compression is enabled, 1 if not
feature_detect_custom_brotli() {
    local config_file="$1"
    # shellcheck disable=SC2034  # site_name used in conditional logic
    local site_name="${2:-}"

    # Check if wp-test-proxy uses brotli-enabled image
    if command -v docker &>/dev/null; then
        if docker ps --filter "name=wp-test-proxy" --format "{{.Image}}" 2>/dev/null | grep -q "brotli"; then
            # shellcheck disable=SC2034  # LAST_DIRECTIVE_SOURCE consumed by registry.sh
            LAST_DIRECTIVE_SOURCE="docker:wp-test-proxy"
            return 0
        fi
    fi

    # Check site config for brotli
    if [[ -f "$config_file" ]] && grep -qE "brotli[[:space:]]+on" "$config_file" 2>/dev/null; then
        # shellcheck disable=SC2034  # LAST_DIRECTIVE_SOURCE consumed by registry.sh
        LAST_DIRECTIVE_SOURCE="$config_file"
        return 0
    fi

    # Check conf.d for compression.conf with brotli or gzip
    local confd_dir
    if type -t get_nginx_confd_dir &>/dev/null; then
        confd_dir=$(get_nginx_confd_dir)
    fi
    if [[ -n "$confd_dir" ]] && [[ -d "$confd_dir" ]]; then
        # Check for our compression.conf
        if [[ -f "${confd_dir}/compression.conf" ]]; then
            # shellcheck disable=SC2034  # LAST_DIRECTIVE_SOURCE consumed by registry.sh
            LAST_DIRECTIVE_SOURCE="conf.d/compression.conf"
            return 0
        fi
        # Check for gzip in any conf.d file
        if grep -rqE "gzip[[:space:]]+on" "$confd_dir" 2>/dev/null; then
            # shellcheck disable=SC2034  # LAST_DIRECTIVE_SOURCE consumed by registry.sh
            LAST_DIRECTIVE_SOURCE="conf.d/"
            return 0
        fi
    fi

    # Check nginx main config for gzip - use helper if available
    local nginx_conf
    if type -t get_nginx_main_conf &>/dev/null; then
        nginx_conf=$(get_nginx_main_conf)
        if [[ -f "$nginx_conf" ]] && grep -qE "gzip[[:space:]]+on" "$nginx_conf" 2>/dev/null; then
            # shellcheck disable=SC2034  # LAST_DIRECTIVE_SOURCE consumed by registry.sh
            LAST_DIRECTIVE_SOURCE="$nginx_conf"
            return 0
        fi
    else
        # Fallback to hardcoded paths
        for conf in /etc/nginx/nginx.conf /usr/local/etc/nginx/nginx.conf /opt/homebrew/etc/nginx/nginx.conf; do
            if [[ -f "$conf" ]] && grep -qE "gzip[[:space:]]+on" "$conf" 2>/dev/null; then
                # shellcheck disable=SC2034  # LAST_DIRECTIVE_SOURCE consumed by registry.sh
                LAST_DIRECTIVE_SOURCE="$conf"
                return 0
            fi
        done
    fi

    return 1
}

################################################################################
# Custom Apply Logic
################################################################################

# Apply compression configuration (gzip + brotli if available)
# Args: $1 = target_site (optional, ignored for global feature)
# Returns: 0 on success, 1 on failure
feature_apply_custom_brotli() {
    # shellcheck disable=SC2034  # target_site reserved for global features
    local target_site="${1:-}"

    if type -t log_to_file &>/dev/null; then
        log_to_file "INFO" "Applying Brotli/Gzip compression..."
    fi

    # Comment out existing gzip directives in nginx.conf to avoid duplicates
    local nginx_conf
    if type -t get_nginx_main_conf &>/dev/null; then
        nginx_conf=$(get_nginx_main_conf)
    else
        nginx_conf="/etc/nginx/nginx.conf"
    fi
    if [[ -f "$nginx_conf" ]] && grep -qE "^[[:space:]]*gzip" "$nginx_conf" 2>/dev/null; then
        if [ "${DRY_RUN:-false}" != true ]; then
            if type -t log_to_file &>/dev/null; then
                log_to_file "INFO" "Commenting out existing gzip directives in $nginx_conf"
            fi
            if type -t sed_i &>/dev/null; then
                if [ -w "$nginx_conf" ]; then
                    sed_i 's/^[[:space:]]*gzip\b/# &/' "$nginx_conf"
                else
                    sed_i --sudo 's/^[[:space:]]*gzip\b/# &/' "$nginx_conf"
                fi
            else
                if [ -w "$nginx_conf" ]; then
                    sed -i 's/^[[:space:]]*gzip\b/# &/' "$nginx_conf"
                else
                    sudo sed -i 's/^[[:space:]]*gzip\b/# &/' "$nginx_conf"
                fi
            fi
        fi
    fi

    # Deploy compression.conf to conf.d
    if type -t deploy_template_to_confd &>/dev/null; then
        if deploy_template_to_confd "compression.conf"; then
            return 0
        fi
    fi

    # Fallback: manual deployment
    local confd_dir
    if type -t get_nginx_confd_dir &>/dev/null; then
        confd_dir=$(get_nginx_confd_dir)
    fi
    if [[ -z "$confd_dir" ]]; then
        if type -t log_warn &>/dev/null; then
            log_warn "Cannot find nginx conf.d directory"
        fi
        return 1
    fi

    local template_dir="${TEMPLATE_DIR:-nginx-optimizer-templates}"
    local src="${template_dir}/compression.conf"
    local dst="${confd_dir}/compression.conf"

    if [[ ! -f "$src" ]]; then
        if type -t log_warn &>/dev/null; then
            log_warn "Compression template not found: $src"
        fi
        return 1
    fi

    if [ "${DRY_RUN:-false}" = true ]; then
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Would deploy" "conf.d/compression.conf"
        fi
        return 0
    fi

    # Deploy with smart sudo
    if [ -w "$confd_dir" ]; then
        cp "$src" "$dst"
    else
        sudo cp "$src" "$dst"
    fi

    if type -t ui_step_path &>/dev/null; then
        ui_step_path "Deployed" "conf.d/compression.conf"
    fi

    return 0
}

################################################################################
# Register Feature
################################################################################

feature_register

