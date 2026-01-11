#!/bin/bash
################################################################################
# features/fastcgi-cache.sh - FastCGI Full-Page Cache
################################################################################
# Feature module with custom apply logic for dual template deployment.
################################################################################

# Ensure registry is loaded
if ! type -t feature_register &>/dev/null; then
    echo "Error: registry.sh must be sourced before feature modules" >&2
    return 1
fi

################################################################################
# Feature Definition
################################################################################

FEATURE_ID="fastcgi-cache"
FEATURE_DISPLAY="FastCGI Full-Page Cache"
FEATURE_DETECT_PATTERN="fastcgi_cache_path"
FEATURE_SCOPE="per-site"
FEATURE_TEMPLATE="fastcgi-cache.conf,fastcgi-cache-zone.conf"
FEATURE_TEMPLATE_CONTEXT="mixed"
FEATURE_ALIASES="fastcgi,cache"
FEATURE_NGINX_MIN_VERSION=""
FEATURE_PREREQ_CHECK=""
FEATURE_HAS_CUSTOM_DETECT="1"
FEATURE_HAS_CUSTOM_APPLY="1"

################################################################################
# Custom Detection Logic
################################################################################

# FastCGI cache detection checks:
# 1. conf.d for fastcgi_cache_path (zone definition)
# 2. Site config for fastcgi_cache directive or include
# Args: $1 = config_file, $2 = site_name (optional)
# Returns: 0 if detected, 1 if not
feature_detect_custom_fastcgi_cache() {
    local config_file="$1"
    local site_name="${2:-}"

    # Check if site config has fastcgi_cache directive
    if grep -qE "fastcgi_cache[[:space:]]+" "$config_file" 2>/dev/null; then
        LAST_DIRECTIVE_SOURCE="$config_file"
        return 0
    fi

    # Check if site config includes our fastcgi-cache template
    if grep -qE "include.*fastcgi-cache\.conf" "$config_file" 2>/dev/null; then
        LAST_DIRECTIVE_SOURCE="$config_file (via include)"
        return 0
    fi

    # Check conf.d for cache zone (global detection)
    local confd_dir
    if type -t get_nginx_confd_dir &>/dev/null; then
        confd_dir=$(get_nginx_confd_dir)
    fi
    if [[ -n "$confd_dir" ]] && [[ -d "$confd_dir" ]]; then
        if grep -rqE "fastcgi_cache_path" "$confd_dir" 2>/dev/null; then
            LAST_DIRECTIVE_SOURCE="conf.d/"
            return 0
        fi
    fi

    return 1
}

################################################################################
# Custom Apply Logic
################################################################################

# FastCGI cache requires special handling:
# 1. Create cache directory (/var/run/nginx-cache)
# 2. Deploy zone config to conf.d (http context)
# 3. Deploy server config to snippets (included in server blocks)
# 4. Inject include into server blocks (only for sites with fastcgi_pass)
# 5. Configure wp-test vhost files

# Args: $1 = target_site (optional)
# Returns: 0 on success, 1 on failure
feature_apply_custom_fastcgi_cache() {
    local target_site="${1:-}"

    # Log operation start
    if type -t log_to_file &>/dev/null; then
        log_to_file "INFO" "Applying FastCGI Full-Page Cache..."
    fi

    # 1. Create cache directory
    _fastcgi_create_cache_dir || return 1

    # 2. Deploy templates to system nginx
    if _fastcgi_has_system_nginx; then
        _fastcgi_deploy_system "$target_site" || return 1
    fi

    # 3. Deploy to wp-test sites (skip if --system-only)
    if [ "${SYSTEM_ONLY:-false}" != true ]; then
        if _fastcgi_has_wptest; then
            _fastcgi_deploy_wptest "$target_site" || return 1
        fi
    fi

    if type -t log_to_file &>/dev/null; then
        log_to_file "SUCCESS" "FastCGI cache applied successfully"
    fi

    return 0
}

################################################################################
# Helper Functions
################################################################################

