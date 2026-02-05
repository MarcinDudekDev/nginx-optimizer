#!/bin/bash
################################################################################
# features/http3.sh - HTTP/3 QUIC Support
################################################################################
# Declarative feature module. Sets variables and calls feature_register.
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
FEATURE_ID="http3"
# shellcheck disable=SC2034
FEATURE_DISPLAY="HTTP/3 QUIC"
# shellcheck disable=SC2034
FEATURE_DETECT_PATTERN="listen.*quic"
# shellcheck disable=SC2034
FEATURE_SCOPE="per-site"
# shellcheck disable=SC2034
FEATURE_TEMPLATE="http3-quic.conf"
# shellcheck disable=SC2034
FEATURE_TEMPLATE_CONTEXT="server"
# shellcheck disable=SC2034
FEATURE_ALIASES="quic"
# shellcheck disable=SC2034
FEATURE_NGINX_MIN_VERSION="1.25"
# shellcheck disable=SC2034
FEATURE_PREREQ_CHECK=""

################################################################################
# Custom Apply Logic
################################################################################

# HTTP/3 requires special handling because:
# 1. Need to check nginx version
# 2. Need to inject quic listener alongside ssl listener
# 3. reuseport can only be set once globally

# Custom apply function (called by registry if FEATURE_HAS_CUSTOM_APPLY=1)
# Args: $1 = target_site (optional)
# Returns: 0 on success, 1 on failure
feature_apply_custom_http3() {
    local target_site="${1:-}"

    # Check nginx version
    if command -v nginx &>/dev/null; then
        local version
        version=$(nginx -v 2>&1 | sed -n 's/.*nginx\/\([0-9.]*\).*/\1/p')

        # Compare versions (1.25 minimum for HTTP/3)
        if ! _version_gte "$version" "1.25"; then
            if type -t log_warn &>/dev/null; then
                log_warn "HTTP/3 requires nginx >= 1.25.0 (current: $version)"
            fi
            return 1
        fi
    fi

    # Deploy template using core function (if template is defined)
    if [ -n "${FEATURE_TEMPLATE:-}" ] && type -t template_deploy &>/dev/null; then
        template_deploy "$FEATURE_TEMPLATE" "$FEATURE_TEMPLATE_CONTEXT" "$target_site"
    fi

    # For system nginx, need to inject listen directives
    local sites_dir
    if type -t get_nginx_sites_dir &>/dev/null; then
        sites_dir=$(get_nginx_sites_dir)
    fi
    if [ -n "$sites_dir" ] && [ -d "$sites_dir" ]; then
        _http3_inject_system_nginx "$target_site" "$sites_dir"
    fi

    # For wp-test, configure vhost (skip if --system-only)
    if [ "${SYSTEM_ONLY:-false}" != true ]; then
        if type -t has_wptest_sites &>/dev/null && has_wptest_sites; then
            _http3_configure_wptest "$target_site"
        fi
    fi

    return 0
}

################################################################################
# Helper Functions
################################################################################

# Version comparison: is $1 >= $2?
_version_gte() {
    local v1="$1"
    local v2="$2"
    # Use sort -V if available (GNU), otherwise simple comparison
    if printf '%s\n%s' "$v2" "$v1" | sort -V 2>/dev/null | head -n1 | grep -qF "$v2"; then
        return 0
    fi
    # Fallback: simple numeric comparison of major.minor
    local v1_major v1_minor v2_major v2_minor
    v1_major="${v1%%.*}"
    v1_minor="${v1#*.}"; v1_minor="${v1_minor%%.*}"
    v2_major="${v2%%.*}"
    v2_minor="${v2#*.}"; v2_minor="${v2_minor%%.*}"

    if [ "$v1_major" -gt "$v2_major" ] 2>/dev/null; then
        return 0
    elif [ "$v1_major" -eq "$v2_major" ] 2>/dev/null && [ "$v1_minor" -ge "$v2_minor" ] 2>/dev/null; then
        return 0
    fi
    return 1
}

