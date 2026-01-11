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

FEATURE_ID="brotli"
FEATURE_DISPLAY="Brotli Compression"
FEATURE_DETECT_PATTERN="brotli on"
FEATURE_SCOPE="global"
FEATURE_TEMPLATE="compression.conf"
FEATURE_TEMPLATE_CONTEXT="http"
FEATURE_ALIASES="compression"
FEATURE_NGINX_MIN_VERSION=""
FEATURE_PREREQ_CHECK="check_brotli_module"

################################################################################
# Custom Detect Logic
################################################################################

# Custom detection: Check if nginx has brotli module compiled in
# Args: $1 = config_file, $2 = site_name (optional)
# Returns: 0 if brotli is available/enabled, 1 if not
feature_detect_custom_brotli() {
    local config_file="$1"
    local site_name="${2:-}"

    # First check if brotli module is available
    if command -v nginx &>/dev/null; then
        # Check for ngx_brotli module (compiled from source)
        if ! nginx -V 2>&1 | grep -qi "brotli"; then
            # Module not available, cannot enable
            return 1
        fi
    fi

    # Check if wp-test-proxy uses brotli-enabled image
    if command -v docker &>/dev/null; then
        if docker ps --filter "name=wp-test-proxy" --format "{{.Image}}" 2>/dev/null | grep -q "brotli"; then
            LAST_DIRECTIVE_SOURCE="docker:wp-test-proxy"
            return 0
        fi
    fi

    # Standard pattern check - brotli on in config
    if [[ -f "$config_file" ]] && grep -qE "$FEATURE_DETECT_PATTERN" "$config_file" 2>/dev/null; then
        LAST_DIRECTIVE_SOURCE="$config_file"
        return 0
    fi

    return 1
}

################################################################################
# Register Feature
################################################################################

feature_register

