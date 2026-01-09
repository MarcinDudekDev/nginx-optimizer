#!/bin/bash

################################################################################
# detector.sh - Nginx Detection & Configuration Analysis
################################################################################

# Nginx location patterns
NGINX_LOCATIONS=(
    "/etc/nginx/nginx.conf"
    "/usr/local/etc/nginx/nginx.conf"
    "/opt/nginx/conf/nginx.conf"
    "/usr/local/nginx/conf/nginx.conf"
)

# shellcheck disable=SC2034  # Used by optimizer.sh for site detection
SITE_CONFIGS=(
    "/etc/nginx/sites-enabled/"
    "/etc/nginx/conf.d/"
    "/usr/local/etc/nginx/servers/"
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

    # Output cache indicator
    echo ""
    echo -e "${CYAN}[CACHED]${NC} Config unchanged (${age_display}, hash: ${current_hash:0:8}...)"
    echo -e "${CYAN}[CACHED]${NC} Run with --no-cache to force fresh analysis"
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "Summary: $TOTAL_SITES_ANALYZED sites (cached)"
    echo "═══════════════════════════════════════════════════════════"

    # Show recommendations from cached state
    show_recommendations

    return 0
}

# Clear analysis cache
clear_analysis_cache() {
    init_analysis_cache
    rm -f "$ANALYSIS_CACHE_FILE"
    log_info "Analysis cache cleared"
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
    log_info "Checking for system nginx..."

    for conf in "${NGINX_LOCATIONS[@]}"; do
        if [ -f "$conf" ]; then
            log_success "Found system nginx: $conf"
            add_instance "system" "nginx" "$conf"

            if command -v nginx &>/dev/null; then
                local version
                version=$(nginx -v 2>&1 | sed -n 's/.*nginx\/\([0-9.]*\).*/\1/p')
                log_info "  Version: $version"

                # Parse full config with nginx -T for source tracking
                if type -t parse_nginx_config &>/dev/null; then
                    parse_nginx_config || log_warn "Could not parse nginx -T output"
                fi
            fi
            return 0
        fi
    done

    log_info "No system nginx found"
    return 1
}

detect_docker_nginx() {
    log_info "Checking for Docker nginx containers..."

    if ! command -v docker &>/dev/null; then
        log_info "Docker not installed"
        return 1
    fi

    # Check if Docker is running
    if ! docker info &>/dev/null; then
        log_info "Docker not running"
        return 1
    fi

    # Check for nginx containers
    local containers
    containers=$(docker ps --filter "ancestor=nginx" --format "{{.Names}}" 2>/dev/null)

    # Also check for wp-test-proxy specifically
    if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "wp-test-proxy"; then
        log_success "Found wp-test nginx-proxy container"
        add_instance "docker" "wp-test-proxy" "wp-test-proxy"
    fi

    if [ -n "$containers" ]; then
        while IFS= read -r container; do
            if [ "$container" != "wp-test-proxy" ]; then
                log_success "Found Docker nginx: $container"
                add_instance "docker" "$container" "$container"
            fi
        done <<< "$containers"
        return 0
    fi

    return 1
}

