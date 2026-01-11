#!/bin/bash

################################################################################
# parser.sh - Nginx Configuration Parser
################################################################################
# Parses nginx -T output to track which file each directive comes from.
# Provides functions to query directive sources and content by file.
#
# Key Features:
# - Parses nginx -T output format (# configuration file /path: marker)
# - Supports both system nginx and Docker containers
# - Bash 3.2 compatible (no associative arrays)
# - Temp file based storage for parsed data
#
# Usage:
#   source nginx-optimizer-lib/parser.sh
#   parser_init
#   parse_nginx_config
#   get_directive_source "fastcgi_cache_path"
#   parser_cleanup
################################################################################

# Storage: temp file path for parsed config data
PARSED_CONFIG_CACHE=""

# Memoization cache for directive_exists_in_file results
# Format: "file_pattern|directive_pattern|0_or_1" per line
# Avoids repeated slow while-read loops for same queries
DIRECTIVE_LOOKUP_CACHE=""

# Batch feature cache - ALL features extracted in ONE pass
# Format: "filepath|feature1,feature2,feature3" per line
# Built once at start, instant lookup after
FEATURE_CACHE=""
FEATURE_CACHE_BUILT=false

# Feature patterns to detect (feature_name:regex)
# shellcheck disable=SC2034  # Reserved for future dynamic pattern matching
FEATURE_PATTERNS="http3:listen.*quic
fastcgi_cache:fastcgi_cache[^_]
brotli:brotli on
gzip:gzip on
security_headers:Strict-Transport-Security
rate_limiting:limit_req
wordpress:xmlrpc
ocsp:ssl_stapling on
tls13:TLSv1.3
tls12:TLSv1.2"

################################################################################
# Initialization & Cleanup
################################################################################

# Initialize parser - creates temp file for storing parsed data
# Call this before using any parser functions
parser_init() {
    if [ -n "$PARSED_CONFIG_CACHE" ] && [ -f "$PARSED_CONFIG_CACHE" ]; then
        rm -f "$PARSED_CONFIG_CACHE"
    fi

    # Clear memoization cache
    DIRECTIVE_LOOKUP_CACHE=""

    # Create temp file (compatible with macOS and Linux)
    PARSED_CONFIG_CACHE=$(mktemp "${TMPDIR:-/tmp}/nginx-parser.XXXXXX")

    if [ ! -f "$PARSED_CONFIG_CACHE" ]; then
        log_error "Failed to create temp file for parser cache"
        return 1
    fi

    return 0
}

# Cleanup temp files - call when done with parser
parser_cleanup() {
    if [ -n "$PARSED_CONFIG_CACHE" ] && [ -f "$PARSED_CONFIG_CACHE" ]; then
        rm -f "$PARSED_CONFIG_CACHE"
        PARSED_CONFIG_CACHE=""
    fi
}

# Build feature cache - ONE pass extracts ALL features for ALL files
# This is the key performance optimization: 1 awk call vs 99 awk calls
build_feature_cache() {
    if [ "$FEATURE_CACHE_BUILT" = true ]; then
        return 0
    fi

    if [ -z "$PARSED_CONFIG_CACHE" ] || [ ! -f "$PARSED_CONFIG_CACHE" ]; then
        return 1
    fi

    # ONE awk pass extracts ALL features for ALL files
    FEATURE_CACHE=$(awk '
        /^###FILE:/ {
            # Save previous file features
            if (current_file != "" && features != "") {
                print current_file "|" features
            }
            current_file = substr($0, 9)
            features = ""
            next
        }
        /listen.*quic/ { if (index(features,"http3")==0) features = features (features?",":"") "http3" }
        /fastcgi_cache[^_]/ { if (index(features,"fastcgi_cache")==0) features = features (features?",":"") "fastcgi_cache" }
        /brotli on/ { if (index(features,"brotli")==0) features = features (features?",":"") "brotli" }
        /gzip on/ { if (index(features,"gzip")==0) features = features (features?",":"") "gzip" }
        /Strict-Transport-Security/ { if (index(features,"security_headers")==0) features = features (features?",":"") "security_headers" }
        /limit_req/ { if (index(features,"rate_limiting")==0) features = features (features?",":"") "rate_limiting" }
        /xmlrpc/ { if (index(features,"wordpress")==0) features = features (features?",":"") "wordpress" }
        /ssl_stapling on/ { if (index(features,"ocsp")==0) features = features (features?",":"") "ocsp" }
        /TLSv1\.3/ { if (index(features,"tls13")==0) features = features (features?",":"") "tls13" }
        /TLSv1\.2/ { if (index(features,"tls12")==0) features = features (features?",":"") "tls12" }
        END {
            if (current_file != "" && features != "") {
                print current_file "|" features
            }
        }
    ' "$PARSED_CONFIG_CACHE")

    FEATURE_CACHE_BUILT=true
}

