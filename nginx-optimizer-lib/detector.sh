#!/bin/bash

################################################################################
# detector.sh - Nginx Detection & Configuration Analysis
################################################################################

# Nginx location patterns (system, Intel Homebrew, Apple Silicon Homebrew)
NGINX_LOCATIONS=(
    "/etc/nginx/nginx.conf"
    "/usr/local/etc/nginx/nginx.conf"
    "/opt/homebrew/etc/nginx/nginx.conf"
    "/opt/nginx/conf/nginx.conf"
    "/usr/local/nginx/conf/nginx.conf"
)

# shellcheck disable=SC2034  # Used by optimizer.sh for site detection
SITE_CONFIGS=(
    "/etc/nginx/sites-enabled/"
    "/etc/nginx/conf.d/"
    "/usr/local/etc/nginx/servers/"
    "/usr/local/etc/nginx/sites-enabled/"
    "/opt/homebrew/etc/nginx/servers/"
    "/opt/homebrew/etc/nginx/sites-enabled/"
    "/opt/homebrew/etc/nginx/conf.d/"
)

# wp-test locations
WP_TEST_NGINX="${HOME}/.wp-test/nginx"
WP_TEST_SITES="${HOME}/.wp-test/sites"

# Store detected instances as "type:name:path" entries
DETECTED_INSTANCES=()

# Cache for nginx -T output (expensive operation)
NGINX_COMPILED_CONFIG=""
NGINX_CONFIG_CACHED=false

# Analysis results cache
ANALYSIS_CACHE_DIR="${DATA_DIR:-$HOME/.nginx-optimizer}/cache"
ANALYSIS_CACHE_FILE=""
CACHED_CONFIG_HASH=""

# Global to store last detected source file for directives
LAST_DIRECTIVE_SOURCE=""

# Site filtering cache
SITE_RELEVANT_FILES=""
SITE_FILTERING_ACTIVE=false

################################################################################
# Input Validation Functions
################################################################################

