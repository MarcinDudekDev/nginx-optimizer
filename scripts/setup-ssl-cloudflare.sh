#!/bin/bash
################################################################################
# setup-ssl-cloudflare.sh - Certbot SSL with CloudFlare DNS Challenge
# For Mikr.us and other IPv6-first servers where HTTP challenge won't work
################################################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Configuration
CF_CREDENTIALS="/root/.secrets/cloudflare.ini"
NGINX_SITES="/etc/nginx/sites-enabled"
NGINX_AVAILABLE="/etc/nginx/sites-available"

show_help() {
    cat << 'EOF'
Usage: setup-ssl-cloudflare.sh [OPTIONS] <domain>

Setup SSL certificate using Let's Encrypt with CloudFlare DNS challenge.
Configures nginx with HTTP/3 (QUIC) support.

OPTIONS:
    -w, --www           Also include www subdomain
    -e, --email EMAIL   Email for Let's Encrypt notifications
    --dry-run           Test without making changes
    -h, --help          Show this help

PREREQUISITES:
    1. CloudFlare managing your DNS
    2. API token with "Edit zone DNS" permission
    3. Credentials file at /root/.secrets/cloudflare.ini containing:
       dns_cloudflare_api_token = YOUR_TOKEN_HERE

EXAMPLES:
    setup-ssl-cloudflare.sh example.com
    setup-ssl-cloudflare.sh -w example.com
    setup-ssl-cloudflare.sh -w -e admin@example.com example.com

EOF
}

# Parse arguments
DOMAIN=""
INCLUDE_WWW=false
EMAIL=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -w|--www)
            INCLUDE_WWW=true
            shift
            ;;
        -e|--email)
            EMAIL="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
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
            DOMAIN="$1"
            shift
            ;;
    esac
done

if [ -z "$DOMAIN" ]; then
    log_error "Domain required"
    show_help
    exit 1
fi

################################################################################
# Pre-flight checks
################################################################################

log_info "Checking prerequisites..."

# Check root
if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root"
    exit 1
fi

# Check CloudFlare credentials
if [ ! -f "$CF_CREDENTIALS" ]; then
    log_error "CloudFlare credentials not found at $CF_CREDENTIALS"
    echo ""
    echo "Create the file with:"
    echo "  mkdir -p /root/.secrets"
    echo "  nano /root/.secrets/cloudflare.ini"
    echo ""
    echo "Add this content:"
    echo "  dns_cloudflare_api_token = YOUR_TOKEN_HERE"
    echo ""
    echo "Then secure it:"
    echo "  chmod 600 /root/.secrets/cloudflare.ini"
    exit 1
fi

# Check credentials file permissions
perms=$(stat -c %a "$CF_CREDENTIALS" 2>/dev/null || stat -f %Lp "$CF_CREDENTIALS" 2>/dev/null)
if [ "$perms" != "600" ]; then
    log_warn "Fixing credentials file permissions..."
    chmod 600 "$CF_CREDENTIALS"
fi

log_success "Prerequisites OK"

################################################################################
# Install certbot
################################################################################

install_certbot() {
    log_info "Checking certbot installation..."

    if command -v certbot &>/dev/null; then
        log_info "Certbot already installed: $(certbot --version 2>&1 | head -1)"

        # Check for cloudflare plugin
        if ! certbot plugins 2>/dev/null | grep -q cloudflare; then
            log_info "Installing CloudFlare plugin..."
            apt-get update
            apt-get install -y python3-certbot-dns-cloudflare
        fi
    else
        log_info "Installing certbot with CloudFlare plugin..."
        apt-get update
        apt-get install -y certbot python3-certbot-dns-cloudflare
    fi

    log_success "Certbot ready"
}

################################################################################
# Get certificate
################################################################################

get_certificate() {
    log_info "Requesting certificate for $DOMAIN..."

    # Build domain list
    local domains="-d $DOMAIN"
    if [ "$INCLUDE_WWW" = true ]; then
        domains="$domains -d www.$DOMAIN"
    fi

    # Build certbot command
    local cmd="certbot certonly --dns-cloudflare"
    cmd="$cmd --dns-cloudflare-credentials $CF_CREDENTIALS"
    cmd="$cmd $domains"
    cmd="$cmd --non-interactive --agree-tos"

    if [ -n "$EMAIL" ]; then
        cmd="$cmd --email $EMAIL"
    else
        cmd="$cmd --register-unsafely-without-email"
    fi

    if [ "$DRY_RUN" = true ]; then
        cmd="$cmd --dry-run"
        log_warn "DRY RUN - no certificate will be issued"
    fi

    # Run certbot
    echo ""
    log_info "Running: $cmd"
    echo ""

    eval $cmd

    if [ "$DRY_RUN" = false ]; then
        log_success "Certificate obtained!"
        log_info "Certificate: /etc/letsencrypt/live/$DOMAIN/fullchain.pem"
        log_info "Private key: /etc/letsencrypt/live/$DOMAIN/privkey.pem"
    fi
}

