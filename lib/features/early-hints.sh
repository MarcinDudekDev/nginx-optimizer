#!/bin/bash
################################################################################
# features/early-hints.sh - HTTP 103 Early Hints
################################################################################
# Forwards 103 Early Hints responses from upstream to clients, allowing
# browsers to preload critical assets while PHP is still rendering.
# Significant LCP win on dynamic WordPress/WooCommerce pages.
#
# Requires nginx >= 1.29.0 (early_hints directive).
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
FEATURE_ID="early-hints"
# shellcheck disable=SC2034
FEATURE_DISPLAY="Early Hints (HTTP 103)"
# shellcheck disable=SC2034
FEATURE_DETECT_PATTERN="early_hints[[:space:]]+on"
# shellcheck disable=SC2034
FEATURE_SCOPE="per-site"
# shellcheck disable=SC2034
FEATURE_TEMPLATE="early-hints.conf"
# shellcheck disable=SC2034
FEATURE_TEMPLATE_CONTEXT="server"
# shellcheck disable=SC2034
FEATURE_ALIASES="103,hints,early"
# shellcheck disable=SC2034
FEATURE_NGINX_MIN_VERSION="1.29"
# shellcheck disable=SC2034
FEATURE_PREREQ_CHECK=""

################################################################################
# Custom Apply Logic
################################################################################

# Apply early_hints directive to server blocks
# Args: $1 = target_site (optional)
# Returns: 0 on success, 1 on failure
feature_apply_custom_early_hints() {
    # shellcheck disable=SC2034  # target_site reserved for per-site features
    local target_site="${1:-}"

    if type -t log_to_file &>/dev/null; then
        log_to_file "INFO" "Applying Early Hints (103)..."
    fi

    if [ "${DRY_RUN:-false}" = true ]; then
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Would inject into" "sites-enabled/*"
        fi
        return 0
    fi

    # System nginx: inject into server blocks
    if type -t has_system_nginx &>/dev/null && has_system_nginx; then
        if type -t inject_server_includes &>/dev/null; then
            local template_dir="${TEMPLATE_DIR:-nginx-optimizer-templates}"
            if inject_server_includes "${template_dir}/early-hints.conf" "early-hints.conf"; then
                if type -t ui_step &>/dev/null; then
                    ui_step "Injected early_hints into server blocks"
                fi
            fi
        fi
    fi

    # wp-test: deploy via vhost.d include pattern
    if [ "${SYSTEM_ONLY:-false}" != true ]; then
        if type -t has_wptest_sites &>/dev/null && has_wptest_sites; then
            _early_hints_apply_wptest "$target_site"
        fi
    fi

    return 0
}

# Apply early_hints to wp-test sites
_early_hints_apply_wptest() {
    # shellcheck disable=SC2034  # reserved for future per-site filtering
    local target_site="$1"
    local wp_test_nginx="${WP_TEST_NGINX:-$HOME/.wp-test/nginx}"
    local vhost_dir="${wp_test_nginx}/vhost.d"
    local template_dir="${TEMPLATE_DIR:-nginx-optimizer-templates}"
    local src="${template_dir}/early-hints.conf"

    [[ -f "$src" ]] || return 0
    [[ -d "$vhost_dir" ]] || mkdir -p "$vhost_dir"

    local snippet="${vhost_dir}/early-hints"
    cp "$src" "$snippet"

    local updated=0
    for site_file in "$vhost_dir"/*; do
        [ -f "$site_file" ] || continue
        local filename
        filename=$(basename "$site_file")
        [[ "$filename" == "default" ]] && continue
        [[ "$filename" == "default_location" ]] && continue
        [[ "$filename" == "early-hints" ]] && continue
        [[ "$filename" == .* ]] && continue

        if grep -q "early_hints" "$site_file" 2>/dev/null; then
            continue
        fi

        printf '\n# Early Hints (HTTP 103)\nearly_hints on;\n' >> "$site_file"
        updated=$((updated + 1))
    done

    if [ "$updated" -gt 0 ]; then
        if type -t ui_step &>/dev/null; then
            ui_step "Enabled early_hints on $updated wp-test site(s)"
        fi
    fi
}

################################################################################
# Register Feature
################################################################################

feature_register