validate_site_name() {
    local name="$1"
    # Only allow alphanumeric, dots, hyphens, and underscores
    if [[ ! "$name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        log_error "Invalid site name '$name': contains illegal characters"
        log_error "Site names can only contain: a-z, A-Z, 0-9, dots, hyphens, underscores"
        return 1
    fi
    # Prevent path traversal attempts
    if [[ "$name" == *".."* ]] || [[ "$name" == "/"* ]]; then
        log_error "Invalid site name '$name': path traversal not allowed"
        return 1
    fi
    return 0
}

################################################################################
# Analysis Cache Functions
################################################################################

# Get hash of current nginx config (for cache validation)
get_config_hash() {
    local config_output
    if [ -n "$NGINX_COMPILED_CONFIG" ]; then
        config_output="$NGINX_COMPILED_CONFIG"
    elif docker ps --format "{{.Names}}" 2>/dev/null | grep -q "wp-test-proxy"; then
        config_output=$(docker exec wp-test-proxy nginx -T 2>/dev/null)
    elif command -v nginx &>/dev/null; then
        config_output=$(nginx -T 2>/dev/null)
    else
        echo ""
        return 1
    fi
    # Use md5 (macOS) or md5sum (Linux)
    if command -v md5 &>/dev/null; then
        printf '%s' "$config_output" | md5 | cut -d' ' -f1
    else
        printf '%s' "$config_output" | md5sum | cut -d' ' -f1
    fi
}

# Initialize cache directory
init_analysis_cache() {
    mkdir -p "$ANALYSIS_CACHE_DIR" 2>/dev/null || true
    ANALYSIS_CACHE_FILE="${ANALYSIS_CACHE_DIR}/analysis.cache"
}

# Save analysis state to cache (called after analysis completes)
save_analysis_cache() {
    local hash="$1"
    [ -z "$hash" ] && return 1
    init_analysis_cache
    {
        echo "HASH:$hash"
        echo "TIME:$(date +%s)"
        echo "SITES:$TOTAL_SITES_ANALYZED"
        echo "---MISSING---"
        printf '%s' "$MISSING_FEATURES"
    } > "$ANALYSIS_CACHE_FILE"
}

# Load cached analysis if hash matches
# Args: $1 = current config hash
# Returns: 0 if cache hit (restores state, shows recommendations), 1 if miss
load_analysis_cache() {
    local current_hash="$1"
    init_analysis_cache

    [ ! -f "$ANALYSIS_CACHE_FILE" ] && return 1

    local cached_hash cached_time cached_sites
    cached_hash=$(grep "^HASH:" "$ANALYSIS_CACHE_FILE" | cut -d: -f2)
    cached_time=$(grep "^TIME:" "$ANALYSIS_CACHE_FILE" | cut -d: -f2)
    cached_sites=$(grep "^SITES:" "$ANALYSIS_CACHE_FILE" | cut -d: -f2)

    # Check hash match
    if [ "$cached_hash" != "$current_hash" ]; then
        return 1
    fi

    # Calculate age
    local now age_seconds age_display
    now=$(date +%s)
    age_seconds=$((now - cached_time))

    if [ "$age_seconds" -lt 60 ]; then
        age_display="${age_seconds}s ago"
    elif [ "$age_seconds" -lt 3600 ]; then
        age_display="$((age_seconds / 60))m ago"
    elif [ "$age_seconds" -lt 86400 ]; then
        age_display="$((age_seconds / 3600))h ago"
    else
        age_display="$((age_seconds / 86400))d ago"
    fi

    # Restore state
    MISSING_FEATURES=$(sed -n '/^---MISSING---$/,$ p' "$ANALYSIS_CACHE_FILE" | tail -n +2)
    TOTAL_SITES_ANALYZED="$cached_sites"

    # Output cache indicator with clean UI
    if type -t ui_section &>/dev/null; then
        ui_section "Using cached analysis..."
        ui_step "Config unchanged" "${age_display}"
        ui_blank
        echo -e "  ─────────────────────────────────────────────────────"
        echo -e "  ${TOTAL_SITES_ANALYZED} site(s) analyzed (use --no-cache to refresh)"
    else
        echo ""
        echo -e "${CYAN}[CACHED]${NC} Config unchanged (${age_display}, hash: ${current_hash:0:8}...)"
        echo -e "${CYAN}[CACHED]${NC} Run with --no-cache to force fresh analysis"
        echo ""
        echo "═══════════════════════════════════════════════════════════"
        echo "Summary: $TOTAL_SITES_ANALYZED sites (cached)"
        echo "═══════════════════════════════════════════════════════════"
    fi

    # Show recommendations from cached state
    show_recommendations

    return 0
}

# Clear analysis cache
clear_analysis_cache() {
    init_analysis_cache
    rm -f "$ANALYSIS_CACHE_FILE"
    # Silent - only log to file
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Analysis cache cleared" >> "${LOG_FILE:-/dev/null}"
}

################################################################################
# Detection Functions
################################################################################

add_instance() {
    local type="$1"
    local name="$2"
    local path="$3"
    DETECTED_INSTANCES+=("${type}:${name}:${path}")
}

get_instance_count() {
    echo "${#DETECTED_INSTANCES[@]}"
}

detect_system_nginx() {
    for conf in "${NGINX_LOCATIONS[@]}"; do
        if [ -f "$conf" ]; then
            add_instance "system" "nginx" "$conf"

            if command -v nginx &>/dev/null; then
                local version
                version=$(nginx -v 2>&1 | sed -n 's/.*nginx\/\([0-9.]*\).*/\1/p')

                # Use clean UI if available
                if type -t ui_step &>/dev/null; then
                    ui_step "System nginx" "v${version}"
                else
                    log_success "Found system nginx: $conf (v${version})"
                fi

                # Parse full config with nginx -T for source tracking
                if type -t parse_nginx_config &>/dev/null; then
                    parse_nginx_config 2>/dev/null || true
                fi
            else
                if type -t ui_step &>/dev/null; then
                    ui_step "System nginx" "$conf"
                else
                    log_success "Found system nginx: $conf"
                fi
            fi
            return 0
        fi
    done

    return 1
}

detect_docker_nginx() {
    if ! command -v docker &>/dev/null; then
        return 1
    fi

    # Check if Docker is running
    if ! docker info &>/dev/null; then
        return 1
    fi

    local found=false

    # Check for wp-test-proxy specifically
    if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "wp-test-proxy"; then
        add_instance "docker" "wp-test-proxy" "wp-test-proxy"
        if type -t ui_step &>/dev/null; then
            ui_step "Docker nginx-proxy" "wp-test"
        else
            log_success "Found wp-test nginx-proxy container"
        fi
        found=true
    fi

    # Check for nginx containers
    local containers
    containers=$(docker ps --filter "ancestor=nginx" --format "{{.Names}}" 2>/dev/null)

    if [ -n "$containers" ]; then
        while IFS= read -r container; do
            if [ "$container" != "wp-test-proxy" ]; then
                add_instance "docker" "$container" "$container"
                if type -t ui_step &>/dev/null; then
                    ui_step "Docker nginx" "$container"
                else
                    log_success "Found Docker nginx: $container"
                fi
                found=true
            fi
        done <<< "$containers"
    fi

    [ "$found" = true ] && return 0
    return 1
}

detect_wp_test_sites() {
    if [ ! -d "$WP_TEST_SITES" ]; then
        return 1
    fi

    local site_count=0
    for site_dir in "$WP_TEST_SITES"/*; do
        if [ -d "$site_dir" ] && [ "$(basename "$site_dir")" != ".DS_Store" ]; then
            local domain
            domain=$(basename "$site_dir")
            add_instance "wp_test" "$domain" "$site_dir"
            site_count=$((site_count + 1))
        fi
    done

    if [ $site_count -eq 0 ]; then
        return 1
    fi

    # Also check for wp-test nginx config
    if [ -f "$WP_TEST_NGINX/proxy.conf" ]; then
        add_instance "wp_test_nginx" "proxy" "$WP_TEST_NGINX/proxy.conf"
    fi

    # Show single summary line
    if type -t ui_step &>/dev/null; then
        ui_step "wp-test sites" "${site_count} found"
    else
        log_success "Found $site_count wp-test site(s)"
    fi
    return 0
}

detect_nginx_instances() {
    local target_site="$1"

    # Reset instances array
    DETECTED_INSTANCES=()

    # Initialize parser if available
    if type -t parser_init &>/dev/null; then
        parser_init 2>/dev/null || true
    fi

    # Show section header
    if type -t ui_section &>/dev/null; then
        ui_section "Detecting..."
    fi

    if [ -n "$target_site" ]; then
        # Validate site name to prevent path traversal
        if ! validate_site_name "$target_site"; then
            exit 1
        fi
        # Check if it's a wp-test site
        if [ -d "$WP_TEST_SITES/$target_site" ]; then
            add_instance "wp_test" "$target_site" "$WP_TEST_SITES/$target_site"
            if type -t ui_step &>/dev/null; then
                ui_step "Target site" "$target_site"
            else
                log_success "Target site found: $target_site"
            fi
        else
            if type -t ui_step_fail &>/dev/null; then
                ui_step_fail "Site not found" "$target_site"
            else
                log_error "Site not found: $target_site"
            fi
            exit 1
        fi
    else
        # Detect all (ignore return codes - we accumulate instances)
        detect_system_nginx || true
        if [ "${SYSTEM_ONLY:-false}" != true ]; then
            detect_docker_nginx || true
            detect_wp_test_sites || true
        fi
    fi

    local count
    count=$(get_instance_count)
    if [ "$count" -eq 0 ]; then
        if type -t ui_step_fail &>/dev/null; then
            ui_step_fail "No nginx installations detected"
        else
            log_warn "No nginx installations detected"
        fi
        return 1
    fi

    return 0
}

list_nginx_instances() {
    detect_nginx_instances ""

    # Clean UI output
    if type -t ui_section &>/dev/null; then
        ui_section "Found installations:"
        for entry in "${DETECTED_INSTANCES[@]}"; do
            local type name path
            type=$(echo "$entry" | cut -d: -f1)
            name=$(echo "$entry" | cut -d: -f2)
            path=$(echo "$entry" | cut -d: -f3-)
            ui_bullet "[$type] $name: $path"
        done
        ui_blank
    else
        echo ""
        echo "═══════════════════════════════════════════════════════════"
        echo "Detected NGINX Installations:"
        echo "═══════════════════════════════════════════════════════════"
        for entry in "${DETECTED_INSTANCES[@]}"; do
            local type name path
            type=$(echo "$entry" | cut -d: -f1)
            name=$(echo "$entry" | cut -d: -f2)
            path=$(echo "$entry" | cut -d: -f3-)
            echo "  • [$type] $name: $path"
        done
        echo ""
    fi
}

################################################################################
# Site Filtering Functions
################################################################################

# Cache for site filter lookups (site_name|files format per line)
SITE_FILTER_CACHE=""
SITE_FILTER_CACHE_BUILT=false

# Cached main nginx.conf path (computed once, used many times)
CACHED_MAIN_NGINX_CONF=""
CACHED_MAIN_NGINX_CONF_SET=false

# Get cached main nginx.conf path
get_main_nginx_conf() {
    if [ "$CACHED_MAIN_NGINX_CONF_SET" = true ]; then
        printf '%s' "$CACHED_MAIN_NGINX_CONF"
        return
    fi

    if type -t list_parsed_files &>/dev/null; then
        CACHED_MAIN_NGINX_CONF=$(list_parsed_files | grep "nginx\.conf$" | head -n1)
    fi
    CACHED_MAIN_NGINX_CONF_SET=true
    printf '%s' "$CACHED_MAIN_NGINX_CONF"
}

# Build site filter cache for ALL sites at once (called once, used many times)
# This is the key optimization - parse config once, lookup instantly per site
build_site_filter_cache() {
    if [ "$SITE_FILTER_CACHE_BUILT" = true ]; then
        return 0
    fi

    local config_file=""
    # Get nginx config (use parser cache if available)
    if [ -n "$PARSED_CONFIG_CACHE" ] && [ -f "$PARSED_CONFIG_CACHE" ]; then
        config_file="$PARSED_CONFIG_CACHE"
    else
        # Create temp file with config
        config_file=$(mktemp)
        if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "wp-test-proxy"; then
            docker exec wp-test-proxy nginx -T 2>/dev/null > "$config_file"
        else
            get_nginx_compiled_config > "$config_file"
        fi
    fi

    if [ ! -s "$config_file" ]; then
        [ "$config_file" != "$PARSED_CONFIG_CACHE" ] && rm -f "$config_file"
        return 1
    fi

    # FAST: Use awk instead of slow bash while-read
    # Note: BSD/macOS awk doesn't support match() with third argument
    SITE_FILTER_CACHE=$(awk '
    BEGIN { main_conf = "" }
    /^###FILE:/ || /^#.*configuration file [^:]+:$/ {
        if (/^###FILE:/) {
            current_file = substr($0, 9)
        } else {
            # BSD-compatible: extract path between "configuration file " and ":"
            gsub(/^.*configuration file /, "")
            gsub(/:$/, "")
            current_file = $0
        }
        if (current_file ~ /nginx\.conf$/ && main_conf == "") main_conf = current_file
        next
    }
    /^[[:space:]]*server[[:space:]]*\{/ {
        in_server = 1
        depth = 1
        server_names = ""
        server_files = current_file
        next
    }
    in_server {
        # Count braces
        n = gsub(/\{/, "{")
        m = gsub(/\}/, "}")
        depth += n - m

        # Capture server_name
        if (/server_name[[:space:]]+/) {
            sub(/.*server_name[[:space:]]+/, "")
            sub(/;.*/, "")
            gsub(/[[:space:]]+/, " ")
            n = split($0, names, " ")
            for (i = 1; i <= n; i++) {
                if (names[i] !~ /^(localhost|_|default_server)$/) {
                    if (server_names != "") server_names = server_names " "
                    server_names = server_names names[i]
                }
            }
        }

        # Track files
        if (current_file != "" && index(server_files, current_file) == 0) {
            server_files = server_files ":" current_file
        }

        # End of server block
        if (depth == 0) {
            in_server = 0
            n = split(server_names, names, " ")
            for (i = 1; i <= n; i++) {
                files = server_files
                if (main_conf != "") files = main_conf ":" files
                print names[i] "|" files
            }
        }
    }
    ' "$config_file")

    [ "$config_file" != "$PARSED_CONFIG_CACHE" ] && rm -f "$config_file"
    # Only mark as built if we actually got cache data
    [ -n "$SITE_FILTER_CACHE" ] && SITE_FILTER_CACHE_BUILT=true
}

