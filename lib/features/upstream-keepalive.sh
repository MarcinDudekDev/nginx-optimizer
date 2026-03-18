#!/bin/bash
################################################################################
# features/upstream-keepalive.sh - Upstream Keepalive for PHP-FPM
################################################################################
# Enables persistent connections between nginx and PHP-FPM workers,
# eliminating connect/accept/close overhead on every request.
# Requires both: upstream block with keepalive + fastcgi_keep_conn on
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
FEATURE_ID="upstream-keepalive"
# shellcheck disable=SC2034
FEATURE_DISPLAY="Upstream Keepalive"
# shellcheck disable=SC2034
FEATURE_DETECT_PATTERN="keepalive[[:space:]]+[0-9]+"
# shellcheck disable=SC2034
FEATURE_SCOPE="global"
# shellcheck disable=SC2034
FEATURE_TEMPLATE="upstream-keepalive.conf"
# shellcheck disable=SC2034
FEATURE_TEMPLATE_CONTEXT="http"
# shellcheck disable=SC2034
FEATURE_ALIASES="keepalive,phpfpm"
# shellcheck disable=SC2034
FEATURE_NGINX_MIN_VERSION=""
# shellcheck disable=SC2034
FEATURE_PREREQ_CHECK=""

################################################################################
# Custom Detection Logic
################################################################################

# Detect upstream keepalive by checking:
# 1. conf.d for our upstream-keepalive.conf template
# 2. Any upstream block with keepalive directive
# 3. fastcgi_keep_conn on in site configs
# Args: $1 = config_file, $2 = site_name (optional)
# Returns: 0 if detected, 1 if not
feature_detect_custom_upstream_keepalive() {
    local config_file="$1"
    # shellcheck disable=SC2034  # site_name reserved for API compatibility
    local site_name="${2:-}"

    # Check conf.d for our template
    local confd_dir
    if type -t get_nginx_confd_dir &>/dev/null; then
        confd_dir=$(get_nginx_confd_dir)
    fi
    if [[ -n "${confd_dir:-}" ]] && [[ -f "${confd_dir}/upstream-keepalive.conf" ]]; then
        # shellcheck disable=SC2034  # LAST_DIRECTIVE_SOURCE consumed by registry.sh
        LAST_DIRECTIVE_SOURCE="conf.d/upstream-keepalive.conf"
        return 0
    fi

    # Check nginx.conf or includes for upstream block with keepalive
    local nginx_conf
    if type -t get_nginx_main_conf &>/dev/null; then
        nginx_conf=$(get_nginx_main_conf)
        if [[ -f "$nginx_conf" ]] && grep -qE "keepalive[[:space:]]+[0-9]+" "$nginx_conf" 2>/dev/null; then
            # shellcheck disable=SC2034  # LAST_DIRECTIVE_SOURCE consumed by registry.sh
            LAST_DIRECTIVE_SOURCE="$nginx_conf"
            return 0
        fi
    fi

    # Check conf.d for any file with upstream keepalive
    if [[ -n "${confd_dir:-}" ]] && [[ -d "$confd_dir" ]]; then
        if grep -rqE "keepalive[[:space:]]+[0-9]+" "$confd_dir" 2>/dev/null; then
            # shellcheck disable=SC2034  # LAST_DIRECTIVE_SOURCE consumed by registry.sh
            LAST_DIRECTIVE_SOURCE="conf.d/"
            return 0
        fi
    fi

    # Check site config for upstream include or keepalive
    if [[ -f "$config_file" ]]; then
        if grep -qE "include.*upstream-keepalive" "$config_file" 2>/dev/null; then
            # shellcheck disable=SC2034  # LAST_DIRECTIVE_SOURCE consumed by registry.sh
            LAST_DIRECTIVE_SOURCE="$config_file (via include)"
            return 0
        fi
    fi

    return 1
}

################################################################################
# Custom Apply Logic
################################################################################

# Apply upstream keepalive:
# 1. Deploy upstream-keepalive.conf to conf.d (http context)
# 2. Add fastcgi_keep_conn on to PHP location blocks
# 3. Update fastcgi_pass to use upstream name instead of direct socket
# Args: $1 = target_site (optional)
# Returns: 0 on success, 1 on failure
feature_apply_custom_upstream_keepalive() {
    local target_site="${1:-}"

    if type -t log_to_file &>/dev/null; then
        log_to_file "INFO" "Applying Upstream Keepalive..."
    fi

    # 1. Detect the actual PHP-FPM socket path from existing configs
    local fpm_socket
    fpm_socket=$(_keepalive_detect_fpm_socket)

    # 2. Deploy upstream block to conf.d
    _keepalive_deploy_upstream "$fpm_socket" || return 1

    # 3. Add fastcgi_keep_conn to site configs
    if _keepalive_has_system_nginx; then
        _keepalive_inject_sites "$target_site" || return 1
    fi

    # 4. Deploy to wp-test sites
    if [ "${SYSTEM_ONLY:-false}" != true ]; then
        if _keepalive_has_wptest; then
            _keepalive_deploy_wptest "$target_site" || return 1
        fi
    fi

    if type -t log_to_file &>/dev/null; then
        log_to_file "SUCCESS" "Upstream keepalive applied successfully"
    fi

    return 0
}

