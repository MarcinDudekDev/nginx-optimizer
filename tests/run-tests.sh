#!/bin/bash
# nginx-optimizer Test Suite
# Comprehensive tests for syntax, portability, and functionality

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGS_DIR="${SCRIPT_DIR}/configs"
OPTIMIZER="${SCRIPT_DIR}/../nginx-optimizer.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

log_pass() { echo -e "${GREEN}[PASS]${NC} $*"; PASS=$((PASS + 1)); }
log_fail() { echo -e "${RED}[FAIL]${NC} $*"; FAIL=$((FAIL + 1)); }
log_skip() { echo -e "${YELLOW}[SKIP]${NC} $*"; SKIP=$((SKIP + 1)); }
log_section() { echo -e "\n${BLUE}=== $* ===${NC}"; }

echo "=========================================="
echo "  nginx-optimizer Test Suite v0.9.0"
echo "=========================================="

################################################################################
# SECTION 1: Static Analysis
################################################################################
log_section "Static Analysis"

# Test: Shellcheck passes (no errors)
echo "Shellcheck validation..."
if command -v shellcheck &>/dev/null; then
    if shellcheck --severity=error "${OPTIMIZER}" "${SCRIPT_DIR}/../nginx-optimizer-lib/"*.sh 2>/dev/null; then
        log_pass "Shellcheck (no errors)"
    else
        log_fail "Shellcheck found errors"
    fi

    # Also check warnings (informational)
    warning_count=$(shellcheck --severity=warning "${OPTIMIZER}" "${SCRIPT_DIR}/../nginx-optimizer-lib/"*.sh 2>&1 | grep -c "SC[0-9]" || true)
    warning_count=${warning_count:-0}
    if [ "$warning_count" -eq 0 ]; then
        log_pass "Shellcheck (no warnings)"
    else
        log_skip "Shellcheck has $warning_count warnings (non-blocking)"
    fi
else
    log_skip "Shellcheck not installed"
fi

################################################################################
# SECTION 2: Bash Compatibility
################################################################################
log_section "Bash Compatibility"

# Test: Bash 3.2 syntax compatibility
echo "Bash 3.2 syntax check..."
for script in "${OPTIMIZER}" "${SCRIPT_DIR}/../nginx-optimizer-lib/"*.sh; do
    name=$(basename "$script")
    if /bin/bash -n "$script" 2>/dev/null; then
        log_pass "$name"
    else
        log_fail "$name"
    fi
done

################################################################################
# SECTION 3: Portability
################################################################################
log_section "Portability Checks"

# Test: No GNU-only commands
echo "Checking for GNU-only commands..."
if grep -r "find.*-printf" "${SCRIPT_DIR}/../nginx-optimizer-lib/" 2>/dev/null; then
    log_fail "Found GNU-only 'find -printf'"
else
    log_pass "No 'find -printf'"
fi

if grep -r "declare -A" "${SCRIPT_DIR}/../nginx-optimizer-lib/" 2>/dev/null; then
    log_fail "Found bash 4+ 'declare -A'"
else
    log_pass "No 'declare -A'"
fi

if grep -r "\bflock\b" "${SCRIPT_DIR}/../nginx-optimizer.sh" "${SCRIPT_DIR}/../nginx-optimizer-lib/"*.sh 2>/dev/null | grep -v "#"; then
    log_fail "Found Linux-only 'flock'"
else
    log_pass "No 'flock'"
fi

################################################################################
# SECTION 4: Functional Tests
################################################################################
log_section "Functional Tests"

# Test: Version command
echo "Testing commands..."
version_output=$("${OPTIMIZER}" --version 2>&1 || true)
if echo "$version_output" | grep -q "0.9.0-beta"; then
    log_pass "--version returns correct version"
else
    log_fail "--version incorrect"
fi

# Test: Help command
help_output=$("${OPTIMIZER}" help 2>&1 || true)
if echo "$help_output" | grep -q "COMMANDS:"; then
    log_pass "help command works"
else
    log_fail "help command failed"
fi

# Test: List command
list_output=$("${OPTIMIZER}" list 2>&1 || true)
if echo "$list_output" | grep -qi "nginx"; then
    log_pass "list command works"
else
    log_fail "list command failed"
fi

# Test: Status command (needs a site or graceful failure)
status_output=$("${OPTIMIZER}" status 2>&1 || true)
if echo "$status_output" | grep -qiE "(Analysis|Detected|No nginx|instance)"; then
    log_pass "status command works"
else
    log_fail "status command failed"
fi

# Test: Analyze command
analyze_output=$("${OPTIMIZER}" analyze 2>&1 || true)
if echo "$analyze_output" | grep -qiE "(Analysis|Detected|No nginx|instance)"; then
    log_pass "analyze command works"
else
    log_fail "analyze command failed"
fi

# Test: Rollback (list backups)
rollback_output=$("${OPTIMIZER}" rollback 2>&1 || true)
if echo "$rollback_output" | grep -qiE "(backup|Available)"; then
    log_pass "rollback command works"
else
    log_fail "rollback command failed"
fi

################################################################################
# SECTION 5: Dry-Run Tests
################################################################################
log_section "Dry-Run Tests"

# Test: Optimize dry-run doesn't modify anything
echo "Testing dry-run safety..."
dryrun_output=$("${OPTIMIZER}" optimize --dry-run 2>&1 || true)
if echo "$dryrun_output" | grep -qi "DRY RUN"; then
    log_pass "optimize --dry-run works"
else
    log_fail "optimize --dry-run failed"
fi

################################################################################
# SECTION 6: Idempotency Test
################################################################################
log_section "Idempotency Test"

# Run dry-run twice, compare output (should be identical)
echo "Testing idempotency..."
output1=$("${OPTIMIZER}" optimize --dry-run 2>&1 | grep -E "Would|DRY RUN" | head -20 || true)
output2=$("${OPTIMIZER}" optimize --dry-run 2>&1 | grep -E "Would|DRY RUN" | head -20 || true)

if [ "$output1" = "$output2" ]; then
    log_pass "Dry-run is idempotent"
else
    log_fail "Dry-run output differs between runs"
fi

################################################################################
# SECTION 7: Config Corpus (if nginx available)
################################################################################
log_section "Config Corpus Validation"

if command -v nginx &>/dev/null; then
    for conf in "${CONFIGS_DIR}"/**/*.conf; do
        [ -f "$conf" ] || continue
        name=$(basename "$conf")
        log_skip "$name (needs Docker nginx)"
    done
else
    log_skip "nginx not installed - skipping config validation"
fi

################################################################################
# Summary
################################################################################
echo ""
echo "=========================================="
echo "  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${SKIP} skipped${NC}"
echo "=========================================="

if [ "$FAIL" -gt 0 ]; then
    echo -e "${RED}TESTS FAILED${NC}"
    exit 1
else
    echo -e "${GREEN}ALL TESTS PASSED${NC}"
    exit 0
fi