# Get cached site files (instant lookup)
# Args: $1 = site name
# Returns: colon-separated list of config files
get_cached_site_files() {
    local site="$1"

    # Build cache if needed
    [ "$SITE_FILTER_CACHE_BUILT" != true ] && build_site_filter_cache

    # Lookup from cache
    echo "$SITE_FILTER_CACHE" | grep "^${site}|" | head -n1 | cut -d'|' -f2 | tr ':' '\n'
}

# Get list of config files relevant to a specific site
# Args: $1 = site name/domain
# Returns: newline-separated list of config file paths
get_site_config_files() {
    local site="$1"
    local relevant_files=""
    local config

    # Use docker exec for wp-test sites
    if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "wp-test-proxy"; then
        config=$(docker exec wp-test-proxy nginx -T 2>/dev/null)
    else
        config=$(get_nginx_compiled_config)
    fi

    if [ -z "$config" ]; then
        return 1
    fi

    local current_file=""
    local in_server_block=false
    local server_block_matches=false
    local server_block_files=""
    local main_nginx_conf=""
    local brace_depth=0

    # Parse nginx -T output
    while IFS= read -r line; do
        # Track current config file
        if [[ "$line" =~ ^#.*configuration\ file\ ([^:]+):$ ]]; then
            current_file="${BASH_REMATCH[1]}"

            # Always include main nginx.conf (global http context)
            if [[ "$current_file" =~ nginx\.conf$ ]] && [ -z "$main_nginx_conf" ]; then
                main_nginx_conf="$current_file"
            fi
        fi

        # Track server blocks and brace depth
        if echo "$line" | grep -q "^[[:space:]]*server[[:space:]]*{"; then
            in_server_block=true
            server_block_matches=false
            server_block_files=""
            brace_depth=1
        elif [ "$in_server_block" = true ]; then
            # Count braces to track depth
            local open_braces
            local close_braces
            open_braces=$(echo "$line" | tr -cd '{' | wc -c | tr -d ' ')
            close_braces=$(echo "$line" | tr -cd '}' | wc -c | tr -d ' ')
            brace_depth=$((brace_depth + open_braces - close_braces))

            # Check for server_name matching this site
            if echo "$line" | grep -q "server_name.*$site"; then
                server_block_matches=true
            fi

            # Track files included in this server block
            if [ -n "$current_file" ]; then
                if ! echo "$server_block_files" | grep -q "$current_file"; then
                    server_block_files="${server_block_files}${current_file}"$'\n'
                fi
            fi

            # Check for include directives
            if [[ "$line" =~ include[[:space:]]+([^;]+)\; ]]; then
                local include_path="${BASH_REMATCH[1]}"
                # Expand vhost.d includes with site name
                if [[ "$include_path" =~ vhost\.d/$site ]]; then
                    server_block_files="${server_block_files}${include_path}"$'\n'
                fi
            fi

            # End of server block
            if [ $brace_depth -eq 0 ]; then
                in_server_block=false
                if [ "$server_block_matches" = true ]; then
                    relevant_files="${relevant_files}${server_block_files}"
                fi
            fi
        fi
    done <<< "$config"

    # Add main nginx.conf if found
    if [ -n "$main_nginx_conf" ]; then
        relevant_files="${main_nginx_conf}"$'\n'"${relevant_files}"
    fi

    # Also check for vhost.d file matching site name
    local vhost_file="${WP_TEST_NGINX}/vhost.d/${site}"
    if [ -f "$vhost_file" ]; then
        relevant_files="${relevant_files}${vhost_file}"$'\n'
    fi

    # Remove duplicates and empty lines
    echo "$relevant_files" | sort -u | grep -v "^$"
}

# Check if a file is relevant to the current site filter
# Args: $1 = file path
# Returns: 0 if relevant, 1 if not
is_file_relevant_to_site() {
    local file="$1"

    # If no site filtering, all files are relevant
    if [ "$SITE_FILTERING_ACTIVE" = false ]; then
        return 0
    fi

    # Check if file is in the relevant files list
    if echo "$SITE_RELEVANT_FILES" | grep -qF "$file"; then
        return 0
    fi

    return 1
}

# Check if directive exists in site-relevant config files
# Args: $1 = pattern, $2 = site name (optional)
# Sets LAST_DIRECTIVE_SOURCE if found
check_directive_for_site() {
    local pattern="$1"
    local site="$2"

    LAST_DIRECTIVE_SOURCE=""

    # If no site specified or filtering not active, use normal check
    if [ -z "$site" ] || [ "$SITE_FILTERING_ACTIVE" = false ]; then
        if type -t get_directive_source &>/dev/null; then
            LAST_DIRECTIVE_SOURCE=$(get_directive_source "$pattern")
            if [ -n "$LAST_DIRECTIVE_SOURCE" ]; then
                return 0
            fi
        fi
        if check_nginx_compiled "$pattern"; then
            return 0
        fi
        return 1
    fi

    # OPTIMIZED: Use parser cache with site filtering
    # Loop through site's relevant files (2-3 files) instead of 700+ lines
    if type -t directive_exists_in_file &>/dev/null && [ -n "${PARSED_CONFIG_CACHE:-}" ]; then
        local file
        while IFS= read -r file; do
            [ -z "$file" ] && continue
            if directive_exists_in_file "$file" "$pattern"; then
                LAST_DIRECTIVE_SOURCE="$file"
                return 0
            fi
        done <<< "$SITE_RELEVANT_FILES"
    fi

    return 1
}

################################################################################
# Registry Adapter Functions
################################################################################
# These functions provide a bridge between the old check_*_enabled() functions
# and the new plugin registry in lib/registry.sh. Allows gradual migration.

# registry_detect_feature - Detect feature using the new registry system
# Args: $1 = feature_id (e.g., "http3", "brotli")
#       $2 = config_file
#       $3 = site_name (optional)
# Returns: 0 if feature is enabled, 1 if not
# Sets: LAST_DIRECTIVE_SOURCE (for compatibility with old system)
registry_detect_feature() {
    local feature_id="$1"
    local config_file="$2"
    local site_name="${3:-}"

    # Check if registry is loaded
    if ! type -t feature_detect &>/dev/null; then
        # Registry not loaded, fall back to returning 1 (not found)
        # This allows the system to work even if lib/ isn't loaded
        return 1
    fi

    # Call registry's feature_detect
    if feature_detect "$feature_id" "$config_file" "$site_name"; then
        return 0
    fi

    return 1
}

# registry_get_feature_display - Get display name for a feature
# Args: $1 = feature_id
# Returns: display name string
registry_get_feature_display() {
    local feature_id="$1"

    if ! type -t feature_get &>/dev/null; then
        echo "$feature_id"
        return
    fi

    local display
    display=$(feature_get "$feature_id" "display" 2>/dev/null)
    if [ -n "$display" ]; then
        echo "$display"
    else
        echo "$feature_id"
    fi
}

# registry_list_features - List all registered features
# Returns: newline-separated list of feature IDs
registry_list_features() {
    if ! type -t feature_list &>/dev/null; then
        return 1
    fi

    feature_list
}

# Initialize site filtering for a specific site
# Args: $1 = site name
init_site_filtering() {
    local site="$1"

    if [ -z "$site" ]; then
        SITE_FILTERING_ACTIVE=false
        SITE_RELEVANT_FILES=""
        return
    fi

    # Use cached lookup (fast) instead of parsing config each time (slow)
    SITE_RELEVANT_FILES=$(get_cached_site_files "$site")

    if [ -z "$SITE_RELEVANT_FILES" ]; then
        # Fallback to full parsing if cache miss
        SITE_RELEVANT_FILES=$(get_site_config_files "$site")
    fi

    if [ -z "$SITE_RELEVANT_FILES" ]; then
        SITE_FILTERING_ACTIVE=false
    else
        SITE_FILTERING_ACTIVE=true
    fi
}

################################################################################
# Configuration Analysis Functions
################################################################################

# Format source path for display (shorten if needed)
# Args: $1 = full path
# Returns: shortened display path
format_source_path() {
    local path="$1"
    if [ -z "$path" ]; then
        echo ""
        return
    fi

    # Extract last 2 path components for readability
    # /etc/nginx/conf.d/security.conf -> conf.d/security.conf
    # /etc/nginx/nginx.conf -> nginx.conf
    # ~/.wp-test/nginx/vhost.d/site.conf -> vhost.d/site.conf

    # Count the number of slashes
    local slash_count
    slash_count=$(echo "$path" | tr -cd '/' | wc -c | tr -d ' ')

    if [ "$slash_count" -ge 2 ]; then
        # Extract last 2 components: dir/file.conf
        echo "$path" | awk -F/ '{print $(NF-1)"/"$NF}'
    else
        # Just use basename for short paths
        basename "$path"
    fi
}

# Get cached nginx -T output (runs once, reuses thereafter)
get_nginx_compiled_config() {
    if [ "$NGINX_CONFIG_CACHED" = false ]; then
        if command -v nginx &>/dev/null; then
            NGINX_COMPILED_CONFIG=$(nginx -T 2>/dev/null || echo "")
        fi
        NGINX_CONFIG_CACHED=true
    fi
    echo "$NGINX_COMPILED_CONFIG"
}

# Reset nginx config cache (call at start of new analysis)
reset_nginx_config_cache() {
    NGINX_COMPILED_CONFIG=""
    NGINX_CONFIG_CACHED=false

    # Re-initialize parser if available
    if type -t parser_init &>/dev/null; then
        parser_init || log_warn "Parser re-initialization failed"
    fi
}

# Check compiled nginx config using cached output (performance optimization)
check_nginx_compiled() {
    local pattern="$1"
    local config
    config=$(get_nginx_compiled_config)
    if [ -n "$config" ]; then
        if echo "$config" | grep -q "$pattern"; then
            return 0
        fi
    fi
    return 1
}

# Analyze nginx config inside a Docker container using docker exec
analyze_docker_container() {
    local container="$1"

    if [ -z "$container" ]; then
        return 1
    fi

    # Check if container is running
    if ! docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^${container}$"; then
        return 1
    fi

    # Try to get nginx config from container
    local config
    config=$(docker exec "$container" nginx -T 2>/dev/null) || {
        if type -t ui_step_fail &>/dev/null; then
            ui_step_fail "Docker nginx" "nginx -T failed"
        fi
        return 1
    }

    # Parse the config output to track source files (basic docker version)
    local current_file=""
    local http3_source=""
    local cache_source=""
    local brotli_source=""
    local gzip_source=""
    local hsts_source=""
    local rate_source=""

    while IFS= read -r line; do
        # Track current config file
        if [[ "$line" =~ ^#.*configuration\ file\ (.+):$ ]]; then
            current_file="${BASH_REMATCH[1]}"
        fi

        # Track directives
        if echo "$line" | grep -qiE "listen.*quic|http3" && [ -z "$http3_source" ]; then
            http3_source="$current_file"
        fi
        if echo "$line" | grep -qi "fastcgi_cache" && [ -z "$cache_source" ]; then
            cache_source="$current_file"
        fi
        if echo "$line" | grep -qi "brotli" && [ -z "$brotli_source" ]; then
            brotli_source="$current_file"
        fi
        if echo "$line" | grep -qi "gzip on" && [ -z "$gzip_source" ]; then
            gzip_source="$current_file"
        fi
        if echo "$line" | grep -qi "Strict-Transport-Security" && [ -z "$hsts_source" ]; then
            hsts_source="$current_file"
        fi
        if echo "$line" | grep -qi "limit_req" && [ -z "$rate_source" ]; then
            rate_source="$current_file"
        fi
    done <<< "$config"

    # Display with sources
    if echo "$config" | grep -qiE "listen.*quic|http3"; then
        printf "    ${GREEN}✓${NC} %-22s" "HTTP/3 QUIC"
        if [ -n "$http3_source" ]; then
            echo " ($(format_source_path "$http3_source"))"
        else
            echo ""
        fi
    else
        echo -e "    ${YELLOW}✗ HTTP/3 QUIC${NC}"
    fi

    if echo "$config" | grep -qi "fastcgi_cache"; then
        printf "    ${GREEN}✓${NC} %-22s" "FastCGI Cache"
        if [ -n "$cache_source" ]; then
            echo " ($(format_source_path "$cache_source"))"
        else
            echo ""
        fi
    else
        echo -e "    ${YELLOW}✗ FastCGI Cache${NC}"
    fi

    if echo "$config" | grep -qi "brotli"; then
        printf "    ${GREEN}✓${NC} %-22s" "Brotli Compression"
        if [ -n "$brotli_source" ]; then
            echo " ($(format_source_path "$brotli_source"))"
        else
            echo ""
        fi
    else
        echo -e "    ${YELLOW}✗ Brotli Compression${NC}"
    fi

    if echo "$config" | grep -qi "gzip on"; then
        printf "    ${GREEN}✓${NC} %-22s" "Gzip Compression"
        if [ -n "$gzip_source" ]; then
            echo " ($(format_source_path "$gzip_source"))"
        else
            echo ""
        fi
    else
        echo -e "    ${YELLOW}✗ Gzip Compression${NC}"
    fi

    if echo "$config" | grep -qi "Strict-Transport-Security"; then
        printf "    ${GREEN}✓${NC} %-22s" "Security Headers (HSTS)"
        if [ -n "$hsts_source" ]; then
            echo " ($(format_source_path "$hsts_source"))"
        else
            echo ""
        fi
    else
        echo -e "    ${YELLOW}✗ Security Headers (HSTS)${NC}"
    fi

    if echo "$config" | grep -qi "limit_req"; then
        printf "    ${GREEN}✓${NC} %-22s" "Rate Limiting"
        if [ -n "$rate_source" ]; then
            echo " ($(format_source_path "$rate_source"))"
        else
            echo ""
        fi
    else
        echo -e "    ${YELLOW}✗ Rate Limiting${NC}"
    fi

    echo ""
    return 0
}

# Check if www variant is missing from SSL server block
# Returns 0 if www is properly handled, 1 if missing
check_www_ssl_mismatch() {
    local config_file="$1"
    local site_name="$2"
    LAST_DIRECTIVE_SOURCE=""

    # Skip if site already starts with www
    [[ "$site_name" == www.* ]] && return 0

    # Skip if no SSL configured
    if ! grep -v '^\s*#' "$config_file" 2>/dev/null | grep -q "listen.*443.*ssl"; then
        return 0
    fi

    # Check if there's a www redirect on port 80 (indicates www should work)
    local has_www_redirect=false
    if grep -v '^\s*#' "$config_file" 2>/dev/null | grep -q "server_name.*www\\.${site_name}"; then
        has_www_redirect=true
    fi

    # If no www handling at all, skip (site doesn't use www)
    [ "$has_www_redirect" = false ] && return 0

    # Extract server blocks with SSL (tracking brace depth for nested blocks)
    local ssl_block
    ssl_block=$(awk '
        /^[[:space:]]*server[[:space:]]*\{/ && !in_server { in_server=1; depth=1; block=""; next }
        in_server && /\{/ { depth++ }
        in_server && /\}/ { depth-- }
        in_server { block = block $0 "\n" }
        in_server && depth == 0 {
            if (block ~ /listen.*443.*ssl/) print block
            in_server=0
        }
    ' "$config_file" 2>/dev/null)

    # Check if SSL block has www.domain in server_name
    if echo "$ssl_block" | grep -q "server_name.*www\\.${site_name}"; then
        LAST_DIRECTIVE_SOURCE="$config_file"
        return 0
    fi

    # www is used but not in SSL block - this is a mismatch
    return 1
}

################################################################################
# Per-Site Analysis Functions
################################################################################

################################################################################
# Registry-Based Detection
################################################################################

# Detect all registered features for a site
# Args: $1 = site_name, $2 = config_file
# Sets: DETECT_SCORE_ENABLED, DETECT_SCORE_TOTAL
# Returns: 0 on success
detect_all_features_for_site() {
    local site_name="$1"
    local config_file="$2"

    DETECT_SCORE_ENABLED=0
    DETECT_SCORE_TOTAL=0

    # Check if registry is available
    if ! type -t feature_list_all &>/dev/null; then
        return 1
    fi

    # Loop through all registered features
    while IFS='|' read -r feature_id feature_display; do
        [ -z "$feature_id" ] && continue

        # Check if this feature affects scoring
        local counts_for_score=true
        case "$feature_id" in
            ocsp|tls*) counts_for_score=false ;;
        esac

        # Detect the feature
        if feature_detect "$feature_id" "$config_file" "$site_name"; then
            # Feature is enabled
            printf "    ${GREEN}✓${NC} %-22s" "$feature_display"
            if [ -n "$LAST_DIRECTIVE_SOURCE" ]; then
                echo " ($(format_source_path "$LAST_DIRECTIVE_SOURCE"))"
            else
                echo ""
            fi

            if [ "$counts_for_score" = true ]; then
                DETECT_SCORE_ENABLED=$((DETECT_SCORE_ENABLED + 1))
            fi
        else
            # Feature is missing
            printf "    ${YELLOW}✗${NC} %-22s\n" "$feature_display"
            record_missing_feature "$feature_id" "$site_name"
        fi

        if [ "$counts_for_score" = true ]; then
            DETECT_SCORE_TOTAL=$((DETECT_SCORE_TOTAL + 1))
        fi
    done <<< "$(feature_list_all)"

    # TLS Versions - special display format (no score)
    local tls_versions=""
    if check_feature_for_site "TLSv1.3" "$site_name" "$config_file"; then
        tls_versions="1.3"
    fi
    if check_feature_for_site "TLSv1.2" "$site_name" "$config_file"; then
        if [ -n "$tls_versions" ]; then
            tls_versions="${tls_versions}, 1.2"
        else
            tls_versions="1.2"
        fi
    fi

    if [ -n "$tls_versions" ]; then
        if echo "$tls_versions" | grep -q "1.3"; then
            printf "    ${GREEN}✓${NC} %-22s" "TLS Versions: ${tls_versions}"
            if [ -n "$LAST_DIRECTIVE_SOURCE" ]; then
                echo " ($(format_source_path "$LAST_DIRECTIVE_SOURCE"))"
            else
                echo ""
            fi
        else
            echo -e "    ${YELLOW}✓ TLS Versions: ${tls_versions} (1.3 recommended)${NC}"
        fi
    else
        echo -e "    ${YELLOW}✗ TLS Versions: not configured${NC}"
    fi

    # WWW/SSL Mismatch check (only for non-www sites with SSL)
    if check_www_ssl_mismatch "$config_file" "$site_name"; then
        # Either no www handling needed, or www is properly configured
        :
    else
        printf "    ${YELLOW}✗${NC} %-22s\n" "WWW in SSL"
        record_missing_feature "www-ssl" "$site_name"
    fi

    return 0
}

# Map regex pattern to feature name for fast cache lookup
pattern_to_feature() {
    local pattern="$1"
    case "$pattern" in
        *quic*) echo "http3" ;;
        *fastcgi_cache*) echo "fastcgi_cache" ;;
        *brotli*) echo "brotli" ;;
        *gzip*) echo "gzip" ;;
        *Strict-Transport*) echo "security_headers" ;;
        *limit_req*) echo "rate_limiting" ;;
        *xmlrpc*) echo "wordpress" ;;
        *ssl_stapling*) echo "ocsp" ;;
        *TLSv1.3*) echo "tls13" ;;
        *TLSv1.2*) echo "tls12" ;;
        *) echo "" ;;
    esac
}