# Inject HTTP/3 into system nginx sites
_http3_inject_system_nginx() {
    local target_site="$1"
    local sites_dir="$2"

    # Use helper if available, fallback to default
    if [ -z "$sites_dir" ]; then
        if type -t find_nginx_dir &>/dev/null; then
            sites_dir=$(find_nginx_dir "sites-enabled")
        fi
        sites_dir="${sites_dir:-/etc/nginx/sites-enabled}"
    fi

    # Check if reuseport already configured globally
    local reuseport_exists=false
    if grep -r "quic.*reuseport\|reuseport.*quic" "$sites_dir"/ 2>/dev/null | grep -qv '^\s*#'; then
        reuseport_exists=true
    fi

    local first_site=true
    for site_conf in "$sites_dir"/*; do
        [ -f "$site_conf" ] || continue

        # Filter by target if specified
        if [ -n "$target_site" ] && [[ "$(basename "$site_conf")" != *"$target_site"* ]]; then
            continue
        fi

        # Skip if already has HTTP/3
        if grep -v '^\s*#' "$site_conf" 2>/dev/null | grep -q "listen.*quic"; then
            continue
        fi

        # Skip if no SSL configured
        if ! grep -v '^\s*#' "$site_conf" 2>/dev/null | grep -q "listen.*443.*ssl"; then
            continue
        fi

        # Determine quic directive
        local quic_directive quic_directive_v6
        if [ "$first_site" = true ] && [ "$reuseport_exists" = false ]; then
            quic_directive="listen 443 quic reuseport;"
            quic_directive_v6="listen [::]:443 quic reuseport;"
            first_site=false
        else
            quic_directive="listen 443 quic;"
            quic_directive_v6="listen [::]:443 quic;"
        fi

        if [ "${DRY_RUN:-false}" = true ]; then
            if type -t ui_step_path &>/dev/null; then
                ui_step_path "Would configure HTTP/3" "$(basename "$site_conf")"
            fi
            continue
        fi

        # Backup and inject
        local backup="${site_conf}.http3bak"

        # Smart sudo: only use if file not writable
        local use_sudo=""
        if [ ! -w "$site_conf" ]; then
            use_sudo="sudo"
        fi

        $use_sudo cp "$site_conf" "$backup"

        awk -v quic="$quic_directive" -v quic_v6="$quic_directive_v6" '
        {
            line = $0
            print line
            if (line ~ /^[[:space:]]*#/) next
            if (line ~ /listen[[:space:]]+443[[:space:]]+ssl/ && line !~ /\[::\]/) {
                print "    " quic
                print "    add_header Alt-Svc '\''h3=\":443\"; ma=86400'\'' always;"
            }
            else if (line ~ /listen[[:space:]]+\[::\]:443[[:space:]]+ssl/) {
                print "    " quic_v6
            }
        }' "$site_conf" > "${site_conf}.tmp"

        $use_sudo mv "${site_conf}.tmp" "$site_conf"

        # Validate
        if nginx -t 2>&1 | grep -q "test failed\|emerg"; then
            $use_sudo mv "$backup" "$site_conf"
            continue
        fi

        $use_sudo rm -f "$backup"
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Configured HTTP/3" "$(basename "$site_conf")"
        fi
    done
}

# Configure HTTP/3 for wp-test site
_http3_configure_wptest() {
    local target_site="$1"

    # Use helper if available
    if type -t iterate_wptest_sites &>/dev/null; then
        iterate_wptest_sites "_http3_configure_wptest_site" "$target_site"
    else
        # Fallback to manual iteration
        local wp_test_sites="${WP_TEST_SITES:-$HOME/.wp-test/sites}"
        if [ -n "$target_site" ]; then
            _http3_configure_wptest_site "$target_site"
        else
            for site_dir in "$wp_test_sites"/*; do
                [ -d "$site_dir" ] || continue
                local site
                site=$(basename "$site_dir")
                _http3_configure_wptest_site "$site"
            done
        fi
    fi
}

_http3_configure_wptest_site() {
    local site="$1"
    local wp_test_nginx="${WP_TEST_NGINX:-$HOME/.wp-test/nginx}"
    local vhost_dir="${wp_test_nginx}/vhost.d"
    local vhost_file="${vhost_dir}/${site}"
    local proxy_conf_dir="${wp_test_nginx}/conf.d"

    if [ "${DRY_RUN:-false}" = true ]; then
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Would configure HTTP/3" "$site"
        fi
        return 0
    fi

    mkdir -p "$vhost_dir" "$proxy_conf_dir"

    # Add include to vhost
    if [ ! -f "$vhost_file" ]; then
        cat > "$vhost_file" << 'EOF'
# HTTP/3 QUIC Configuration
include /etc/nginx/conf.d/http3-quic.conf;
EOF
    elif ! grep -q "http3-quic" "$vhost_file"; then
        echo "" >> "$vhost_file"
        echo "# HTTP/3 QUIC Configuration" >> "$vhost_file"
        echo "include /etc/nginx/conf.d/http3-quic.conf;" >> "$vhost_file"
    fi

    # Copy template to conf.d
    local template_path
    template_path=$(template_path "$FEATURE_TEMPLATE" 2>/dev/null || echo "")
    if [ -f "$template_path" ]; then
        cp "$template_path" "$proxy_conf_dir/"
    fi

    if type -t ui_step_path &>/dev/null; then
        ui_step_path "Configured HTTP/3" "$site"
    fi

    # Note about local dev
    if [[ "$site" =~ \.(loc|local|test|localhost)$ ]]; then
        if type -t log_info &>/dev/null; then
            log_info "Note: HTTP/3 requires valid SSL cert (will use HTTP/2 locally)"
        fi
    fi
}

################################################################################
# Register Feature
################################################################################

feature_register
