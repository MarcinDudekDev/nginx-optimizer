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
NC='\033[0m' # No Color

# Options
DRY_RUN=false
# shellcheck disable=SC2034  # Used by sourced library files (compiler.sh, optimizer.sh)
FORCE=false
QUIET=false
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

source_libraries() {
    for lib in detector backup optimizer validator compiler docker monitoring benchmark honeypot; do
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
    help                        Show this help message

OPTIONS:
    --dry-run                   Show what would be done without applying
    --force                     Skip confirmations
    -q, --quiet                 Suppress informational output (for scripting)
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

ENVIRONMENT:
    Supports system nginx, Docker containers, and wp-test environments
    Backups stored in: ${BACKUP_DIR}
    Logs stored in: ${LOG_DIR}

For more information, visit: https://github.com/MarcinDudekDev/nginx-optimizer
EOF
}

show_version() {
    echo "nginx-optimizer version ${VERSION}"
}

################################################################################
# Command Functions
################################################################################

cmd_analyze() {
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
    log_info "Starting optimization process..."

    if [ "$DRY_RUN" = true ]; then
        log_warn "DRY RUN MODE - No changes will be made"
    fi

    if [ -n "$TARGET_SITE" ]; then
        log_info "Target: ${TARGET_SITE}"
    else
        log_info "Target: All sites"
    fi

    # Create backup first
    if [ "$DRY_RUN" = false ]; then
        if type -t create_backup &>/dev/null; then
            create_backup "$TARGET_SITE"
        else
            log_error "Backup library not loaded"
            exit 1
        fi
    fi

    # Apply optimizations
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

    log_success "Optimization complete!"
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
    log_info "Checking optimization status..."

    if type -t show_status &>/dev/null; then
        show_status "$TARGET_SITE"
    else
        log_error "Detector library not loaded"
        exit 1
    fi
}

cmd_list() {
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
            analyze|optimize|compile|rollback|test|status|list|benchmark|help|honeypot|honeypot-logs|honeypot-export|honeypot-fail2ban)
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
                show_version
                exit 0
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

    # Show banner unless quiet mode
    if [ "$QUIET" = false ]; then
        echo ""
        echo "╔════════════════════════════════════════════════════════════╗"
        echo "║          nginx-optimizer v${VERSION}                           ║"
        echo "╚════════════════════════════════════════════════════════════╝"
        echo ""
    fi

    # Check prerequisites and load libraries
    check_prerequisites
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
        help)
            show_help
            ;;
        *)
            log_error "Unknown command: $COMMAND"
            show_help
            exit 1
            ;;
    esac

    echo ""
    log_info "Log file: ${LOG_FILE}"
}

# Run main function
main "$@"