# Check if feature exists for a specific site
# Args: $1 = pattern (regex)
#       $2 = site name
#       $3 = config file
# Returns: 0 if found, 1 if not
check_feature_for_site() {
    local pattern="$1"
    local site_name="$2"
    local config_file="$3"

    LAST_DIRECTIVE_SOURCE=""

    # FAST PATH: Use pre-built feature cache (1 awk pass vs 99)
    local feature
    feature=$(pattern_to_feature "$pattern")
    if [ -n "$feature" ] && type -t has_feature_in_file &>/dev/null; then
        # Check in site's config file
        if has_feature_in_file "$config_file" "$feature"; then
            LAST_DIRECTIVE_SOURCE="$config_file"
            return 0
        fi

        # Check in site's relevant files (if site filtering active)
        if [ "$SITE_FILTERING_ACTIVE" = true ] && [ -n "$SITE_RELEVANT_FILES" ]; then
            local file
            while IFS= read -r file; do
                [ -z "$file" ] && continue
                if has_feature_in_file "$file" "$feature"; then
                    LAST_DIRECTIVE_SOURCE="$file"
                    return 0
                fi
            done <<< "$SITE_RELEVANT_FILES"
        fi

        # Check in main nginx.conf (global features like gzip)
        local main_nginx_conf
        main_nginx_conf=$(get_main_nginx_conf)
        if [ -n "$main_nginx_conf" ] && has_feature_in_file "$main_nginx_conf" "$feature"; then
            LAST_DIRECTIVE_SOURCE="$main_nginx_conf"
            return 0
        fi

        return 1
    fi

    # SLOW FALLBACK: For unknown patterns, use regex search
    if type -t directive_exists_in_file &>/dev/null; then
        if directive_exists_in_file "$config_file" "$pattern"; then
            LAST_DIRECTIVE_SOURCE="$config_file"
            return 0
        fi
    fi

    return 1
}

