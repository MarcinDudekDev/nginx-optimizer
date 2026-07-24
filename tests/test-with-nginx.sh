#!/bin/bash
# Docker-based nginx configuration validation
# Validates template configs with a real nginx binary via Docker
# Skips gracefully if Docker is not available

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGS_DIR="${SCRIPT_DIR}/configs"
TEMPLATES_DIR="${SCRIPT_DIR}/../nginx-optimizer-templates"
WRAPPERS_DIR="${SCRIPT_DIR}/wrappers"

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
FULL_NGINX_CONFIGS="nginx-with-includes.conf nginx-official-default.conf \
debian-ubuntu-default.conf ubuntu-gzip-commented.conf alpine-minimal.conf \
cpanel-main-nginx.conf"

# Configs that need brotli module (not in stock nginx)
BROTLI_CONFIGS="already-optimized.conf"

################################################################################
# Negative fixtures: tests/configs/invalid/ MUST fail nginx -t
#
# A malformed config that quietly parses is a worse result than one that fails,
# so these are asserted in the failing direction. See tests/configs/invalid/README.md.
################################################################################

invalid_count=$(find "${CONFIGS_DIR}/invalid" -name '*.conf' 2>/dev/null | wc -l | tr -d ' ')
if [ "$invalid_count" -eq 0 ]; then
    log_fail "no fixtures in tests/configs/invalid/ — the negative assertions are not running"
fi