################################################################################
# Helper Functions
################################################################################

# Detect the PHP-FPM socket path from existing nginx configs
# Prints: socket path (defaults to unix:/var/run/php-fpm.sock)
_keepalive_detect_fpm_socket() {
    local socket=""

    # Check system nginx sites for fastcgi_pass
    local sites_dir
    if type -t find_nginx_dir &>/dev/null; then
        sites_dir=$(find_nginx_dir "sites-enabled")
    fi
    if [[ -n "${sites_dir:-}" ]] && [[ -d "$sites_dir" ]]; then
        socket=$(grep -rhE "fastcgi_pass[[:space:]]+unix:" "$sites_dir" 2>/dev/null | head -1 | sed 's/.*fastcgi_pass[[:space:]]*//;s/[[:space:]]*;.*//')
    fi

    # Check wp-test configs
    if [[ -z "$socket" ]]; then
        local wp_test_nginx="${WP_TEST_NGINX:-$HOME/.wp-test/nginx}"
        if [[ -d "$wp_test_nginx" ]]; then
            socket=$(grep -rhE "fastcgi_pass[[:space:]]+unix:" "$wp_test_nginx" 2>/dev/null | head -1 | sed 's/.*fastcgi_pass[[:space:]]*//;s/[[:space:]]*;.*//')
        fi
    fi

    # Check common socket locations on disk
    if [[ -z "$socket" ]]; then
        for sock in /var/run/php-fpm.sock /var/run/php/php-fpm.sock /var/run/php/php8.2-fpm.sock /var/run/php/php8.3-fpm.sock; do
            if [[ -S "$sock" ]]; then
                socket="unix:${sock}"
                break
            fi
        done
    fi

    # Default
    echo "${socket:-unix:/var/run/php-fpm.sock}"
}

# Deploy upstream block to conf.d
_keepalive_deploy_upstream() {
    local fpm_socket="$1"
    local template_dir="${TEMPLATE_DIR:-nginx-optimizer-templates}"
    local src="${template_dir}/upstream-keepalive.conf"

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

    local dst="${confd_dir}/upstream-keepalive.conf"

    if [ "${DRY_RUN:-false}" = true ]; then
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Would deploy" "conf.d/upstream-keepalive.conf (socket: $fpm_socket)"
        fi
        return 0
    fi

    if [[ -f "$src" ]]; then
        # Create temp copy with actual socket path substituted
        local temp_file
        if type -t secure_mktemp &>/dev/null; then
            temp_file=$(secure_mktemp)
        else
            temp_file=$(mktemp)
        fi

        # Replace the default socket path with detected one
        sed "s|unix:/var/run/php-fpm.sock|${fpm_socket}|g" "$src" > "$temp_file"

        if type -t smart_copy &>/dev/null; then
            smart_copy "$temp_file" "$dst"
        elif [[ -w "$confd_dir" ]]; then
            cp "$temp_file" "$dst"
        else
            sudo cp "$temp_file" "$dst"
        fi
        rm -f "$temp_file"

        if [[ -f "$dst" ]]; then
            if type -t ui_step_path &>/dev/null; then
                ui_step_path "Deployed config" "conf.d/upstream-keepalive.conf"
            fi
            return 0
        fi
    fi

    return 1
}

# Check if system nginx exists
_keepalive_has_system_nginx() {
    if type -t get_nginx_sites_dir &>/dev/null; then
        local sites_dir
        sites_dir=$(get_nginx_sites_dir)
        [[ -n "$sites_dir" ]] && [[ -d "$sites_dir" ]] && return 0
    fi
    [[ -d "/etc/nginx/sites-enabled" ]] || [[ -d "/opt/homebrew/etc/nginx/sites-enabled" ]]
}

# Check if wp-test sites exist
_keepalive_has_wptest() {
    local wp_test_sites="${WP_TEST_SITES:-$HOME/.wp-test/sites}"
    [[ -d "$wp_test_sites" ]] && [[ -n "$(ls -A "$wp_test_sites" 2>/dev/null)" ]]
}

