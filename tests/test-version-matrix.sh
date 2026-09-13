#!/bin/bash
# Docker-based nginx VERSION MATRIX validation
#
# test-with-nginx.sh proves the corpus and templates parse on ONE nginx —
# whatever nginx:latest is today. This script proves the portable parts still
# parse on the OLDEST versions we claim to support, and that fixtures using
# directives introduced on newer nginx are skipped — not failed — on versions
# too old to have them.
#
# Matrix: nginx:1.18, 1.22, 1.25, 1.27 (official Docker Hub tags).
#   - minimal full config + portable http-context templates: PASS on all four
#   - HTTP/3 / quic / `http2 on;` / early_hints fixtures: SKIP below their
#     minimum version, RUN at or above it
#
# Same contract as test-with-nginx.sh: Docker missing or daemon down exits 0.
# A missing Docker Hub tag skips THAT version with a reason, never the run.

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
echo "  nginx Version Matrix Validation (Docker)"
echo "=========================================="

# Check Docker availability — same skip contract as test-with-nginx.sh
if ! command -v docker &>/dev/null; then
    echo "Docker not available - skipping all tests"
    exit 0
fi

if ! docker info &>/dev/null 2>&1; then
    echo "Docker daemon not running - skipping all tests"
    exit 0
fi

MATRIX_VERSIONS="1.18 1.22 1.25 1.27"

# Minimal valid fixture: a complete upstream-default nginx.conf. Mounted as
# /etc/nginx/nginx.conf (not conf.d) — it already carries events{} and http{}.
MINIMAL_FIXTURE="${CONFIGS_DIR}/minimal/nginx-official-default.conf"

# http-context templates that must parse on EVERY version in the matrix:
# gzip and open_file_cache predate 1.18 by a decade. compression.conf's brotli
# lines are commented out — stock images carry no brotli module, so this file
# is intentionally gzip-only here (compiling brotli for the matrix is out of
# scope; see the issue).
PORTABLE_TEMPLATES="compression.conf open-file-cache.conf"

# Version-gated fixtures, one per line: "path|min-version|label".
# Below min-version they log SKIP; at or above it `nginx -t` must pass.
# early_hints needs nginx 1.29 — newer than the whole matrix — so today it
# exercises the skip path on every row; it starts running by itself the day a
# >=1.29 tag joins MATRIX_VERSIONS.
GATED_FIXTURES="
${CONFIGS_DIR}/tls/http3-quic.conf|1.25|tls/http3-quic.conf (listen quic, http2 on, http3 on)
${TEMPLATES_DIR}/early-hints.conf|1.29|early-hints.conf (early_hints on)
"

################################################################################
# Helpers
################################################################################

# Numeric dotted compare, bash 3.2-safe: version_lt 1.9 1.18 -> true.
# (String compare would lie there — '9' > '1' lexically.)
version_lt() {
    local a_maj="${1%%.*}" a_min="${1#*.}"
    local b_maj="${2%%.*}" b_min="${2#*.}"
    a_min="${a_min%%.*}"
    b_min="${b_min%%.*}"
    if [ "$a_maj" -eq "$b_maj" ]; then
        [ "$a_min" -lt "$b_min" ]
    else
        [ "$a_maj" -lt "$b_maj" ]
    fi
}

# Returns 0 when the image is runnable (already cached, or pulled now).
# On failure sets MATRIX_SKIP_REASON for the caller's skip line — "tag gone"
# and "registry unreachable" are different reasons, not one shrug.
MATRIX_SKIP_REASON=""
ensure_image() {
    local image="$1"
    if docker image inspect "$image" >/dev/null 2>&1; then
        return 0
    fi
    if docker pull -q "$image" >/dev/null 2>&1; then
        return 0
    fi
    if docker manifest inspect "$image" >/dev/null 2>&1; then
        MATRIX_SKIP_REASON="tag exists on Docker Hub but pull failed"
    else
        MATRIX_SKIP_REASON="tag not found on Docker Hub (or registry unreachable)"
    fi
    return 1
}

# Runs `nginx -t` inside image $1 with the given -v mounts (pass -v args first,
# image is appended). On failure, NGINX_T_ERR carries the first real nginx
# error line for the caller's log line.
NGINX_T_ERR=""
nginx_t() {
    local image="$1" out
    shift
    if out=$(docker run --rm "$@" "$image" nginx -t 2>&1); then
        NGINX_T_ERR=""
        return 0
    fi
    NGINX_T_ERR=$(printf '%s\n' "$out" | grep -E "emerg|error" | grep -v "docker-entrypoint" | head -1 || true)
    return 1
}