# Create cache directory with proper permissions
_fastcgi_create_cache_dir() {
    local cache_dir="/var/run/nginx-cache"

    if [ -d "$cache_dir" ]; then
        return 0
    fi

    if [ "${DRY_RUN:-false}" = true ]; then
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Would create cache dir" "$cache_dir"
        fi
        return 0
    fi

    # Try system directory first
    if sudo mkdir -p "$cache_dir" 2>/dev/null; then
        sudo chown -R www-data:www-data "$cache_dir" 2>/dev/null || \
        sudo chown -R _www:_www "$cache_dir" 2>/dev/null || \
        sudo chown -R nginx:nginx "$cache_dir" 2>/dev/null || true

        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Created cache directory" "$cache_dir"
        fi
        return 0
    fi

    # Fallback to home directory
    cache_dir="$HOME/.nginx-cache"
    mkdir -p "$cache_dir" 2>/dev/null

    if type -t ui_step_path &>/dev/null; then
        ui_step_path "Created cache directory" "\$HOME/.nginx-cache"
    fi

    return 0
}

# Check if system nginx exists (cross-platform)
_fastcgi_has_system_nginx() {
    if type -t get_nginx_sites_dir &>/dev/null; then
        local sites_dir
        sites_dir=$(get_nginx_sites_dir)
        [ -n "$sites_dir" ] && [ -d "$sites_dir" ] && return 0
    fi
    if type -t get_nginx_confd_dir &>/dev/null; then
        local confd_dir
        confd_dir=$(get_nginx_confd_dir)
        [ -n "$confd_dir" ] && [ -d "$confd_dir" ] && return 0
    fi
    # Fallback to hardcoded paths
    [ -d "/etc/nginx/sites-enabled" ] || [ -d "/etc/nginx/conf.d" ] || \
    [ -d "/opt/homebrew/etc/nginx/sites-enabled" ] || [ -d "/opt/homebrew/etc/nginx/conf.d" ]
}

# Check if wp-test sites exist
_fastcgi_has_wptest() {
    local wp_test_sites="${WP_TEST_SITES:-$HOME/.wp-test/sites}"
    [ -d "$wp_test_sites" ] && [ -n "$(ls -A "$wp_test_sites" 2>/dev/null)" ]
}

# Deploy to system nginx
_fastcgi_deploy_system() {
    local target_site="$1"

    # Deploy zone config to conf.d (http context)
    if type -t deploy_template_to_confd &>/dev/null; then
        deploy_template_to_confd "fastcgi-cache-zone.conf" || return 1
    else
        _fastcgi_deploy_confd || return 1
    fi

    # Deploy server config to snippets (cross-platform)
    local snippets_dir
    if type -t get_nginx_snippets_dir &>/dev/null; then
        snippets_dir=$(get_nginx_snippets_dir)
    fi
    if [ -z "$snippets_dir" ]; then
        # Fallback: create snippets dir next to conf.d
        local confd_dir
        if type -t get_nginx_confd_dir &>/dev/null; then
            confd_dir=$(get_nginx_confd_dir)
        fi
        if [ -n "$confd_dir" ]; then
            snippets_dir="$(dirname "$confd_dir")/snippets"
        else
            snippets_dir="/etc/nginx/snippets"
        fi
    fi

    if [ "${DRY_RUN:-false}" = true ]; then
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Would create" "snippets/fastcgi-cache.conf"
        fi
    else
        local template_dir="${TEMPLATE_DIR:-nginx-optimizer-templates}"
        local src="${template_dir}/fastcgi-cache.conf"
        local dst="${snippets_dir}/fastcgi-cache.conf"

        if [ -f "$src" ]; then
            # Create directory with sudo if needed
            if [ -w "$(dirname "$snippets_dir")" ]; then
                mkdir -p "$snippets_dir" 2>/dev/null
            else
                sudo mkdir -p "$snippets_dir" 2>/dev/null
            fi

            # Use smart_copy helper if available
            if type -t smart_copy &>/dev/null; then
                smart_copy "$src" "$dst"
            else
                # Fallback to inline sudo logic
                if [ -w "$snippets_dir" ]; then
                    cp "$src" "$dst" 2>/dev/null
                else
                    sudo cp "$src" "$dst" 2>/dev/null
                fi
            fi

            if [ -f "$dst" ]; then
                if type -t ui_step_path &>/dev/null; then
                    ui_step_path "Created config" "snippets/fastcgi-cache.conf"
                fi
            else
                if type -t log_to_file &>/dev/null; then
                    log_to_file "ERROR" "Failed to deploy fastcgi-cache.conf to snippets"
                fi
                return 1
            fi
        fi
    fi

    # Inject include directives into server blocks
    _fastcgi_inject_system "$target_site"

    return 0
}

