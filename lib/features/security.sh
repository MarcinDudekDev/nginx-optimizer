#!/bin/bash
################################################################################
# features/security.sh - Security Headers & Rate Limiting
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

FEATURE_ID="security"
FEATURE_DISPLAY="Security Headers & Rate Limiting"
FEATURE_DETECT_PATTERN="Strict-Transport-Security"
FEATURE_SCOPE="per-site"
FEATURE_TEMPLATE="security-headers.conf,security-http.conf"
FEATURE_TEMPLATE_CONTEXT="server"
FEATURE_ALIASES="headers"
FEATURE_NGINX_MIN_VERSION=""
FEATURE_PREREQ_CHECK=""

################################################################################
# Custom Apply Logic
################################################################################

# Security requires dual-template deployment:
# 1. security-http.conf -> conf.d (http context, rate limiting zones)
# 2. security-headers.conf -> snippets or vhost.d (server context, headers)
#
# Args: $1 = target_site (optional)
# Returns: 0 on success, 1 on failure
feature_apply_custom_security() {
    local target_site="${1:-}"

    # Ensure templates exist
    if type -t ensure_template &>/dev/null; then
        if ! ensure_template "security-headers.conf" create_security_template; then
            return 1
        fi
    fi

    # Apply to system nginx
    if type -t has_system_nginx &>/dev/null && has_system_nginx; then
        _security_apply_system "$target_site"
    fi

    # Apply to wp-test
    if type -t has_wptest_sites &>/dev/null && has_wptest_sites; then
        _security_apply_wptest "$target_site"
    fi

    return 0
}

################################################################################
# Helper Functions
################################################################################

# Apply security to system nginx
_security_apply_system() {
    local target_site="$1"

    # Deploy rate limiting zones to conf.d (http context)
    if type -t deploy_template_to_confd &>/dev/null; then
        deploy_template_to_confd "security-http.conf"
    fi

    if [ "${DRY_RUN:-false}" = true ]; then
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Would inject into" "sites-enabled/*"
        fi
        return 0
    fi

    # Inject security headers into server blocks
    if type -t inject_server_includes &>/dev/null; then
        local template_dir="${TEMPLATE_DIR:-nginx-optimizer-templates}"
        if inject_server_includes "${template_dir}/security-headers.conf" "security-headers.conf"; then
            if type -t ui_step &>/dev/null; then
                ui_step "Injected security headers into server blocks"
            fi
        fi
    fi
}

# Apply security to wp-test
_security_apply_wptest() {
    local target_site="$1"
    local wp_test_nginx="${WP_TEST_NGINX:-$HOME/.wp-test/nginx}"

    if [ "${DRY_RUN:-false}" = true ]; then
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Would configure" "wp-test security"
        fi
        return 0
    fi

    local vhost_dir="${wp_test_nginx}/vhost.d"
    local vhost_default="${vhost_dir}/default"

    mkdir -p "$vhost_dir"

    # Deploy security headers to vhost.d/default
    if type -t deploy_template_to_wptest &>/dev/null; then
        deploy_template_to_wptest "security-headers.conf"
    else
        # Fallback: copy template directly
        local template_dir="${TEMPLATE_DIR:-nginx-optimizer-templates}"
        if [[ -f "${template_dir}/security-headers.conf" ]]; then
            cp "${template_dir}/security-headers.conf" "$vhost_default"
        fi
    fi

    # Update site-specific files to include default
    local updated=0
    for site_file in "$vhost_dir"/*; do
        [ -f "$site_file" ] || continue
        local filename
        filename=$(basename "$site_file")

        # Skip default, default_location, and hidden files
        [[ "$filename" == "default" ]] && continue
        [[ "$filename" == "default_location" ]] && continue
        [[ "$filename" == .* ]] && continue

        # Check if already includes default
        if grep -q "include.*/vhost.d/default" "$site_file" 2>/dev/null; then
            continue
        fi

        # Add include directive at the beginning
        local temp_file
        if type -t secure_mktemp &>/dev/null; then
            temp_file=$(secure_mktemp)
        else
            temp_file=$(mktemp)
        fi
        echo "# Include default security headers" > "$temp_file"
        echo "include /etc/nginx/vhost.d/default;" >> "$temp_file"
        echo "" >> "$temp_file"
        cat "$site_file" >> "$temp_file"
        mv "$temp_file" "$site_file"
        ((updated++))
    done

    if [ "$updated" -gt 0 ]; then
        if type -t ui_step &>/dev/null; then
            ui_step "Updated $updated wp-test site(s) with security headers"
        fi
    fi
}

################################################################################
# Register Feature
################################################################################

feature_register

