#!/bin/bash
################################################################################
# features/redis.sh - Redis Object Cache
################################################################################
# Feature module with custom detection and apply logic for docker-compose.
################################################################################

# Ensure registry is loaded
if ! type -t feature_register &>/dev/null; then
    echo "Error: registry.sh must be sourced before feature modules" >&2
    return 1
fi

################################################################################
# Feature Definition
################################################################################

FEATURE_ID="redis"
FEATURE_DISPLAY="Redis Object Cache"
FEATURE_DETECT_PATTERN="docker-compose:redis"
FEATURE_SCOPE="per-site"
FEATURE_TEMPLATE=""
FEATURE_TEMPLATE_CONTEXT=""
FEATURE_ALIASES=""
FEATURE_NGINX_MIN_VERSION=""
FEATURE_PREREQ_CHECK=""
FEATURE_HAS_CUSTOM_DETECT="1"
FEATURE_HAS_CUSTOM_APPLY="1"

################################################################################
# Custom Detection
################################################################################

# Detect if Redis is configured by checking docker-compose.yml
# Args: $1 = config_file (unused for Redis), $2 = site_name
# Returns: 0 if enabled, 1 if not
# Sets: LAST_DIRECTIVE_SOURCE
feature_detect_custom_redis() {
    local config_file="$1"
    local site_name="$2"

    # Redis is wp-test specific, needs site name
    if [ -z "$site_name" ]; then
        return 1
    fi

    local wp_test_sites="${WP_TEST_SITES:-$HOME/.wp-test/sites}"
    local site_dir="${wp_test_sites}/${site_name}"
    local compose_file="${site_dir}/docker-compose.yml"

    if [ ! -f "$compose_file" ]; then
        return 1
    fi

    # Check for redis service in docker-compose.yml
    if grep -q "redis:" "$compose_file" 2>/dev/null; then
        LAST_DIRECTIVE_SOURCE="$compose_file"
        return 0
    fi

    return 1
}

################################################################################
# Custom Apply
################################################################################

# Apply Redis configuration by adding redis service to docker-compose.yml
# Args: $1 = target_site (optional)
# Returns: 0 on success, 1 on failure
feature_apply_custom_redis() {
    local target_site="${1:-}"

    # Check prerequisites
    if ! command -v docker &>/dev/null; then
        if type -t log_warn &>/dev/null; then
            log_warn "Docker not installed, skipping Redis setup"
        fi
        return 1
    fi

    local wp_test_sites="${WP_TEST_SITES:-$HOME/.wp-test/sites}"

    if [ ! -d "$wp_test_sites" ]; then
        if type -t log_warn &>/dev/null; then
            log_warn "wp-test sites directory not found"
        fi
        return 1
    fi

    if type -t log_to_file &>/dev/null; then
        log_to_file "INFO" "Applying Redis Object Cache..."
    fi

    # Apply to specific site or all sites
    if [ -n "$target_site" ] && [ -d "$wp_test_sites/$target_site" ]; then
        _redis_apply_site "$target_site"
    elif [ -z "$target_site" ]; then
        for site_dir in "$wp_test_sites"/*; do
            if [ -d "$site_dir" ]; then
                local site
                site=$(basename "$site_dir")
                _redis_apply_site "$site"
            fi
        done
    fi

    if type -t log_to_file &>/dev/null; then
        log_to_file "SUCCESS" "Redis configuration applied"
    fi

    return 0
}

################################################################################
# Helper Functions
################################################################################

# Apply Redis to a single wp-test site
_redis_apply_site() {
    local site="$1"
    local wp_test_sites="${WP_TEST_SITES:-$HOME/.wp-test/sites}"
    local compose_file="$wp_test_sites/$site/docker-compose.yml"

    if [ ! -f "$compose_file" ]; then
        if type -t log_warn &>/dev/null; then
            log_warn "docker-compose.yml not found for $site"
        fi
        return 1
    fi

    # Check if already configured
    if grep -q "redis:" "$compose_file" 2>/dev/null; then
        if type -t log_to_file &>/dev/null; then
            log_to_file "INFO" "Redis already configured for $site"
        fi
        return 0
    fi

    if type -t log_to_file &>/dev/null; then
        log_to_file "INFO" "Adding Redis to: $site"
    fi

    if [ "${DRY_RUN:-false}" = true ]; then
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Would add Redis to" "$site"
        fi
        return 0
    fi

    # Add Redis service to docker-compose.yml
    if type -t safe_add_docker_service &>/dev/null; then
        # Use safe YAML manipulation function if available
        local redis_definition="image: redis:alpine
    container_name: redis-${site}
    command: redis-server --maxmemory 256mb --maxmemory-policy allkeys-lru
    networks:
      - default"

        if safe_add_docker_service "$compose_file" "redis" "$redis_definition"; then
            _redis_show_next_steps "$site"
            return 0
        else
            if type -t log_error &>/dev/null; then
                log_error "Failed to add Redis service to docker-compose.yml"
            fi
            return 1
        fi
    else
        # Fallback: simple append (less safe)
        _redis_append_to_compose "$compose_file" "$site"
    fi
}

# Fallback method: append Redis service to docker-compose.yml
_redis_append_to_compose() {
    local compose_file="$1"
    local site="$2"

    # Backup original
    cp "$compose_file" "${compose_file}.bak"

    # Check if file has services: section
    if ! grep -q "^services:" "$compose_file"; then
        if type -t log_error &>/dev/null; then
            log_error "Invalid docker-compose.yml format (no services section)"
        fi
        return 1
    fi

    # Append Redis service
    cat >> "$compose_file" << EOF

  redis:
    image: redis:alpine
    container_name: redis-${site}
    command: redis-server --maxmemory 256mb --maxmemory-policy allkeys-lru
    networks:
      - default
EOF

    if type -t ui_step_path &>/dev/null; then
        ui_step_path "Added Redis to" "$site"
    fi

    _redis_show_next_steps "$site"
    return 0
}

# Show next steps after Redis is configured
_redis_show_next_steps() {
    local site="$1"
    local wp_test_sites="${WP_TEST_SITES:-$HOME/.wp-test/sites}"

    if type -t log_to_file &>/dev/null; then
        log_to_file "SUCCESS" "Redis configured for $site"
        log_to_file "INFO" "Next steps:"
        log_to_file "INFO" "  1. Restart containers: cd $wp_test_sites/$site && docker-compose up -d"
        log_to_file "INFO" "  2. Install Redis Object Cache plugin in WordPress"
        log_to_file "INFO" "  3. Add to wp-config.php:"
        log_to_file "INFO" "     define('WP_REDIS_HOST', 'redis');"
        log_to_file "INFO" "     define('WP_REDIS_PORT', 6379);"
    fi
}

################################################################################
# Register Feature
################################################################################

feature_register

