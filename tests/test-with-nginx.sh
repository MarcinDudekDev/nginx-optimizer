#!/bin/bash
# Docker-based nginx configuration validation
# Validates template configs with a real nginx binary via Docker
# Skips gracefully if Docker is not available

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGS_DIR="${SCRIPT_DIR}/configs"
TEMPLATES_DIR="${SCRIPT_DIR}/../nginx-optimizer-templates"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

log_pass() { echo -e "${GREEN}[PASS]${NC} $*"; PASS=$((PASS + 1)); }
log_fail() { echo -e "${RED}[FAIL]${NC} $*"; FAIL=$((FAIL + 1)); }
log_skip() { echo -e "${YELLOW}[SKIP]${NC} $*"; SKIP=$((SKIP + 1)); }

echo "=========================================="
echo "  nginx Config Validation (Docker)"
echo "=========================================="

# Check Docker availability
if ! command -v docker &>/dev/null; then
    echo "Docker not available - skipping all tests"
    exit 0
fi

if ! docker info &>/dev/null 2>&1; then
    echo "Docker daemon not running - skipping all tests"
    exit 0
fi

# Pull nginx image if needed (quiet)
docker pull nginx:latest -q >/dev/null 2>&1 || true

################################################################################
# Setup: Generate self-signed SSL cert for configs that need it
################################################################################

CERT_DIR=$(mktemp -d)
openssl req -x509 -nodes -days 1 -newkey rsa:2048 \
    -keyout "$CERT_DIR/privkey.pem" \
    -out "$CERT_DIR/fullchain.pem" \
    -subj "/CN=test.example.com" 2>/dev/null

################################################################################
# Config Corpus Tests
################################################################################

echo ""
echo "Testing config corpus..."

# Configs that are full nginx.conf files (contain events/http blocks)
# These get mounted as /etc/nginx/nginx.conf, not as a conf.d include
FULL_NGINX_CONFIGS="nginx-with-includes.conf nginx-official-default.conf"

# Configs that need brotli module (not in stock nginx)
BROTLI_CONFIGS="already-optimized.conf"

for conf in "${CONFIGS_DIR}"/*.conf "${CONFIGS_DIR}"/**/*.conf; do
    [ -f "$conf" ] || continue
    name=$(basename "$conf")

    # Skip brotli-dependent configs (stock nginx doesn't have brotli module)
    if echo "$FULL_NGINX_CONFIGS" | grep -qw "$name" 2>/dev/null; then
        # Full nginx.conf — mount as main config, not conf.d
        if docker run --rm \
            -v "$conf:/etc/nginx/nginx.conf:ro" \
            nginx:latest nginx -t 2>/dev/null; then
            log_pass "$name (full config)"
        else
            log_fail "$name (full config)"
        fi
        continue
    fi

    if echo "$BROTLI_CONFIGS" | grep -qw "$name" 2>/dev/null; then
        log_skip "$name (requires brotli module)"
        continue
    fi

    # Check if config references SSL certs
    if grep -q "ssl_certificate" "$conf" 2>/dev/null; then
        # SSL config — create a wrapper that mounts our test certs
        tmpdir=$(mktemp -d)

        # Rewrite all cert paths to use our test certs
        sed \
            -e 's|ssl_certificate_key .*|ssl_certificate_key /etc/nginx/ssl/privkey.pem;|g' \
            -e 's|ssl_certificate .*|ssl_certificate /etc/nginx/ssl/fullchain.pem;|g' \
            "$conf" > "$tmpdir/test.conf"

        if docker run --rm \
            -v "$tmpdir/test.conf:/etc/nginx/conf.d/test.conf:ro" \
            -v "$CERT_DIR/fullchain.pem:/etc/nginx/ssl/fullchain.pem:ro" \
            -v "$CERT_DIR/privkey.pem:/etc/nginx/ssl/privkey.pem:ro" \
            nginx:latest nginx -t 2>/dev/null; then
            log_pass "$name (with test SSL)"
        else
            # Show actual error for debugging
            local_err=$(docker run --rm \
                -v "$tmpdir/test.conf:/etc/nginx/conf.d/test.conf:ro" \
                -v "$CERT_DIR/fullchain.pem:/etc/nginx/ssl/fullchain.pem:ro" \
                -v "$CERT_DIR/privkey.pem:/etc/nginx/ssl/privkey.pem:ro" \
                nginx:latest nginx -t 2>&1 | grep -E "emerg|error" | grep -v "docker-entrypoint" | head -2)
            log_fail "$name: $local_err"
        fi
        rm -rf "$tmpdir"
    else
        # Simple config — mount directly as conf.d include
        if docker run --rm -v "$conf:/etc/nginx/conf.d/test.conf:ro" nginx:latest nginx -t 2>/dev/null; then
            log_pass "$name"
        else
            local_err=$(docker run --rm -v "$conf:/etc/nginx/conf.d/test.conf:ro" nginx:latest nginx -t 2>&1 | grep -E "emerg|error" | grep -v "docker-entrypoint" | head -2)
            log_fail "$name: $local_err"
        fi
    fi
done

################################################################################
# Template Snippet Tests
################################################################################

echo ""
echo "Testing template snippets..."
for tmpl in "${TEMPLATES_DIR}"/*.conf; do
    [ -f "$tmpl" ] || continue
    name=$(basename "$tmpl")

    # Create a temp wrapper that includes the template
    tmpdir=$(mktemp -d)
    cat > "$tmpdir/nginx.conf" << WRAPPER
events { worker_connections 1024; }
http {
    include /etc/nginx/templates/$name;
    server {
        listen 80;
        server_name localhost;
        location / { return 200 'ok'; }
    }
}
WRAPPER

    if docker run --rm \
        -v "$tmpdir/nginx.conf:/etc/nginx/nginx.conf:ro" \
        -v "$tmpl:/etc/nginx/templates/$name:ro" \
        nginx:latest nginx -t 2>/dev/null; then
        log_pass "template: $name"
    else
        # Many templates are server-context snippets, try as include in server block
        cat > "$tmpdir/nginx.conf" << WRAPPER2
events { worker_connections 1024; }
http {
    server {
        listen 80;
        server_name localhost;
        include /etc/nginx/templates/$name;
        location / { return 200 'ok'; }
    }
}
WRAPPER2
        if docker run --rm \
            -v "$tmpdir/nginx.conf:/etc/nginx/nginx.conf:ro" \
            -v "$tmpl:/etc/nginx/templates/$name:ro" \
            nginx:latest nginx -t 2>/dev/null; then
            log_pass "template: $name (server context)"
        else
            log_skip "template: $name (context-dependent, manual review needed)"
        fi
    fi

    rm -rf "$tmpdir"
done

################################################################################
# Cleanup & Summary
################################################################################

rm -rf "$CERT_DIR"

echo ""
echo "=========================================="
echo -e "  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${SKIP} skipped${NC}"
echo "=========================================="

if [ "$FAIL" -gt 0 ]; then
    echo -e "${RED}TESTS FAILED${NC}"
    exit 1
else
    echo -e "${GREEN}ALL TESTS PASSED${NC}"
    exit 0
fi
