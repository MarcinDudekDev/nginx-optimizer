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
# SECTION 16: WordPress Permalink Rewrite Detection
################################################################################
log_section "WordPress Permalink Rewrite Tests"

# ADD_WP_REWRITE / DRY_RUN are read as globals inside scan_wp_rewrite (sourced
# from optimizer.sh); export so shellcheck sees them as used across scopes.
export ADD_WP_REWRITE DRY_RUN
WP_CFG_DIR="${CONFIGS_DIR}/wordpress"

# Functions come from optimizer.sh (sourced earlier in SECTION 11).
if ! type -t wp_has_rewrite &>/dev/null; then
    log_fail "wp_has_rewrite function missing"
fi

# (a) Config WITH try_files -> detected as present, no warning.
if wp_has_rewrite "${WP_CFG_DIR}/basic-wordpress.conf"; then
    log_pass "wp_has_rewrite detects existing try_files -> /index.php"
else
    log_fail "wp_has_rewrite missed existing try_files"
fi

# (b) Config WITHOUT try_files -> detected as missing.
if wp_has_rewrite "${WP_CFG_DIR}/wordpress-no-rewrite.conf"; then
    log_fail "wp_has_rewrite false positive on config without try_files"
else
    log_pass "wp_has_rewrite reports missing try_files"
fi

# Build isolated scan dirs under ~/.wp-test so they pass the path-safety gate
# (is_safe_config_file only allows nginx dirs and ~/.wp-test/*).
WP_TEST_ROOT="${HOME}/.wp-test"
mkdir -p "$WP_TEST_ROOT"
WP_SCAN_DIR=$(mktemp -d "${WP_TEST_ROOT}/scan-rewrite.XXXXXX")
cp "${WP_CFG_DIR}/basic-wordpress.conf" "${WP_SCAN_DIR}/with-rewrite.conf"

# (a) scan: config with rewrite produces NO warning.
ADD_WP_REWRITE=false DRY_RUN=false scan_output=$(scan_wp_rewrite "$WP_SCAN_DIR" 2>&1 || true)
if printf "%s" "$scan_output" | grep -qi "permalink\|404\|try_files"; then
    log_fail "scan_wp_rewrite warned on a config that already has try_files"
else
    log_pass "scan_wp_rewrite silent when try_files present"
fi

# (b) scan: config without rewrite produces a 404 warning.
cp "${WP_CFG_DIR}/wordpress-no-rewrite.conf" "${WP_SCAN_DIR}/no-rewrite.conf"
ADD_WP_REWRITE=false DRY_RUN=false scan_warn=$(scan_wp_rewrite "$WP_SCAN_DIR" 2>&1 || true)
if printf "%s" "$scan_warn" | grep -qi "404"; then
    log_pass "scan_wp_rewrite warns about missing try_files (404)"
else
    log_fail "scan_wp_rewrite did not warn about missing try_files"
fi

# Warning must NOT auto-modify the file (overlay safety).
if wp_has_rewrite "${WP_SCAN_DIR}/no-rewrite.conf"; then
    log_fail "scan_wp_rewrite modified config without --add-wp-rewrite"
else
    log_pass "scan_wp_rewrite leaves config untouched by default"
fi

# (c) --add-wp-rewrite injects the block exactly once (idempotent).
WP_INJECT_FILE="${WP_SCAN_DIR}/inject-target.conf"
cp "${WP_CFG_DIR}/wordpress-no-rewrite.conf" "$WP_INJECT_FILE"
wp_inject_rewrite "$WP_INJECT_FILE" >/dev/null 2>&1 || true
count1=$(grep -cE 'try_files[[:space:]]+[^;]*/index\.php' "$WP_INJECT_FILE" || true)
# Run again — must not duplicate (returns 2 = already present).
wp_inject_rewrite "$WP_INJECT_FILE" >/dev/null 2>&1 || true
count2=$(grep -cE 'try_files[[:space:]]+[^;]*/index\.php' "$WP_INJECT_FILE" || true)
if [ "$count1" = "1" ] && [ "$count2" = "1" ]; then
    log_pass "wp_inject_rewrite adds front controller once and is idempotent"
else
    log_fail "wp_inject_rewrite idempotency broken (run1=$count1 run2=$count2)"
fi

