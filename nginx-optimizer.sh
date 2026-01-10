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
VERSION="0.9.0-beta"

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
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Options
DRY_RUN=false
# shellcheck disable=SC2034  # Used by sourced library files (compiler.sh, optimizer.sh)
FORCE=false
QUIET=false
VERBOSE=false
JSON_OUTPUT=false
SHOW_VERSION=false
NO_CACHE=false
SPECIFIC_FEATURE=""
EXCLUDE_FEATURE=""
# shellcheck disable=SC2034  # Used by sourced library files (backup.sh)
CUSTOM_BACKUP_DIR=""
TARGET_SITE=""

################################################################################
# Lock File Management
################################################################################

LOCK_FILE="${DATA_DIR}/nginx-optimizer.lock"

acquire_lock() {
    # Portable lock using mkdir (atomic on all platforms)
    if ! mkdir "$LOCK_FILE" 2>/dev/null; then
        # Check if stale lock (process not running)
        if [ -f "$LOCK_FILE/pid" ]; then
            local old_pid
            old_pid=$(cat "$LOCK_FILE/pid" 2>/dev/null)
            if [ -n "$old_pid" ] && ! kill -0 "$old_pid" 2>/dev/null; then
                # Stale lock, remove and retry
                rm -rf "$LOCK_FILE"
                mkdir "$LOCK_FILE" 2>/dev/null || {
                    log_error "Another instance is running (lock: $LOCK_FILE)"
                    exit 1
                }
            else
                log_error "Another instance is running (lock: $LOCK_FILE)"
                exit 1
            fi
        else
            log_error "Another instance is running (lock: $LOCK_FILE)"
            exit 1
        fi
    fi
    # Store our PID for stale lock detection
    echo $$ > "$LOCK_FILE/pid"
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
        log_error "Missing prerequisites: ${missing[*]}"
        log_error "Install with: brew install ${missing[*]} (macOS) or apt install ${missing[*]} (Linux)"
        exit 1
    fi

    # Check nginx (optional since might be Docker-only)
    if ! command -v nginx &>/dev/null && ! command -v docker &>/dev/null; then
        log_warn "Neither nginx nor docker found. Limited functionality."
    fi

    log_success "All prerequisites satisfied"
}

# Quiet version for clean UI mode
check_prerequisites_quiet() {
    local missing=()

    for cmd in rsync curl jq; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "  ${RED}Missing:${NC} ${missing[*]}"
        echo -e "  Install: brew install ${missing[*]} (macOS) or apt install ${missing[*]} (Linux)"
        exit 1
    fi

    # Log to file only
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Prerequisites OK" >> "${LOG_FILE}"
}

source_libraries() {
    # Source UI library first (required for all output)
    local ui_lib="${LIB_DIR}/ui.sh"
    if [ -f "$ui_lib" ]; then
        # shellcheck source=/dev/null
        source "$ui_lib"
    fi

    for lib in parser detector backup optimizer validator compiler docker monitoring benchmark honeypot; do
        lib_file="${LIB_DIR}/${lib}.sh"
        if [ -f "$lib_file" ]; then
            # shellcheck source=/dev/null
            source "$lib_file"
        else
            log_warn "Library not found: ${lib}.sh (will create on first run)"
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
        json_output "{\"command\": \"analyze\", \"version\": \"${VERSION}\", \"target\": \"${TARGET_SITE:-all}\", \"status\": \"placeholder\", \"message\": \"Full JSON output requires detector library refactoring\"}"
        return 0
    fi

    log_info "Analyzing nginx configurations..."

    if [ -n "$TARGET_SITE" ]; then
        log_info "Target: ${TARGET_SITE}"
    else
        log_info "Target: All sites"
    fi

    if type -t detect_nginx_instances &>/dev/null; then
        detect_nginx_instances "$TARGET_SITE"
        analyze_optimizations "$TARGET_SITE"
    else
        log_error "Detector library not loaded. Run setup first."
        exit 1
    fi
}

cmd_optimize() {
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
        # Minimal JSON output for status
        local json_result
        json_result=$(cat <<EOF
{
  "command": "status",
  "version": "${VERSION}",
  "target": "${TARGET_SITE:-all}",
  "status": "ok",
  "message": "Use non-JSON mode for detailed optimization analysis"
}
EOF
)
        json_output "$json_result"
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
        # Run detection but capture output
        log_info "Detecting nginx installations..." >> "$LOG_FILE"
        # Minimal JSON - actual detection would need refactoring
        local json_result
        json_result=$(cat <<EOF
{
  "command": "list",
  "version": "${VERSION}",
  "status": "ok",
  "message": "JSON list output not fully implemented. Use non-JSON mode."
}
EOF
)
        json_output "$json_result"
        return 0
    fi

    log_info "Detecting nginx installations..."

    if type -t list_nginx_instances &>/dev/null; then
        list_nginx_instances
    else
        log_error "Detector library not loaded"
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
            analyze|optimize|compile|rollback|test|status|list|benchmark|help|update|honeypot|honeypot-logs|honeypot-export|honeypot-fail2ban)
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
                NO_CACHE=true
                shift
                ;;
            --feature)
                if [ -z "${2:-}" ] || [[ "$2" == -* ]]; then
                    log_error "--feature requires a value"
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
                EXCLUDE_FEATURE="$2"
                shift 2
                ;;
            --backup-dir)
                if [ -z "${2:-}" ] || [[ "$2" == -* ]]; then
                    log_error "--backup-dir requires a path"
                    exit 1
                fi
                # shellcheck disable=SC2034  # Used by sourced library files
                CUSTOM_BACKUP_DIR="$2"
                shift 2
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
                # Assume it's a site name or backup timestamp
                TARGET_SITE="$1"
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
# Main Function
################################################################################

main() {
    # Initialize directories first (needed for logging)
    init_directories

    # Parse arguments early to know if quiet mode is enabled
    parse_arguments "$@"

    # Acquire lock to prevent race conditions
    acquire_lock
    trap release_lock EXIT

    # Show banner only in verbose mode (new UI handles headers)
    if [ "$VERBOSE" = true ] && [ "$QUIET" = false ]; then
        echo ""
        echo "╔════════════════════════════════════════════════════════════╗"
        echo "║          nginx-optimizer v${VERSION}                           ║"
        echo "╚════════════════════════════════════════════════════════════╝"
        echo ""
    fi

    # Check prerequisites and load libraries (quiet for clean UI)
    check_prerequisites_quiet
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
