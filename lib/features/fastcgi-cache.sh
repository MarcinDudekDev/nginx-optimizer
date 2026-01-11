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
FEATURE_HAS_CUSTOM_DETECT="0"
FEATURE_HAS_CUSTOM_APPLY="1"

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
feature_apply_custom_fastcgi-cache() {
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

    # 3. Deploy to wp-test sites
    if _fastcgi_has_wptest; then
        _fastcgi_deploy_wptest "$target_site" || return 1
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

# Check if system nginx exists
_fastcgi_has_system_nginx() {
    [ -d "/etc/nginx/sites-enabled" ] || [ -d "/etc/nginx/conf.d" ]
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

    # Deploy server config to snippets
    if [ "${DRY_RUN:-false}" = true ]; then
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Would create" "snippets/fastcgi-cache.conf"
        fi
    else
        local template_dir="${TEMPLATE_DIR:-/Users/cminds/Tools/nginx-optimizer/nginx-optimizer-templates}"
        local src="${template_dir}/fastcgi-cache.conf"
        local dst="/etc/nginx/snippets/fastcgi-cache.conf"

        if [ -f "$src" ]; then
            sudo mkdir -p "/etc/nginx/snippets" 2>/dev/null
            if sudo cp "$src" "$dst" 2>/dev/null; then
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

# Deploy zone config to conf.d
_fastcgi_deploy_confd() {
    local template_dir="${TEMPLATE_DIR:-/Users/cminds/Tools/nginx-optimizer/nginx-optimizer-templates}"
    local src="${template_dir}/fastcgi-cache-zone.conf"
    local dst="/etc/nginx/conf.d/fastcgi-cache-zone.conf"

    if [ "${DRY_RUN:-false}" = true ]; then
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Would deploy" "conf.d/fastcgi-cache-zone.conf"
        fi
        return 0
    fi

    if [ -f "$src" ]; then
        sudo mkdir -p "/etc/nginx/conf.d" 2>/dev/null
        if sudo cp "$src" "$dst" 2>/dev/null; then
            if type -t ui_step_path &>/dev/null; then
                ui_step_path "Deployed config" "conf.d/fastcgi-cache-zone.conf"
            fi
            return 0
        fi
    fi

    return 1
}

# Inject include directives into system nginx server blocks
_fastcgi_inject_system() {
    local target_site="$1"

    if [ ! -d "/etc/nginx/sites-enabled" ]; then
        return 0
    fi

    if [ "${DRY_RUN:-false}" = true ]; then
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Would inject into" "sites-enabled/*"
        fi
        return 0
    fi

    local injected=0
    for site_conf in /etc/nginx/sites-enabled/*; do
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
        awk '
        BEGIN { injected = 0 }
        {
            print $0
            # Skip commented lines
            if ($0 ~ /^[[:space:]]*#/) next
            # Inject after first server {
            if (!injected && $0 ~ /server[[:space:]]*\{/) {
                print "    include /etc/nginx/snippets/fastcgi-cache.conf;"
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
    local wp_test_sites="${WP_TEST_SITES:-$HOME/.wp-test/sites}"
    local wp_test_nginx="${WP_TEST_NGINX:-$HOME/.wp-test/nginx}"

    # Deploy template to wp-test conf.d
    if type -t deploy_template_to_wptest &>/dev/null; then
        deploy_template_to_wptest "fastcgi-cache.conf"
    else
        _fastcgi_deploy_wptest_confd
    fi

    # Configure individual sites
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

    return 0
}

# Deploy to wp-test conf.d
_fastcgi_deploy_wptest_confd() {
    local wp_test_nginx="${WP_TEST_NGINX:-$HOME/.wp-test/nginx}"
    local template_dir="${TEMPLATE_DIR:-/Users/cminds/Tools/nginx-optimizer/nginx-optimizer-templates}"
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

