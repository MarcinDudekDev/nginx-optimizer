#!/bin/bash
################################################################################
# features/wordpress.sh - WordPress Security Exclusions
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

FEATURE_ID="wordpress"
FEATURE_DISPLAY="WordPress Security Exclusions"
FEATURE_DETECT_PATTERN="xmlrpc"
FEATURE_SCOPE="per-site"
FEATURE_TEMPLATE="wordpress-exclusions.conf"
FEATURE_TEMPLATE_CONTEXT="server"
FEATURE_ALIASES="wp"
FEATURE_NGINX_MIN_VERSION=""
FEATURE_PREREQ_CHECK=""

################################################################################
# Custom Apply Logic
################################################################################

# WordPress exclusions need server block injection
# Args: $1 = target_site (optional)
# Returns: 0 on success, 1 on failure
feature_apply_custom_wordpress() {
    local target_site="${1:-}"

    # Ensure template exists
    if type -t ensure_template &>/dev/null; then
        if ! ensure_template "wordpress-exclusions.conf" create_wordpress_exclusions_template; then
            return 1
        fi
    fi

    # Apply to system nginx
    if type -t has_system_nginx &>/dev/null && has_system_nginx; then
        _wordpress_apply_system "$target_site"
    fi

    # Apply to wp-test (skip if --system-only)
    if [ "${SYSTEM_ONLY:-false}" != true ]; then
        if type -t has_wptest_sites &>/dev/null && has_wptest_sites; then
            _wordpress_apply_wptest "$target_site"
        fi

        # Auto-detect WooCommerce (wp-test only)
        if type -t has_wptest_sites &>/dev/null && has_wptest_sites; then
            if type -t detect_woocommerce &>/dev/null && detect_woocommerce "$target_site"; then
                if type -t ui_step &>/dev/null; then
                    ui_step "WooCommerce detected, rules included"
                fi
            fi
        fi
    fi

    return 0
}

################################################################################
# Helper Functions
################################################################################

# Apply WordPress exclusions to system nginx
_wordpress_apply_system() {
    local target_site="$1"

    if [ "${DRY_RUN:-false}" = true ]; then
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Would inject into" "sites-enabled/*"
        fi
        return 0
    fi

    # Inject WordPress exclusions into server blocks
    if type -t inject_server_includes &>/dev/null; then
        local template_dir="${TEMPLATE_DIR:-nginx-optimizer-templates}"
        if inject_server_includes "${template_dir}/wordpress-exclusions.conf" "wordpress-exclusions.conf"; then
            if type -t ui_step &>/dev/null; then
                ui_step "Injected WordPress exclusions into server blocks"
            fi
        fi
    fi
}

# Apply WordPress exclusions to wp-test
_wordpress_apply_wptest() {
    local target_site="$1"

    if type -t deploy_template_to_wptest &>/dev/null; then
        deploy_template_to_wptest "wordpress-exclusions.conf"
    else
        # Fallback: copy template to vhost.d
        local wp_test_nginx="${WP_TEST_NGINX:-$HOME/.wp-test/nginx}"
        local vhost_dir="${wp_test_nginx}/vhost.d"
        local template_dir="${TEMPLATE_DIR:-nginx-optimizer-templates}"

        if [ "${DRY_RUN:-false}" = true ]; then
            return 0
        fi

        mkdir -p "$vhost_dir"
        if [[ -f "${template_dir}/wordpress-exclusions.conf" ]]; then
            cp "${template_dir}/wordpress-exclusions.conf" "${vhost_dir}/"
        fi
    fi
}

################################################################################
# Register Feature
################################################################################

feature_register
