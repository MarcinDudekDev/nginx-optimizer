#!/bin/bash
################################################################################
# core/templates.sh - Template Management
################################################################################
# Handles loading, validation, and deployment of nginx config templates.
# Used by feature modules via the registry.
################################################################################

# Template directory (set by main script, fallback to relative path)
TEMPLATE_DIR="${TEMPLATE_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../nginx-optimizer-templates}"

# wp-test paths
WP_TEST_NGINX="${WP_TEST_NGINX:-$HOME/.wp-test/nginx}"
WP_TEST_SITES="${WP_TEST_SITES:-$HOME/.wp-test/sites}"

################################################################################
# Template Loading
################################################################################

# Load template content from file
# Args: $1 = template filename
# Prints: template content
# Returns: 0 if found, 1 if not
template_load() {
    local name="$1"
    local path="${TEMPLATE_DIR}/${name}"

    if [ -f "$path" ]; then
        cat "$path"
        return 0
    fi
    return 1
}

# Check if template exists
# Args: $1 = template filename
# Returns: 0 if exists, 1 if not
template_exists() {
    local name="$1"
    [ -f "${TEMPLATE_DIR}/${name}" ]
}

# Get template path
# Args: $1 = template filename
# Prints: full path
template_path() {
    echo "${TEMPLATE_DIR}/${1}"
}

################################################################################
# Template Deployment
################################################################################

# Deploy template to /etc/nginx/conf.d/ (system nginx, requires sudo)
# Args: $1 = template filename
# Returns: 0 on success, 1 on failure
template_deploy_to_confd() {
    local name="$1"
    local source="${TEMPLATE_DIR}/${name}"
    local dest="/etc/nginx/conf.d/${name}"

    if [ ! -f "$source" ]; then
        return 1
    fi

    if [ "${DRY_RUN:-false}" = true ]; then
        # Log what would happen (use ui function if available)
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Would deploy" "conf.d/${name}"
        fi
        return 0
    fi

    if sudo cp "$source" "$dest" 2>/dev/null; then
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Deployed" "conf.d/${name}"
        fi
        return 0
    fi
    return 1
}

# Deploy template to /etc/nginx/snippets/ (for includes)
# Args: $1 = template filename
# Returns: 0 on success, 1 on failure
template_deploy_to_snippets() {
    local name="$1"
    local source="${TEMPLATE_DIR}/${name}"
    local dest="/etc/nginx/snippets/${name}"

    if [ ! -f "$source" ]; then
        return 1
    fi

    if [ "${DRY_RUN:-false}" = true ]; then
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Would deploy" "snippets/${name}"
        fi
        return 0
    fi

    sudo mkdir -p /etc/nginx/snippets 2>/dev/null
    if sudo cp "$source" "$dest" 2>/dev/null; then
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Deployed" "snippets/${name}"
        fi
        return 0
    fi
    return 1
}

# Deploy template to wp-test nginx conf.d
# Args: $1 = template filename
# Returns: 0 on success, 1 on failure
template_deploy_to_wptest() {
    local name="$1"
    local source="${TEMPLATE_DIR}/${name}"
    local dest="${WP_TEST_NGINX}/conf.d/${name}"

    if [ ! -f "$source" ]; then
        return 1
    fi

    mkdir -p "$(dirname "$dest")" 2>/dev/null

    if [ "${DRY_RUN:-false}" = true ]; then
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Would deploy" "wp-test/conf.d/${name}"
        fi
        return 0
    fi

    if cp "$source" "$dest" 2>/dev/null; then
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Deployed" "wp-test/conf.d/${name}"
        fi
        return 0
    fi
    return 1
}

# Deploy template to wp-test vhost.d for specific site
# Args: $1 = template filename, $2 = site name
# Returns: 0 on success, 1 on failure
template_deploy_to_vhost() {
    local name="$1"
    local site="$2"
    local source="${TEMPLATE_DIR}/${name}"
    local dest="${WP_TEST_NGINX}/vhost.d/${site}"

    if [ ! -f "$source" ]; then
        return 1
    fi

    mkdir -p "$(dirname "$dest")" 2>/dev/null

    if [ "${DRY_RUN:-false}" = true ]; then
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Would configure" "vhost.d/${site}"
        fi
        return 0
    fi

    # Append to existing vhost file or create new
    if [ -f "$dest" ]; then
        # Check if already included
        if ! grep -qF "$name" "$dest" 2>/dev/null; then
            echo "" >> "$dest"
            echo "# Include ${name}" >> "$dest"
            echo "include /etc/nginx/conf.d/${name};" >> "$dest"
        fi
    else
        echo "# Include ${name}" > "$dest"
        echo "include /etc/nginx/conf.d/${name};" >> "$dest"
    fi

    if type -t ui_step_path &>/dev/null; then
        ui_step_path "Configured" "vhost.d/${site}"
    fi
    return 0
}

################################################################################
# Template Deployment by Context
################################################################################

# Deploy template based on context (server vs http)
# Args: $1 = template filename
#       $2 = context ("server" or "http")
#       $3 = target_site (optional, for per-site deployment)
# Returns: 0 on success, 1 on failure
template_deploy() {
    local name="$1"
    local context="${2:-server}"
    local target_site="${3:-}"

    local success=false

    case "$context" in
        http)
            # HTTP context = conf.d (auto-included in http block)
            if [ -d "/etc/nginx/conf.d" ]; then
                template_deploy_to_confd "$name" && success=true
            fi
            if [ -d "$WP_TEST_NGINX" ]; then
                template_deploy_to_wptest "$name" && success=true
            fi
            ;;
        server)
            # Server context = snippets (manually included in server blocks)
            if [ -d "/etc/nginx" ]; then
                template_deploy_to_snippets "$name" && success=true
            fi
            if [ -n "$target_site" ] && [ -d "$WP_TEST_NGINX" ]; then
                template_deploy_to_vhost "$name" "$target_site" && success=true
            elif [ -d "$WP_TEST_NGINX" ]; then
                template_deploy_to_wptest "$name" && success=true
            fi
            ;;
        *)
            return 1
            ;;
    esac

    [ "$success" = true ]
}

################################################################################
# Environment Detection (for deployment decisions)
################################################################################

# Check if system nginx with sites-enabled exists
has_system_nginx() {
    [ -d "/etc/nginx/sites-enabled" ] && [ -n "$(ls -A /etc/nginx/sites-enabled 2>/dev/null)" ]
}

# Check if wp-test sites exist
has_wptest_sites() {
    [ -d "$WP_TEST_SITES" ] && [ -n "$(ls -A "$WP_TEST_SITES" 2>/dev/null)" ]
}

# Check if Docker wp-test proxy is running
has_docker_wptest() {
    command -v docker &>/dev/null && docker ps --format "{{.Names}}" 2>/dev/null | grep -q "wp-test-proxy"
}
