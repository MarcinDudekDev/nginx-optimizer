#!/bin/bash

################################################################################
# nginx-optimizer - Comprehensive NGINX Optimization Tool
#
# Features:
# - HTTP/3 (QUIC) support
# - Full-page FastCGI caching
# - Redis object caching
# - Brotli + Zopfli compression
# - WordPress-specific exclusions
# - Security headers + anti-bot hardening
# - PHP 8.2/8.3 OpCache optimization
################################################################################

set -euo pipefail

# Script version
VERSION="0.10.0-beta"

# Directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/nginx-optimizer-lib"
TEMPLATE_DIR="${SCRIPT_DIR}/nginx-optimizer-templates"
DATA_DIR="${HOME}/.nginx-optimizer"
BACKUP_DIR="${DATA_DIR}/backups"
LOG_DIR="${DATA_DIR}/logs"
# shellcheck disable=SC2034  # Reserved for future config file support
CONFIG_FILE="${DATA_DIR}/config.json"

# Log file with timestamp
LOG_FILE="${LOG_DIR}/optimization-$(date +%Y%m%d-%H%M%S).log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
# shellcheck disable=SC2034  # Used by sourced library files (ui.sh, detector.sh)
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Respect NO_COLOR env var (https://no-color.org/) early — before any output
# Flag-based --no-color is handled post-parse via apply_color_settings()
if [[ -n "${NO_COLOR:-}" ]]; then
    RED="" GREEN="" YELLOW="" BLUE="" CYAN="" NC=""
fi

# Options
DRY_RUN=false
# shellcheck disable=SC2034  # Used by sourced library files (compiler.sh, optimizer.sh)
FORCE=false
QUIET=false
VERBOSE=false
JSON_OUTPUT=false
SHOW_VERSION=false
# shellcheck disable=SC2034  # Used by sourced library files (detector.sh)
NO_CACHE=false
CHECK_MODE=false
NO_COLOR_FLAG=false
SPECIFIC_FEATURE=""
EXCLUDE_FEATURE=""
# shellcheck disable=SC2034  # Used by sourced library files (backup.sh)
CUSTOM_BACKUP_DIR=""
TARGET_SITE=""
SYSTEM_ONLY=false
# shellcheck disable=SC2034  # Used by sourced library files (security.sh)
NO_RATE_LIMIT=false

# Allowed feature names for --feature flag
ALLOWED_FEATURES=(
    "http3" "quic"
    "fastcgi-cache" "fastcgi" "cache"
    "redis"
    "brotli" "compression"
    "security" "headers"
    "wordpress" "wp"
    "opcache" "php"
    "upstream-keepalive" "keepalive" "phpfpm"
    "www-ssl" "www"
    "honeypot"
)

# Validate input name (site names, backup timestamps)
# Must be safe for use in file paths - no traversal, no special chars
_validate_input_name() {
    local name="$1"
    [[ "$name" =~ ^[a-zA-Z0-9._-]+$ ]] && [[ "$name" != *".."* ]] && [[ "$name" != /* ]]
}

# Validate feature name against allowed list
validate_feature_name() {
    local feature="$1"
    local allowed
    for allowed in "${ALLOWED_FEATURES[@]}"; do
        [[ "$feature" == "$allowed" ]] && return 0
    done
    return 1
}

################################################################################
# Lock File Management
################################################################################

LOCK_FILE="${DATA_DIR}/nginx-optimizer.lock"

acquire_lock() {
    # Portable lock using mkdir (atomic on all platforms)
    local max_attempts=3
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if mkdir "$LOCK_FILE" 2>/dev/null; then
            # Got the lock - store PID immediately
            echo $$ > "$LOCK_FILE/pid"
            return 0
        fi

        # Lock exists - check if stale
        if [ -f "$LOCK_FILE/pid" ]; then
            local old_pid
            old_pid=$(cat "$LOCK_FILE/pid" 2>/dev/null || true)
            if [ -n "$old_pid" ] && ! kill -0 "$old_pid" 2>/dev/null; then
                # Stale lock - atomically rename before cleanup to prevent race
                local stale_name="${LOCK_FILE}.stale.$$"
                if mv "$LOCK_FILE" "$stale_name" 2>/dev/null; then
                    rm -rf "$stale_name" &  # Background cleanup
                    attempt=$((attempt + 1))
                    continue  # Retry mkdir
                fi
            fi
        fi

        # Lock held by active process
        log_error "Another instance is running (lock: $LOCK_FILE)"
        exit 1
    done

    log_error "Could not acquire lock after $max_attempts attempts"
    exit 1
}

release_lock() {
    rm -rf "$LOCK_FILE" 2>/dev/null || true
}

################################################################################
# Logging Functions
################################################################################

log() {
    local level=$1
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    echo "[${timestamp}] [${level}] ${message}" | tee -a "${LOG_FILE}"
}

log_info() {
    if [ "$QUIET" = false ]; then
        echo -e "${BLUE}[INFO]${NC} $*" | tee -a "${LOG_FILE}"
    else
        echo "[INFO] $*" >> "${LOG_FILE}"
    fi
}

log_success() {
    if [ "$QUIET" = false ]; then
        echo -e "${GREEN}[SUCCESS]${NC} $*" | tee -a "${LOG_FILE}"
    else
        echo "[SUCCESS] $*" >> "${LOG_FILE}"
    fi
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "${LOG_FILE}"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "${LOG_FILE}"
}

# JSON output helper - requires jq
json_output() {
    local data="$1"
    if command -v jq &>/dev/null; then
        echo "$data" | jq .
    else
        echo "$data"
    fi
}

################################################################################
# Initialization
################################################################################

init_directories() {
    mkdir -p "${DATA_DIR}"
    mkdir -p "${BACKUP_DIR}"
    mkdir -p "${LOG_DIR}"
    mkdir -p "${TEMPLATE_DIR}"
    mkdir -p "${LIB_DIR}"
}

check_prerequisites() {
    local missing=()

    for cmd in rsync curl jq; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        if [ "${QUIET:-false}" = true ]; then
            echo -e "  ${RED}Missing:${NC} ${missing[*]}"
        else
            log_error "Missing prerequisites: ${missing[*]}"
        fi
        echo -e "  Install: brew install ${missing[*]} (macOS) or apt install ${missing[*]} (Linux)"
        exit 1
    fi

    if [ "${QUIET:-false}" = true ]; then
        # Log to file only in quiet mode
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Prerequisites OK" >> "${LOG_FILE}"
    else
        # Check nginx (optional since might be Docker-only)
        if ! command -v nginx &>/dev/null && ! command -v docker &>/dev/null; then
            log_warn "Neither nginx nor docker found. Limited functionality."
        fi
        log_success "All prerequisites satisfied"
    fi
}

source_libraries() {
    # Source UI library first (required for all output)
    local ui_lib="${LIB_DIR}/ui.sh"
    if [ -f "$ui_lib" ]; then
        # shellcheck source=/dev/null
        source "$ui_lib"
    fi

    for lib in parser detector backup optimizer validator compiler docker monitoring benchmark honeypot warning-fixer; do
        lib_file="${LIB_DIR}/${lib}.sh"
        if [ -f "$lib_file" ]; then
            # shellcheck source=/dev/null
            source "$lib_file"
        else
            log_warn "Library not found: ${lib}.sh (will create on first run)"
        fi
    done

    # Source new plugin architecture (lib/)
    # Order matters: registry first, then core modules, then features
    local new_lib_dir="${SCRIPT_DIR}/lib"

    # 1. Registry (provides feature_register, feature_detect, etc.)
    if [ -f "${new_lib_dir}/registry.sh" ]; then
        # shellcheck source=/dev/null
        source "${new_lib_dir}/registry.sh"
    fi

    # 2. Core modules (templates, etc.)
    for core_lib in "${new_lib_dir}"/core/*.sh; do
        if [ -f "$core_lib" ]; then
            # shellcheck source=/dev/null
            source "$core_lib"
        fi
    done

    # 3. Feature modules (each calls feature_register)
    for feature_lib in "${new_lib_dir}"/features/*.sh; do
        if [ -f "$feature_lib" ]; then
            # shellcheck source=/dev/null
            source "$feature_lib"
        fi
    done
}

################################################################################
# Help Functions
################################################################################

show_help() {
    cat << EOF
nginx-optimizer v${VERSION} - Comprehensive NGINX Optimization Tool

USAGE:
    nginx-optimizer [COMMAND] [OPTIONS] [SITE]

COMMANDS:
    analyze [site]              Analyze nginx config & show missing optimizations
    optimize [site]             Apply optimizations to site or all sites
    compile                     Compile nginx from source with Brotli support
    rollback [timestamp]        Rollback to previous configuration
    test [site]                 Test nginx configuration
    status [site]               Show optimization status
    list                        List all detected nginx installations
    benchmark [site]            Run performance benchmarks
    honeypot <site>             Deploy honeypot tarpit for site (traps bots)
    honeypot-logs [hours]       Analyze honeypot logs (default: 24h)
    honeypot-export             Export attacker IPs for blocklists
    check [site]                Pre-flight readiness check (deps, config, features)
    diff [timestamp]            Compare current config with backup
    remove [--feature <name>]   Remove applied optimizations
    verify                      Verify applied state matches running config
    fix-warnings                Detect and fix nginx config warnings
    update                      Self-update from git repository
    help                        Show this help message

OPTIONS:
    --dry-run                   Show what would be done without applying
    --force                     Skip confirmations
    -q, --quiet                 Suppress informational output (for scripting)
    --verbose                   Show detailed technical output
    --json                      Output JSON (for status, list commands)
    --feature <name>            Apply specific feature only
    --exclude <name>            Exclude specific feature
    --backup-dir <path>         Custom backup directory
    --system-only               Only operate on system nginx (skip wp-test)
    --no-rate-limit             Disable rate limiting in security config
    --no-color                  Disable colored output (also: NO_COLOR env var)
    --check                     Pre-flight check (same as 'check' command)
    -v, --version               Show version

FEATURES:
    http3                       HTTP/3 (QUIC) support
    fastcgi-cache               Full-page FastCGI caching
    redis                       Redis object caching
    brotli                      Brotli + Zopfli compression
    security                    Security headers + rate limiting
    wordpress                   WordPress-specific exclusions
    opcache                     PHP OpCache optimization
    honeypot                    Bot tarpit with canary tokens

EXAMPLES:
    # Analyze all nginx instances
    nginx-optimizer analyze

    # Analyze specific wp-test site
    nginx-optimizer analyze quiz-test.local

    # Preview optimizations (dry-run)
    nginx-optimizer optimize --dry-run

    # Optimize specific site
    nginx-optimizer optimize quiz-test.local

    # Apply only HTTP/3
    nginx-optimizer optimize --feature http3

    # Optimize but skip Brotli
    nginx-optimizer optimize --exclude brotli

    # Run performance benchmark
    nginx-optimizer benchmark quiz-test.local

    # Restore previous backup
    nginx-optimizer rollback 20250124-143022

    # List all nginx installations
    nginx-optimizer list

    # Check optimization status
    nginx-optimizer status

    # Deploy honeypot for a site
    nginx-optimizer honeypot mysite.com

    # Analyze honeypot activity (last 24h)
    nginx-optimizer honeypot-logs

    # Export attacker IPs for blocklist
    nginx-optimizer honeypot-export

    # Update nginx-optimizer to latest version
    nginx-optimizer update

ENVIRONMENT:
    Supports system nginx, Docker containers, and wp-test environments
    Backups stored in: ${BACKUP_DIR}
    Logs stored in: ${LOG_DIR}

For more information, visit: https://github.com/MarcinDudekDev/nginx-optimizer
EOF
}

show_version() {
    if [ "$JSON_OUTPUT" = true ]; then
        json_output "{\"version\": \"${VERSION}\"}"
    else
        echo "nginx-optimizer version ${VERSION}"
    fi
}

################################################################################
# Command Functions
################################################################################

cmd_analyze() {
    if [ "$JSON_OUTPUT" = true ]; then
        # Build real JSON from feature detection + state data
        local json_features=""
        if type -t feature_list &>/dev/null; then
            local fid
            while IFS= read -r fid; do
                [ -z "$fid" ] && continue
                local display
                display=$(feature_get "$fid" "display" 2>/dev/null)
                [ -z "$display" ] && display="$fid"
                # Check if feature is in applied state
                local applied="false"
                if type -t get_applied_features &>/dev/null; then
                    if get_applied_features "${TARGET_SITE:-all}" 2>/dev/null | grep -qx "$fid"; then
                        applied="true"
                    fi
                fi
                local entry
                entry=$(printf '"%s":{"display":"%s","applied":%s}' "$fid" "$display" "$applied")
                if [ -n "$json_features" ]; then
                    json_features="${json_features},${entry}"
                else
                    json_features="$entry"
                fi
            done < <(feature_list)
        fi
        json_output "$(printf '{"command":"analyze","version":"%s","target":"%s","features":{%s}}' \
            "$VERSION" "${TARGET_SITE:-all}" "$json_features")"
        return 0
    fi

    # Show clean UI header
    if type -t ui_header &>/dev/null; then
        ui_header
        ui_context "Analyzing" "${TARGET_SITE:-All sites}"
        ui_blank
    else
        log_info "Analyzing nginx configurations..."
        if [ -n "$TARGET_SITE" ]; then
            log_info "Target: ${TARGET_SITE}"
        fi
    fi

    if type -t detect_nginx_instances &>/dev/null; then
        if detect_nginx_instances "$TARGET_SITE"; then
            analyze_optimizations "$TARGET_SITE"
        fi
    else
        if type -t ui_error_box &>/dev/null; then
            ui_error_box "Detector library not loaded. Run setup first."
        else
            log_error "Detector library not loaded. Run setup first."
        fi
        exit 1
    fi
}

cmd_optimize() {
    # If --check was passed with optimize, run check instead
    if [ "$CHECK_MODE" = true ]; then
        cmd_check
        return $?
    fi

    # Create backup first (before showing UI)
    if [ "$DRY_RUN" = false ]; then
        if type -t create_backup &>/dev/null; then
            create_backup "$TARGET_SITE"
        else
            log_error "Backup library not loaded"
            exit 1
        fi
    fi

    # Apply optimizations (handles all UI output)
    if type -t apply_optimizations &>/dev/null; then
        apply_optimizations "$TARGET_SITE" "$SPECIFIC_FEATURE" "$EXCLUDE_FEATURE"
    else
        log_error "Optimizer library not loaded"
        exit 1
    fi

    # Validate and reload
    if [ "$DRY_RUN" = false ]; then
        if type -t validate_and_reload &>/dev/null; then
            validate_and_reload "$TARGET_SITE"
        fi
    fi
}

cmd_rollback() {
    local backup_timestamp="$1"

    if [ -z "$backup_timestamp" ]; then
        log_info "Available backups:"
        ls -1 "${BACKUP_DIR}" | tail -10
        echo ""
        read -rp "Enter backup timestamp to restore: " backup_timestamp
    fi

    # Validate backup timestamp format (YYYYMMDD-HHMMSS)
    if [[ ! "$backup_timestamp" =~ ^[0-9]{8}-[0-9]{6}$ ]]; then
        log_error "Invalid backup timestamp format: $backup_timestamp"
        log_error "Expected format: YYYYMMDD-HHMMSS (e.g., 20250124-143022)"
        exit 1
    fi

    if type -t restore_backup &>/dev/null; then
        restore_backup "$backup_timestamp"
    else
        log_error "Backup library not loaded"
        exit 1
    fi
}

cmd_test() {
    log_info "Testing nginx configuration..."

    if type -t test_nginx_config &>/dev/null; then
        test_nginx_config "$TARGET_SITE"
    else
        log_error "Validator library not loaded"
        exit 1
    fi
}

cmd_status() {
    if [ "$JSON_OUTPUT" = true ]; then
        # Build JSON from state file data
        local applied_json="[]"
        if type -t load_applied_state &>/dev/null; then
            local state
            state=$(load_applied_state)
            if command -v jq &>/dev/null; then
                applied_json=$(echo "$state" | jq -c '.applied')
            else
                applied_json=$(echo "$state" | sed 's/.*"applied"://' | sed 's/}$//')
            fi
        fi
        json_output "$(printf '{"command":"status","version":"%s","target":"%s","applied":%s}' \
            "$VERSION" "${TARGET_SITE:-all}" "$applied_json")"
        return 0
    fi

    log_info "Checking optimization status..."

    if type -t show_status &>/dev/null; then
        show_status "$TARGET_SITE"
    else
        log_error "Detector library not loaded"
        exit 1
    fi
}

cmd_list() {
    if [ "$JSON_OUTPUT" = true ]; then
        # Build JSON from detected instances
        local instances_json=""
        if [ ${#DETECTED_INSTANCES[@]} -gt 0 ] 2>/dev/null; then
            for inst in "${DETECTED_INSTANCES[@]}"; do
                local itype iname ipath
                itype="${inst%%:*}"
                local rest="${inst#*:}"
                iname="${rest%%:*}"
                ipath="${rest#*:}"
                local entry
                entry=$(printf '{"type":"%s","name":"%s","path":"%s"}' "$itype" "$iname" "$ipath")
                if [ -n "$instances_json" ]; then
                    instances_json="${instances_json},${entry}"
                else
                    instances_json="$entry"
                fi
            done
        fi
        # Also list registered features
        local features_json=""
        if type -t feature_list_all &>/dev/null; then
            local line
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                local fid="${line%%|*}"
                local fdisplay="${line#*|}"
                local entry
                entry=$(printf '{"id":"%s","display":"%s"}' "$fid" "$fdisplay")
                if [ -n "$features_json" ]; then
                    features_json="${features_json},${entry}"
                else
                    features_json="$entry"
                fi
            done < <(feature_list_all)
        fi
        json_output "$(printf '{"command":"list","version":"%s","instances":[%s],"features":[%s]}' \
            "$VERSION" "$instances_json" "$features_json")"
        return 0
    fi

    # Show clean UI header
    if type -t ui_header &>/dev/null; then
        ui_header
    fi

    if type -t list_nginx_instances &>/dev/null; then
        list_nginx_instances
    else
        if type -t ui_error_box &>/dev/null; then
            ui_error_box "Detector library not loaded"
        else
            log_error "Detector library not loaded"
        fi
        exit 1
    fi
}

cmd_benchmark() {
    log_info "Running performance benchmarks..."

    if [ -z "$TARGET_SITE" ]; then
        log_error "Site parameter required for benchmarks"
        log_info "Usage: nginx-optimizer benchmark <site>"
        exit 1
    fi

    if type -t run_benchmark &>/dev/null; then
        run_benchmark "$TARGET_SITE"
    else
        log_error "Benchmark library not loaded"
        exit 1
    fi
}

cmd_compile() {
    log_info "Compiling nginx from source with Brotli support..."

    if type -t compile_nginx_with_brotli &>/dev/null; then
        compile_nginx_with_brotli
    else
        log_error "Compiler library not loaded"
        exit 1
    fi
}

cmd_check() {
    if [ "$JSON_OUTPUT" = true ]; then
        # Build JSON check output
        local prereqs_json=""
        for cmd in rsync curl jq; do
            local found="false"
            command -v "$cmd" &>/dev/null && found="true"
            local entry
            entry=$(printf '{"name":"%s","found":%s}' "$cmd" "$found")
            if [ -n "$prereqs_json" ]; then
                prereqs_json="${prereqs_json},${entry}"
            else
                prereqs_json="$entry"
            fi
        done
        local nginx_ready="false"
        if command -v nginx &>/dev/null && nginx -t 2>/dev/null; then
            nginx_ready="true"
        fi
        local features_json=""
        if type -t feature_list &>/dev/null; then
            local fid
            while IFS= read -r fid; do
                [ -z "$fid" ] && continue
                local entry
                entry=$(printf '"%s"' "$fid")
                if [ -n "$features_json" ]; then
                    features_json="${features_json},${entry}"
                else
                    features_json="$entry"
                fi
            done < <(feature_list)
        fi
        json_output "$(printf '{"command":"check","version":"%s","ready":%s,"prerequisites":[%s],"features":[%s]}' \
            "$VERSION" "$nginx_ready" "$prereqs_json" "$features_json")"
        return 0
    fi

    # Show header
    if type -t ui_header &>/dev/null; then
        ui_header
        ui_context "Checking" "${TARGET_SITE:-System readiness}"
        ui_blank
    else
        log_info "Running pre-optimization checks..."
    fi

    local issues=0

    # 1. Check prerequisites
    if type -t ui_section &>/dev/null; then
        ui_section "Prerequisites"
    fi
    local deps_ok=true
    for cmd in rsync curl jq; do
        if command -v "$cmd" &>/dev/null; then
            log_success "  $cmd: found"
        else
            log_error "  $cmd: missing"
            deps_ok=false
            issues=$((issues + 1))
        fi
    done
    if [ "$deps_ok" = true ]; then
        log_success "All dependencies available"
    fi

    # 2. Test nginx configuration
    if type -t ui_section &>/dev/null; then
        ui_section "Nginx Configuration"
    fi
    if command -v nginx &>/dev/null; then
        if nginx -t 2>/dev/null; then
            log_success "nginx configuration valid"
        else
            log_error "nginx configuration invalid"
            issues=$((issues + 1))
        fi
    elif command -v docker &>/dev/null && docker ps --format "{{.Names}}" 2>/dev/null | grep -q "wp-test-proxy"; then
        if docker exec wp-test-proxy nginx -t 2>/dev/null; then
            log_success "wp-test nginx-proxy configuration valid"
        else
            log_error "wp-test nginx-proxy configuration invalid"
            issues=$((issues + 1))
        fi
    else
        log_warn "No nginx instance found (system or Docker)"
    fi

    # 3. Check registered features
    if type -t ui_section &>/dev/null; then
        ui_section "Registered Features"
    fi
    if type -t feature_list &>/dev/null; then
        local feature_id
        while IFS= read -r feature_id; do
            [ -z "$feature_id" ] && continue
            local display_name
            display_name=$(feature_get "$feature_id" "display" 2>/dev/null)
            [ -z "$display_name" ] && display_name="$feature_id"
            log_info "  $display_name ($feature_id)"
        done < <(feature_list)
    else
        log_warn "Feature registry not loaded"
        issues=$((issues + 1))
    fi

    # 4. Check backup directory
    if type -t ui_section &>/dev/null; then
        ui_section "Backup System"
    fi
    if [ -d "$BACKUP_DIR" ] && [ -w "$BACKUP_DIR" ]; then
        local backup_count
        backup_count=$(ls -1 "$BACKUP_DIR" 2>/dev/null | wc -l | tr -d ' ')
        log_success "Backup directory writable ($backup_count existing backups)"
    else
        log_error "Backup directory not writable: $BACKUP_DIR"
        issues=$((issues + 1))
    fi

    # Summary
    echo ""
    if [ "$issues" -eq 0 ]; then
        if type -t ui_success_box &>/dev/null; then
            ui_success_box "System ready" "All checks passed. Safe to run optimize."
        else
            log_success "All checks passed. System ready for optimization."
        fi
        return 0
    else
        if type -t ui_warn_box &>/dev/null; then
            ui_warn_box "$issues issue(s) found. Review above before optimizing."
        else
            log_error "$issues issue(s) found. Review above before optimizing."
        fi
        return 1
    fi
}

cmd_remove() {
    local feature_to_remove="${SPECIFIC_FEATURE:-}"

    if [ -z "$feature_to_remove" ]; then
        # Show what's applied and ask
        if type -t get_applied_features &>/dev/null; then
            local applied
            applied=$(get_applied_features "${TARGET_SITE:-all}")
            if [ -z "$applied" ]; then
                log_info "No features currently tracked as applied"
                log_info "Use: nginx-optimizer remove --feature <name>"
                return 0
            fi
            log_info "Currently applied features:"
            echo "$applied" | while IFS= read -r f; do
                echo "  - $f"
            done
            echo ""
            log_info "Use: nginx-optimizer remove --feature <name> to remove specific feature"
        else
            log_error "State tracking not available"
            exit 1
        fi
        return 0
    fi

    # Resolve feature alias to ID
    local feature_id=""
    if type -t feature_get_by_alias &>/dev/null; then
        feature_id=$(feature_get_by_alias "$feature_to_remove" 2>/dev/null)
    fi
    if [ -z "$feature_id" ]; then
        log_error "Unknown feature: $feature_to_remove"
        exit 1
    fi

    local display_name
    display_name=$(feature_get "$feature_id" "display" 2>/dev/null)
    [ -z "$display_name" ] && display_name="$feature_id"

    # Create safety backup before removing
    if [ "$DRY_RUN" = false ]; then
        if type -t create_backup &>/dev/null; then
            log_info "Creating safety backup before removal..."
            create_backup "$TARGET_SITE"
        fi
    fi

    if type -t ui_header &>/dev/null; then
        ui_header
        if [ "$DRY_RUN" = true ]; then
            ui_warn_box "DRY RUN - No changes will be made"
        fi
        ui_context "Removing" "$display_name"
        ui_blank
    else
        log_info "Removing $display_name..."
    fi

    # Remove via registry
    if type -t feature_remove &>/dev/null; then
        if feature_remove "$feature_id" "$TARGET_SITE"; then
            if type -t ui_step &>/dev/null; then
                ui_step "$display_name removed"
            else
                log_success "$display_name removed"
            fi

            # Validate nginx config after removal
            if [ "$DRY_RUN" = false ]; then
                if command -v nginx &>/dev/null; then
                    if ! nginx -t 2>/dev/null; then
                        log_error "nginx -t failed after removal — rolling back"
                        if type -t restore_backup &>/dev/null && [ -n "${CURRENT_BACKUP_DIR:-}" ]; then
                            FORCE=true restore_backup "$(basename "$CURRENT_BACKUP_DIR")"
                        fi
                        exit 1
                    fi
                fi

                # Update state file
                if type -t save_applied_state &>/dev/null && [ -f "${STATE_FILE:-}" ]; then
                    # Remove entry from state
                    if command -v jq &>/dev/null; then
                        local temp_state
                        temp_state=$(mktemp)
                        jq -c --arg fid "$feature_id" \
                            '.applied = [.applied[] | select(.feature != $fid)]' \
                            "$STATE_FILE" > "$temp_state"
                        mv "$temp_state" "$STATE_FILE"
                    else
                        # Rebuild without this feature
                        local entries=""
                        local line
                        while IFS= read -r line; do
                            if echo "$line" | grep -q "\"feature\":\"${feature_id}\""; then
                                continue
                            fi
                            if [ -n "$entries" ]; then
                                entries="${entries},${line}"
                            else
                                entries="$line"
                            fi
                        done < <(_parse_state_entries)
                        printf '{"applied":[%s]}\n' "$entries" > "$STATE_FILE"
                    fi
                fi

                # Reload nginx
                if type -t validate_and_reload &>/dev/null; then
                    validate_and_reload "$TARGET_SITE"
                fi
            fi
        else
            log_info "$display_name is not currently applied or could not be removed"
        fi
    else
        log_error "Feature registry not loaded"
        exit 1
    fi
}

cmd_verify() {
    if type -t ui_header &>/dev/null; then
        ui_header
        ui_context "Verifying" "Applied state vs running config"
        ui_blank
    else
        log_info "Verifying applied state against running configuration..."
    fi

    # Load state
    if ! type -t get_applied_features &>/dev/null; then
        log_error "State tracking not available"
        exit 1
    fi

    local applied
    applied=$(get_applied_features "${TARGET_SITE:-}")

    if [ -z "$applied" ]; then
        log_info "No features tracked in state file"
        log_info "Run 'optimize' first to build state, or state was cleared by rollback"
        return 0
    fi

    local v_ok=0
    local v_drift=0
    local v_miss=0

    # For each feature marked as applied, check if still detected
    while IFS= read -r feature_id; do
        [ -z "$feature_id" ] && continue
        local display_name
        display_name=$(feature_get "$feature_id" "display" 2>/dev/null)
        [ -z "$display_name" ] && display_name="$feature_id"

        # Check if feature template or pattern is still present
        local still_present=false

        # Check template in conf.d
        local template
        template=$(feature_get "$feature_id" "template" 2>/dev/null)
        if [ -n "$template" ]; then
            if type -t get_nginx_confd_dir &>/dev/null; then
                local confd_dir
                confd_dir=$(get_nginx_confd_dir)
                if [ -n "$confd_dir" ] && [ -f "$confd_dir/$template" ]; then
                    still_present=true
                fi
            fi
            # Also check wp-test
            local wp_nginx="${WP_TEST_NGINX:-$HOME/.wp-test/nginx}"
            if [ -f "$wp_nginx/conf.d/$template" ]; then
                still_present=true
            fi
        fi

        if [ "$still_present" = true ]; then
            v_ok=$((v_ok + 1))
            if type -t ui_step &>/dev/null; then
                ui_step "$display_name: verified"
            else
                log_success "  $display_name: verified"
            fi
        else
            v_miss=$((v_miss + 1))
            if type -t ui_step_fail &>/dev/null; then
                ui_step_fail "$display_name" "missing (state says applied but not found)"
            else
                log_warn "  $display_name: MISSING (state says applied)"
            fi
        fi
    done <<< "$applied"

    # Check for drift: features detected but NOT in state
    if type -t feature_list &>/dev/null; then
        local fid
        while IFS= read -r fid; do
            [ -z "$fid" ] && continue
            # Skip if already in applied list
            if echo "$applied" | grep -qx "$fid"; then
                continue
            fi
            # Check if feature template exists (simple presence check)
            local tmpl
            tmpl=$(feature_get "$fid" "template" 2>/dev/null)
            if [ -n "$tmpl" ]; then
                local tmpl_found=false
                if type -t get_nginx_confd_dir &>/dev/null; then
                    local confd
                    confd=$(get_nginx_confd_dir)
                    [ -n "$confd" ] && [ -f "$confd/$tmpl" ] && tmpl_found=true
                fi
                local wpn="${WP_TEST_NGINX:-$HOME/.wp-test/nginx}"
                [ -f "$wpn/conf.d/$tmpl" ] && tmpl_found=true

                if [ "$tmpl_found" = true ]; then
                    v_drift=$((v_drift + 1))
                    local dn
                    dn=$(feature_get "$fid" "display" 2>/dev/null)
                    [ -z "$dn" ] && dn="$fid"
                    if type -t ui_step_pending &>/dev/null; then
                        ui_step_pending "$dn: drift (found but not in state)"
                    else
                        log_warn "  $dn: DRIFT (present but not tracked)"
                    fi
                fi
            fi
        done < <(feature_list)
    fi

    # Summary
    echo ""
    if [ "$v_miss" -eq 0 ] && [ "$v_drift" -eq 0 ]; then
        if type -t ui_success_box &>/dev/null; then
            ui_success_box "Verification passed" "$v_ok feature(s) verified, 0 issues"
        else
            log_success "$v_ok feature(s) verified, no issues"
        fi
        return 0
    else
        log_info "$v_ok verified, $v_drift drifted, $v_miss missing"
        return 1
    fi
}

cmd_diff() {
    local backup_timestamp="${TARGET_SITE:-}"

    local backup_path=""
    if [ -n "$backup_timestamp" ]; then
        # Validate backup timestamp format
        if [[ ! "$backup_timestamp" =~ ^[0-9]{8}-[0-9]{6}$ ]]; then
            log_error "Invalid backup timestamp format: $backup_timestamp"
            log_error "Expected format: YYYYMMDD-HHMMSS (e.g., 20250124-143022)"
            exit 1
        fi
        backup_path="${BACKUP_DIR}/${backup_timestamp}"
        if [ ! -d "$backup_path" ]; then
            log_error "Backup not found: $backup_path"
            exit 1
        fi
    else
        # Find most recent backup
        if [ ! -d "$BACKUP_DIR" ]; then
            log_info "No backups found in $BACKUP_DIR"
            return 0
        fi
        local latest
        latest=$(ls -1t "$BACKUP_DIR" 2>/dev/null | head -1)
        if [ -z "$latest" ]; then
            log_info "No backups found"
            return 0
        fi
        backup_path="${BACKUP_DIR}/${latest}"
        log_info "Comparing against most recent backup: $latest"
    fi

    # Determine diff command (prefer colordiff if available and colors enabled)
    local diff_cmd="diff"
    local diff_opts="-u"
    if [ -z "${NO_COLOR:-}$NO_COLOR_FLAG" ] || { [ "$NO_COLOR_FLAG" != "true" ] && [ -z "${NO_COLOR:-}" ]; }; then
        if command -v colordiff &>/dev/null; then
            diff_cmd="colordiff"
        elif diff --color=auto /dev/null /dev/null 2>/dev/null; then
            diff_opts="-u --color=auto"
        fi
    fi

    local has_diff=false

    # Compare each backed-up directory against its current location
    local -a dir_pairs=()
    [ -d "$backup_path/nginx" ] && dir_pairs+=("$backup_path/nginx|/etc/nginx")
    [ -d "$backup_path/nginx-homebrew-intel" ] && dir_pairs+=("$backup_path/nginx-homebrew-intel|/usr/local/etc/nginx")
    [ -d "$backup_path/nginx-homebrew-arm" ] && dir_pairs+=("$backup_path/nginx-homebrew-arm|/opt/homebrew/etc/nginx")
    [ -d "$backup_path/wp-test-nginx" ] && dir_pairs+=("$backup_path/wp-test-nginx|$HOME/.wp-test/nginx")

    for pair in "${dir_pairs[@]}"; do
        local bak_dir="${pair%%|*}"
        local cur_dir="${pair##*|}"

        [ -d "$cur_dir" ] || continue

        echo ""
        log_info "Comparing: $cur_dir"
        echo "---"

        local diff_output
        diff_output=$($diff_cmd $diff_opts -r "$bak_dir" "$cur_dir" 2>/dev/null || true)
        if [ -n "$diff_output" ]; then
            echo "$diff_output"
            has_diff=true
        else
            echo "  No differences"
        fi
    done

    echo ""
    if [ "$has_diff" = true ]; then
        log_info "Differences found between backup and current config"
        return 1
    else
        log_success "No differences found"
        return 0
    fi
}

cmd_honeypot() {
    if [ -z "$TARGET_SITE" ]; then
        log_error "Site domain required for honeypot deployment"
        log_info "Usage: nginx-optimizer honeypot <site-domain>"
        exit 1
    fi

    log_info "Deploying honeypot tarpit for $TARGET_SITE..."

    if type -t deploy_honeypot &>/dev/null; then
        deploy_honeypot "$TARGET_SITE"

        echo ""
        log_info "Next steps:"
        log_info "1. Add to your nginx site config:"
        echo "   include ${TEMPLATE_DIR}/honeypot-tarpit.conf;"
        echo ""
        log_info "2. Test nginx config:"
        echo "   sudo nginx -t"
        echo ""
        log_info "3. Reload nginx:"
        echo "   sudo systemctl reload nginx"
        echo ""
        log_info "4. (Optional) Enable fail2ban integration:"
        echo "   nginx-optimizer honeypot-fail2ban"
    else
        log_error "Honeypot library not loaded"
        exit 1
    fi
}

cmd_honeypot_logs() {
    local hours="${TARGET_SITE:-24}"

    log_info "Analyzing honeypot logs..."

    if type -t analyze_honeypot_logs &>/dev/null; then
        analyze_honeypot_logs "$hours"
    else
        log_error "Honeypot library not loaded"
        exit 1
    fi
}

cmd_honeypot_export() {
    log_info "Exporting attacker IPs..."

    if type -t export_attacker_ips &>/dev/null; then
        export_attacker_ips
    else
        log_error "Honeypot library not loaded"
        exit 1
    fi
}

cmd_honeypot_fail2ban() {
    log_info "Setting up fail2ban integration..."

    if type -t create_fail2ban_config &>/dev/null; then
        create_fail2ban_config
    else
        log_error "Honeypot library not loaded"
        exit 1
    fi
}

cmd_update() {
    log_info "Checking for updates..."

    # Check if we're in a git repository
    if [ ! -d "${SCRIPT_DIR}/.git" ]; then
        log_error "Not a git installation. Update manually or reinstall."
        log_info "Install with: curl -fsSL https://raw.githubusercontent.com/MarcinDudekDev/nginx-optimizer/main/install.sh | bash"
        exit 1
    fi

    cd "$SCRIPT_DIR"

    # Check for local modifications
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        log_warn "Local modifications detected:"
        git status --short
        echo ""
        if [ "$FORCE" = false ]; then
            read -rp "Continue anyway? Changes will be stashed. [y/N] " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                log_info "Update cancelled."
                exit 0
            fi
            git stash
            log_info "Local changes stashed. Restore with: git stash pop"
        else
            git stash
        fi
    fi

    # Fetch and show what's new
    local current_version
    current_version=$(git rev-parse --short HEAD)

    git fetch origin main --quiet

    local new_commits
    new_commits=$(git log HEAD..origin/main --oneline 2>/dev/null)

    if [ -z "$new_commits" ]; then
        log_success "Already up to date (${current_version})"
        exit 0
    fi

    echo ""
    log_info "Changes available:"
    echo "$new_commits" | head -10
    local commit_count
    commit_count=$(echo "$new_commits" | wc -l | tr -d ' ')
    if [ "$commit_count" -gt 10 ]; then
        echo "  ... and $((commit_count - 10)) more commits"
    fi
    echo ""

    # Pull updates
    if git pull origin main --quiet; then
        local new_version
        new_version=$(git rev-parse --short HEAD)
        log_success "Updated: ${current_version} -> ${new_version}"

        # Show if version number changed
        local script_version
        script_version=$(grep '^VERSION=' "$SCRIPT_DIR/nginx-optimizer.sh" | cut -d'"' -f2)
        log_info "nginx-optimizer version: ${script_version}"
    else
        log_error "Update failed. Check network connection and try again."
        exit 1
    fi
}

################################################################################
# Interactive Wizard
################################################################################

show_wizard() {
    if [ "$QUIET" = true ]; then
        log_error "No command specified. Use --help for usage."
        exit 1
    fi

    echo ""
    echo "nginx-optimizer v${VERSION} - Interactive Mode"
    echo ""
    echo "What would you like to do?"
    echo ""
    echo "  1) Analyze     - Scan nginx configs and show missing optimizations"
    echo "  2) Optimize    - Apply optimizations (with backup)"
    echo "  3) Rollback    - Restore previous configuration"
    echo "  4) Status      - Show current optimization status"
    echo "  5) Help        - Show full help message"
    echo "  q) Quit"
    echo ""

    while true; do
        read -rp "Enter choice [1-5, q]: " choice
        case "$choice" in
            1) COMMAND="analyze"; break ;;
            2) COMMAND="optimize"; break ;;
            3) COMMAND="rollback"; break ;;
            4) COMMAND="status"; break ;;
            5) COMMAND="help"; break ;;
            q|Q) echo "Goodbye!"; exit 0 ;;
            *) echo "Invalid choice. Please enter 1-5 or q." ;;
        esac
    done
}

################################################################################
# Argument Parsing
################################################################################

parse_arguments() {
    COMMAND=""

    while [ $# -gt 0 ]; do
        case "$1" in
            analyze|optimize|compile|rollback|test|status|list|benchmark|check|diff|remove|verify|help|update|honeypot|honeypot-logs|honeypot-export|honeypot-fail2ban|fix-warnings)
                COMMAND="$1"
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --force)
                # shellcheck disable=SC2034  # Used by sourced library files
                FORCE=true
                shift
                ;;
            -q|--quiet)
                QUIET=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                export UI_VERBOSE=true
                shift
                ;;
            --json)
                JSON_OUTPUT=true
                QUIET=true  # JSON mode implies quiet
                shift
                ;;
            --no-cache)
                # shellcheck disable=SC2034  # Used by detector.sh
                NO_CACHE=true
                shift
                ;;
            --feature)
                if [ -z "${2:-}" ] || [[ "$2" == -* ]]; then
                    log_error "--feature requires a value"
                    exit 1
                fi
                if ! validate_feature_name "$2"; then
                    log_error "Unknown feature: $2"
                    log_info "Valid features: ${ALLOWED_FEATURES[*]}"
                    exit 1
                fi
                SPECIFIC_FEATURE="$2"
                shift 2
                ;;
            --exclude)
                if [ -z "${2:-}" ] || [[ "$2" == -* ]]; then
                    log_error "--exclude requires a value"
                    exit 1
                fi
                if ! validate_feature_name "$2"; then
                    log_error "Unknown feature to exclude: $2"
                    log_info "Valid features: ${ALLOWED_FEATURES[*]}"
                    exit 1
                fi
                EXCLUDE_FEATURE="$2"
                shift 2
                ;;
            --backup-dir)
                if [ -z "${2:-}" ] || [[ "$2" == -* ]]; then
                    log_error "--backup-dir requires a path"
                    exit 1
                fi
                # Resolve and validate path - must be under $HOME or /tmp
                local resolved_backup_dir
                resolved_backup_dir=$(realpath "$2" 2>/dev/null || echo "$2")
                case "$resolved_backup_dir" in
                    "$HOME"/*|/tmp/*)
                        # shellcheck disable=SC2034  # Used by sourced library files
                        CUSTOM_BACKUP_DIR="$resolved_backup_dir"
                        ;;
                    *)
                        log_error "Backup directory must be under \$HOME or /tmp: $2"
                        exit 1
                        ;;
                esac
                shift 2
                ;;
            --system-only)
                SYSTEM_ONLY=true
                export SYSTEM_ONLY
                shift
                ;;
            --no-rate-limit)
                NO_RATE_LIMIT=true
                export NO_RATE_LIMIT
                shift
                ;;
            --no-color)
                NO_COLOR_FLAG=true
                shift
                ;;
            --check)
                CHECK_MODE=true
                DRY_RUN=true
                shift
                ;;
            -v|--version)
                SHOW_VERSION=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                # Validate as site name or backup timestamp
                if [[ "$1" =~ ^[0-9]{8}-[0-9]{6}$ ]]; then
                    # Valid backup timestamp format
                    TARGET_SITE="$1"
                elif _validate_input_name "$1"; then
                    TARGET_SITE="$1"
                else
                    log_error "Invalid input: $1"
                    log_error "Site names can only contain: a-z, A-Z, 0-9, dots, hyphens, underscores"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # Handle --version after all flags parsed (so --json works with it)
    if [ "$SHOW_VERSION" = true ]; then
        show_version
        exit 0
    fi

    if [ -z "$COMMAND" ]; then
        show_wizard
    fi
}

################################################################################
# Color Settings (applied after argument parsing)
################################################################################

apply_color_settings() {
    # Disable colors if --no-color flag was passed or stdout is not a terminal
    if [[ "$NO_COLOR_FLAG" == "true" ]] || [[ ! -t 1 ]]; then
        # shellcheck disable=SC2034  # CYAN used by sourced library files (ui.sh, detector.sh)
        RED="" GREEN="" YELLOW="" BLUE="" CYAN="" NC=""
    fi
}

################################################################################
# Main Function
################################################################################

main() {
    # Initialize directories first (needed for logging)
    init_directories

    # Parse arguments early to know if quiet mode is enabled
    parse_arguments "$@"

    # Apply color settings after parsing (handles --no-color and pipe detection)
    apply_color_settings

    # Acquire lock to prevent race conditions
    acquire_lock

    # Combined cleanup handler: rollback active transactions + release lock
    cleanup_handler() {
        # Rollback any in-progress transaction
        if type -t transaction_rollback &>/dev/null && [ "${TRANSACTION_ACTIVE:-false}" = true ]; then
            transaction_rollback
            log_warn "Transaction rolled back due to interruption" 2>/dev/null || true
        fi
        release_lock
    }
    trap cleanup_handler EXIT INT TERM

    # Show banner only in verbose mode (new UI handles headers)
    if [ "$VERBOSE" = true ] && [ "$QUIET" = false ]; then
        echo ""
        echo "╔════════════════════════════════════════════════════════════╗"
        echo "║          nginx-optimizer v${VERSION}                           ║"
        echo "╚════════════════════════════════════════════════════════════╝"
        echo ""
    fi

    # Check prerequisites and load libraries (quiet for clean UI)
    QUIET=true check_prerequisites
    source_libraries

    # Execute command
    case "$COMMAND" in
        analyze)
            cmd_analyze
            ;;
        optimize)
            cmd_optimize
            ;;
        compile)
            cmd_compile
            ;;
        rollback)
            cmd_rollback "$TARGET_SITE"
            ;;
        test)
            cmd_test
            ;;
        status)
            cmd_status
            ;;
        list)
            cmd_list
            ;;
        benchmark)
            cmd_benchmark
            ;;
        check)
            cmd_check
            ;;
        diff)
            cmd_diff
            ;;
        remove)
            cmd_remove
            ;;
        verify)
            cmd_verify
            ;;
        honeypot)
            cmd_honeypot
            ;;
        honeypot-logs)
            cmd_honeypot_logs
            ;;
        honeypot-export)
            cmd_honeypot_export
            ;;
        honeypot-fail2ban)
            cmd_honeypot_fail2ban
            ;;
        fix-warnings)
            cmd_fix_warnings
            ;;
        update)
            cmd_update
            ;;
        help)
            show_help
            ;;
        *)
            log_error "Unknown command: $COMMAND"
            show_help
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