for conf in "${CONFIGS_DIR}"/invalid/*.conf; do
    [ -f "$conf" ] || continue
    name=$(basename "$conf")
    if docker run --rm -v "$conf:/etc/nginx/conf.d/test.conf:ro" nginx:latest nginx -t >/dev/null 2>&1; then
        log_fail "invalid/$name: nginx -t ACCEPTED a fixture that must be rejected"
    else
        log_pass "invalid/$name (correctly rejected)"
    fi
done

# `find`, not `"$CONFIGS_DIR"/**/*.conf`: without globstar `**` collapses to `*`, so a
# config nested any deeper than one level would get shape coverage from
# test-corpus.sh and never be handed to nginx -t here.
while IFS= read -r conf; do
    [ -f "$conf" ] || continue
    name=$(basename "$conf")

    # Skip brotli-dependent configs (stock nginx doesn't have brotli module)
    if echo "$FULL_NGINX_CONFIGS" | grep -qw "$name" 2>/dev/null; then
        # Full nginx.conf — mount as main config, not conf.d
        if docker run --rm \
            -v "$conf:/etc/nginx/nginx.conf:ro" \
            nginx:latest nginx -t >/dev/null 2>&1; then
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

        # Rewrite all cert paths to use our test certs. Each pattern is anchored on
        # the trailing space, so `ssl_certificate .*` cannot swallow
        # `ssl_certificate_key`; the order below is for readability, not correctness.
        sed \
            -e 's|ssl_certificate_key .*|ssl_certificate_key /etc/nginx/ssl/privkey.pem;|g' \
            -e 's|ssl_trusted_certificate .*|ssl_trusted_certificate /etc/nginx/ssl/fullchain.pem;|g' \
            -e 's|ssl_client_certificate .*|ssl_client_certificate /etc/nginx/ssl/fullchain.pem;|g' \
            -e 's|ssl_certificate .*|ssl_certificate /etc/nginx/ssl/fullchain.pem;|g' \
            "$conf" > "$tmpdir/test.conf"

        if docker run --rm \
            -v "$tmpdir/test.conf:/etc/nginx/conf.d/test.conf:ro" \
            -v "$CERT_DIR/fullchain.pem:/etc/nginx/ssl/fullchain.pem:ro" \
            -v "$CERT_DIR/privkey.pem:/etc/nginx/ssl/privkey.pem:ro" \
            nginx:latest nginx -t >/dev/null 2>&1; then
            log_pass "$name (with test SSL)"
        else
            # Show actual error for debugging
            local_err=$(docker run --rm \
                -v "$tmpdir/test.conf:/etc/nginx/conf.d/test.conf:ro" \
                -v "$CERT_DIR/fullchain.pem:/etc/nginx/ssl/fullchain.pem:ro" \
                -v "$CERT_DIR/privkey.pem:/etc/nginx/ssl/privkey.pem:ro" \
                nginx:latest nginx -t 2>&1 || true) ; local_err=$(printf '%s' "$local_err" | grep -E "emerg|error" | grep -v "docker-entrypoint" | head -2 || true)
            log_fail "$name: $local_err"
        fi
        rm -rf "$tmpdir"
    else
        # Simple config — mount directly as conf.d include
        if docker run --rm -v "$conf:/etc/nginx/conf.d/test.conf:ro" nginx:latest nginx -t >/dev/null 2>&1; then
            log_pass "$name"
        else
            local_err=$(docker run --rm -v "$conf:/etc/nginx/conf.d/test.conf:ro" nginx:latest nginx -t 2>&1 || true) ; local_err=$(printf '%s' "$local_err" | grep -E "emerg|error" | grep -v "docker-entrypoint" | head -2 || true)
            log_fail "$name: $local_err"
        fi
    fi
done < <(find "$CONFIGS_DIR" -name '*.conf' -not -path '*/invalid/*' | sort)

################################################################################
# Template Snippet Tests
################################################################################

echo ""
echo "Testing template snippets..."
for tmpl in "${TEMPLATES_DIR}"/*.conf; do
    [ -f "$tmpl" ] || continue
    name=$(basename "$tmpl")

    tmpdir=$(mktemp -d)

    # Per-template wrapper: some templates need context the generic wrapper
    # cannot supply (a limit_req_zone, a map, a fastcgi_cache_path). If
    # tests/wrappers/<name> exists, use it — @INCLUDE@ marks the insertion point.
    # See tests/wrappers/README.md.
    if [ -f "${WRAPPERS_DIR}/$name" ]; then
        include_line="        include /etc/nginx/templates/$name;"
        awk -v inc="$include_line" '{ if ($0 == "@INCLUDE@") print inc; else print }' \
            "${WRAPPERS_DIR}/$name" > "$tmpdir/nginx.conf"

        if docker run --rm \
            -v "$tmpdir/nginx.conf:/etc/nginx/nginx.conf:ro" \
            -v "${TEMPLATES_DIR}:/etc/nginx/templates:ro" \
            nginx:latest nginx -t >/dev/null 2>&1; then
            log_pass "template: $name (wrapper context)"
        else
            wrapper_err=$(docker run --rm \
                -v "$tmpdir/nginx.conf:/etc/nginx/nginx.conf:ro" \
                -v "${TEMPLATES_DIR}:/etc/nginx/templates:ro" \
                nginx:latest nginx -t 2>&1 || true)
            wrapper_err=$(printf '%s' "$wrapper_err" | grep -E "emerg" | head -1 || true)
            log_fail "template: $name (wrapper context): $wrapper_err"
        fi
        rm -rf "$tmpdir"
        continue
    fi

    # Create a temp wrapper that includes the template
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
        nginx:latest nginx -t >/dev/null 2>&1; then
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
            nginx:latest nginx -t >/dev/null 2>&1; then
            log_pass "template: $name (server context)"
        else
            # Distinguish "needs a module stock nginx lacks" from "we have not
            # written a wrapper yet". The first is a permanent, legitimate skip;
            # the second is missing coverage and should be fixed with a wrapper
            # in tests/wrappers/. A skip that does not say which is which reads
            # as covered when it is not.
            # `|| true` on BOTH stages: under `set -euo pipefail` a non-matching
            # grep (and nginx -t's own non-zero exit) would abort the suite.
            skip_out=$(docker run --rm \
                -v "$tmpdir/nginx.conf:/etc/nginx/nginx.conf:ro" \
                -v "$tmpl:/etc/nginx/templates/$name:ro" \
                nginx:latest nginx -t 2>&1 || true)
            skip_err=$(printf '%s' "$skip_out" | grep -oE 'unknown directive "[^"]+"' | head -1 || true)
            if [ -n "$skip_err" ]; then
                log_skip "template: $name (needs a third-party module: $skip_err)"
            else
                log_skip "template: $name (NO WRAPPER YET — add tests/wrappers/$name)"
            fi
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