# Check if feature exists in file (INSTANT lookup from pre-built cache)
# Args: $1 = file path (partial match OK)
#       $2 = feature name (http3, fastcgi_cache, gzip, etc)
# Returns: 0 if found, 1 if not
has_feature_in_file() {
    local file_pattern="$1"
    local feature="$2"

    # Build cache if needed (only runs once)
    [ "$FEATURE_CACHE_BUILT" != true ] && build_feature_cache

    # INSTANT: grep the small in-memory cache
    if echo "$FEATURE_CACHE" | grep -F "$file_pattern" | grep -qF "$feature"; then
        return 0
    fi
    return 1
}

################################################################################
# Core Parsing Functions
################################################################################

# Parse nginx -T output and store in temp file
# Args: $1 = raw nginx -T output (optional - if empty, runs nginx -T)
# Stores data in format: ###FILE:/path/to/file followed by content lines
parse_nginx_config() {
    local config_output="${1:-}"

    # Initialize if not already done
    if [ -z "$PARSED_CONFIG_CACHE" ] || [ ! -f "$PARSED_CONFIG_CACHE" ]; then
        parser_init || return 1
    fi

    # Clear cache file
    : > "$PARSED_CONFIG_CACHE"

    # Get nginx -T output if not provided
    if [ -z "$config_output" ]; then
        if ! command -v nginx &>/dev/null; then
            log_error "nginx command not found"
            return 1
        fi

        config_output=$(nginx -T 2>&1)
        local exit_code=$?

        if [ $exit_code -ne 0 ]; then
            log_error "nginx -T failed with exit code $exit_code"
            return 1
        fi
    fi

    # Parse output with awk (POSIX compatible - no gawk features)
    # Look for lines starting with "# configuration file" and track current file
    echo "$config_output" | awk '
        BEGIN {
            current_file = ""
        }

        # Match: # configuration file /path/to/file:
        /^# configuration file / {
            # Extract file path - BSD awk compatible
            # Remove prefix "# configuration file " and trailing ":"
            line = $0
            sub(/^# configuration file /, "", line)
            sub(/:$/, "", line)
            if (line != "") {
                current_file = line
                print "###FILE:" current_file
            }
            next
        }

        # Skip other comment lines that are not content
        /^#/ && !/^# configuration file/ {
            next
        }

        # Output content lines (only if we have a current file)
        {
            if (current_file != "") {
                print $0
            }
        }
    ' >> "$PARSED_CONFIG_CACHE"

    # Verify we got some data
    if [ ! -s "$PARSED_CONFIG_CACHE" ]; then
        log_warn "Parser: No configuration data extracted"
        return 1
    fi

    return 0
}

# Parse docker container nginx config
# Args: $1 = container name
parse_docker_nginx_config() {
    local container="$1"

    if [ -z "$container" ]; then
        log_error "Container name required"
        return 1
    fi

    # Check if docker is available
    if ! command -v docker &>/dev/null; then
        log_error "Docker command not found"
        return 1
    fi

    # Check if container is running
    if ! docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^${container}$"; then
        log_error "Container '$container' is not running"
        return 1
    fi

    # Get nginx -T output from container
    local config_output
    config_output=$(docker exec "$container" nginx -T 2>&1)
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        log_error "nginx -T failed in container '$container'"
        return 1
    fi

    # Parse the output
    parse_nginx_config "$config_output"
    return $?
}

################################################################################
# Query Functions
################################################################################

# Check if directive exists in parsed config
# Args: $1 = grep pattern (can be regex)
# Returns: 0 if found, 1 if not found
directive_exists() {
    local pattern="$1"

    if [ -z "$PARSED_CONFIG_CACHE" ] || [ ! -f "$PARSED_CONFIG_CACHE" ]; then
        log_error "Parser not initialized - call parser_init first"
        return 1
    fi

    # Search for pattern in cache file (skip ###FILE: markers)
    if grep -v "^###FILE:" "$PARSED_CONFIG_CACHE" | grep -q "$pattern"; then
        return 0
    fi

    return 1
}

