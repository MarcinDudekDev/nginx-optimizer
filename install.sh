#!/bin/bash

################################################################################
# nginx-optimizer - One-Line Installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/MarcinDudekDev/nginx-optimizer/main/install.sh | bash
#
# Or with custom directory:
#   NGINX_OPTIMIZER_INSTALL_DIR=/custom/path curl -fsSL ... | bash
################################################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
REPO_URL="https://github.com/MarcinDudekDev/nginx-optimizer.git"
DEFAULT_INSTALL_DIR="${HOME}/.nginx-optimizer"
INSTALL_DIR="${NGINX_OPTIMIZER_INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"

# Trap errors
trap 'error_handler $? $LINENO' ERR

error_handler() {
    local exit_code=$1
    local line_number=$2
    echo -e "${RED}✗ Installation failed at line ${line_number} with exit code ${exit_code}${NC}" >&2
    echo -e "${YELLOW}Please check the error above and try again.${NC}" >&2
    echo -e "${YELLOW}For help, visit: https://github.com/MarcinDudekDev/nginx-optimizer/issues${NC}" >&2
    exit "$exit_code"
}

# Print functions
print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}" >&2
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_info() {
    echo -e "${BLUE}→ $1${NC}"
}

print_header() {
    echo ""
    echo -e "${BLUE}=====================================${NC}"
    echo -e "${BLUE}  nginx-optimizer Installer${NC}"
    echo -e "${BLUE}=====================================${NC}"
    echo ""
}

# Detect OS
detect_os() {
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        OS="Linux"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macOS"
    else
        OS="Unknown"
    fi
}

# Check prerequisites
check_prerequisites() {
    print_info "Checking prerequisites..."

    local missing_tools=()

    # Check for git (required)
    if ! command -v git &> /dev/null; then
        missing_tools+=("git")
    fi

    # Check for curl (optional, but helpful)
    if ! command -v curl &> /dev/null; then
        print_warning "curl not found (recommended)"
    fi

    # Check for jq (optional)
    if ! command -v jq &> /dev/null; then
        print_warning "jq not found (recommended for JSON operations)"
    fi

    if [ ${#missing_tools[@]} -gt 0 ]; then
        print_error "Missing required tools: ${missing_tools[*]}"
        echo ""
        if [[ "$OS" == "Linux" ]]; then
            echo "Install with: sudo apt-get install ${missing_tools[*]} || sudo yum install ${missing_tools[*]}"
        elif [[ "$OS" == "macOS" ]]; then
            echo "Install with: brew install ${missing_tools[*]}"
        fi
        exit 1
    fi

    print_success "Prerequisites check passed"
}

# Install or update
install_or_update() {
    if [[ -d "$INSTALL_DIR" ]]; then
        print_warning "Directory already exists: $INSTALL_DIR"
        echo ""
        read -p "Update existing installation? [y/N] " -n 1 -r
        echo ""

        if [[ $REPLY =~ ^[Yy]$ ]]; then
            print_info "Updating nginx-optimizer..."
            cd "$INSTALL_DIR"

            # Stash any local changes
            if [[ -n $(git status -s) ]]; then
                print_warning "Stashing local changes..."
                git stash
            fi

            git pull origin main
            print_success "Updated to latest version"
        else
            print_info "Skipping update"
            return 0
        fi
    else
        print_info "Installing nginx-optimizer to: $INSTALL_DIR"
        git clone "$REPO_URL" "$INSTALL_DIR"
        print_success "Cloned repository"
    fi
}

# Make executable
make_executable() {
    print_info "Making script executable..."
    chmod +x "$INSTALL_DIR/nginx-optimizer.sh"
    print_success "Script is now executable"
}

# Setup PATH
setup_path() {
    print_info "Setting up PATH..."

    # Try to create symlink in /usr/local/bin
    if [[ -d "/usr/local/bin" ]] && [[ -w "/usr/local/bin" ]]; then
        ln -sf "$INSTALL_DIR/nginx-optimizer.sh" /usr/local/bin/nginx-optimizer
        print_success "Created symlink: /usr/local/bin/nginx-optimizer"
        SYMLINK_CREATED=true
    elif [[ -d "/usr/local/bin" ]] && ! [[ -w "/usr/local/bin" ]]; then
        # Try with sudo
        print_warning "/usr/local/bin exists but is not writable"
        read -p "Try creating symlink with sudo? [y/N] " -n 1 -r
        echo ""

        if [[ $REPLY =~ ^[Yy]$ ]]; then
            sudo ln -sf "$INSTALL_DIR/nginx-optimizer.sh" /usr/local/bin/nginx-optimizer
            print_success "Created symlink: /usr/local/bin/nginx-optimizer (with sudo)"
            SYMLINK_CREATED=true
        else
            SYMLINK_CREATED=false
        fi
    else
        SYMLINK_CREATED=false
    fi

    if [[ "$SYMLINK_CREATED" != "true" ]]; then
        print_warning "Symlink not created. Add to your PATH manually:"
        echo ""
        echo "  For bash (~/.bashrc):"
        echo "    echo 'export PATH=\"\$PATH:$INSTALL_DIR\"' >> ~/.bashrc"
        echo "    source ~/.bashrc"
        echo ""
        echo "  For zsh (~/.zshrc):"
        echo "    echo 'export PATH=\"\$PATH:$INSTALL_DIR\"' >> ~/.zshrc"
        echo "    source ~/.zshrc"
        echo ""
    fi
}

# Show success message
show_success() {
    echo ""
    echo -e "${GREEN}=====================================${NC}"
    echo -e "${GREEN}  Installation Complete!${NC}"
    echo -e "${GREEN}=====================================${NC}"
    echo ""

    # Show version
    print_info "Installed version:"
    "$INSTALL_DIR/nginx-optimizer.sh" --version || echo "  nginx-optimizer 0.9.0-beta"
    echo ""

    # Show usage
    print_info "Quick start:"
    if [[ "$SYMLINK_CREATED" == "true" ]]; then
        echo "  nginx-optimizer              # Interactive wizard"
        echo "  nginx-optimizer analyze      # Analyze current setup"
        echo "  nginx-optimizer optimize     # Apply optimizations"
        echo "  nginx-optimizer help         # Show all commands"
    else
        echo "  $INSTALL_DIR/nginx-optimizer.sh              # Interactive wizard"
        echo "  $INSTALL_DIR/nginx-optimizer.sh analyze      # Analyze current setup"
        echo "  $INSTALL_DIR/nginx-optimizer.sh optimize     # Apply optimizations"
        echo "  $INSTALL_DIR/nginx-optimizer.sh help         # Show all commands"
    fi
    echo ""

    print_success "Ready to optimize NGINX!"
    echo ""
}

# Main installation flow
main() {
    SYMLINK_CREATED=false

    print_header

    detect_os
    print_info "Detected OS: $OS"

    check_prerequisites
    install_or_update
    make_executable
    setup_path
    show_success
}

# Run main
main