# Deploy zone config to conf.d (cross-platform)
_fastcgi_deploy_confd() {
    local template_dir="${TEMPLATE_DIR:-nginx-optimizer-templates}"
    local src="${template_dir}/fastcgi-cache-zone.conf"
    local confd_dir

    # Get cross-platform conf.d directory - use helper if available
    if type -t find_nginx_dir &>/dev/null; then
        confd_dir=$(find_nginx_dir "conf.d")
    fi
    if [ -z "$confd_dir" ]; then
        # Fallback detection
        for dir in /etc/nginx/conf.d /opt/homebrew/etc/nginx/conf.d /usr/local/etc/nginx/conf.d; do
            if [ -d "$dir" ]; then
                confd_dir="$dir"
                break
            fi
        done
    fi

    [ -z "$confd_dir" ] && return 1

    local dst="${confd_dir}/fastcgi-cache-zone.conf"

    if [ "${DRY_RUN:-false}" = true ]; then
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Would deploy" "conf.d/fastcgi-cache-zone.conf"
        fi
        return 0
    fi

    if [ -f "$src" ]; then
        # Create directory with sudo if needed
        if [ -w "$confd_dir" ]; then
            mkdir -p "$confd_dir" 2>/dev/null
        else
            sudo mkdir -p "$confd_dir" 2>/dev/null
        fi

        # Use smart_copy helper if available
        if type -t smart_copy &>/dev/null; then
            smart_copy "$src" "$dst"
        else
            # Fallback to inline sudo logic
            if [ -w "$confd_dir" ]; then
                cp "$src" "$dst" 2>/dev/null
            else
                sudo cp "$src" "$dst" 2>/dev/null
            fi
        fi

        if [ -f "$dst" ]; then
            if type -t ui_step_path &>/dev/null; then
                ui_step_path "Deployed config" "conf.d/fastcgi-cache-zone.conf"
            fi
            return 0
        fi
    fi

    return 1
}