# Get first file path containing directive
# Args: $1 = grep pattern (can be regex)
# Prints: filepath (or empty if not found)
# Returns: 0 if found, 1 if not found
get_directive_source() {
    local pattern="$1"

    if [ -z "$PARSED_CONFIG_CACHE" ] || [ ! -f "$PARSED_CONFIG_CACHE" ]; then
        log_error "Parser not initialized - call parser_init first"
        return 1
    fi

    # Use awk to track current file and search for pattern
    awk -v pattern="$pattern" '
        /^###FILE:/ {
            current_file = substr($0, 9)
            next
        }

        # Check if line matches pattern
        $0 ~ pattern {
            if (current_file != "") {
                print current_file
                exit 0
            }
        }
    ' "$PARSED_CONFIG_CACHE"

    local found=$?
    return $found
}

# Get all file paths containing directive
# Args: $1 = grep pattern (can be regex)
# Prints: list of file paths, one per line
get_all_directive_sources() {
    local pattern="$1"

    if [ -z "$PARSED_CONFIG_CACHE" ] || [ ! -f "$PARSED_CONFIG_CACHE" ]; then
        log_error "Parser not initialized - call parser_init first"
        return 1
    fi

    # Use awk to track current file and collect all matches
    awk -v pattern="$pattern" '
        /^###FILE:/ {
            current_file = substr($0, 9)
            next
        }

        # Check if line matches pattern
        $0 ~ pattern {
            if (current_file != "" && !seen[current_file]) {
                print current_file
                seen[current_file] = 1
            }
        }
    ' "$PARSED_CONFIG_CACHE"

    return 0
}

# Get config content for specific file
# Args: $1 = file path pattern (supports partial match)
# Prints: content of matching file section(s)
get_file_content() {
    local file_pattern="$1"

    if [ -z "$PARSED_CONFIG_CACHE" ] || [ ! -f "$PARSED_CONFIG_CACHE" ]; then
        log_error "Parser not initialized - call parser_init first"
        return 1
    fi

    # Use awk to extract content for matching files
    awk -v pattern="$file_pattern" '
        /^###FILE:/ {
            current_file = substr($0, 9)
            # Check if file path matches pattern
            if (current_file ~ pattern) {
                printing = 1
                print "# File: " current_file
            } else {
                printing = 0
            }
            next
        }

        # Print content if we are in a matching file section
        {
            if (printing) {
                print $0
            }
        }
    ' "$PARSED_CONFIG_CACHE"

    return 0
}

# Get directive with line context (shows surrounding lines)
# Args: $1 = grep pattern
#       $2 = lines of context before/after (optional, default 2)
# Prints: file path, line content with context
get_directive_context() {
    local pattern="$1"
    local context="${2:-2}"

    if [ -z "$PARSED_CONFIG_CACHE" ] || [ ! -f "$PARSED_CONFIG_CACHE" ]; then
        log_error "Parser not initialized - call parser_init first"
        return 1
    fi

    # Use awk to show context around matches
    awk -v pattern="$pattern" -v context="$context" '
        /^###FILE:/ {
            current_file = substr($0, 9)
            line_num = 0
            next
        }

        {
            line_num++
            # Store lines in circular buffer for context
            lines[line_num % (context * 2 + 1)] = $0
            line_nums[line_num % (context * 2 + 1)] = line_num

            # Check if current line matches
            if ($0 ~ pattern) {
                # Print file header if first match in this file
                if (!file_printed[current_file]) {
                    print "\n=== " current_file " ==="
                    file_printed[current_file] = 1
                }

                # Print context before
                for (i = line_num - context; i < line_num; i++) {
                    if (i > 0) {
                        idx = i % (context * 2 + 1)
                        if (line_nums[idx] == i) {
                            print "  " i ": " lines[idx]
                        }
                    }
                }

                # Print matching line
                print "▶ " line_num ": " $0

                # Mark that we need to print context after
                show_after = context
            } else if (show_after > 0) {
                # Print context after match
                print "  " line_num ": " $0
                show_after--
            }
        }
    ' "$PARSED_CONFIG_CACHE"

    return 0
}

################################################################################
# Helper Functions for Site-Specific Detection
################################################################################

