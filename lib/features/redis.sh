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

# shellcheck disable=SC2034  # FEATURE_* vars consumed by feature_register() in registry.sh
FEATURE_ID="redis"
# shellcheck disable=SC2034
FEATURE_DISPLAY="Redis Object Cache"
# shellcheck disable=SC2034
FEATURE_DETECT_PATTERN="docker-compose:redis"
# shellcheck disable=SC2034
FEATURE_SCOPE="per-site"
# shellcheck disable=SC2034
FEATURE_TEMPLATE=""
# shellcheck disable=SC2034
FEATURE_TEMPLATE_CONTEXT=""
# shellcheck disable=SC2034
FEATURE_ALIASES=""
# shellcheck disable=SC2034
FEATURE_NGINX_MIN_VERSION=""
# shellcheck disable=SC2034
FEATURE_PREREQ_CHECK=""

################################################################################
# Custom Detection
################################################################################

# Detect if Redis is configured
# Args: $1 = config_file, $2 = site_name (optional for wp-test)
# Returns: 0 if enabled, 1 if not
# Sets: LAST_DIRECTIVE_SOURCE
feature_detect_custom_redis() {
    # shellcheck disable=SC2034  # config_file reserved for API compatibility
    local config_file="$1"
    local site_name="${2:-}"

    # Check 1: System Redis - is redis-server running?
    if command -v redis-cli &>/dev/null && redis-cli ping &>/dev/null 2>&1; then
        # shellcheck disable=SC2034  # LAST_DIRECTIVE_SOURCE consumed by registry.sh
        LAST_DIRECTIVE_SOURCE="system (redis-server running)"
        return 0
    fi

    # Check 2: wp-test Docker - redis service in docker-compose.yml
    if [[ -n "$site_name" ]]; then
        local wp_test_sites="${WP_TEST_SITES:-$HOME/.wp-test/sites}"
        local compose_file="${wp_test_sites}/${site_name}/docker-compose.yml"
        if [[ -f "$compose_file" ]] && grep -q "redis:" "$compose_file" 2>/dev/null; then
            # shellcheck disable=SC2034  # LAST_DIRECTIVE_SOURCE consumed by registry.sh
            LAST_DIRECTIVE_SOURCE="$compose_file"
            return 0
        fi
    fi

    return 1
}

################################################################################
# Custom Apply
################################################################################

# Apply Redis configuration
# For system nginx: install Redis, configure PHP sessions
# For wp-test: add redis service to docker-compose.yml
# Args: $1 = target_site (optional)
# Returns: 0 on success, 1 on failure
feature_apply_custom_redis() {
    local target_site="${1:-}"

    if type -t log_to_file &>/dev/null; then
        log_to_file "INFO" "Applying Redis Object Cache..."
    fi

    # System nginx mode
    if [ "${SYSTEM_ONLY:-false}" = true ]; then
        _redis_apply_system
        return $?
    fi

    # wp-test mode (Docker) - use helper if available
    if command -v docker &>/dev/null; then
        if type -t iterate_wptest_sites &>/dev/null; then
            iterate_wptest_sites "_redis_apply_site" "$target_site"
        else
            # Fallback to manual iteration
            local wp_test_sites="${WP_TEST_SITES:-$HOME/.wp-test/sites}"
            if [ -d "$wp_test_sites" ]; then
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
            fi
        fi
    fi

    # Also apply system Redis if available
    if type -t has_system_nginx &>/dev/null && has_system_nginx; then
        _redis_apply_system
    fi

    if type -t log_to_file &>/dev/null; then
        log_to_file "SUCCESS" "Redis configuration applied"
    fi

    return 0
}

# Apply Redis for system nginx
_redis_apply_system() {
    # Check if Redis is already running
    if command -v redis-cli &>/dev/null && redis-cli ping &>/dev/null 2>&1; then
        if type -t ui_step &>/dev/null; then
            ui_step "Redis server already running"
        fi
        _redis_system_show_wp_config
        return 0
    fi

    # Try to install Redis
    if [ "${DRY_RUN:-false}" = true ]; then
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Would install" "Redis server"
        fi
        return 0
    fi

    # macOS with Homebrew
    if command -v brew &>/dev/null; then
        if ! brew list redis &>/dev/null 2>&1; then
            if type -t ui_step &>/dev/null; then
                ui_step "Installing Redis via Homebrew..."
            fi
            brew install redis 2>/dev/null
        fi
        # Start Redis service
        brew services start redis 2>/dev/null
        if type -t ui_step &>/dev/null; then
            ui_step "Redis service started"
        fi
    # Linux with apt
    elif command -v apt-get &>/dev/null; then
        if ! command -v redis-server &>/dev/null; then
            if type -t ui_step &>/dev/null; then
                ui_step "Installing Redis..."
            fi
            sudo apt-get update && sudo apt-get install -y redis-server 2>/dev/null
        fi
        sudo systemctl enable redis-server 2>/dev/null
        sudo systemctl start redis-server 2>/dev/null
    else
        if type -t log_warn &>/dev/null; then
            log_warn "Cannot auto-install Redis. Please install manually."
        fi
        return 1
    fi

    _redis_system_show_wp_config
    return 0
}

# Show WordPress configuration for system Redis
_redis_system_show_wp_config() {
    if type -t log_to_file &>/dev/null; then
        log_to_file "INFO" "WordPress Redis Object Cache setup:"
        log_to_file "INFO" "  1. Install 'Redis Object Cache' plugin"
        log_to_file "INFO" "  2. Add to wp-config.php:"
        log_to_file "INFO" "     define('WP_REDIS_HOST', '127.0.0.1');"
        log_to_file "INFO" "     define('WP_REDIS_PORT', 6379);"
        log_to_file "INFO" "  3. Enable in Settings > Redis"
    fi
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