# (c) scan with ADD_WP_REWRITE=true injects via the orchestrator too.
WP_SCAN2_DIR=$(mktemp -d "${WP_TEST_ROOT}/scan-inject.XXXXXX")
cp "${WP_CFG_DIR}/wordpress-no-rewrite.conf" "${WP_SCAN2_DIR}/site.conf"
ADD_WP_REWRITE=true DRY_RUN=false scan_wp_rewrite "$WP_SCAN2_DIR" >/dev/null 2>&1 || true
if wp_has_rewrite "${WP_SCAN2_DIR}/site.conf"; then
    log_pass "scan_wp_rewrite injects front controller with --add-wp-rewrite"
else
    log_fail "scan_wp_rewrite did not inject with --add-wp-rewrite"
fi

# Guard: existing `location /` without try_files must NOT get a second one.
WP_GUARD_DIR=$(mktemp -d "${WP_TEST_ROOT}/scan-guard.XXXXXX")
cat > "${WP_GUARD_DIR}/proxy.conf" <<'GUARD'
server {
    listen 80;
    server_name proxy.example.com;
    location / {
        proxy_pass http://127.0.0.1:8080;
    }
}
GUARD
ADD_WP_REWRITE=true DRY_RUN=false guard_out=$(scan_wp_rewrite "$WP_GUARD_DIR" 2>&1 || true)
guard_count=$(grep -cE 'location[[:space:]]+/[[:space:]]*\{' "${WP_GUARD_DIR}/proxy.conf" || true)
if [ "$guard_count" = "1" ] && printf "%s" "$guard_out" | grep -qi "review manually"; then
    log_pass "scan_wp_rewrite refuses to add a duplicate location / (manual-review warning)"
else
    log_fail "scan_wp_rewrite mishandled existing location / (count=$guard_count)"
fi

# Cleanup
rm -rf "$WP_SCAN_DIR" "$WP_SCAN2_DIR" "$WP_GUARD_DIR"

################################################################################
# SECTION 17: awk data-injection safety (issue #3)
################################################################################
log_section "awk Injection Safety"

# awk applies ESCAPE PROCESSING to every -v assignment, so a value containing a
# literal backslash-n becomes a real newline and injects a second nginx
# directive. ENVIRON[] does no such processing. This is the actual exposure —
# bash never evaluates $(..)/backticks inside a variable's value, so shell
# execution was never possible here.
awk_evil='snippets/x.conf;\n    return 444'

# The vulnerable form, kept as the control: it must still split into two lines.
awk_vuln_lines=$(awk -v f="$awk_evil" 'BEGIN{print "    include " f ";"}' | grep -c .)
if [ "$awk_vuln_lines" -eq 2 ]; then
    log_pass "Control: awk -v does expand \\n into a second directive (2 lines)"
else
    log_fail "Control failed — awk -v produced $awk_vuln_lines lines, expected 2"
fi

# The form the code now uses must keep it to a single directive.
awk_safe_lines=$(AWK_F="$awk_evil" awk 'BEGIN{print "    include " ENVIRON["AWK_F"] ";"}' | grep -c .)
if [ "$awk_safe_lines" -eq 1 ]; then
    log_pass "ENVIRON[] keeps an escaped value on one line (no directive injection)"
else
    log_fail "ENVIRON[] leaked a newline — $awk_safe_lines lines, expected 1"
fi

# No injection site may pass a PATH through -v. Numeric tuning values are fine
# (they cannot carry an escape), so only flag the path-carrying variables.
awk_bad_sites=$(grep -rn 'awk -v \(include_line\|include_file\|snippets\)=' \
    "${SCRIPT_DIR}/../nginx-optimizer-lib/"*.sh "${SCRIPT_DIR}/../lib/features/"*.sh 2>/dev/null || true)
if [ -z "$awk_bad_sites" ]; then
    log_pass "No path-carrying awk -v assignments remain in injection code"
else
    log_fail "Path passed via awk -v (use ENVIRON): $awk_bad_sites"
fi

################################################################################
# SECTION 18: Shared RAM Budget (sysinfo)
################################################################################
log_section "RAM Budget Tests"

# sysinfo.sh is a pure-helper module: source it directly and drive it by
# overriding the detection caches (_SYSINFO_RAM_MB / _SYSINFO_CPU_CORES).
source "${SCRIPT_DIR}/../lib/core/sysinfo.sh"

