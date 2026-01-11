#!/bin/bash
################################################################################
# core/helpers.sh - Common Helper Functions
################################################################################
# Consolidates reusable patterns used across feature modules:
# - Cross-platform nginx path detection
# - Smart sudo handling for file operations
# - Dry-run step output formatting
# - wp-test site iteration
################################################################################

################################################################################
# Cross-Platform Nginx Paths
################################################################################

# Cross-platform nginx base directories (ordered by preference)
# Used by find functions to locate nginx config directories on different systems
NGINX_CONFIG_PATHS=(
    "/etc/nginx"
    "/opt/homebrew/etc/nginx"
    "/usr/local/etc/nginx"
)

################################################################################
# File Operations
################################################################################

# Copy file with automatic sudo handling
# Checks write permission on destination directory and uses sudo only if needed
# Args: $1 = source path, $2 = destination path
# Returns: 0 on success, 1 on failure
smart_copy() {
    local src="$1"
    local dst="$2"
    local dst_dir

    [ -z "$src" ] || [ -z "$dst" ] && return 1
    [ ! -f "$src" ] && return 1

    dst_dir=$(dirname "$dst")

    if [ -w "$dst_dir" ]; then
        cp "$src" "$dst"
    else
        sudo cp "$src" "$dst"
    fi
}

################################################################################
# Dry-Run Helpers
################################################################################

# Output a dry-run or actual step message with consistent formatting
# Uses ui_step_path if available (from UI module), otherwise silent
# Args: $1 = action verb (past tense for actual, base form for would)
#       $2 = target description
# Uses global: DRY_RUN
# Example: dry_run_step "deploy" "conf.d/cache.conf"
#   DRY_RUN=true  -> "Would deploy conf.d/cache.conf"
#   DRY_RUN=false -> "Deployed conf.d/cache.conf"
dry_run_step() {
    local action="$1"
    local target="$2"

    [ -z "$action" ] || [ -z "$target" ] && return 1

    if [ "${DRY_RUN:-false}" = true ]; then
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Would ${action}" "$target"
        fi
    else
        if type -t ui_step_path &>/dev/null; then
            # Capitalize first letter for actual action
            local capitalized
            capitalized="$(echo "${action:0:1}" | tr '[:lower:]' '[:upper:]')${action:1}"
            ui_step_path "$capitalized" "$target"
        fi
    fi
}

################################################################################
# wp-test Site Iteration
################################################################################

# Iterate over wp-test sites and call a callback function for each
# Handles both targeted (single site) and bulk (all sites) operations
# Args: $1 = callback function name (receives site_name as $1)
#       $2 = target_site filter (optional, process only this site)
# Uses globals: WP_TEST_SITES (defaults to ~/.wp-test/sites)
# Returns: 0 always (skip if wp-test not installed)
# Example: iterate_wptest_sites "_my_feature_apply_site" "mysite.local"
iterate_wptest_sites() {
    local callback="$1"
    local target_site="${2:-}"
    local wp_test_sites="${WP_TEST_SITES:-$HOME/.wp-test/sites}"

    [ -z "$callback" ] && return 1
    [ -d "$wp_test_sites" ] || return 0

    if [ -n "$target_site" ] && [ -d "$wp_test_sites/$target_site" ]; then
        # Single site mode
        "$callback" "$target_site"
    else
        # All sites mode
        for site_dir in "$wp_test_sites"/*; do
            [ -d "$site_dir" ] || continue
            local site
            site=$(basename "$site_dir")
            "$callback" "$site"
        done
    fi
}

################################################################################
# Nginx Path Detection
################################################################################

# Find the main nginx.conf file (cross-platform)
# Searches NGINX_CONFIG_PATHS array in order
# Prints: full path to nginx.conf
# Returns: 0 if found, 1 if not found
get_nginx_main_conf() {
    local base
    for base in "${NGINX_CONFIG_PATHS[@]}"; do
        if [ -f "$base/nginx.conf" ]; then
            echo "$base/nginx.conf"
            return 0
        fi
    done
    return 1
}

# Find a specific nginx subdirectory (cross-platform)
# Searches NGINX_CONFIG_PATHS array for the specified subdirectory
# Special handling: sites-enabled falls back to servers/ (Homebrew pattern)
# Args: $1 = subdir name (conf.d, sites-enabled, snippets, etc.)
# Prints: full path to subdirectory
# Returns: 0 if found, 1 if not found
find_nginx_dir() {
    local subdir="$1"
    local base

    [ -z "$subdir" ] && return 1

    # Primary search
    for base in "${NGINX_CONFIG_PATHS[@]}"; do
        if [ -d "$base/$subdir" ]; then
            echo "$base/$subdir"
            return 0
        fi
    done

    # Fallback for Homebrew: 'servers' instead of 'sites-enabled'
    if [ "$subdir" = "sites-enabled" ]; then
        for base in "${NGINX_CONFIG_PATHS[@]}"; do
            if [ -d "$base/servers" ]; then
                echo "$base/servers"
                return 0
            fi
        done
    fi

    return 1
}
