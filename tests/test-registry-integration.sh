#!/bin/bash
################################################################################
# test-registry-integration.sh - Verify registry integration
################################################################################
# Run from project root: ./tests/test-registry-integration.sh
################################################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Counters
PASS=0
FAIL=0

# Test helpers
pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    PASS=$((PASS + 1))
}

fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    FAIL=$((FAIL + 1))
}

skip() {
    echo -e "${YELLOW}[SKIP]${NC} $1"
}

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=================================="
echo "Registry Integration Tests"
echo "=================================="
echo ""

# Test 1: Source registry
echo "Test 1: Source registry.sh"
if [ -f "${SCRIPT_DIR}/lib/registry.sh" ]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/lib/registry.sh"
    if type -t feature_register &>/dev/null; then
        pass "feature_register function exists"
    else
        fail "feature_register function not found"
    fi
else
    fail "lib/registry.sh not found"
fi

# Test 2: Source core modules
echo "Test 2: Source core modules"
if [ -d "${SCRIPT_DIR}/lib/core" ]; then
    for f in "${SCRIPT_DIR}"/lib/core/*.sh; do
        [ -f "$f" ] || continue
        # shellcheck source=/dev/null
        source "$f"
    done
    if type -t template_deploy &>/dev/null; then
        pass "template_deploy function exists"
    else
        skip "template_deploy not found (may not be defined in core)"
    fi
else
    skip "lib/core directory not found"
fi

# Test 3: Source feature modules
echo "Test 3: Source feature modules"
FEATURE_COUNT=0
if [ -d "${SCRIPT_DIR}/lib/features" ]; then
    for f in "${SCRIPT_DIR}"/lib/features/*.sh; do
        [ -f "$f" ] || continue
        # shellcheck source=/dev/null
        source "$f"
        FEATURE_COUNT=$((FEATURE_COUNT + 1))
    done
    if [ "$FEATURE_COUNT" -gt 0 ]; then
        pass "Sourced $FEATURE_COUNT feature modules"
    else
        fail "No feature modules found"
    fi
else
    fail "lib/features directory not found"
fi

# Test 4: Verify features registered
echo "Test 4: Verify features registered"
if type -t feature_list &>/dev/null; then
    REGISTERED=$(feature_list | wc -l | tr -d ' ')
    if [ "$REGISTERED" -gt 0 ]; then
        pass "$REGISTERED features registered"
        echo "    Features: $(feature_list | tr '\n' ' ')"
    else
        fail "No features registered"
    fi
else
    fail "feature_list function not available"
fi

# Test 5: Check specific features exist
echo "Test 5: Check expected features"
for feat in http3 brotli security wordpress; do
    if type -t feature_exists &>/dev/null && feature_exists "$feat"; then
        pass "Feature '$feat' registered"
    else
        fail "Feature '$feat' not registered"
    fi
done

# Test 6: Source detector.sh and check adapter
echo "Test 6: Check registry adapter in detector.sh"
if [ -f "${SCRIPT_DIR}/nginx-optimizer-lib/detector.sh" ]; then
    # Need some globals first
    DATA_DIR="${HOME}/.nginx-optimizer"
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/nginx-optimizer-lib/detector.sh" 2>/dev/null || true

    if type -t registry_detect_feature &>/dev/null; then
        pass "registry_detect_feature adapter exists"
    else
        fail "registry_detect_feature adapter not found"
    fi

    if type -t registry_list_features &>/dev/null; then
        pass "registry_list_features adapter exists"
    else
        fail "registry_list_features adapter not found"
    fi
else
    fail "detector.sh not found"
fi

# Test 7: Test feature_detect function
echo "Test 7: Test feature_detect"
if type -t feature_detect &>/dev/null; then
    # Create a temp config file with http3 directive
    TEMP_CONF=$(mktemp)
    echo "listen 443 ssl;" > "$TEMP_CONF"
    echo "listen 443 quic reuseport;" >> "$TEMP_CONF"

    if feature_detect "http3" "$TEMP_CONF"; then
        pass "feature_detect found http3 in test config"
    else
        fail "feature_detect did not find http3 in test config"
    fi

    rm -f "$TEMP_CONF"
else
    skip "feature_detect not available"
fi

# Test 8: Test feature_get function
echo "Test 8: Test feature_get"
if type -t feature_get &>/dev/null; then
    if feature_exists "http3"; then
        DISPLAY=$(feature_get "http3" "display")
        if [ "$DISPLAY" = "HTTP/3 QUIC" ]; then
            pass "feature_get retrieves display name correctly"
        else
            fail "feature_get returned unexpected display: $DISPLAY"
        fi

        PATTERN=$(feature_get "http3" "pattern")
        if [ -n "$PATTERN" ]; then
            pass "feature_get retrieves pattern correctly"
        else
            fail "feature_get returned empty pattern"
        fi
    else
        skip "http3 feature not registered"
    fi
else
    skip "feature_get not available"
fi

# Test 9: Test alias resolution
echo "Test 9: Test feature alias resolution"
if type -t feature_get_by_alias &>/dev/null; then
    # http3 has alias "quic"
    RESOLVED=$(feature_get_by_alias "quic" 2>/dev/null || echo "")
    if [ "$RESOLVED" = "http3" ]; then
        pass "Alias 'quic' resolves to 'http3'"
    else
        fail "Alias 'quic' did not resolve correctly (got: $RESOLVED)"
    fi
else
    skip "feature_get_by_alias not available"
fi

# Test 10: Test custom detect flag
echo "Test 10: Test custom function flags"
if type -t feature_get &>/dev/null && feature_exists "http3"; then
    HAS_CUSTOM_APPLY=$(feature_get "http3" "custom_apply")
    if [ "$HAS_CUSTOM_APPLY" = "1" ]; then
        pass "http3 custom_apply flag set correctly"
    else
        fail "http3 custom_apply flag incorrect (got: $HAS_CUSTOM_APPLY)"
    fi

    # Check if custom apply function exists
    if declare -f "feature_apply_custom_http3" &>/dev/null; then
        pass "feature_apply_custom_http3 function exists"
    else
        fail "feature_apply_custom_http3 function not found"
    fi
else
    skip "Cannot test custom flags"
fi

# Summary
echo ""
echo "=================================="
echo "Summary: $PASS passed, $FAIL failed"
echo "=================================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