# Check if directive exists in specific file
# Args: $1 = file path pattern
#       $2 = grep pattern
# Returns: 0 if found, 1 if not
directive_exists_in_file() {
    local file_pattern="$1"
    local directive_pattern="$2"

    if [ -z "$PARSED_CONFIG_CACHE" ] || [ ! -f "$PARSED_CONFIG_CACHE" ]; then
        log_error "Parser not initialized - call parser_init first"
        return 1
    fi

    # Check memoization cache first (FAST PATH)
    local cache_key="${file_pattern}|${directive_pattern}"
    local cached_result
    cached_result=$(printf '%s' "$DIRECTIVE_LOOKUP_CACHE" | grep -F "$cache_key|" | head -n1)
    if [ -n "$cached_result" ]; then
        # Return cached result (0=found, 1=not found)
        local result="${cached_result##*|}"
        return "$result"
    fi

    # FAST PATH: Use awk instead of slow bash while-read
    # awk processes files 10-100x faster than bash loops
    local found
    found=$(awk -v file_pat="$file_pattern" -v dir_pat="$directive_pattern" '
        /^###FILE:/ {
            current_file = substr($0, 9)
            in_target = (current_file ~ file_pat) ? 1 : 0
            next
        }
        in_target && $0 ~ dir_pat {
            print "1"
            exit
        }
    ' "$PARSED_CONFIG_CACHE")

    # Cache and return result
    if [ "$found" = "1" ]; then
        DIRECTIVE_LOOKUP_CACHE="${DIRECTIVE_LOOKUP_CACHE}${cache_key}|0"$'\n'
        return 0
    else
        DIRECTIVE_LOOKUP_CACHE="${DIRECTIVE_LOOKUP_CACHE}${cache_key}|1"$'\n'
        return 1
    fi
}

# List all parsed files
# Prints: list of all file paths found in parsed config
list_parsed_files() {
    if [ -z "$PARSED_CONFIG_CACHE" ] || [ ! -f "$PARSED_CONFIG_CACHE" ]; then
        log_error "Parser not initialized - call parser_init first"
        return 1
    fi

    grep "^###FILE:" "$PARSED_CONFIG_CACHE" | sed 's/^###FILE://' | sort -u
    return 0
}

################################################################################
# Site Extraction Functions
################################################################################

# Extract all unique sites from parsed nginx config
# Returns: Lines in format "site_name|config_file|ssl_status"
# Example output:
#   site1.com|/etc/nginx/sites-enabled/site1.conf|ssl
#   www.site1.com|/etc/nginx/sites-enabled/site1.conf|ssl
#   site2.com|/etc/nginx/sites-enabled/site2.conf|http
#
# Logic:
# - Parses server blocks, tracks listen directives and server_name values
# - Prefers SSL/443 server blocks over HTTP/80 redirects for same site
# - Skips: default_server, localhost, _ (catch-all), empty names
# - Handles multiple server_name values on one line
# - Handles multiple server blocks in same file
extract_all_sites() {
    if [ -z "$PARSED_CONFIG_CACHE" ] || [ ! -f "$PARSED_CONFIG_CACHE" ]; then
        log_error "Parser not initialized"
        return 1
    fi

    # Use awk to parse server blocks and extract server_name values
    # Track: current file, whether in server block, SSL status, server_name values
    awk '
        BEGIN {
            current_file = ""
            in_server = 0
            brace_depth = 0
            has_ssl = 0
            server_names = ""
        }

        # Track current file
        /^###FILE:/ {
            current_file = substr($0, 9)
            next
        }

        # Track server block entry
        /server[[:space:]]*\{/ {
            in_server = 1
            brace_depth = 0
            has_ssl = 0
            server_names = ""
            # Count opening brace on same line
            line = $0
            gsub(/[^\{]/, "", line)
            brace_depth += length(line)
            next
        }

        # Inside server block: track braces
        in_server {
            # Check for SSL indicators in listen directive
            if ($0 ~ /^[[:space:]]*listen[[:space:]]/) {
                if ($0 ~ /443/ || $0 ~ /ssl/ || $0 ~ /quic/) {
                    has_ssl = 1
                }
            }

            # Extract server_name values
            if ($0 ~ /^[[:space:]]*server_name[[:space:]]/) {
                # Remove leading whitespace, "server_name", and trailing semicolon
                names = $0
                sub(/^[[:space:]]*server_name[[:space:]]+/, "", names)
                sub(/;.*$/, "", names)

                # Split multiple names and accumulate
                split(names, name_array, /[[:space:]]+/)
                for (i in name_array) {
                    name = name_array[i]
                    # Skip empty, wildcards, localhost, default_server
                    if (name != "" && name != "_" && name != "localhost" && name !~ /default_server/) {
                        if (server_names == "") {
                            server_names = name
                        } else {
                            server_names = server_names " " name
                        }
                    }
                }
            }

            # Count braces to detect server block end
            opening = $0
            closing = $0
            gsub(/[^\{]/, "", opening)
            gsub(/[^\}]/, "", closing)
            brace_depth += length(opening) - length(closing)

            # Server block ended
            if (brace_depth <= 0 && $0 ~ /\}/) {
                # Output all collected server_name values for this block
                if (server_names != "" && current_file != "") {
                    ssl_status = has_ssl ? "ssl" : "http"

                    # Split server_names and output each
                    split(server_names, final_names, /[[:space:]]+/)
                    for (i in final_names) {
                        if (final_names[i] != "") {
                            print final_names[i] "|" current_file "|" ssl_status
                        }
                    }
                }

                in_server = 0
                brace_depth = 0
                has_ssl = 0
                server_names = ""
            }
        }
    ' "$PARSED_CONFIG_CACHE" | awk -F'|' '
        # Second pass: prefer SSL version when site appears in both http and ssl
        {
            site = $1
            file = $2
            ssl = $3
            key = site "|" file

            # Store entry, preferring ssl over http
            if (!(key in seen) || ssl == "ssl") {
                seen[key] = 1
                entries[key] = site "|" file "|" ssl
            }
        }

        END {
            # Output unique entries
            for (key in entries) {
                print entries[key]
            }
        }
    '

    return 0
}