# Display score bar for a single site
# Args: $1 = enabled count, $2 = total count
show_site_score() {
    local enabled=$1
    local total=$2

    if [ "$total" -eq 0 ]; then
        echo -e "${YELLOW}0/0 (0%)${NC}"
        return
    fi

    local percent=$(( (enabled * 100 + total / 2) / total ))
    local color

    if (( percent >= 80 )); then
        color=$GREEN
    elif (( percent >= 50 )); then
        color=$YELLOW
    else
        color=$RED
    fi

    echo -e "${color}${enabled}/${total} (${percent}%)${NC}"
}

# Analyze optimizations for a single site
# Args: $1 = site name (e.g., "mysite.com")
#       $2 = config file path (e.g., "/etc/nginx/sites-enabled/mysite.conf")
# Outputs: Feature checklist with per-site score
# Returns: 0 on success
analyze_single_site() {
    local site_name="$1"
    local config_file="$2"

    # Clean UI: site header with box
    if type -t ui_section &>/dev/null; then
        ui_blank
        echo -e "  ${CYAN}${site_name}${NC}"
        echo -e "  $(format_source_path "$config_file")"
    else
        echo ""
        echo "═══════════════════════════════════════════════════════════"
        echo "Site: $site_name ($(format_source_path "$config_file"))"
        echo "═══════════════════════════════════════════════════════════"
    fi

    # Initialize site filtering for this specific site
    init_site_filtering "$site_name"

    # Use registry-based detection for all registered features
    detect_all_features_for_site "$site_name" "$config_file"

    # Show site score
    echo ""
    printf "    Score: "
    show_site_score "$DETECT_SCORE_ENABLED" "$DETECT_SCORE_TOTAL"
}