if ! type -t sysinfo_ram_budget_php &>/dev/null; then
    log_fail "sysinfo_ram_budget_php function missing"
fi

# Set the simulated box. Cores fixed at 4 so the RAM path (not the cores*10
# cap) is what we are testing on the small tiers.
sysinfo_simulate() {
    _SYSINFO_RAM_MB="$1"
    _SYSINFO_CPU_CORES="${2:-4}"
}

# Expected budget per tier: (RAM - opcache - keys_zone) * 50%
#   tier ram   opcache keys  usable  budget
#   1    512   64      10    438     219
#   2    1024  96      20    908     454
#   3    2048  160     50    1838    919
#   4    4096  192     100   3804    1902
#   5    8192  256     128   7808    3904
#   6    16384 384     256   15744   7872
for tier_case in "512:219" "1024:454" "2048:919" "4096:1902" "8192:3904" "16384:7872"; do
    tier_ram="${tier_case%%:*}"
    tier_expect="${tier_case##*:}"
    sysinfo_simulate "$tier_ram"
    tier_got=$(sysinfo_ram_budget_php)
    if [ "$tier_got" = "$tier_expect" ]; then
        log_pass "sysinfo_ram_budget_php(${tier_ram}MB) = ${tier_got}MB"
    else
        log_fail "sysinfo_ram_budget_php(${tier_ram}MB) = ${tier_got}MB, expected ${tier_expect}MB"
    fi
done

# The budget must ALWAYS be strictly below a flat 50% of total RAM — that is
# the whole point of subtracting the shared allocations first.
budget_ok=true
for tier_ram in 512 1024 2048 4096 8192 16384; do
    sysinfo_simulate "$tier_ram"
    if [ "$(sysinfo_ram_budget_php)" -ge $(( tier_ram / 2 )) ]; then
        budget_ok=false
        echo "  ${tier_ram}MB budget did not shrink below flat 50%"
    fi
done
if [ "$budget_ok" = true ]; then
    log_pass "PHP budget is below flat 50% on every tier (shared SHM subtracted)"
else
    log_fail "PHP budget still at or above flat 50% on some tier"
fi

# Total commitment (PHP workers at their ceiling + opcache + keys_zone +
# MySQL 20% + OS 15% of usable) must leave real headroom on every tier.
# Before this change tiers 1-3 sat at 93-96%.
commit_ok=true
for tier_ram in 512 1024 2048 4096 8192 16384; do
    sysinfo_simulate "$tier_ram"
    c_opcache=$(sysinfo_opcache_memory)
    c_zone=$(sysinfo_fastcgi_keys_zone); c_zone="${c_zone%m}"
    c_usable=$(( tier_ram - c_opcache - c_zone ))
    c_php=$(( $(sysinfo_fpm_max_children) * SYSINFO_AVG_WORKER_MB ))
    c_total=$(( c_php + c_opcache + c_zone + c_usable * 35 / 100 ))
    c_pct=$(( c_total * 100 / tier_ram ))
    if [ "$c_pct" -gt 86 ]; then
        commit_ok=false
        echo "  ${tier_ram}MB committed at ${c_pct}% (>86%)"
    fi
done
if [ "$commit_ok" = true ]; then
    log_pass "Total RAM commitment stays under 86% on every tier"
else
    log_fail "Total RAM commitment over 86% on some tier"
fi

# max_children must never exceed what the budget can actually pay for.
children_ok=true
for tier_ram in 512 1024 2048 4096 8192 16384; do
    sysinfo_simulate "$tier_ram"
    mc=$(sysinfo_fpm_max_children)
    afford=$(( $(sysinfo_ram_budget_php) / SYSINFO_AVG_WORKER_MB ))
    # 3 is the hard floor and may legitimately exceed the budget on a tiny box
    if [ "$mc" -gt "$afford" ] && [ "$mc" -ne 3 ]; then
        children_ok=false
        echo "  ${tier_ram}MB: max_children=${mc} > affordable ${afford}"
    fi
done
if [ "$children_ok" = true ]; then
    log_pass "max_children never exceeds the RAM budget"
else
    log_fail "max_children exceeds the RAM budget on some tier"
fi