# Get the server block content for a specific site
# Args: $1 = site name/domain
# Returns: The server block content (SSL version preferred)
# Prints: Full server block content including braces
get_site_server_block() {
    local site="$1"

    if [ -z "$site" ]; then
        log_error "Site name required"
        return 1
    fi

    if [ -z "$PARSED_CONFIG_CACHE" ] || [ ! -f "$PARSED_CONFIG_CACHE" ]; then
        log_error "Parser not initialized"
        return 1
    fi

    # Use awk to find and extract the server block for this site
    # Prefer SSL/443 blocks over HTTP/80 redirects
    awk -v target_site="$site" '
        BEGIN {
            current_file = ""
            in_server = 0
            brace_depth = 0
            has_ssl = 0
            has_target_site = 0
            block_content = ""
            best_block = ""
            best_block_ssl = 0
        }

        # Track current file
        /^###FILE:/ {
            current_file = substr($0, 9)
            next
        }

        # Track server block entry
        /server[[:space:]]*\{/ {
            in_server = 1
            brace_depth = 0
            has_ssl = 0
            has_target_site = 0
            block_content = $0 "\n"

            # Count opening brace
            line = $0
            gsub(/[^\{]/, "", line)
            brace_depth += length(line)
            next
        }

        # Inside server block
        in_server {
            block_content = block_content $0 "\n"

            # Check for SSL
            if ($0 ~ /^[[:space:]]*listen[[:space:]]/) {
                if ($0 ~ /443/ || $0 ~ /ssl/ || $0 ~ /quic/) {
                    has_ssl = 1
                }
            }

            # Check for target site in server_name
            if ($0 ~ /^[[:space:]]*server_name[[:space:]]/) {
                if ($0 ~ target_site) {
                    has_target_site = 1
                }
            }

            # Count braces
            opening = $0
            closing = $0
            gsub(/[^\{]/, "", opening)
            gsub(/[^\}]/, "", closing)
            brace_depth += length(opening) - length(closing)

            # Server block ended
            if (brace_depth <= 0 && $0 ~ /\}/) {
                # If this block contains our target site, consider it
                if (has_target_site) {
                    # Prefer SSL blocks over non-SSL
                    if (best_block == "" || (has_ssl && !best_block_ssl)) {
                        best_block = block_content
                        best_block_ssl = has_ssl
                    }
                }

                in_server = 0
                brace_depth = 0
                has_ssl = 0
                has_target_site = 0
                block_content = ""
            }
        }

        END {
            if (best_block != "") {
                printf "%s", best_block
            }
        }
    ' "$PARSED_CONFIG_CACHE"

    return 0
}

# Get statistics about parsed config
# Prints: summary of files and directives
parser_stats() {
    if [ -z "$PARSED_CONFIG_CACHE" ] || [ ! -f "$PARSED_CONFIG_CACHE" ]; then
        log_error "Parser not initialized - call parser_init first"
        return 1
    fi

    local file_count
    local line_count
    local content_lines

    file_count=$(grep -c "^###FILE:" "$PARSED_CONFIG_CACHE")
    line_count=$(wc -l < "$PARSED_CONFIG_CACHE")
    content_lines=$((line_count - file_count))

    echo "Parser Statistics:"
    echo "  Files parsed: $file_count"
    echo "  Content lines: $content_lines"
    echo "  Total lines: $line_count"

    return 0
}