# Inject include directives into system nginx server blocks (cross-platform)
_fastcgi_inject_system() {
    local target_site="$1"

    # Get cross-platform sites directory - use helper if available
    local sites_dir
    if type -t find_nginx_dir &>/dev/null; then
        sites_dir=$(find_nginx_dir "sites-enabled")
    fi
    if [ -z "$sites_dir" ]; then
        for dir in /etc/nginx/sites-enabled /opt/homebrew/etc/nginx/sites-enabled /usr/local/etc/nginx/sites-enabled; do
            if [ -d "$dir" ]; then
                sites_dir="$dir"
                break
            fi
        done
    fi

    if [ -z "$sites_dir" ] || [ ! -d "$sites_dir" ]; then
        return 0
    fi

    # Get snippets directory for include path
    local snippets_dir
    if type -t get_nginx_snippets_dir &>/dev/null; then
        snippets_dir=$(get_nginx_snippets_dir)
    fi
    if [ -z "$snippets_dir" ]; then
        snippets_dir="$(dirname "$sites_dir")/snippets"
    fi

    if [ "${DRY_RUN:-false}" = true ]; then
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Would inject into" "sites-enabled/*"
        fi
        return 0
    fi

    local injected=0
    for site_conf in "$sites_dir"/*; do
        [ -f "$site_conf" ] || continue

        # Filter by target site if specified
        if [ -n "$target_site" ] && [ "$(basename "$site_conf")" != "$target_site" ]; then
            continue
        fi

        # Skip if already configured
        if grep -q "fastcgi-cache.conf" "$site_conf" 2>/dev/null; then
            continue
        fi

        # Skip if no PHP/FastCGI (not a PHP site)
        if ! grep -q "fastcgi_pass" "$site_conf" 2>/dev/null; then
            continue
        fi

        # Inject the include directive
        local temp_file
        if type -t secure_mktemp &>/dev/null; then
            temp_file=$(secure_mktemp)
        else
            temp_file=$(mktemp)
        fi

        # Add include after server { line
        awk -v snippets="$snippets_dir" '
        BEGIN { injected = 0 }
        {
            print $0
            # Skip commented lines
            if ($0 ~ /^[[:space:]]*#/) next
            # Inject after first server {
            if (!injected && $0 ~ /server[[:space:]]*\{/) {
                print "    include " snippets "/fastcgi-cache.conf;"
                injected = 1
            }
        }' "$site_conf" > "$temp_file"

        if sudo cp "$temp_file" "$site_conf" 2>/dev/null; then
            if type -t ui_step_path &>/dev/null; then
                ui_step_path "Configured site" "$(basename "$site_conf")"
            fi
            ((injected++))
        fi
        rm -f "$temp_file"
    done

    if type -t log_to_file &>/dev/null && [ $injected -gt 0 ]; then
        log_to_file "INFO" "Configured $injected system nginx site(s) for FastCGI cache"
    fi

    return 0
}

# Deploy to wp-test sites
_fastcgi_deploy_wptest() {
    local target_site="$1"
    local wp_test_nginx="${WP_TEST_NGINX:-$HOME/.wp-test/nginx}"

    # Deploy template to wp-test conf.d
    if type -t deploy_template_to_wptest &>/dev/null; then
        deploy_template_to_wptest "fastcgi-cache.conf"
    else
        _fastcgi_deploy_wptest_confd
    fi

    # Configure individual sites - use helper if available
    if type -t iterate_wptest_sites &>/dev/null; then
        iterate_wptest_sites "_fastcgi_configure_wptest_site" "$target_site"
    else
        # Fallback to manual iteration
        local wp_test_sites="${WP_TEST_SITES:-$HOME/.wp-test/sites}"
        if [ -n "$target_site" ] && [ -d "$wp_test_sites/$target_site" ]; then
            _fastcgi_configure_wptest_site "$target_site"
            if type -t ui_step_path &>/dev/null; then
                ui_step_path "Configured site" "$target_site"
            fi
        else
            for site_dir in "$wp_test_sites"/*; do
                if [ -d "$site_dir" ]; then
                    local site
                    site=$(basename "$site_dir")
                    _fastcgi_configure_wptest_site "$site"
                    if type -t ui_step_path &>/dev/null; then
                        ui_step_path "Configured site" "$site"
                    fi
                fi
            done
        fi
    fi

    return 0
}

# Deploy to wp-test conf.d
_fastcgi_deploy_wptest_confd() {
    local wp_test_nginx="${WP_TEST_NGINX:-$HOME/.wp-test/nginx}"
    local template_dir="${TEMPLATE_DIR:-nginx-optimizer-templates}"
    local src="${template_dir}/fastcgi-cache.conf"
    local dst="${wp_test_nginx}/conf.d/fastcgi-cache.conf"

    if [ "${DRY_RUN:-false}" = true ]; then
        return 0
    fi

    mkdir -p "${wp_test_nginx}/conf.d" 2>/dev/null
    cp "$src" "$dst" 2>/dev/null || true
}

# Configure individual wp-test site
_fastcgi_configure_wptest_site() {
    local site="$1"
    local wp_test_nginx="${WP_TEST_NGINX:-$HOME/.wp-test/nginx}"
    local vhost_file="${wp_test_nginx}/vhost.d/${site}"

    if [ "${DRY_RUN:-false}" = true ]; then
        return 0
    fi

    mkdir -p "$(dirname "$vhost_file")"

    if ! grep -q "fastcgi_cache" "$vhost_file" 2>/dev/null; then
        cat >> "$vhost_file" << 'EOF'

# FastCGI Cache Configuration
include /etc/nginx/conf.d/fastcgi-cache.conf;

# Enable cache for PHP
location ~ \.php$ {
    fastcgi_cache WORDPRESS;
}
EOF
    fi
}

################################################################################
# Register Feature
################################################################################

feature_register
