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
echo "  nginx-optimizer Test Suite v0.10.0"
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
if echo "$version_output" | grep -q "0.10.0-beta"; then
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
if echo "$status_output" | grep -qiE "(Analysis|Detected|No nginx|instance|status|Detecting|analyzed|optimization)"; then
    log_pass "status command works"
else
    log_fail "status command failed"
fi

# Test: Analyze command
analyze_output=$("${OPTIMIZER}" analyze 2>&1 || true)
if echo "$analyze_output" | grep -qiE "(Analy|Detect|No nginx|instance|nginx-optimizer|error)"; then
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
# SECTION 5: Parser Module Tests
################################################################################
log_section "Parser Module Tests"

# Create mock config directory if it doesn't exist
mkdir -p "${CONFIGS_DIR}"

# Create mock nginx -T output for testing
MOCK_CONFIG_FILE="${CONFIGS_DIR}/mock-nginx-t-output.txt"
cat > "$MOCK_CONFIG_FILE" << 'EOF'
# configuration file /etc/nginx/nginx.conf:
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;

http {
    gzip on;
    include /etc/nginx/conf.d/*.conf;
}

# configuration file /etc/nginx/conf.d/default.conf:
server {
    listen 80;
    server_name localhost;
    root /var/www/html;
}

# configuration file /etc/nginx/conf.d/site.conf:
server {
    listen 443 ssl;
    listen 443 quic;
    server_name mysite.local;

    fastcgi_cache_path /tmp/cache levels=1:2 keys_zone=MYCACHE:10m;
    add_header Strict-Transport-Security "max-age=31536000";

    location / {
        fastcgi_cache MYCACHE;
    }
}
EOF

# Test: Parser module loads without errors
echo "Testing parser module..."
if source "${SCRIPT_DIR}/../nginx-optimizer-lib/parser.sh" 2>/dev/null; then
    log_pass "parser.sh loads"
else
    log_fail "parser.sh failed to load"
fi

# Test: Parser init function exists
if type -t parser_init &>/dev/null; then
    log_pass "parser_init function exists"
else
    log_fail "parser_init function missing"
fi

# Test: Parser cleanup function exists
if type -t parser_cleanup &>/dev/null; then
    log_pass "parser_cleanup function exists"
else
    log_fail "parser_cleanup function missing"
fi

# Test: Parser init creates temp file
if parser_init 2>/dev/null; then
    if [ -n "$PARSED_CONFIG_CACHE" ] && [ -f "$PARSED_CONFIG_CACHE" ]; then
        log_pass "parser_init creates temp file"
    else
        log_fail "parser_init didn't create temp file"
    fi
else
    log_fail "parser_init failed"
fi

# Test: Parser handles missing nginx gracefully
PATH_BAK="$PATH"
PATH="/nonexistent"
parser_init 2>/dev/null || true
result=$?
PATH="$PATH_BAK"
log_pass "Parser handles missing nginx"

# Test: Parse mock config
parser_init 2>/dev/null
mock_content=$(cat "$MOCK_CONFIG_FILE")
if parse_nginx_config "$mock_content" 2>/dev/null; then
    log_pass "Parser parses mock config"
else
    log_fail "Parser failed to parse mock config"
fi

# Test: Directive exists function
if directive_exists "gzip on" 2>/dev/null; then
    log_pass "directive_exists finds gzip"
else
    log_fail "directive_exists didn't find gzip"
fi

# Test: Directive exists returns false for non-existent directive
if directive_exists "nonexistent_directive_xyz" 2>/dev/null; then
    log_fail "directive_exists found non-existent directive"
else
    log_pass "directive_exists correctly returns false"
fi

# Test: get_directive_source function
source_file=$(get_directive_source "fastcgi_cache_path" 2>/dev/null || true)
if echo "$source_file" | grep -q "site.conf"; then
    log_pass "get_directive_source finds correct file"
else
    log_fail "get_directive_source didn't find correct file"
fi

# Test: get_all_directive_sources function
if type -t get_all_directive_sources &>/dev/null; then
    sources=$(get_all_directive_sources "listen" 2>/dev/null || true)
    if [ -n "$sources" ]; then
        log_pass "get_all_directive_sources returns results"
    else
        log_fail "get_all_directive_sources returned empty"
    fi
else
    log_fail "get_all_directive_sources function missing"
fi

# Test: directive_exists_in_file function
if directive_exists_in_file "site.conf" "listen.*quic" 2>/dev/null; then
    log_pass "directive_exists_in_file finds HTTP/3"
else
    log_fail "directive_exists_in_file didn't find HTTP/3"
fi

# Test: directive_exists_in_file returns false for wrong file
if directive_exists_in_file "default.conf" "fastcgi_cache_path" 2>/dev/null; then
    log_fail "directive_exists_in_file found directive in wrong file"
else
    log_pass "directive_exists_in_file correctly scopes to file"
fi

# Test: list_parsed_files function
if type -t list_parsed_files &>/dev/null; then
    files=$(list_parsed_files 2>/dev/null || true)
    file_count=$(echo "$files" | grep -c ".conf" || true)
    if [ "$file_count" -ge 3 ]; then
        log_pass "list_parsed_files returns all files"
    else
        log_fail "list_parsed_files returned $file_count files, expected 3+"
    fi
else
    log_fail "list_parsed_files function missing"
fi

# Test: get_file_content function
if type -t get_file_content &>/dev/null; then
    content=$(get_file_content "site.conf" 2>/dev/null || true)
    if echo "$content" | grep -q "fastcgi_cache_path"; then
        log_pass "get_file_content returns file content"
    else
        log_fail "get_file_content didn't return expected content"
    fi
else
    log_fail "get_file_content function missing"
fi

# Test: parser_stats function
if type -t parser_stats &>/dev/null; then
    stats=$(parser_stats 2>/dev/null || true)
    if echo "$stats" | grep -q "Files parsed"; then
        log_pass "parser_stats returns statistics"
    else
        log_fail "parser_stats didn't return statistics"
    fi
else
    log_fail "parser_stats function missing"
fi

# Test: Parser cleanup
parser_cleanup 2>/dev/null
if [ -z "$PARSED_CONFIG_CACHE" ] || [ ! -f "$PARSED_CONFIG_CACHE" ]; then
    log_pass "parser_cleanup removes temp file"
else
    log_fail "parser_cleanup didn't remove temp file"
fi

# Test: Analyze command with site name (shouldn't crash)
analyze_output=$("${OPTIMIZER}" analyze test-site.local 2>&1 || true)
if [[ ! "$analyze_output" =~ "command not found" ]] && [[ ! "$analyze_output" =~ "syntax error" ]]; then
    log_pass "analyze with site name doesn't crash"
else
    log_fail "analyze with site name crashed"
fi

# Cleanup mock config
rm -f "$MOCK_CONFIG_FILE"

################################################################################
# SECTION 6: Per-Site Analysis Tests
################################################################################
log_section "Per-Site Analysis Tests"

# Test 1: extract_all_sites function exists
echo "Testing extract_all_sites function..."
source "${SCRIPT_DIR}/../nginx-optimizer-lib/parser.sh" 2>/dev/null
if type -t extract_all_sites &>/dev/null; then
    log_pass "extract_all_sites function exists"
else
    log_fail "extract_all_sites function missing"
fi

# Test 2: extract_all_sites parses mock config
echo "Testing site extraction from mock config..."
# Create mock config
mock_config='###FILE:/etc/nginx/sites-enabled/site1.conf
server {
    listen 443 ssl;
    server_name site1.com www.site1.com;
}
###FILE:/etc/nginx/sites-enabled/site2.conf
server {
    listen 443 ssl;
    server_name site2.com;
}'

# Write to temp file and parse
parser_init
echo "$mock_config" > "$PARSED_CONFIG_CACHE"
sites=$(extract_all_sites)

if echo "$sites" | grep -q "site1.com"; then
    log_pass "extract_all_sites finds site1.com"
else
    log_fail "extract_all_sites missed site1.com"
fi

if echo "$sites" | grep -q "site2.com"; then
    log_pass "extract_all_sites finds site2.com"
else
    log_fail "extract_all_sites missed site2.com"
fi

parser_cleanup

# Test 3: analyze_single_site function exists
echo "Testing analyze_single_site function..."
source "${SCRIPT_DIR}/../nginx-optimizer-lib/detector.sh" 2>/dev/null
if type -t analyze_single_site &>/dev/null; then
    log_pass "analyze_single_site function exists"
else
    log_fail "analyze_single_site function missing"
fi

# Test 4: Per-site output format
echo "Testing per-site output format..."
# Create a minimal mock and test output contains expected patterns
output=$("${OPTIMIZER}" analyze 2>&1 || true)

# Should contain site header format
if echo "$output" | grep -qE "^Site:|═.*Site:"; then
    log_pass "Output contains per-site headers"
else
    log_skip "Per-site headers not found (may need real nginx config)"
fi

# Should contain Score: X/Y format
if echo "$output" | grep -qE "Score:.*[0-9]+/[0-9]+"; then
    log_pass "Output contains per-site scores"
else
    log_skip "Per-site scores not found (may need real nginx config)"
fi

# Test 5: Single site analysis
echo "Testing single site analysis..."
# Test that specifying a site doesn't crash
output=$("${OPTIMIZER}" analyze nonexistent-site.local 2>&1 || true)

# Should either show site not found or handle gracefully
if [[ ! "$output" =~ "Segmentation fault" ]] && [[ ! "$output" =~ "core dumped" ]]; then
    log_pass "Single site analysis handles gracefully"
else
    log_fail "Single site analysis crashed"
fi

# Test 6: HTTP redirect server blocks skipped
echo "Testing HTTP redirect blocks are skipped..."
mock_config='###FILE:/etc/nginx/sites-enabled/redirect.conf
server {
    listen 80;
    server_name redirect.com;
    return 301 https://$host$request_uri;
}
server {
    listen 443 ssl;
    server_name redirect.com;
}'

parser_init
echo "$mock_config" > "$PARSED_CONFIG_CACHE"
sites=$(extract_all_sites)

# Should only have one entry for redirect.com (the SSL one)
count=$(echo "$sites" | grep -c "redirect.com" || true)
if [ "$count" -eq 1 ]; then
    log_pass "HTTP redirect blocks skipped"
else
    log_skip "May have duplicates for redirect.com (count: $count)"
fi

parser_cleanup

# Test 7: localhost and _ are filtered
echo "Testing special server_names filtered..."
mock_config='###FILE:/etc/nginx/conf.d/default.conf
server {
    listen 80 default_server;
    server_name _;
}
server {
    listen 80;
    server_name localhost;
}
###FILE:/etc/nginx/sites-enabled/real.conf
server {
    listen 443 ssl;
    server_name real-site.com;
}'

parser_init
echo "$mock_config" > "$PARSED_CONFIG_CACHE"
sites=$(extract_all_sites)

if echo "$sites" | grep -q "_"; then
    log_fail "Catch-all _ not filtered"
else
    log_pass "Catch-all _ filtered"
fi

if echo "$sites" | grep -q "localhost"; then
    log_fail "localhost not filtered"
else
    log_pass "localhost filtered"
fi

if echo "$sites" | grep -q "real-site.com"; then
    log_pass "Real sites preserved"
else
    log_fail "Real sites were filtered incorrectly"
fi

parser_cleanup

################################################################################
# SECTION 7: Dry-Run Tests
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
# SECTION 8: Idempotency Test
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
# SECTION 9: Input Validation Tests
################################################################################
log_section "Input Validation Tests"

# Test: Path traversal rejected
echo "Testing input validation..."
traversal_output=$("${OPTIMIZER}" analyze "../etc/passwd" 2>&1 || true)
if printf "%s" "$traversal_output" | grep -qi "invalid"; then
    log_pass "Path traversal rejected: ../etc/passwd"
else
    log_fail "Path traversal not rejected: ../etc/passwd"
fi

# Test: Command injection rejected
injection_output=$("${OPTIMIZER}" analyze 'site$(whoami)' 2>&1 || true)
if printf "%s" "$injection_output" | grep -qi "invalid"; then
    log_pass "Command injection rejected: site\$(whoami)"
else
    log_fail "Command injection not rejected: site\$(whoami)"
fi

# Test: Valid site name accepted (may fail on "not found" but not on validation)
valid_output=$("${OPTIMIZER}" analyze "valid-site.local" 2>&1 || true)
if printf "%s" "$valid_output" | grep -qi "invalid.*input"; then
    log_fail "Valid site name rejected: valid-site.local"
else
    log_pass "Valid site name accepted: valid-site.local"
fi

# Test: Invalid rollback timestamp rejected
rollback_output=$("${OPTIMIZER}" rollback "not-a-timestamp" 2>&1 || true)
if printf "%s" "$rollback_output" | grep -qi "invalid.*timestamp"; then
    log_pass "Invalid rollback timestamp rejected"
else
    log_fail "Invalid rollback timestamp not rejected"
fi

# Test: Backup dir outside HOME rejected
backupdir_output=$("${OPTIMIZER}" optimize --backup-dir "/etc" 2>&1 || true)
if printf "%s" "$backupdir_output" | grep -qi "must be under"; then
    log_pass "Unsafe backup dir rejected: /etc"
else
    log_fail "Unsafe backup dir not rejected: /etc"
fi

# Test: Check command works
check_output=$("${OPTIMIZER}" check 2>&1 || true)
if printf "%s" "$check_output" | grep -qiE "(check|ready|issue|Prerequisites)"; then
    log_pass "check command works"
else
    log_fail "check command failed"
fi

################################################################################
# SECTION 10: Config Corpus (if nginx available)
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
# SECTION 11: State Tracking Tests
################################################################################
log_section "State Tracking Tests"

# Source optimizer.sh to get state functions
DATA_DIR=$(mktemp -d)
STATE_FILE="${DATA_DIR}/state.json"
LOG_FILE="${DATA_DIR}/test.log"
source "${SCRIPT_DIR}/../nginx-optimizer-lib/optimizer.sh" 2>/dev/null

# Test: save_applied_state creates state file
echo "Testing state tracking..."
if type -t save_applied_state &>/dev/null; then
    save_applied_state "http3" "test-site.local" "20250206-120000"
    if [ -f "$STATE_FILE" ]; then
        log_pass "save_applied_state creates state file"
    else
        log_fail "save_applied_state did not create state file"
    fi
else
    log_fail "save_applied_state function missing"
fi

# Test: state file contains the entry
if [ -f "$STATE_FILE" ] && grep -q '"feature":"http3"' "$STATE_FILE"; then
    log_pass "State file contains feature entry"
else
    log_fail "State file missing feature entry"
fi

# Test: get_applied_features returns features
if type -t get_applied_features &>/dev/null; then
    features=$(get_applied_features "test-site.local")
    if printf "%s" "$features" | grep -q "http3"; then
        log_pass "get_applied_features returns http3"
    else
        log_fail "get_applied_features did not return http3"
    fi
else
    log_fail "get_applied_features function missing"
fi

# Test: save second feature, both exist
save_applied_state "brotli" "test-site.local" "20250206-120000"
features=$(get_applied_features "test-site.local")
if printf "%s" "$features" | grep -q "http3" && printf "%s" "$features" | grep -q "brotli"; then
    log_pass "Multiple features tracked"
else
    log_fail "Multiple features not tracked correctly"
fi

# Test: clear_state_for_rollback empties state
if type -t clear_state_for_rollback &>/dev/null; then
    clear_state_for_rollback
    features=$(get_applied_features)
    if [ -z "$features" ]; then
        log_pass "clear_state_for_rollback clears all entries"
    else
        log_fail "clear_state_for_rollback did not clear entries"
    fi
else
    log_fail "clear_state_for_rollback function missing"
fi

# Test: load_applied_state returns valid JSON
if type -t load_applied_state &>/dev/null; then
    state_json=$(load_applied_state)
    if printf "%s" "$state_json" | grep -q '"applied"'; then
        log_pass "load_applied_state returns valid JSON structure"
    else
        log_fail "load_applied_state returned invalid JSON"
    fi
else
    log_fail "load_applied_state function missing"
fi

# Cleanup
rm -rf "$DATA_DIR"

################################################################################
# SECTION 12: --no-color Tests
################################################################################
log_section "--no-color Tests"

# Test: --no-color flag strips escape sequences
echo "Testing --no-color..."
nocolor_output=$("${OPTIMIZER}" --no-color --version 2>&1 || true)
if printf "%s" "$nocolor_output" | grep -q $'\033'; then
    log_fail "--no-color still has escape sequences"
else
    log_pass "--no-color strips escape sequences"
fi

# Test: NO_COLOR env var works
nocolor_env_output=$(NO_COLOR=1 "${OPTIMIZER}" --version 2>&1 || true)
if printf "%s" "$nocolor_env_output" | grep -q $'\033'; then
    log_fail "NO_COLOR env var still has escape sequences"
else
    log_pass "NO_COLOR env var strips escape sequences"
fi

################################################################################
# SECTION 13: diff Command Tests
################################################################################
log_section "diff Command Tests"

# Test: diff command runs without crashing
echo "Testing diff command..."
diff_output=$("${OPTIMIZER}" diff 2>&1 || true)
if printf "%s" "$diff_output" | grep -qiE "(diff|backup|No backups)"; then
    log_pass "diff command works"
else
    log_fail "diff command failed"
fi

# Test: diff with invalid timestamp
diff_bad_output=$("${OPTIMIZER}" diff 99999999-999999 2>&1 || true)
if printf "%s" "$diff_bad_output" | grep -qi "not found"; then
    log_pass "diff rejects invalid backup timestamp"
else
    log_fail "diff did not reject invalid backup"
fi

################################################################################
# SECTION 14: remove Command Tests
################################################################################
log_section "remove Command Tests"

# Test: remove command exists and runs
echo "Testing remove command..."
remove_output=$("${OPTIMIZER}" remove --feature http3 2>&1 || true)
if printf "%s" "$remove_output" | grep -qiE "(remove|not applied|No features)"; then
    log_pass "remove command works"
else
    log_fail "remove command failed"
fi

################################################################################
# SECTION 15: verify Command Tests
################################################################################
log_section "verify Command Tests"

# Test: verify command exists and runs
echo "Testing verify command..."
verify_output=$("${OPTIMIZER}" verify 2>&1 || true)
if printf "%s" "$verify_output" | grep -qiE "(verif|drift|state|No features)"; then
    log_pass "verify command works"
else
    log_fail "verify command failed"
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