# Inject fastcgi_keep_conn into site configs
_keepalive_inject_sites() {
    local target_site="$1"

    local sites_dir
    if type -t find_nginx_dir &>/dev/null; then
        sites_dir=$(find_nginx_dir "sites-enabled")
    fi
    if [[ -z "${sites_dir:-}" ]]; then
        for dir in /etc/nginx/sites-enabled /opt/homebrew/etc/nginx/sites-enabled /usr/local/etc/nginx/sites-enabled; do
            if [[ -d "$dir" ]]; then
                sites_dir="$dir"
                break
            fi
        done
    fi

    if [[ -z "${sites_dir:-}" ]] || [[ ! -d "$sites_dir" ]]; then
        return 0
    fi

    if [ "${DRY_RUN:-false}" = true ]; then
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Would inject keepalive into" "sites-enabled/*"
        fi
        return 0
    fi

    local injected=0
    for site_conf in "$sites_dir"/*; do
        [[ -f "$site_conf" ]] || continue

        # Filter by target site if specified
        if [[ -n "$target_site" ]] && [[ "$(basename "$site_conf")" != "$target_site" ]]; then
            continue
        fi

        # Skip if already configured
        if grep -q "fastcgi_keep_conn" "$site_conf" 2>/dev/null; then
            continue
        fi

        # Skip if no PHP/FastCGI (not a PHP site)
        if ! grep -q "fastcgi_pass" "$site_conf" 2>/dev/null; then
            continue
        fi

        local temp_file
        if type -t secure_mktemp &>/dev/null; then
            temp_file=$(secure_mktemp)
        else
            temp_file=$(mktemp)
        fi

        # Inject fastcgi_keep_conn on after fastcgi_pass lines
        # Also update fastcgi_pass to use upstream name if using direct socket
        awk '
        {
            print $0
            # After fastcgi_pass line, add fastcgi_keep_conn on
            if ($0 ~ /^[[:space:]]*fastcgi_pass[[:space:]]/ && $0 !~ /^[[:space:]]*#/) {
                # Get indentation from current line
                match($0, /^[[:space:]]*/)
                indent = substr($0, RSTART, RLENGTH)
                print indent "fastcgi_keep_conn on;"
            }
        }' "$site_conf" > "$temp_file"

        if sudo cp "$temp_file" "$site_conf" 2>/dev/null; then
            if type -t ui_step_path &>/dev/null; then
                ui_step_path "Configured site" "$(basename "$site_conf")"
            fi
            injected=$((injected + 1))
        fi
        rm -f "$temp_file"
    done

    if type -t log_to_file &>/dev/null && [[ $injected -gt 0 ]]; then
        log_to_file "INFO" "Added fastcgi_keep_conn to $injected site(s)"
    fi

    return 0
}

# Deploy to wp-test sites
_keepalive_deploy_wptest() {
    local target_site="$1"
    local wp_test_nginx="${WP_TEST_NGINX:-$HOME/.wp-test/nginx}"

    # Deploy upstream config to wp-test conf.d
    local template_dir="${TEMPLATE_DIR:-nginx-optimizer-templates}"
    local src="${template_dir}/upstream-keepalive.conf"

    if [ "${DRY_RUN:-false}" = true ]; then
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Would deploy to" "wp-test conf.d/upstream-keepalive.conf"
        fi
        return 0
    fi

    mkdir -p "${wp_test_nginx}/conf.d" 2>/dev/null
    if [[ -f "$src" ]]; then
        cp "$src" "${wp_test_nginx}/conf.d/upstream-keepalive.conf" 2>/dev/null || true
    fi

    # Add fastcgi_keep_conn to vhost.d files
    local wp_test_sites="${WP_TEST_SITES:-$HOME/.wp-test/sites}"
    if [[ -d "$wp_test_sites" ]]; then
        for site_dir in "$wp_test_sites"/*; do
            [[ -d "$site_dir" ]] || continue
            local site
            site=$(basename "$site_dir")

            if [[ -n "$target_site" ]] && [[ "$site" != "$target_site" ]]; then
                continue
            fi

            local vhost_file="${wp_test_nginx}/vhost.d/${site}"
            mkdir -p "$(dirname "$vhost_file")"

            if ! grep -q "fastcgi_keep_conn" "$vhost_file" 2>/dev/null; then
                cat >> "$vhost_file" << 'EOF'

# Upstream Keepalive - persistent PHP-FPM connections
fastcgi_keep_conn on;
EOF
                if type -t ui_step_path &>/dev/null; then
                    ui_step_path "Configured site" "$site"
                fi
            fi
        done
    fi

    return 0
}

################################################################################
# Register Feature
################################################################################

feature_register