################################################################################
# Configure nginx
################################################################################

configure_nginx() {
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would configure nginx for $DOMAIN"
        return
    fi

    log_info "Configuring nginx for $DOMAIN..."

    # Check if nginx is installed
    if ! command -v nginx &>/dev/null; then
        log_warn "Nginx not installed, skipping nginx configuration"
        log_info "Install nginx and run this script again, or configure manually"
        return
    fi

    local conf_file="$NGINX_AVAILABLE/$DOMAIN"

    # Backup existing config
    if [ -f "$conf_file" ]; then
        cp "$conf_file" "${conf_file}.bak.$(date +%Y%m%d-%H%M%S)"
        log_info "Backed up existing config"
    fi

    # Get server IPv6
    local ipv6=$(ip -6 addr show scope global | grep -oP '(?<=inet6\s)[\da-f:]+' | head -1)

    # Determine www handling
    local server_names="$DOMAIN"
    if [ "$INCLUDE_WWW" = true ]; then
        server_names="$DOMAIN www.$DOMAIN"
    fi

    # Create nginx config with HTTP/3
    cat > "$conf_file" << EOF
# HTTP to HTTPS redirect
server {
    listen [::]:80;
    server_name $server_names;
    return 301 https://\$host\$request_uri;
}

# HTTPS with HTTP/3
server {
    # IPv6 SSL (Mikr.us is IPv6-first)
    listen [::]:443 ssl http2;
    listen [::]:443 quic reuseport;

    server_name $server_names;

    # SSL Certificate (Let's Encrypt)
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    # SSL Configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;

    # OCSP Stapling
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 1.1.1.1 1.0.0.1 valid=300s;
    resolver_timeout 5s;

    # HTTP/3 (QUIC)
    add_header Alt-Svc 'h3=":443"; ma=86400' always;

    # Security Headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # Document root - adjust as needed
    root /var/www/$DOMAIN;
    index index.html index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    # PHP-FPM (uncomment and adjust socket path if needed)
    # location ~ \.php\$ {
    #     include snippets/fastcgi-php.conf;
    #     fastcgi_pass unix:/run/php/php8.2-fpm.sock;
    # }

    # Deny access to hidden files
    location ~ /\. {
        deny all;
    }
}
EOF

    # Create document root if it doesn't exist
    if [ ! -d "/var/www/$DOMAIN" ]; then
        mkdir -p "/var/www/$DOMAIN"
        echo "<h1>$DOMAIN</h1><p>SSL with HTTP/3 configured!</p>" > "/var/www/$DOMAIN/index.html"
        log_info "Created document root: /var/www/$DOMAIN"
    fi

    # Enable site
    if [ ! -L "$NGINX_SITES/$DOMAIN" ]; then
        ln -sf "$conf_file" "$NGINX_SITES/$DOMAIN"
    fi

    # Test nginx config
    if nginx -t 2>&1; then
        log_success "Nginx configuration valid"

        # Reload nginx
        systemctl reload nginx || service nginx reload
        log_success "Nginx reloaded"
    else
        log_error "Nginx configuration invalid!"
        log_info "Check: $conf_file"
        return 1
    fi
}

################################################################################
# Setup auto-renewal
################################################################################

setup_renewal() {
    if [ "$DRY_RUN" = true ]; then
        return
    fi

    log_info "Checking auto-renewal..."

    # Check if systemd timer exists
    if systemctl list-timers | grep -q certbot; then
        log_success "Auto-renewal already configured (systemd timer)"
    else
        # Add cron job as fallback
        if ! crontab -l 2>/dev/null | grep -q certbot; then
            (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --deploy-hook 'systemctl reload nginx'") | crontab -
            log_success "Auto-renewal cron job added"
        else
            log_info "Certbot cron job already exists"
        fi
    fi

    # Test renewal
    log_info "Testing renewal (dry-run)..."
    certbot renew --dry-run 2>&1 | tail -3
}

################################################################################
# CloudFlare instructions
################################################################################

show_cloudflare_instructions() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo -e "${GREEN}SSL Certificate Ready!${NC}"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "Now update CloudFlare settings:"
    echo ""
    echo "  1. SSL/TLS → Overview → Select: ${GREEN}Full (strict)${NC}"
    echo ""
    echo "  2. DNS → Verify AAAA record points to your IPv6"
    echo "     (Keep orange cloud enabled for proxy)"
    echo ""
    echo "  3. Test HTTP/3:"
    echo "     curl -I --http3 https://$DOMAIN"
    echo "     Or use: https://http3check.net/?host=$DOMAIN"
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
}

################################################################################
# Main
################################################################################

main() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║     SSL Setup with CloudFlare DNS Challenge + HTTP/3      ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    install_certbot
    get_certificate
    configure_nginx
    setup_renewal

    if [ "$DRY_RUN" = false ]; then
        show_cloudflare_instructions
    fi
}

main