analyze_optimizations() {
    local target_site="$1"
    local skip_recommendations="${2:-false}"

    # Check analysis cache (unless --no-cache or targeting specific site)
    if [ "${NO_CACHE:-false}" != "true" ] && [ -z "$target_site" ]; then
        local config_hash
        config_hash=$(get_config_hash)
        if [ -n "$config_hash" ] && load_analysis_cache "$config_hash"; then
            return 0
        fi
        # Store hash for saving cache later
        CACHED_CONFIG_HASH="$config_hash"
    fi

    # If target_site specified, only analyze that site using per-site view
    if [ -n "$target_site" ]; then
        # Initialize parser for Docker config if needed (skip in system-only mode)
        if [ "${SYSTEM_ONLY:-false}" != true ]; then
            if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "wp-test-proxy"; then
                if type -t parse_docker_nginx_config &>/dev/null; then
                    parse_docker_nginx_config "wp-test-proxy" 2>/dev/null || true
                fi
            fi
        fi

        # Get site's config file from parser
        if type -t extract_all_sites &>/dev/null; then
            local sites
            sites=$(extract_all_sites)

            local found=false
            local site_config=""

            while IFS='|' read -r site_name config_file _; do
                if [ "$site_name" = "$target_site" ]; then
                    site_config="$config_file"
                    found=true
                    break
                fi
            done <<< "$sites"

            if [ "$found" = true ]; then
                analyze_single_site "$target_site" "$site_config"

                echo ""
                echo "═══════════════════════════════════════════════════════════"
                echo "Legend:"
                echo -e "  ${GREEN}✓${NC} = Enabled"
                echo -e "  ${YELLOW}✗${NC} = Missing (can be optimized)"
                echo "═══════════════════════════════════════════════════════════"
                return 0
            else
                log_error "Site not found in nginx config: $target_site"
                return 1
            fi
        fi
    fi

    # Otherwise, extract ALL sites and analyze each
    if type -t ui_section &>/dev/null; then
        ui_section "Analyzing configurations..."
    else
        echo ""
        echo "═══════════════════════════════════════════════════════════"
        echo "Per-Site Configuration Analysis"
        echo "═══════════════════════════════════════════════════════════"
    fi

    # Initialize parser for Docker config if needed (skip in system-only mode)
    if [ "${SYSTEM_ONLY:-false}" != true ]; then
        if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "wp-test-proxy"; then
            if type -t parse_docker_nginx_config &>/dev/null; then
                parse_docker_nginx_config "wp-test-proxy" 2>/dev/null || true
            fi
        fi
    fi

    # Pre-build caches ONCE (major performance optimization)
    # This parses config once upfront, then each site uses instant cache lookup
    build_site_filter_cache
    # Build feature cache for instant feature lookups (1 awk call vs 99)
    if type -t build_feature_cache &>/dev/null; then
        build_feature_cache
    fi

    # Get all sites from parser
    local sites
    if type -t extract_all_sites &>/dev/null; then
        sites=$(extract_all_sites)
    else
        log_error "extract_all_sites function not available"
        return 1
    fi

    if [ -z "$sites" ]; then
        log_warn "No sites found in nginx configuration"
        echo ""
        echo "═══════════════════════════════════════════════════════════"
        echo "No sites to analyze"
        echo "═══════════════════════════════════════════════════════════"
        return 1
    fi

    local total_sites=0

    # Reset recommendation tracking
    reset_recommendations

    # Iterate through each unique site
    while IFS='|' read -r site_name config_file _; do
        # Skip empty lines
        [ -z "$site_name" ] && continue

        analyze_single_site "$site_name" "$config_file"
        total_sites=$((total_sites + 1))
    done <<< "$sites"

    # Update global count for recommendations
    TOTAL_SITES_ANALYZED=$total_sites

    # Show summary with clean UI
    if type -t ui_blank &>/dev/null; then
        ui_blank
        echo -e "  ─────────────────────────────────────────────────────"
        echo -e "  ${GREEN}✓${NC} = Enabled    ${YELLOW}✗${NC} = Missing"
        echo -e "  Analyzed ${total_sites} site(s)"
    else
        echo ""
        echo "═══════════════════════════════════════════════════════════"
        echo "Summary: $total_sites sites analyzed"
        echo "═══════════════════════════════════════════════════════════"
        echo "Legend:"
        echo -e "  ${GREEN}✓${NC} = Enabled"
        echo -e "  ${YELLOW}✗${NC} = Missing (can be optimized)"
        echo "═══════════════════════════════════════════════════════════"
    fi

    # Save to cache for instant subsequent runs
    if [ -n "$CACHED_CONFIG_HASH" ]; then
        save_analysis_cache "$CACHED_CONFIG_HASH"
    fi

    # Show recommendations and optionally apply (unless skipped for refresh)
    if [ "$skip_recommendations" != "true" ]; then
        show_recommendations
    fi
}

