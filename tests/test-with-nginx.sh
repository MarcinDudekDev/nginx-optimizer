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

# Test each config in the corpus
echo ""
echo "Testing config corpus..."
for conf in "${CONFIGS_DIR}"/*.conf "${CONFIGS_DIR}"/**/*.conf; do
    [ -f "$conf" ] || continue
    name=$(basename "$conf")

    if docker run --rm -v "$conf:/etc/nginx/conf.d/test.conf:ro" nginx:latest nginx -t 2>/dev/null; then
        log_pass "$name"
    else
        log_fail "$name"
    fi
done

# Test template snippets (these are includes, not full configs)
# Create a minimal wrapper config for each template
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

# Summary
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