detect_wp_test_sites() {
    log_info "Checking for wp-test sites..."

    if [ ! -d "$WP_TEST_SITES" ]; then
        log_info "No wp-test sites directory found"
        return 1
    fi

    local site_count=0
    for site_dir in "$WP_TEST_SITES"/*; do
        if [ -d "$site_dir" ] && [ "$(basename "$site_dir")" != ".DS_Store" ]; then
            local domain
            domain=$(basename "$site_dir")
            log_success "Found wp-test site: $domain"
            add_instance "wp_test" "$domain" "$site_dir"
            site_count=$((site_count + 1))
        fi
    done

    if [ $site_count -eq 0 ]; then
        log_info "No wp-test sites found"
        return 1
    fi

    # Also check for wp-test nginx config
    if [ -f "$WP_TEST_NGINX/proxy.conf" ]; then
        log_success "Found wp-test nginx config: $WP_TEST_NGINX/proxy.conf"
        add_instance "wp_test_nginx" "proxy" "$WP_TEST_NGINX/proxy.conf"
    fi

    log_success "Found $site_count wp-test site(s)"
    return 0
}

detect_nginx_instances() {
    local target_site="$1"

    log_info "Scanning for nginx installations..."
    echo ""

    # Reset instances array
    DETECTED_INSTANCES=()

    # Initialize parser if available
    if type -t parser_init &>/dev/null; then
        parser_init || log_warn "Parser initialization failed, using legacy detection"
    fi

    if [ -n "$target_site" ]; then
        # Validate site name to prevent path traversal
        if ! validate_site_name "$target_site"; then
            exit 1
        fi
        # Check if it's a wp-test site
        if [ -d "$WP_TEST_SITES/$target_site" ]; then
            add_instance "wp_test" "$target_site" "$WP_TEST_SITES/$target_site"
            log_success "Target site found: $target_site"
        else
            log_error "Site not found: $target_site"
            exit 1
        fi
    else
        # Detect all (ignore return codes - we accumulate instances)
        detect_system_nginx || true
        detect_docker_nginx || true
        detect_wp_test_sites || true
    fi

    echo ""
    local count
    count=$(get_instance_count)
    if [ "$count" -eq 0 ]; then
        log_warn "No nginx installations detected"
        return 1
    fi

    log_success "Detected $count nginx instance(s)"
    return 0
}

list_nginx_instances() {
    detect_nginx_instances ""

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "Detected NGINX Installations:"
    echo "═══════════════════════════════════════════════════════════"

    for entry in "${DETECTED_INSTANCES[@]}"; do
        local type
        local name
        local path
        type=$(echo "$entry" | cut -d: -f1)
        name=$(echo "$entry" | cut -d: -f2)
        path=$(echo "$entry" | cut -d: -f3-)
        echo "  • [$type] $name: $path"
    done
    echo ""
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
    SITE_FILTER_CACHE=$(awk '
    BEGIN { main_conf = "" }
    /^###FILE:/ || /^#.*configuration file [^:]+:$/ {
        if (/^###FILE:/) {
            current_file = substr($0, 9)
        } else {
            match($0, /configuration file ([^:]+):/, arr)
            if (arr[1]) current_file = arr[1]
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
    SITE_FILTER_CACHE_BUILT=true
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
            local open_braces=$(echo "$line" | tr -cd '{' | wc -c | tr -d ' ')
            local close_braces=$(echo "$line" | tr -cd '}' | wc -c | tr -d ' ')
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

# Initialize site filtering for a specific site
# Args: $1 = site name
init_site_filtering() {
    local site="$1"

    if [ -z "$site" ]; then
        SITE_FILTERING_ACTIVE=false
        SITE_RELEVANT_FILES=""
        return
    fi

    log_info "Initializing site filtering for: $site"

    # Use cached lookup (fast) instead of parsing config each time (slow)
    SITE_RELEVANT_FILES=$(get_cached_site_files "$site")

    if [ -z "$SITE_RELEVANT_FILES" ]; then
        # Fallback to full parsing if cache miss
        SITE_RELEVANT_FILES=$(get_site_config_files "$site")
    fi

    if [ -z "$SITE_RELEVANT_FILES" ]; then
        log_warn "No config files found for site: $site"
        SITE_FILTERING_ACTIVE=false
    else
        SITE_FILTERING_ACTIVE=true
        log_info "Site filtering active for: $site"
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
    local slash_count=$(echo "$path" | tr -cd '/' | wc -c | tr -d ' ')

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
        log_error "Container name required"
        return 1
    fi

    # Check if container is running
    if ! docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^${container}$"; then
        log_warn "Container '$container' is not running"
        return 1
    fi

    log_info "Analyzing Docker container: $container"

    # Try to get nginx config from container
    local config
    config=$(docker exec "$container" nginx -T 2>/dev/null) || {
        log_warn "  Could not retrieve nginx config from container"
        echo -e "    ${YELLOW}⚠ nginx -T failed in container${NC}"
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

check_http3_enabled() {
    local config_file="$1"
    local site_name="$2"
    LAST_DIRECTIVE_SOURCE=""

    # Use site-filtered check if site specified
    if [ -n "$site_name" ] && [ "$SITE_FILTERING_ACTIVE" = true ]; then
        check_directive_for_site "listen.*quic" "$site_name"
        return $?
    fi

    # Use new parser if available
    if type -t get_directive_source &>/dev/null; then
        local source
        source=$(get_directive_source "listen.*quic")
        if [ -n "$source" ]; then
            LAST_DIRECTIVE_SOURCE="$source"
            return 0
        fi
    fi

    # Fallback: Check compiled config first (most reliable)
    if check_nginx_compiled "listen.*quic"; then
        return 0
    fi

    # Fallback to file check
    if [ -f "$config_file" ] && grep -q "listen.*quic" "$config_file" 2>/dev/null; then
        return 0
    fi

    return 1
}

check_fastcgi_cache_enabled() {
    local config_file="$1"
    local site_name="$2"
    LAST_DIRECTIVE_SOURCE=""

    # Use site-filtered check if site specified
    if [ -n "$site_name" ] && [ "$SITE_FILTERING_ACTIVE" = true ]; then
        check_directive_for_site "fastcgi_cache_path" "$site_name"
        return $?
    fi

    # Use new parser if available
    if type -t get_directive_source &>/dev/null; then
        local source
        source=$(get_directive_source "fastcgi_cache_path")
        if [ -n "$source" ]; then
            LAST_DIRECTIVE_SOURCE="$source"
            return 0
        fi
    fi

    # Fallback: Check compiled config first
    if check_nginx_compiled "fastcgi_cache_path"; then
        return 0
    fi

    # Fallback to file check
    if [ -f "$config_file" ] && grep -q "fastcgi_cache_path" "$config_file" 2>/dev/null; then
        return 0
    fi

    return 1
}

check_brotli_enabled() {
    local config_file="$1"
    local site_name="$2"
    LAST_DIRECTIVE_SOURCE=""

    # Use site-filtered check if site specified
    if [ -n "$site_name" ] && [ "$SITE_FILTERING_ACTIVE" = true ]; then
        check_directive_for_site "brotli on" "$site_name"
        return $?
    fi

    # Use new parser if available
    if type -t get_directive_source &>/dev/null; then
        local source
        source=$(get_directive_source "brotli on")
        if [ -n "$source" ]; then
            LAST_DIRECTIVE_SOURCE="$source"
            return 0
        fi
    fi

    # Fallback: Check compiled config first
    if check_nginx_compiled "brotli on"; then
        return 0
    fi

    # Fallback to file check
    if [ -f "$config_file" ] && grep -q "brotli on" "$config_file" 2>/dev/null; then
        return 0
    fi

    # Check if wp-test-proxy uses brotli-enabled image
    if command -v docker &>/dev/null; then
        if docker ps --filter "name=wp-test-proxy" --format "{{.Image}}" 2>/dev/null | grep -q "brotli"; then
            return 0
        fi
    fi

    return 1
}

check_security_headers() {
    local config_file="$1"
    local site_name="$2"
    LAST_DIRECTIVE_SOURCE=""

    # Use site-filtered check if site specified
    if [ -n "$site_name" ] && [ "$SITE_FILTERING_ACTIVE" = true ]; then
        check_directive_for_site "Strict-Transport-Security" "$site_name"
        return $?
    fi

    # Use new parser if available
    if type -t get_directive_source &>/dev/null; then
        local source
        source=$(get_directive_source "Strict-Transport-Security")
        if [ -n "$source" ]; then
            LAST_DIRECTIVE_SOURCE="$source"
            return 0
        fi
    fi

    # Fallback: Check compiled config first
    if check_nginx_compiled "Strict-Transport-Security"; then
        return 0
    fi

    # Fallback to file check
    if [ -f "$config_file" ] && grep -q "Strict-Transport-Security" "$config_file" 2>/dev/null; then
        return 0
    fi

    return 1
}

check_rate_limiting() {
    local config_file="$1"
    local site_name="$2"
    LAST_DIRECTIVE_SOURCE=""

    # Use site-filtered check if site specified
    if [ -n "$site_name" ] && [ "$SITE_FILTERING_ACTIVE" = true ]; then
        check_directive_for_site "limit_req_zone" "$site_name"
        return $?
    fi

    # Use new parser if available
    if type -t get_directive_source &>/dev/null; then
        local source
        source=$(get_directive_source "limit_req_zone")
        if [ -n "$source" ]; then
            LAST_DIRECTIVE_SOURCE="$source"
            return 0
        fi
    fi

    # Fallback: Check compiled config first
    if check_nginx_compiled "limit_req_zone"; then
        return 0
    fi

    # Fallback to file check
    if [ -f "$config_file" ] && grep -q "limit_req_zone" "$config_file" 2>/dev/null; then
        return 0
    fi

    return 1
}

check_wordpress_exclusions() {
    local config_file="$1"
    local site_name="$2"
    LAST_DIRECTIVE_SOURCE=""

    # Use site-filtered check if site specified
    if [ -n "$site_name" ] && [ "$SITE_FILTERING_ACTIVE" = true ]; then
        check_directive_for_site "xmlrpc" "$site_name"
        return $?
    fi

    # Use new parser if available
    if type -t get_directive_source &>/dev/null; then
        local source
        source=$(get_directive_source "xmlrpc")
        if [ -n "$source" ]; then
            LAST_DIRECTIVE_SOURCE="$source"
            return 0
        fi
    fi

    # Fallback: Check compiled config first
    if check_nginx_compiled "xmlrpc"; then
        return 0
    fi

    # Fallback to file check
    if [ -f "$config_file" ] && grep -q "xmlrpc" "$config_file" 2>/dev/null; then
        return 0
    fi

    return 1
}

check_gzip_enabled() {
    local config_file="$1"
    local site_name="$2"
    LAST_DIRECTIVE_SOURCE=""

    # Use site-filtered check if site specified
    if [ -n "$site_name" ] && [ "$SITE_FILTERING_ACTIVE" = true ]; then
        check_directive_for_site "gzip on" "$site_name"
        return $?
    fi

    # Use new parser if available
    if type -t get_directive_source &>/dev/null; then
        local source
        source=$(get_directive_source "gzip on")
        if [ -n "$source" ]; then
            LAST_DIRECTIVE_SOURCE="$source"
            return 0
        fi
    fi

    # Fallback: Check compiled config first
    if check_nginx_compiled "gzip on"; then
        return 0
    fi

    # Fallback to file check
    if [ -f "$config_file" ] && grep -q "gzip on" "$config_file" 2>/dev/null; then
        return 0
    fi

    return 1
}

check_redis_configured() {
    local site_dir="$1"

    local compose_file="${site_dir}/docker-compose.yml"

    if [ ! -f "$compose_file" ]; then
        return 1
    fi

    if grep -q "redis:" "$compose_file" 2>/dev/null; then
        return 0
    fi

    return 1
}

check_ocsp_stapling() {
    local config_file="$1"
    local site_name="$2"
    LAST_DIRECTIVE_SOURCE=""

    # Use site-filtered check if site specified
    if [ -n "$site_name" ] && [ "$SITE_FILTERING_ACTIVE" = true ]; then
        check_directive_for_site "ssl_stapling on" "$site_name"
        return $?
    fi

    # Use new parser if available
    if type -t get_directive_source &>/dev/null; then
        local source
        source=$(get_directive_source "ssl_stapling on")
        if [ -n "$source" ]; then
            LAST_DIRECTIVE_SOURCE="$source"
            return 0
        fi
    fi

    # Fallback: Check compiled config first
    if check_nginx_compiled "ssl_stapling on"; then
        return 0
    fi

    # Fallback to file check
    if [ -f "$config_file" ] && grep -q "ssl_stapling on" "$config_file" 2>/dev/null; then
        return 0
    fi

    return 1
}

check_tls_versions() {
    local config_file="$1"
    local site_name="$2"
    local tls_versions=""
    LAST_DIRECTIVE_SOURCE=""

    # Use site-filtered check if site specified
    if [ -n "$site_name" ] && [ "$SITE_FILTERING_ACTIVE" = true ]; then
        if check_directive_for_site "TLSv1.3" "$site_name"; then
            tls_versions="1.3"
        fi
    else
        # Use new parser if available for TLSv1.3
        if type -t get_directive_source &>/dev/null; then
            local source
            source=$(get_directive_source "TLSv1.3")
            if [ -n "$source" ]; then
                LAST_DIRECTIVE_SOURCE="$source"
                tls_versions="1.3"
            fi
        fi

        # Fallback for TLSv1.3 check
        if [ -z "$tls_versions" ]; then
            if check_nginx_compiled "TLSv1.3" || ([ -f "$config_file" ] && grep -q "TLSv1.3" "$config_file" 2>/dev/null); then
                tls_versions="1.3"
            fi
        fi
    fi

    # Check for TLSv1.2 (acceptable)
    if [ -n "$site_name" ] && [ "$SITE_FILTERING_ACTIVE" = true ]; then
        if check_directive_for_site "TLSv1.2" "$site_name"; then
            if [ -n "$tls_versions" ]; then
                tls_versions="${tls_versions}, 1.2"
            else
                tls_versions="1.2"
            fi
        fi
    else
        if check_nginx_compiled "TLSv1.2" || ([ -f "$config_file" ] && grep -q "TLSv1.2" "$config_file" 2>/dev/null); then
            if [ -n "$tls_versions" ]; then
                tls_versions="${tls_versions}, 1.2"
            else
                tls_versions="1.2"
            fi
        fi
    fi

    echo "$tls_versions"
}

################################################################################
# Per-Site Analysis Functions
################################################################################

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

    # Reset score for this site
    local site_score_enabled=0
    local site_score_total=0

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "Site: $site_name ($(format_source_path "$config_file"))"
    echo "═══════════════════════════════════════════════════════════"

    # Initialize site filtering for this specific site
    init_site_filtering "$site_name"

    # HTTP/3 QUIC - per-site (check in site's server block)
    if check_feature_for_site "listen.*quic" "$site_name" "$config_file"; then
        printf "    ${GREEN}✓${NC} %-22s" "HTTP/3 QUIC"
        if [ -n "$LAST_DIRECTIVE_SOURCE" ]; then
            echo " ($(format_source_path "$LAST_DIRECTIVE_SOURCE"))"
        else
            echo ""
        fi
        site_score_enabled=$((site_score_enabled + 1))
    else
        printf "    ${YELLOW}✗${NC} %-22s\n" "HTTP/3 QUIC"
        record_missing_feature "http3" "$site_name"
    fi
    site_score_total=$((site_score_total + 1))

    # FastCGI Cache - per-site
    if check_feature_for_site "fastcgi_cache" "$site_name" "$config_file"; then
        printf "    ${GREEN}✓${NC} %-22s" "FastCGI Cache"
        if [ -n "$LAST_DIRECTIVE_SOURCE" ]; then
            echo " ($(format_source_path "$LAST_DIRECTIVE_SOURCE"))"
        else
            echo ""
        fi
        site_score_enabled=$((site_score_enabled + 1))
    else
        printf "    ${YELLOW}✗${NC} %-22s\n" "FastCGI Cache"
        record_missing_feature "fastcgi-cache" "$site_name"
    fi
    site_score_total=$((site_score_total + 1))

    # Brotli - can be global
    if check_feature_for_site "brotli on" "$site_name" "$config_file"; then
        printf "    ${GREEN}✓${NC} %-22s" "Brotli Compression"
        if [ -n "$LAST_DIRECTIVE_SOURCE" ]; then
            echo " ($(format_source_path "$LAST_DIRECTIVE_SOURCE"))"
        else
            echo ""
        fi
        site_score_enabled=$((site_score_enabled + 1))
    else
        printf "    ${YELLOW}✗${NC} %-22s\n" "Brotli Compression"
        record_missing_feature "brotli" "$site_name"
    fi
    site_score_total=$((site_score_total + 1))

    # Gzip - can be global
    if check_feature_for_site "gzip on" "$site_name" "$config_file"; then
        printf "    ${GREEN}✓${NC} %-22s" "Gzip Compression"
        if [ -n "$LAST_DIRECTIVE_SOURCE" ]; then
            echo " ($(format_source_path "$LAST_DIRECTIVE_SOURCE"))"
        else
            echo ""
        fi
        site_score_enabled=$((site_score_enabled + 1))
    else
        printf "    ${YELLOW}✗${NC} %-22s\n" "Gzip Compression"
        record_missing_feature "gzip" "$site_name"
    fi
    site_score_total=$((site_score_total + 1))

    # Security Headers - per-site
    if check_feature_for_site "Strict-Transport-Security" "$site_name" "$config_file"; then
        printf "    ${GREEN}✓${NC} %-22s" "Security Headers"
        if [ -n "$LAST_DIRECTIVE_SOURCE" ]; then
            echo " ($(format_source_path "$LAST_DIRECTIVE_SOURCE"))"
        else
            echo ""
        fi
        site_score_enabled=$((site_score_enabled + 1))
    else
        printf "    ${YELLOW}✗${NC} %-22s\n" "Security Headers"
        record_missing_feature "security" "$site_name"
    fi
    site_score_total=$((site_score_total + 1))

    # Rate Limiting - per-site
    if check_feature_for_site "limit_req" "$site_name" "$config_file"; then
        printf "    ${GREEN}✓${NC} %-22s" "Rate Limiting"
        if [ -n "$LAST_DIRECTIVE_SOURCE" ]; then
            echo " ($(format_source_path "$LAST_DIRECTIVE_SOURCE"))"
        else
            echo ""
        fi
        site_score_enabled=$((site_score_enabled + 1))
    else
        printf "    ${YELLOW}✗${NC} %-22s\n" "Rate Limiting"
        record_missing_feature "rate-limiting" "$site_name"
    fi
    site_score_total=$((site_score_total + 1))

    # WordPress Exclusions - per-site
    if check_feature_for_site "xmlrpc" "$site_name" "$config_file"; then
        printf "    ${GREEN}✓${NC} %-22s" "WordPress Exclusions"
        if [ -n "$LAST_DIRECTIVE_SOURCE" ]; then
            echo " ($(format_source_path "$LAST_DIRECTIVE_SOURCE"))"
        else
            echo ""
        fi
        site_score_enabled=$((site_score_enabled + 1))
    else
        printf "    ${YELLOW}✗${NC} %-22s\n" "WordPress Exclusions"
        record_missing_feature "wordpress" "$site_name"
    fi
    site_score_total=$((site_score_total + 1))

    # OCSP Stapling - per-site (no score)
    if check_feature_for_site "ssl_stapling on" "$site_name" "$config_file"; then
        printf "    ${GREEN}✓${NC} %-22s" "OCSP Stapling"
        if [ -n "$LAST_DIRECTIVE_SOURCE" ]; then
            echo " ($(format_source_path "$LAST_DIRECTIVE_SOURCE"))"
        else
            echo ""
        fi
    else
        printf "    ${YELLOW}✗${NC} %-22s\n" "OCSP Stapling"
        record_missing_feature "ocsp" "$site_name"
    fi

    # TLS Versions - per-site (no score)
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

    # Show site score
    echo ""
    printf "    Score: "
    show_site_score "$site_score_enabled" "$site_score_total"
    echo ""
}

################################################################################
# Legacy Analysis Functions (kept for backward compatibility)
################################################################################

analyze_config_file() {
    local config_file="$1"
    local instance_name="$2"
    local site_name="$3"

    # Show filtering indicator if active
    if [ "$SITE_FILTERING_ACTIVE" = true ]; then
        log_info "Analyzing: $instance_name (filtered view for $site_name)"
    else
        log_info "Analyzing: $instance_name"
    fi

    # HTTP/3 QUIC
    if check_http3_enabled "$config_file" "$site_name"; then
        printf "    ${GREEN}✓${NC} %-22s" "HTTP/3 QUIC"
        if [ -n "$LAST_DIRECTIVE_SOURCE" ]; then
            echo " ($(format_source_path "$LAST_DIRECTIVE_SOURCE"))"
        else
            echo ""
        fi
        increment_score 1
    else
        echo -e "    ${YELLOW}✗ HTTP/3 QUIC${NC}"
        increment_score 0
    fi

    # FastCGI Cache
    if check_fastcgi_cache_enabled "$config_file" "$site_name"; then
        printf "    ${GREEN}✓${NC} %-22s" "FastCGI Cache"
        if [ -n "$LAST_DIRECTIVE_SOURCE" ]; then
            echo " ($(format_source_path "$LAST_DIRECTIVE_SOURCE"))"
        else
            echo ""
        fi
        increment_score 1
    else
        echo -e "    ${YELLOW}✗ FastCGI Cache${NC}"
        increment_score 0
    fi

    # Brotli Compression
    if check_brotli_enabled "$config_file" "$site_name"; then
        printf "    ${GREEN}✓${NC} %-22s" "Brotli Compression"
        if [ -n "$LAST_DIRECTIVE_SOURCE" ]; then
            echo " ($(format_source_path "$LAST_DIRECTIVE_SOURCE"))"
        else
            echo ""
        fi
        increment_score 1
    else
        echo -e "    ${YELLOW}✗ Brotli Compression${NC}"
        increment_score 0
    fi

    # Gzip Compression
    if check_gzip_enabled "$config_file" "$site_name"; then
        printf "    ${GREEN}✓${NC} %-22s" "Gzip Compression"
        if [ -n "$LAST_DIRECTIVE_SOURCE" ]; then
            echo " ($(format_source_path "$LAST_DIRECTIVE_SOURCE"))"
        else
            echo ""
        fi
        increment_score 1
    else
        echo -e "    ${YELLOW}✗ Gzip Compression${NC}"
        increment_score 0
    fi

    # Security Headers
    if check_security_headers "$config_file" "$site_name"; then
        printf "    ${GREEN}✓${NC} %-22s" "Security Headers"
        if [ -n "$LAST_DIRECTIVE_SOURCE" ]; then
            echo " ($(format_source_path "$LAST_DIRECTIVE_SOURCE"))"
        else
            echo ""
        fi
        increment_score 1
    else
        echo -e "    ${YELLOW}✗ Security Headers${NC}"
        increment_score 0
    fi

    # Rate Limiting
    if check_rate_limiting "$config_file" "$site_name"; then
        printf "    ${GREEN}✓${NC} %-22s" "Rate Limiting"
        if [ -n "$LAST_DIRECTIVE_SOURCE" ]; then
            echo " ($(format_source_path "$LAST_DIRECTIVE_SOURCE"))"
        else
            echo ""
        fi
        increment_score 1
    else
        echo -e "    ${YELLOW}✗ Rate Limiting${NC}"
        increment_score 0
    fi

    # WordPress Exclusions
    if check_wordpress_exclusions "$config_file" "$site_name"; then
        printf "    ${GREEN}✓${NC} %-22s" "WordPress Exclusions"
        if [ -n "$LAST_DIRECTIVE_SOURCE" ]; then
            echo " ($(format_source_path "$LAST_DIRECTIVE_SOURCE"))"
        else
            echo ""
        fi
        increment_score 1
    else
        echo -e "    ${YELLOW}✗ WordPress Exclusions${NC}"
        increment_score 0
    fi

    # OCSP Stapling (no score)
    if check_ocsp_stapling "$config_file" "$site_name"; then
        printf "    ${GREEN}✓${NC} %-22s" "OCSP Stapling"
        if [ -n "$LAST_DIRECTIVE_SOURCE" ]; then
            echo " ($(format_source_path "$LAST_DIRECTIVE_SOURCE"))"
        else
            echo ""
        fi
    else
        echo -e "    ${YELLOW}✗ OCSP Stapling${NC}"
    fi

    # TLS Versions (no score)
    local tls_versions
    tls_versions=$(check_tls_versions "$config_file" "$site_name")
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

    echo ""
}

# Track already analyzed config files to avoid redundant analysis
declare -a ANALYZED_FILES=()

is_already_analyzed() {
    local file="$1"
    # Handle empty array case for set -u compatibility
    if [ ${#ANALYZED_FILES[@]} -eq 0 ]; then
        return 1
    fi
    for analyzed in "${ANALYZED_FILES[@]}"; do
        if [ "$analyzed" = "$file" ]; then
            return 0
        fi
    done
    return 1
}

mark_as_analyzed() {
    local file="$1"
    ANALYZED_FILES+=("$file")
}

reset_analyzed_files() {
    ANALYZED_FILES=()
}

analyze_wp_test_site() {
    local site_name="$1"
    local site_dir="$2"

    # Initialize site filtering if this is a specific site analysis
    if [ -n "$site_name" ]; then
        init_site_filtering "$site_name"
    fi

    if [ "$SITE_FILTERING_ACTIVE" = true ]; then
        log_info "Analyzing wp-test site: $site_name (filtered view)"
    else
        log_info "Analyzing wp-test site: $site_name"
    fi

    # Check nginx proxy config (only analyze once across all sites)
    local proxy_conf="${WP_TEST_NGINX}/proxy.conf"
    if [ -f "$proxy_conf" ]; then
        if is_already_analyzed "$proxy_conf"; then
            log_info "  (Proxy config already analyzed above)"
        else
            # Only analyze if not filtered OR if this file is relevant
            if [ "$SITE_FILTERING_ACTIVE" = false ] || is_file_relevant_to_site "$proxy_conf"; then
                analyze_config_file "$proxy_conf" "Shared Proxy Config" "$site_name"
                mark_as_analyzed "$proxy_conf"
            fi
        fi
    fi

    # Check vhost config (unique per site)
    local vhost_conf="${WP_TEST_NGINX}/vhost.d/${site_name}"
    if [ -f "$vhost_conf" ]; then
        # Always analyze vhost file for the target site
        if [ "$SITE_FILTERING_ACTIVE" = false ] || is_file_relevant_to_site "$vhost_conf"; then
            analyze_config_file "$vhost_conf" "VHost Config ($site_name)" "$site_name"
        fi
    else
        log_info "  No custom vhost config for $site_name"
    fi

    # Check Redis
    if check_redis_configured "$site_dir"; then
        echo -e "    ${GREEN}✓ Redis Configured${NC}"
        increment_score 1
    else
        echo -e "    ${YELLOW}✗ Redis Not Configured${NC}"
        increment_score 0
    fi

    # Check for docker-compose
    if [ -f "${site_dir}/docker-compose.yml" ]; then
        echo -e "    ${GREEN}✓ Docker Compose Found${NC}"
    fi

    echo ""
}

analyze_optimizations() {
    local target_site="$1"

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
        # Initialize parser for Docker config if needed
        if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "wp-test-proxy"; then
            if type -t parse_docker_nginx_config &>/dev/null; then
                parse_docker_nginx_config "wp-test-proxy" || log_warn "Could not parse Docker nginx config"
            fi
        fi

        # Get site's config file from parser
        if type -t extract_all_sites &>/dev/null; then
            local sites
            sites=$(extract_all_sites)

            local found=false
            local site_config=""

            while IFS='|' read -r site_name config_file ssl_status; do
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
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "Per-Site Configuration Analysis"
    echo "═══════════════════════════════════════════════════════════"

    # Initialize parser for Docker config if needed
    if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "wp-test-proxy"; then
        if type -t parse_docker_nginx_config &>/dev/null; then
            parse_docker_nginx_config "wp-test-proxy" || log_warn "Could not parse Docker nginx config"
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
    while IFS='|' read -r site_name config_file ssl_status; do
        # Skip empty lines
        [ -z "$site_name" ] && continue

        analyze_single_site "$site_name" "$config_file"
        total_sites=$((total_sites + 1))
    done <<< "$sites"

    # Update global count for recommendations
    TOTAL_SITES_ANALYZED=$total_sites

    # Show summary
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "Summary: $total_sites sites analyzed"
    echo "═══════════════════════════════════════════════════════════"
    echo "Legend:"
    echo -e "  ${GREEN}✓${NC} = Enabled"
    echo -e "  ${YELLOW}✗${NC} = Missing (can be optimized)"
    echo "═══════════════════════════════════════════════════════════"

    # Save to cache for instant subsequent runs
    if [ -n "$CACHED_CONFIG_HASH" ]; then
        save_analysis_cache "$CACHED_CONFIG_HASH"
    fi

    # Show recommendations and optionally apply
    show_recommendations
}

# Global score counters
SCORE_ENABLED=0
SCORE_TOTAL=0

# Recommendation tracking - stores "feature:site" entries
# Format: "http3:site1.com\nhttp3:site2.com\nbrotli:ALL\n..."
MISSING_FEATURES=""
TOTAL_SITES_ANALYZED=0
ALL_SITES_LIST=""

# Feature metadata: feature_name|display_name|is_global|cli_feature
FEATURE_META="http3|HTTP/3 QUIC|0|http3
fastcgi-cache|FastCGI Cache|0|fastcgi-cache
brotli|Brotli Compression|1|brotli
gzip|Gzip Compression|1|compression
security|Security Headers|0|security
rate-limiting|Rate Limiting|0|security
wordpress|WordPress Exclusions|0|wordpress
ocsp|OCSP Stapling|1|security"

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
    ALL_SITES_LIST=""
}

# Generate and display recommendations
show_recommendations() {
    [ -z "$MISSING_FEATURES" ] && return 0

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "Recommended Actions"
    echo "═══════════════════════════════════════════════════════════"

    local recommendations=""
    local rec_count=0

    # Process each feature type
    while IFS='|' read -r feat_name display_name is_global cli_feature; do
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

        if [ "$missing_count" -eq "$TOTAL_SITES_ANALYZED" ] && [ "$is_global" = "1" ]; then
            # All sites missing a global feature - suggest global enable
            echo ""
            echo -e "  ${YELLOW}${rec_count}.${NC} Enable ${display_name} globally (affects all $missing_count sites)"
            echo -e "     ${CYAN}./nginx-optimizer.sh optimize --feature ${cli_feature}${NC}"
        elif [ "$missing_count" -eq "$TOTAL_SITES_ANALYZED" ]; then
            # All sites missing a per-site feature
            echo ""
            echo -e "  ${YELLOW}${rec_count}.${NC} Enable ${display_name} for all $missing_count sites"
            echo -e "     ${CYAN}./nginx-optimizer.sh optimize --feature ${cli_feature}${NC}"
        elif [ "$missing_count" -gt 3 ]; then
            # Many sites missing - show count
            echo ""
            echo -e "  ${YELLOW}${rec_count}.${NC} Enable ${display_name} ($missing_count sites missing)"
            echo -e "     ${CYAN}./nginx-optimizer.sh optimize --feature ${cli_feature}${NC}"
        else
            # Few sites missing - list them
            local site_list
            site_list=$(printf '%s' "$missing_sites" | tr '\n' ', ' | sed 's/,$//')
            echo ""
            echo -e "  ${YELLOW}${rec_count}.${NC} Enable ${display_name} for: ${site_list}"
            echo -e "     ${CYAN}./nginx-optimizer.sh optimize --feature ${cli_feature}${NC}"
        fi
    done <<< "$FEATURE_META"

    if [ "$rec_count" -eq 0 ]; then
        echo ""
        echo -e "  ${GREEN}All optimizations already applied!${NC}"
        return 0
    fi

    echo ""
    echo -e "  ${CYAN}0.${NC} Apply ALL recommendations"
    echo "═══════════════════════════════════════════════════════════"

    # Interactive prompt (only if not in quiet mode and stdout is terminal)
    if [ "${QUIET:-}" != "true" ] && [ -t 1 ]; then
        echo ""
        read -r -p "Select [1-${rec_count}, 0=all, Enter=skip]: " selection

        # Skip if empty
        [ -z "$selection" ] && return 0

        # Validate selection
        if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -gt "$rec_count" ]; then
            echo "Invalid selection. Skipped."
            return 0
        fi

        # Check for lock file
        local lock_file="${DATA_DIR:-$HOME/.nginx-optimizer}/nginx-optimizer.lock"
        if [ -f "$lock_file" ]; then
            echo ""
            echo -e "${YELLOW}Lock file exists: $lock_file${NC}"
            read -r -p "Remove stale lock and continue? [y/N] " remove_lock
            if [[ "$remove_lock" =~ ^[yY] ]]; then
                rm -f "$lock_file"
                echo "Lock removed."
            else
                echo "Skipped. Remove lock manually if needed."
                return 0
            fi
        fi

        # Build command based on selection
        local cmd_feature=""
        if [ "$selection" -eq 0 ]; then
            echo ""
            echo "Running: ./nginx-optimizer.sh optimize --dry-run"
        else
            # Get the feature for this selection number
            local current=0
            while IFS='|' read -r feat_name display_name is_global cli_feature; do
                [ -z "$feat_name" ] && continue
                local missing_sites
                missing_sites=$(printf '%s' "$MISSING_FEATURES" | grep "^${feat_name}:" | cut -d: -f2 | sort -u || true)
                [ -z "$missing_sites" ] && continue
                current=$((current + 1))
                if [ "$current" -eq "$selection" ]; then
                    cmd_feature="$cli_feature"
                    break
                fi
            done <<< "$FEATURE_META"
            echo ""
            echo "Running: ./nginx-optimizer.sh optimize --feature $cmd_feature --dry-run"
        fi

        echo "(Use --force to apply without dry-run)"
        echo ""

        # Execute
        if [ -n "$cmd_feature" ]; then
            ./nginx-optimizer.sh optimize --feature "$cmd_feature" --dry-run
        else
            ./nginx-optimizer.sh optimize --dry-run
        fi
    fi
}

reset_score() {
    SCORE_ENABLED=0
    SCORE_TOTAL=0
}

increment_score() {
    local enabled=$1
    SCORE_TOTAL=$((SCORE_TOTAL + 1))
    if [ "$enabled" = "1" ]; then
        SCORE_ENABLED=$((SCORE_ENABLED + 1))
    fi
}

show_optimization_score() {
    local enabled_count=$1
    local total_count=$2
    local bar_width=10

    if [ "$total_count" -eq 0 ]; then
        echo -e "${YELLOW}No optimizations checked${NC}"
        return
    fi

    local percent=$(( (enabled_count * 100 + total_count / 2) / total_count ))
    local filled=$(( (enabled_count * bar_width) / total_count ))
    local full_block="█"
    local empty_block="░"
    local bar=""

    for ((i = 0; i < bar_width; i++)); do
        if (( i < filled )); then
            bar+=$full_block
        else
            bar+=$empty_block
        fi
    done

    local color
    if (( percent >= 80 )); then
        color=$GREEN
    elif (( percent >= 50 )); then
        color=$YELLOW
    else
        color=$RED
    fi

    echo -e "${color}[${bar}] ${enabled_count}/${total_count} (${percent}%)${NC}"
}

show_status() {
    local target_site="$1"

    reset_score
    detect_nginx_instances "$target_site"
    analyze_optimizations "$target_site"
}