# Recommendation tracking - stores "feature:site" entries
# Format: "http3:site1.com\nhttp3:site2.com\nbrotli:ALL\n..."
MISSING_FEATURES=""
TOTAL_SITES_ANALYZED=0

# Get feature menu data from registry (dynamic, not hardcoded)
# Falls back to static list if registry not available
# Format: feature_name|display_name|is_global|cli_feature
get_feature_menu_data() {
    # Try to get from registry first
    if type -t feature_list_for_menu &>/dev/null; then
        feature_list_for_menu
    else
        # Fallback: static list (should not happen if registry loaded)
        echo "http3|HTTP/3 QUIC|0|http3"
        echo "fastcgi-cache|FastCGI Cache|0|fastcgi-cache"
        echo "brotli|Compression|1|brotli"
        echo "security|Security Headers|0|security"
        echo "wordpress|WordPress Exclusions|0|wordpress"
        echo "opcache|PHP OpCache|1|opcache"
        echo "redis|Redis Object Cache|1|redis"
    fi
}

# Record a missing feature for a site
# Args: $1 = feature name, $2 = site name
record_missing_feature() {
    local feature="$1"
    local site="$2"
    MISSING_FEATURES="${MISSING_FEATURES}${feature}:${site}"$'\n'
}

# Reset recommendation tracking
reset_recommendations() {
    MISSING_FEATURES=""
    TOTAL_SITES_ANALYZED=0
}