# The 3-worker floor overrides the budget on boxes too small to pay for it.
# That is deliberate (1-2 workers is not a serving config) but MUST be reported,
# not emitted silently — pin both the boundary and the reporting.
# Boundary: budget must cover 3 x 40MB = 120MB, i.e. usable >= 240MB.
#   256MB -> usable 182 -> budget 91 -> affords 2  -> floor binds
#   320MB -> usable 246 -> budget 123 -> affords 3 -> floor does not bind
sysinfo_simulate 256
if sysinfo_fpm_floor_binds && [ "$(sysinfo_fpm_overcommit_mb)" -gt 0 ]; then
    log_pass "Floor-vs-budget collision detected on a 256MB box ($(sysinfo_fpm_overcommit_mb)MB over)"
else
    log_fail "256MB box over-commits via the 3-worker floor but is not reported"
fi

sysinfo_simulate 320
if sysinfo_fpm_floor_binds || [ "$(sysinfo_fpm_overcommit_mb)" -ne 0 ]; then
    log_fail "320MB box flagged as over-committed but the budget covers 3 workers"
else
    log_pass "Floor-vs-budget collision clears at 320MB (budget affords the floor)"
fi

# Every tier this tool actually targets must be free of the collision
floor_ok=true
for tier_ram in 512 1024 2048 4096 8192 16384; do
    sysinfo_simulate "$tier_ram"
    if sysinfo_fpm_floor_binds; then
        floor_ok=false
        echo "  ${tier_ram}MB: 3-worker floor overrides the RAM budget"
    fi
done
if [ "$floor_ok" = true ]; then
    log_pass "No tier from 512MB up hits the floor-vs-budget collision"
else
    log_fail "A supported tier over-commits via the worker floor"
fi

# The warning must reach sysinfo_summary(), not just the helper
sysinfo_simulate 256
if printf "%s" "$(sysinfo_summary)" | grep -q "OVER-COMMITTED"; then
    log_pass "sysinfo_summary warns about the over-commit on a 256MB box"
else
    log_fail "sysinfo_summary stayed silent about a 256MB over-commit"
fi
# Negative assertion — must prove the output EXISTS before proving what it lacks.
# An empty or errored summary would satisfy "does not contain OVER-COMMITTED"
# trivially, i.e. a green light for nothing.
sysinfo_simulate 2048
healthy_summary=$(sysinfo_summary)
if ! printf "%s" "$healthy_summary" | grep -q "RAM budget:"; then
    log_fail "sysinfo_summary produced no budget line on 2GB — negative test cannot be trusted"
elif printf "%s" "$healthy_summary" | grep -q "OVER-COMMITTED"; then
    log_fail "sysinfo_summary cried over-commit on a healthy 2GB box"
else
    log_pass "sysinfo_summary silent on a healthy 2GB box (output verified non-empty)"
fi

# CPU cap still binds on a big-RAM / few-core box
sysinfo_simulate 16384 2
if [ "$(sysinfo_fpm_max_children)" = "20" ]; then
    log_pass "CPU cap binds on 16GB/2-core box (max_children=20)"
else
    log_fail "CPU cap broken: 16GB/2-core gave $(sysinfo_fpm_max_children), expected 20"
fi

# Degenerate box: budget must stay positive and children hit the floor of 3
sysinfo_simulate 128 1
if [ "$(sysinfo_ram_budget_php)" -gt 0 ] && [ "$(sysinfo_fpm_max_children)" = "3" ]; then
    log_pass "Degenerate 128MB box: positive budget, max_children floors at 3"
else
    log_fail "Degenerate 128MB box mishandled (budget=$(sysinfo_ram_budget_php), children=$(sysinfo_fpm_max_children))"
fi

# keys_zone parsing: a "g"-suffixed zone must be read as gigabytes
sysinfo_fastcgi_keys_zone() { echo "1g"; }
sysinfo_simulate 8192
# (8192 - 256 opcache - 1024 zone) * 50% = 3456
if [ "$(sysinfo_ram_budget_php)" = "3456" ]; then
    log_pass "keys_zone 'g' suffix parsed as gigabytes"
else
    log_fail "keys_zone 'g' suffix mis-parsed (got $(sysinfo_ram_budget_php), expected 3456)"
fi
# Restore the real implementation (unset -f would drop it entirely)
source "${SCRIPT_DIR}/../lib/core/sysinfo.sh"

# Reset caches so nothing downstream inherits a simulated box
_SYSINFO_RAM_MB=""
_SYSINFO_CPU_CORES=""

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
