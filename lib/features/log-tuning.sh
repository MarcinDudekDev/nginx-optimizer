#!/bin/bash
################################################################################
# features/log-tuning.sh - Log Tuning
################################################################################
# Custom log format with upstream timing metrics for performance analysis.
# Buffered log writes to reduce disk I/O on high-traffic sites.
# With thanks to easyinstallvps project's logging approach -- https://github.com/sugan0927/easyinstallvps
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
FEATURE_ID="log-tuning"
# shellcheck disable=SC2034
FEATURE_DISPLAY="Log Tuning"
# shellcheck disable=SC2034
FEATURE_DETECT_PATTERN="log_format[[:space:]]+timed"
# shellcheck disable=SC2034
FEATURE_SCOPE="global"
# shellcheck disable=SC2034
FEATURE_TEMPLATE="log-tuning.conf"
# shellcheck disable=SC2034
FEATURE_TEMPLATE_CONTEXT="http"
# shellcheck disable=SC2034
FEATURE_ALIASES="logging,logs"
# shellcheck disable=SC2034
FEATURE_NGINX_MIN_VERSION=""
# shellcheck disable=SC2034
FEATURE_PREREQ_CHECK=""

################################################################################
# Custom Detection Logic
################################################################################

# Detect log tuning configuration
# Args: $1 = config_file, $2 = site_name (optional)
# Returns: 0 if detected, 1 if not
feature_detect_custom_log_tuning() {
    # shellcheck disable=SC2034  # config_file part of detection API
    local config_file="$1"
    # shellcheck disable=SC2034  # site_name reserved for API compatibility
    local site_name="${2:-}"

    # Check conf.d for our template
    local confd_dir
    if type -t get_nginx_confd_dir &>/dev/null; then
        confd_dir=$(get_nginx_confd_dir)
    fi
    if [[ -n "${confd_dir:-}" ]] && [[ -f "${confd_dir}/log-tuning.conf" ]]; then
        # shellcheck disable=SC2034  # LAST_DIRECTIVE_SOURCE consumed by registry.sh
        LAST_DIRECTIVE_SOURCE="conf.d/log-tuning.conf"
        return 0
    fi

    # Check nginx.conf for timed log format
    local nginx_conf
    if type -t get_nginx_main_conf &>/dev/null; then
        nginx_conf=$(get_nginx_main_conf)
        if [[ -f "$nginx_conf" ]] && grep -qE 'log_format[[:space:]]+timed' "$nginx_conf" 2>/dev/null; then
            # shellcheck disable=SC2034  # LAST_DIRECTIVE_SOURCE consumed by registry.sh
            LAST_DIRECTIVE_SOURCE="$nginx_conf"
            return 0
        fi
    fi

    # Check conf.d for any file with timed log format
    if [[ -n "${confd_dir:-}" ]] && [[ -d "$confd_dir" ]]; then
        if grep -rqE 'log_format[[:space:]]+timed' "$confd_dir" 2>/dev/null; then
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

# Apply log tuning to conf.d
# Args: $1 = target_site (optional, ignored for global feature)
# Returns: 0 on success, 1 on failure
feature_apply_custom_log_tuning() {
    # shellcheck disable=SC2034  # target_site reserved for global features
    local target_site="${1:-}"

    if type -t log_to_file &>/dev/null; then
        log_to_file "INFO" "Applying Log Tuning..."
    fi

    # Skip if already configured
    local nginx_conf
    if type -t get_nginx_main_conf &>/dev/null; then
        nginx_conf=$(get_nginx_main_conf)
        if [[ -f "$nginx_conf" ]] && grep -qE 'log_format[[:space:]]+timed' "$nginx_conf" 2>/dev/null; then
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
    if [[ -n "${confd_dir:-}" ]] && grep -rqE 'log_format[[:space:]]+timed' "$confd_dir" 2>/dev/null; then
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Already configured in" "conf.d/"
        fi
        return 0
    fi

    # Deploy to conf.d
    if type -t deploy_template_to_confd &>/dev/null; then
        if deploy_template_to_confd "log-tuning.conf"; then
            if type -t apply_log &>/dev/null; then
                apply_log INFO "To use: access_log /var/log/nginx/access.log timed buffer=32k flush=5s;"
            fi
            return 0
        fi
    fi

    # Fallback: manual deployment
    if [[ -z "${confd_dir:-}" ]]; then
        for dir in /etc/nginx/conf.d /opt/homebrew/etc/nginx/conf.d /usr/local/etc/nginx/conf.d; do
            if [[ -d "$dir" ]]; then
                confd_dir="$dir"
                break
            fi
        done
    fi

    if [[ -z "${confd_dir:-}" ]]; then
        if type -t apply_log &>/dev/null; then
            apply_log WARN "Cannot find nginx conf.d directory"
        fi
        return 1
    fi

    local template_dir="${TEMPLATE_DIR:-nginx-optimizer-templates}"
    local src="${template_dir}/log-tuning.conf"
    local dst="${confd_dir}/log-tuning.conf"

    if [[ ! -f "$src" ]]; then
        if type -t apply_log &>/dev/null; then
            apply_log WARN "Log tuning template not found: $src"
        fi
        return 1
    fi

    if [ "${DRY_RUN:-false}" = true ]; then
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Would deploy" "conf.d/log-tuning.conf"
        fi
        return 0
    fi

    smart_copy "$src" "$dst"

    if [[ -f "$dst" ]]; then
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Deployed" "conf.d/log-tuning.conf"
        fi
        if type -t apply_log &>/dev/null; then
            apply_log INFO "To use: access_log /var/log/nginx/access.log timed buffer=32k flush=5s;"
        fi
        return 0
    fi

    return 1
}

################################################################################
# Register Feature
################################################################################

feature_register
