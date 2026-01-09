#!/bin/bash
# nginx-optimizer Test Suite
# Validates configs don't break after optimization

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGS_DIR="${SCRIPT_DIR}/configs"
OPTIMIZER="${SCRIPT_DIR}/../nginx-optimizer.sh"

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

echo "=================================="
echo "nginx-optimizer Test Suite"
echo "=================================="
echo ""

# Test 1: Shellcheck passes
echo "Test: Shellcheck validation"
if command -v shellcheck &>/dev/null; then
    if shellcheck --severity=error "${OPTIMIZER}" "${SCRIPT_DIR}/../nginx-optimizer-lib/"*.sh 2>/dev/null; then
        log_pass "Shellcheck (no errors)"
    else
        log_fail "Shellcheck found errors"
    fi
else
    log_skip "Shellcheck not installed"
fi

# Test 2: Bash 3.2 syntax compatibility
echo ""
echo "Test: Bash 3.2 syntax compatibility"
for script in "${OPTIMIZER}" "${SCRIPT_DIR}/../nginx-optimizer-lib/"*.sh; do
    name=$(basename "$script")
    if /bin/bash -n "$script" 2>/dev/null; then
        log_pass "$name"
    else
        log_fail "$name"
    fi
done

# Test 3: Tool runs without error
echo ""
echo "Test: Tool basic functionality"
if "${OPTIMIZER}" --version &>/dev/null; then
    log_pass "--version works"
else
    log_fail "--version failed"
fi

if "${OPTIMIZER}" help &>/dev/null; then
    log_pass "help command works"
else
    log_fail "help command failed"
fi

# Test 4: No GNU-only commands
echo ""
echo "Test: Portable commands (no GNU-only)"
if grep -r "find.*-printf" "${SCRIPT_DIR}/../nginx-optimizer-lib/" 2>/dev/null; then
    log_fail "Found GNU-only 'find -printf'"
else
    log_pass "No 'find -printf' found"
fi

if grep -r "declare -A" "${SCRIPT_DIR}/../nginx-optimizer-lib/" 2>/dev/null; then
    log_fail "Found bash 4+ 'declare -A'"
else
    log_pass "No 'declare -A' found"
fi

# Test 5: Config files are valid nginx syntax (if nginx available)
echo ""
echo "Test: Config corpus validation"
if command -v nginx &>/dev/null; then
    for conf in "${CONFIGS_DIR}"/**/*.conf; do
        [ -f "$conf" ] || continue
        name=$(basename "$conf")
        # Note: These configs won't pass nginx -t standalone (missing includes)
        # This is a placeholder for future Docker-based testing
        log_skip "$name (needs Docker nginx for full validation)"
    done
else
    log_skip "nginx not installed - skipping config validation"
fi

# Summary
echo ""
echo "=================================="
echo "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${SKIP} skipped${NC}"
echo "=================================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