################################################################################
# Setup: self-signed cert for fixtures that reference ssl_certificate
################################################################################

CERT_DIR=$(mktemp -d)
openssl req -x509 -nodes -days 1 -newkey rsa:2048 \
    -keyout "$CERT_DIR/privkey.pem" \
    -out "$CERT_DIR/fullchain.pem" \
    -subj "/CN=test.example.com" 2>/dev/null

################################################################################
# Matrix run
################################################################################

for ver in $MATRIX_VERSIONS; do
    image="nginx:${ver}"
    echo ""
    echo "--- nginx:${ver} ---"

    if ! ensure_image "$image"; then
        log_skip "nginx:${ver} — ${MATRIX_SKIP_REASON}"
        continue
    fi

    # 1. Minimal full config — must parse on every supported version.
    if nginx_t "$image" -v "${MINIMAL_FIXTURE}:/etc/nginx/nginx.conf:ro"; then
        log_pass "nginx:${ver} minimal fixture (full nginx.conf)"
    else
        log_fail "nginx:${ver} minimal fixture rejected: ${NGINX_T_ERR}"
    fi

    # 2. Portable http-context templates — wrapped in a generated full config,
    #    same shape as test-with-nginx.sh's generic wrapper.
    for tmpl in $PORTABLE_TEMPLATES; do
        tmpdir=$(mktemp -d)
        cat > "$tmpdir/nginx.conf" <<WRAPPER
events { worker_connections 1024; }
http {
    include /etc/nginx/templates/${tmpl};
    server {
        listen 80;
        server_name localhost;
        location / { return 200 'ok'; }
    }
}
WRAPPER
        if nginx_t "$image" \
            -v "$tmpdir/nginx.conf:/etc/nginx/nginx.conf:ro" \
            -v "${TEMPLATES_DIR}/${tmpl}:/etc/nginx/templates/${tmpl}:ro"; then
            log_pass "nginx:${ver} template ${tmpl} (http context)"
        else
            log_fail "nginx:${ver} template ${tmpl} failed on a version that must support it: ${NGINX_T_ERR}"
        fi
        rm -rf "$tmpdir"
    done

    # 3. Version-gated fixtures — server-context snippets mounted into conf.d/
    #    (the image's stock nginx.conf already includes conf.d/*.conf inside
    #    http{}). Below their min-version they must SKIP, never FAIL.
    while IFS='|' read -r fpath minver label; do
        [ -n "$fpath" ] || continue
        if version_lt "$ver" "$minver"; then
            log_skip "nginx:${ver} ${label} — needs nginx >= ${minver}"
            continue
        fi

        if grep -q "ssl_certificate" "$fpath" 2>/dev/null; then
            # Rewrite cert paths to the generated self-signed pair — same sed
            # pipeline as test-with-nginx.sh (key/trusted/client anchored
            # before the bare ssl_certificate pattern so it can't swallow them).
            tmpdir=$(mktemp -d)
            sed \
                -e 's|ssl_certificate_key .*|ssl_certificate_key /etc/nginx/ssl/privkey.pem;|g' \
                -e 's|ssl_trusted_certificate .*|ssl_trusted_certificate /etc/nginx/ssl/fullchain.pem;|g' \
                -e 's|ssl_client_certificate .*|ssl_client_certificate /etc/nginx/ssl/fullchain.pem;|g' \
                -e 's|ssl_certificate .*|ssl_certificate /etc/nginx/ssl/fullchain.pem;|g' \
                "$fpath" > "$tmpdir/test.conf"
            if nginx_t "$image" \
                -v "$tmpdir/test.conf:/etc/nginx/conf.d/test.conf:ro" \
                -v "$CERT_DIR/fullchain.pem:/etc/nginx/ssl/fullchain.pem:ro" \
                -v "$CERT_DIR/privkey.pem:/etc/nginx/ssl/privkey.pem:ro"; then
                log_pass "nginx:${ver} ${label}"
            else
                log_fail "nginx:${ver} ${label} rejected: ${NGINX_T_ERR}"
            fi
            rm -rf "$tmpdir"
        else
            if nginx_t "$image" -v "$fpath:/etc/nginx/conf.d/test.conf:ro"; then
                log_pass "nginx:${ver} ${label}"
            else
                log_fail "nginx:${ver} ${label} rejected: ${NGINX_T_ERR}"
            fi
        fi
    done <<< "$GATED_FIXTURES"
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