# Generate and display recommendations
# Display recommendations menu (non-interactive version)
display_recommendations_menu() {
    local rec_count=0

    echo ""
    echo -e "  Recommended optimizations:"
    echo ""

    # Process each feature type
    while IFS='|' read -r feat_name display_name _is_global cli_feature; do
        [ -z "$feat_name" ] && continue

        # Count sites missing this feature
        local missing_sites
        missing_sites=$(printf '%s' "$MISSING_FEATURES" | grep "^${feat_name}:" | cut -d: -f2 | sort -u || true)
        local missing_count=0
        if [ -n "$missing_sites" ]; then
            missing_count=$(printf '%s\n' "$missing_sites" | wc -l | tr -d ' ')
        fi

        [ "$missing_count" -eq 0 ] && continue

        rec_count=$((rec_count + 1))

        # Format: number + feature name + site info
        local site_info=""
        if [ "$missing_count" -eq "$TOTAL_SITES_ANALYZED" ]; then
            site_info="all ${missing_count} sites"
        elif [ "$missing_count" -gt 3 ]; then
            site_info="${missing_count} sites"
        else
            site_info=$(printf '%s' "$missing_sites" | tr '\n' ', ' | sed 's/,$//')
        fi

        printf "    ${GREEN}%d${NC}  %-24s ${CYAN}%s${NC}\n" "$rec_count" "$display_name" "$site_info"
    done <<< "$(get_feature_menu_data)"

    echo "$rec_count"  # Return count via stdout capture
}

# Get feature by selection number
get_feature_by_number() {
    local target_num="$1"
    local current=0

    while IFS='|' read -r feat_name _display _is_global cli_feature; do
        [ -z "$feat_name" ] && continue
        local missing_sites
        missing_sites=$(printf '%s' "$MISSING_FEATURES" | grep "^${feat_name}:" | cut -d: -f2 | sort -u || true)
        [ -z "$missing_sites" ] && continue
        current=$((current + 1))
        if [ "$current" -eq "$target_num" ]; then
            echo "$cli_feature"
            return 0
        fi
    done <<< "$(get_feature_menu_data)"
}

show_recommendations() {
    [ -z "$MISSING_FEATURES" ] && return 0

    # Non-interactive mode - display menu but don't prompt
    if [ "${QUIET:-}" = "true" ] || [ ! -t 0 ]; then
        local menu_output
        menu_output=$(display_recommendations_menu)
        # Print menu without the count line (last line is rec_count)
        echo "$menu_output" | sed '$d'
        echo ""
        echo -e "    ${GREEN}0${NC}  Apply ALL"
        echo ""
        return 0
    fi

    # Interactive loop
    while true; do
        # Display menu and capture rec_count (last line of output)
        local menu_output
        menu_output=$(display_recommendations_menu)
        local rec_count
        rec_count=$(echo "$menu_output" | tail -1)
        echo "$menu_output" | sed '$d'  # Print menu without the count line

        if [ "$rec_count" -eq 0 ] 2>/dev/null; then
            # All optimizations applied - show success box
            if type -t ui_success_box &>/dev/null; then
                ui_blank
                ui_success_box "All optimizations applied"
            else
                echo ""
                echo -e "  ┌─────────────────────────────────────────────────────┐"
                echo -e "  │  ${GREEN}✓${NC} All optimizations already applied!             │"
                echo -e "  └─────────────────────────────────────────────────────┘"
            fi
            echo ""
            return 0
        fi

        echo ""
        echo -e "    ${GREEN}0${NC}  Apply ALL"
        echo ""
        echo -e "  ─────────────────────────────────────────────────────"
        echo -e "  ${CYAN}q${NC}=quit  ${CYAN}r${NC}=refresh"
        echo ""
        read -r -p "  Select [1-${rec_count}, 0=all, q]: " selection

        # Handle special inputs
        case "$selection" in
            q|Q|quit|exit)
                echo ""
                return 0
                ;;
            r|R|refresh|reanalyze)
                echo ""
                # Clear cache and re-run analysis (skip recommendations to avoid nesting)
                NO_CACHE=true
                MISSING_FEATURES=""
                reset_recommendations
                analyze_optimizations "" true
                continue
                ;;
            "")
                # Empty = just refresh menu
                continue
                ;;
        esac

        # Validate numeric selection
        if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -gt "$rec_count" ]; then
            echo -e "  ${RED}Invalid selection.${NC}"
            sleep 1
            continue
        fi

        # Release our lock before spawning optimize
        local lock_dir="${DATA_DIR:-$HOME/.nginx-optimizer}/nginx-optimizer.lock"
        [ -d "$lock_dir" ] && rm -rf "$lock_dir" 2>/dev/null || true

        # Build and execute command
        local cmd_feature=""
        if [ "$selection" -ne 0 ]; then
            cmd_feature=$(get_feature_by_number "$selection")
        fi

        # Build common flags to preserve context (array for shellcheck compliance)
        local -a common_flags=()
        [ "${SYSTEM_ONLY:-false}" = true ] && common_flags+=("--system-only")
        [ -n "${TARGET_SITE:-}" ] && common_flags+=("$TARGET_SITE")

        # First show dry-run preview
        echo ""
        if [ -n "$cmd_feature" ]; then
            ./nginx-optimizer.sh optimize --feature "$cmd_feature" --dry-run "${common_flags[@]}" 2>&1 || true
        else
            ./nginx-optimizer.sh optimize --dry-run "${common_flags[@]}" 2>&1 || true
        fi

        # Ask to apply for real
        echo ""
        read -r -p "  Apply these changes? [y/N/q]: " confirm
        case "$confirm" in
            q|Q|quit|exit)
                echo ""
                return 0
                ;;
            y|Y)
                echo ""
                if [ -n "$cmd_feature" ]; then
                    ./nginx-optimizer.sh optimize --feature "$cmd_feature" --force "${common_flags[@]}" 2>&1 || true
                else
                    ./nginx-optimizer.sh optimize --force "${common_flags[@]}" 2>&1 || true
                fi
                echo ""
                echo -e "  ${CYAN}Press 'r' to refresh, or select another option${NC}"
                ;;
            *)
                # N or empty - just go back to menu
                ;;
        esac
    done
}

show_status() {
    local target_site="$1"

    detect_nginx_instances "$target_site"
    analyze_optimizations "$target_site"
}
