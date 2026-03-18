#!/bin/bash
################################################################################
# features/open-file-cache.sh - Open File Cache
################################################################################
# Caches file descriptors and metadata to eliminate filesystem syscalls.
# Significant impact on high-traffic sites with many static assets.
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
FEATURE_ID="open-file-cache"
# shellcheck disable=SC2034
FEATURE_DISPLAY="Open File Cache"
# shellcheck disable=SC2034
FEATURE_DETECT_PATTERN="open_file_cache[[:space:]]+max="
# shellcheck disable=SC2034
FEATURE_SCOPE="global"
# shellcheck disable=SC2034
FEATURE_TEMPLATE="open-file-cache.conf"
# shellcheck disable=SC2034
FEATURE_TEMPLATE_CONTEXT="http"
# shellcheck disable=SC2034
FEATURE_ALIASES="filecache"
# shellcheck disable=SC2034
FEATURE_NGINX_MIN_VERSION=""
# shellcheck disable=SC2034
FEATURE_PREREQ_CHECK=""

################################################################################
# Custom Detection Logic
################################################################################

# Detect open_file_cache in nginx configs
# Args: $1 = config_file, $2 = site_name (optional)
# Returns: 0 if detected, 1 if not
feature_detect_custom_open_file_cache() {
    # shellcheck disable=SC2034  # config_file part of detection API, not used for global feature
    local config_file="$1"
    # shellcheck disable=SC2034  # site_name reserved for API compatibility
    local site_name="${2:-}"

    # Check conf.d for our template
    local confd_dir
    if type -t get_nginx_confd_dir &>/dev/null; then
        confd_dir=$(get_nginx_confd_dir)
    fi
    if [[ -n "${confd_dir:-}" ]] && [[ -f "${confd_dir}/open-file-cache.conf" ]]; then
        # shellcheck disable=SC2034  # LAST_DIRECTIVE_SOURCE consumed by registry.sh
        LAST_DIRECTIVE_SOURCE="conf.d/open-file-cache.conf"
        return 0
    fi

    # Check nginx.conf for open_file_cache directive
    local nginx_conf
    if type -t get_nginx_main_conf &>/dev/null; then
        nginx_conf=$(get_nginx_main_conf)
        if [[ -f "$nginx_conf" ]] && grep -qE "open_file_cache[[:space:]]+max=" "$nginx_conf" 2>/dev/null; then
            # shellcheck disable=SC2034  # LAST_DIRECTIVE_SOURCE consumed by registry.sh
            LAST_DIRECTIVE_SOURCE="$nginx_conf"
            return 0
        fi
    fi

    # Check conf.d for any file with open_file_cache
    if [[ -n "${confd_dir:-}" ]] && [[ -d "$confd_dir" ]]; then
        if grep -rqE "open_file_cache[[:space:]]+max=" "$confd_dir" 2>/dev/null; then
            # shellcheck disable=SC2034  # LAST_DIRECTIVE_SOURCE consumed by registry.sh
            LAST_DIRECTIVE_SOURCE="conf.d/"
            return 0
        fi
    fi

    return 1
}

################################################################################
# Custom Apply Logic
################################################################################

# Apply open_file_cache to conf.d
# Args: $1 = target_site (optional, ignored for global feature)
# Returns: 0 on success, 1 on failure
feature_apply_custom_open_file_cache() {
    # shellcheck disable=SC2034  # target_site reserved for global features
    local target_site="${1:-}"

    if type -t log_to_file &>/dev/null; then
        log_to_file "INFO" "Applying Open File Cache..."
    fi

    # Skip if already configured in nginx.conf or conf.d (avoid duplicate directive)
    local nginx_conf
    if type -t get_nginx_main_conf &>/dev/null; then
        nginx_conf=$(get_nginx_main_conf)
        if [[ -f "$nginx_conf" ]] && grep -qE "^[[:space:]]*open_file_cache[[:space:]]+max=" "$nginx_conf" 2>/dev/null; then
            if type -t ui_step_path &>/dev/null; then
                ui_step_path "Already configured in" "$nginx_conf"
            fi
            return 0
        fi
    fi
    local confd_dir
    if type -t get_nginx_confd_dir &>/dev/null; then
        confd_dir=$(get_nginx_confd_dir)
    fi
    if [[ -n "${confd_dir:-}" ]] && grep -rqE "open_file_cache[[:space:]]+max=" "$confd_dir" 2>/dev/null; then
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Already configured in" "conf.d/"
        fi
        return 0
    fi

    # Deploy to conf.d
    if type -t deploy_template_to_confd &>/dev/null; then
        if deploy_template_to_confd "open-file-cache.conf"; then
            return 0
        fi
    fi

    # Fallback: manual deployment
    local confd_dir
    if type -t get_nginx_confd_dir &>/dev/null; then
        confd_dir=$(get_nginx_confd_dir)
    fi
    if [[ -z "${confd_dir:-}" ]]; then
        for dir in /etc/nginx/conf.d /opt/homebrew/etc/nginx/conf.d /usr/local/etc/nginx/conf.d; do
            if [[ -d "$dir" ]]; then
                confd_dir="$dir"
                break
            fi
        done
    fi

    if [[ -z "${confd_dir:-}" ]]; then
        if type -t log_warn &>/dev/null; then
            log_warn "Cannot find nginx conf.d directory"
        fi
        return 1
    fi

    local template_dir="${TEMPLATE_DIR:-nginx-optimizer-templates}"
    local src="${template_dir}/open-file-cache.conf"
    local dst="${confd_dir}/open-file-cache.conf"

    if [[ ! -f "$src" ]]; then
        if type -t log_warn &>/dev/null; then
            log_warn "Open file cache template not found: $src"
        fi
        return 1
    fi

    if [ "${DRY_RUN:-false}" = true ]; then
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Would deploy" "conf.d/open-file-cache.conf"
        fi
        return 0
    fi

    if [[ -w "$confd_dir" ]]; then
        cp "$src" "$dst"
    else
        sudo cp "$src" "$dst"
    fi

    if [[ -f "$dst" ]]; then
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Deployed" "conf.d/open-file-cache.conf"
        fi
        return 0
    fi

    return 1
}

################################################################################
# Register Feature
################################################################################

feature_register
