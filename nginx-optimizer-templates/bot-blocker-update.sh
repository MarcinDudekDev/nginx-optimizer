#!/bin/bash

################################################################################
# bot-blocker-update.sh - Auto-Update Bot Blocker Rules
################################################################################

# Configuration
BLOCKER_REPO="https://raw.githubusercontent.com/mitchellkrogza/nginx-ultimate-bad-bot-blocker/master"
INSTALL_DIR="/etc/nginx"
BACKUP_DIR="$HOME/.nginx-optimizer/backups/bot-blocker"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${NC}[INFO] $*${NC}"
}

log_success() {
    echo -e "${GREEN}[SUCCESS] $*${NC}"
}

log_error() {
    echo -e "${RED}[ERROR] $*${NC}"
}

log_warn() {
    echo -e "${YELLOW}[WARN] $*${NC}"
}

################################################################################
# Main Functions
################################################################################

check_prerequisites() {
    if ! command -v nginx &>/dev/null; then
        log_error "nginx not found"
        exit 1
    fi

    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        log_error "curl or wget required"
        exit 1
    fi
}

backup_current_rules() {
    log_info "Backing up current bot blocker rules..."

    mkdir -p "$BACKUP_DIR"

    if [ -f "${INSTALL_DIR}/conf.d/globalblacklist.conf" ]; then
        cp "${INSTALL_DIR}/conf.d/globalblacklist.conf" \
            "${BACKUP_DIR}/globalblacklist.conf.$(date +%Y%m%d)"

        log_success "Backup created"
    else
        log_info "No existing rules found"
    fi
}

download_bot_blocker() {
    log_info "Downloading latest bot blocker rules..."

    local temp_dir=$(mktemp -d)

    # Download main blocker file
    if command -v curl &>/dev/null; then
        curl -sSL "${BLOCKER_REPO}/conf.d/globalblacklist.conf" \
            -o "${temp_dir}/globalblacklist.conf"
    else
        wget -q "${BLOCKER_REPO}/conf.d/globalblacklist.conf" \
            -O "${temp_dir}/globalblacklist.conf"
    fi

    if [ $? -eq 0 ]; then
        log_success "Download complete"

        # Install to nginx
        sudo cp "${temp_dir}/globalblacklist.conf" "${INSTALL_DIR}/conf.d/" 2>/dev/null || \
            cp "${temp_dir}/globalblacklist.conf" "${INSTALL_DIR}/conf.d/"

        log_success "Bot blocker rules installed"
    else
        log_error "Download failed"
        exit 1
    fi

    rm -rf "$temp_dir"
}

test_nginx_config() {
    log_info "Testing nginx configuration..."

    if nginx -t 2>&1 | grep -q "syntax is ok"; then
        log_success "Configuration test passed"
        return 0
    else
        log_error "Configuration test failed"
        return 1
    fi
}

reload_nginx() {
    log_info "Reloading nginx..."

    if command -v systemctl &>/dev/null; then
        sudo systemctl reload nginx
    elif command -v service &>/dev/null; then
        sudo service nginx reload
    else
        sudo nginx -s reload
    fi

    if [ $? -eq 0 ]; then
        log_success "Nginx reloaded"
    else
        log_error "Nginx reload failed"
        exit 1
    fi
}

show_stats() {
    log_info "Bot blocker statistics:"

    if [ -f "${INSTALL_DIR}/conf.d/globalblacklist.conf" ]; then
        local bad_bots=$(grep -c "~" "${INSTALL_DIR}/conf.d/globalblacklist.conf" 2>/dev/null || echo 0)
        echo "  Blocked bots: $bad_bots"

        local file_date=$(stat -f "%Sm" -t "%Y-%m-%d" "${INSTALL_DIR}/conf.d/globalblacklist.conf" 2>/dev/null || \
                         stat -c "%y" "${INSTALL_DIR}/conf.d/globalblacklist.conf" 2>/dev/null | cut -d' ' -f1)
        echo "  Last updated: ${file_date:-unknown}"
    else
        echo "  Not installed"
    fi
}

################################################################################
# Main Script
################################################################################

main() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║          Bot Blocker Auto-Update                           ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    check_prerequisites
    backup_current_rules
    download_bot_blocker

    if test_nginx_config; then
        reload_nginx
        echo ""
        show_stats
        echo ""
        log_success "Bot blocker rules updated successfully!"
    else
        log_error "Restoring previous configuration..."

        if [ -f "${BACKUP_DIR}/globalblacklist.conf.$(date +%Y%m%d)" ]; then
            sudo cp "${BACKUP_DIR}/globalblacklist.conf.$(date +%Y%m%d)" \
                "${INSTALL_DIR}/conf.d/globalblacklist.conf" 2>/dev/null || \
                cp "${BACKUP_DIR}/globalblacklist.conf.$(date +%Y%m%d)" \
                "${INSTALL_DIR}/conf.d/globalblacklist.conf"

            log_info "Previous configuration restored"
        fi

        exit 1
    fi
}

# Run if executed directly
if [ "${BASH_SOURCE[0]}" -ef "$0" ]; then
    main "$@"
fi
