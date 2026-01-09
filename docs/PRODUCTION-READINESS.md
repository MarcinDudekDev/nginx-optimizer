# Production Readiness Plan for nginx-optimizer

## Critical Assessment: What's Missing

This document outlines everything needed to make nginx-optimizer a production-grade, open-source tool comparable to certbot.

---

## 0. ARCHITECTURAL CRITIQUE (Read First)

### Is the Overall Approach Sound?

**Current approach:** Copy pre-made config templates into nginx.

**Problems with this approach:**

| Issue | Severity | Example |
|-------|----------|---------|
| No adaptation to existing config | High | Adds gzip even if already enabled |
| Hardcoded values | High | `max_size=512m` regardless of server RAM |
| Can create duplicates | High | Multiple `add_header` for same header |
| No conflict detection | High | What if user has custom rate limits? |
| One-size-fits-all | Medium | Same config for 1 req/s blog and 1000 req/s store |

**Better approach (what certbot/nginx-amplify do):**
1. Parse existing config into AST
2. Analyze what's present vs missing
3. Patch only what's needed
4. Validate no conflicts
5. Offer profiles (conservative/balanced/aggressive)

### Missing Core Optimizations

The tool claims to optimize nginx but **misses fundamental performance settings**:

| Missing Optimization | Impact | Why It Matters |
|---------------------|--------|----------------|
| `worker_processes auto` | High | Uses all CPU cores |
| `worker_connections 4096` | High | Handle more concurrent connections |
| `open_file_cache` | High | Huge win for static files |
| `sendfile on` | Medium | Kernel-level file serving |
| `tcp_nopush on` | Medium | Optimize packet sending |
| `tcp_nodelay on` | Medium | Disable Nagle's algorithm |
| `keepalive_timeout` tuning | Medium | Connection reuse |
| `client_body_buffer_size` | Medium | Reduce disk I/O |
| `proxy_buffering` | Medium | For reverse proxy setups |
| `ssl_session_cache` | Medium | TLS session resumption |
| `upstream keepalive` | High | Reuse PHP-FPM connections |
| `resolver` | Medium | Required for dynamic upstreams |

### FastCGI Cache Design Flaws

Current `fastcgi-cache.conf` has issues:

```nginx
# PROBLEM 1: /var/run is tmpfs on most Linux - cleared on reboot!
fastcgi_cache_path /var/run/nginx-cache ...

# PROBLEM 2: No cache lock = stampede on cache miss
# Missing: fastcgi_cache_lock on;

# PROBLEM 3: Comment says "except tracking params" but doesn't implement it
if ($query_string != "") {
    set $skip_cache 1;  # Skips ALL query strings!
}

# PROBLEM 4: No purge mechanism when content updates

# PROBLEM 5: Hardcoded 512m regardless of available RAM/disk
```

### What Should Change Architecturally

1. **Add config parsing** - Don't blindly append, analyze first
2. **Add profiles** - `--profile conservative|balanced|aggressive`
3. **Add server sizing** - Detect RAM/CPU, adjust values
4. **Add conflict detection** - Warn if directive already exists
5. **Add dry-run diff** - Show exact changes before applying

---

## 1. SECURITY (Critical Priority)

### 1.1 Input Validation Gaps
- [ ] Site names could contain shell metacharacters → command injection
- [ ] Feature names not validated against allowlist
- [ ] Path traversal in `--backup-dir` parameter
- [ ] Template injection if config contains malicious patterns
- [ ] Symlink following could write to arbitrary locations

### 1.2 Privilege Escalation Risks
- [ ] Tool runs sudo liberally - minimize sudo surface
- [ ] Credentials in honeypot module could leak to logs
- [ ] Backup files might have overly permissive modes
- [ ] Lock file in user-writable location

### 1.3 Race Conditions
- [ ] TOCTOU in file existence checks before writes
- [ ] Lock file process might die, leaving stale lock
- [ ] Concurrent docker operations

### 1.4 Missing Security Infrastructure
- [ ] No SECURITY.md with vulnerability disclosure process
- [ ] No security audit has been performed
- [ ] No dependency scanning (shellcheck isn't enough)

---

## 2. ROBUSTNESS (High Priority)

### 2.1 Edge Cases Not Handled
- [ ] Nginx Plus (commercial) - different features/syntax
- [ ] OpenResty (nginx + Lua blocks in config)
- [ ] Kubernetes Ingress nginx - different config structure
- [ ] Nginx as pure reverse proxy (no PHP/WordPress)
- [ ] Multiple nginx instances on same server
- [ ] Very large configs (10k+ lines) - performance?
- [ ] Configs with non-ASCII characters/paths
- [ ] Configs with complex maps/conditionals
- [ ] Configs that `include` via HTTP URLs
- [ ] Custom-compiled nginx with unusual module set

### 2.2 Platform Compatibility
- [ ] **macOS ships bash 3.2** - associative arrays fail!
- [ ] BSD sed vs GNU sed (different `-i` syntax)
- [ ] BSD stat vs GNU stat (different flags)
- [ ] mawk vs gawk differences
- [ ] Alpine Linux (busybox, musl libc)
- [ ] SELinux/AppArmor blocking operations
- [ ] Different service managers (systemd/init.d/launchd/runit)
- [ ] Snap/Flatpak nginx installations
- [ ] cPanel/Plesk/DirectAdmin managed nginx

### 2.3 Specific Bugs Found in Code Review

**backup.sh - GNU-only find commands (breaks macOS/BSD):**
```bash
# Line 337-344: Uses -printf which is GNU find only!
find "$BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d -printf '%T@ %p\0' | \
    sort -z -n | head -z -n -"$keep_count"

# Same issue at lines 327-329, 375-376
```

**validator.sh - Missing timeout on nginx -t:**
```bash
# Line 20: nginx -t can hang forever on broken configs
if nginx -t 2>&1 | tee -a "$LOG_FILE"; then
# Should use: timeout 30 nginx -t
```

**honeypot.sh - empty_gif requires module:**
```bash
# Line 125: empty_gif needs ngx_http_empty_gif_module
empty_gif;  # May not be compiled in!
```

**rate-limiting.conf - No burst parameter:**
```nginx
# Rate limits without burst = harsh rejections
limit_req_zone $binary_remote_addr zone=general:10m rate=15r/s;
# Should be: limit_req zone=general burst=20 nodelay;
```

### 2.3 Failure Modes Not Covered
- [ ] `nginx -t` hangs (no timeout)
- [ ] Disk full during backup
- [ ] Docker daemon unresponsive
- [ ] Network timeout during bot-blocker update
- [ ] Ctrl+C during optimization (partial state)
- [ ] nginx reload succeeds but site broken (config valid but wrong)

### 2.4 Dependency Issues
- [ ] jq required but no graceful fallback
- [ ] rsync required
- [ ] curl required
- [ ] openssl required (for honeypot)
- [ ] No version checks for dependencies

---

## 3. TESTING (High Priority)

### 3.1 Test Infrastructure Needed
- [ ] **ShellCheck** - static analysis for bash bugs
- [ ] **BATS** - Bash Automated Testing System
- [ ] **GitHub Actions CI** with test matrix
- [ ] **Docker-based test environments** for different nginx versions

### 3.2 Test Coverage Needed
| Test Type | Status | Priority |
|-----------|--------|----------|
| Unit tests for each function | Missing | High |
| Integration tests (full workflow) | Missing | High |
| Real-world config corpus | Missing | High |
| Idempotency tests (run twice) | Missing | Critical |
| Rollback verification | Missing | Critical |
| Platform matrix (Ubuntu, Debian, Alpine, macOS) | Missing | High |
| Nginx version matrix (1.18, 1.22, 1.25, 1.27) | Missing | Medium |
| Fuzz testing of argument parsing | Missing | Medium |
| Performance/memory testing | Missing | Low |
| ARM architecture (Pi, M1) | Missing | Low |

### 3.3 Config Corpus Strategy
```
tests/
├── configs/
│   ├── minimal/          # Bare minimum valid configs
│   ├── wordpress/        # WordPress-specific configs
│   ├── reverse-proxy/    # Pure proxy configs
│   ├── complex/          # Multi-site, includes, maps
│   ├── edge-cases/       # Weird but valid configs
│   └── broken/           # Intentionally invalid (should fail gracefully)
├── expected/             # Expected output after optimization
└── fixtures/             # Mock data for unit tests
```

Source configs from:
- GitHub search: `filename:nginx.conf`
- DigitalOcean community configs
- nginx.org examples
- WordPress hosting guides (Starter templates)

---

## 4. USER EXPERIENCE (Medium Priority)

### 4.1 Missing Commands/Modes
- [ ] **Interactive wizard** - `nginx-optimizer` with no args should guide user
- [ ] **`--check` mode** - like ansible, validate without changing
- [ ] **`diff` command** - show what would change before applying
- [ ] **`remove` command** - cleanly uninstall optimizations
- [ ] **`doctor` command** - diagnose common issues
- [ ] **`export` command** - export current config as template
- [ ] **Partial rollback** - undo just one feature

### 4.2 Output/Feedback Issues
- [ ] No JSON output mode for tooling integration
- [ ] Progress indicators for long operations
- [ ] Better error messages with suggested fixes
- [ ] Verbose mode (`-vvv`) for debugging
- [ ] No colored output disable flag (`--no-color`)

### 4.3 Automation Gaps
- [ ] Exit codes not documented
- [ ] No `--yes` flag to accept all prompts
- [ ] No way to read config from stdin
- [ ] No environment variable configuration

### 4.4 Certbot-Inspired Features Missing
- [ ] `--staging` equivalent for testing
- [ ] Tracking what was changed (for clean removal)
- [ ] Pre/post hooks for custom actions
- [ ] Built-in update checker

---

## 5. DOCUMENTATION (Medium Priority)

### 5.1 Missing Documentation
- [ ] Man page (`nginx-optimizer.1`)
- [ ] Troubleshooting guide
- [ ] Architecture diagram
- [ ] API documentation (for scripting)
- [ ] Examples directory with common use cases
- [ ] FAQ
- [ ] Comparison with alternatives (nginx-config-optimizer, gixy, etc.)

### 5.2 Missing Community Files
- [ ] CONTRIBUTING.md
- [ ] CODE_OF_CONDUCT.md
- [ ] SECURITY.md
- [ ] CHANGELOG.md (keep a changelog format)
- [ ] Issue templates
- [ ] PR template

---

## 6. DISTRIBUTION (Lower Priority)

### 6.1 Installation Methods Needed
- [ ] **One-liner install script** (like certbot)
- [ ] **Homebrew formula** (macOS)
- [ ] **APT repository** (Debian/Ubuntu)
- [ ] **RPM repository** (RHEL/Fedora)
- [ ] **AUR package** (Arch)
- [ ] **Docker image** for portable usage
- [ ] **GitHub Releases** with checksums

### 6.2 Update Mechanism
- [ ] Self-update command
- [ ] Version check on startup (opt-in)
- [ ] Migration scripts between versions

---

## 7. OPERATIONAL CONCERNS

### 7.1 Observability
- [ ] Log rotation (logs can grow large)
- [ ] Structured logging option
- [ ] Opt-in anonymous usage telemetry
- [ ] Performance metrics

### 7.2 Integration
- [ ] Ansible module/role
- [ ] Terraform provider (stretch goal)
- [ ] Conflict detection with other tools (puppet, chef)

---

## 8. THE "SCARY" STUFF - Production Risks

### 8.1 Ways This Tool Can Break Production
1. **nginx fails to start** after optimization → site down
2. **Rate limiting too aggressive** → blocks legitimate users
3. **Security headers break embeds** → iframes, widgets fail
4. **HTTP/3 breaks old clients** → some users can't connect
5. **FastCGI cache serves stale content** → users see old pages
6. **WordPress exclusions too broad** → breaks REST API
7. **Conflicts with hosting panel** → cPanel/Plesk fight back

### 8.2 Mitigations Needed
- [ ] **Safe mode** - only non-breaking optimizations
- [ ] **Automatic health check** after applying changes
- [ ] **Automatic rollback** if nginx fails to start
- [ ] **Warning system** for risky operations
- [ ] **Dry-run by default** for destructive operations

---

## 9. COMPETITIVE ANALYSIS

### What exists already?
| Tool | What It Does | How It's Better Than Us |
|------|--------------|------------------------|
| **gixy** | Static analysis | Parses config properly, finds security issues |
| **crossplane** | Config parser library | Proper AST parsing, used by nginx amplify |
| **certbot** | SSL automation | Interactive wizard, tracks changes, clean uninstall |
| **nginx amplify** | Monitoring + recommendations | AI-powered suggestions, doesn't blindly apply |
| **nginxconfig.io** | Generator | Creates complete configs from scratch |

### What We Should Learn From Each

**From gixy:** Proper config parsing, not regex hacks
**From certbot:** Interactive wizard, `--dry-run`, `--staging`, rollback
**From crossplane:** Use a real parser library (Python: crossplane, Go: nginx-plus-go)
**From amplify:** Recommendations with explanations, not silent changes

### Our Realistic Position

**Current:** A bash script that appends config snippets (risky, inflexible)

**Realistic MVP:** A well-tested, WordPress-focused optimizer with:
- Clear scope (WordPress/PHP on nginx only)
- Safe defaults (conservative by default, opt-in aggressive)
- Proper testing (real config corpus)
- Good UX (wizard mode)

### Our unique value proposition:
**"One command to make WordPress on nginx fast and secure"**

Not trying to be a general nginx tool - focus on WordPress where we can excel.

---

## 10. PRIORITY MATRIX

### Must Have (Before Open Source)
1. ShellCheck passing (no warnings)
2. Basic test suite with CI
3. macOS bash 3.2 compatibility fix
4. SECURITY.md with disclosure process
5. Input validation hardening
6. Automatic rollback on nginx failure
7. CHANGELOG.md

### Should Have (v1.0)
1. Real-world config test corpus
2. Interactive wizard mode
3. `--check` dry-run mode
4. Idempotency guarantee
5. Homebrew formula
6. Comprehensive documentation

### Nice to Have (v1.x)
1. JSON output mode
2. Self-update
3. APT/RPM packages
4. Ansible integration

---

## 11. IMMEDIATE ACTION ITEMS

### Diagnostic Results (2025-01-09) - UPDATED

| Check | Result | Severity |
|-------|--------|----------|
| ShellCheck errors | 0 | ✅ OK |
| ShellCheck warnings | 0 | ✅ **FIXED** |
| Bash 4+ features | None | ✅ **FIXED** |
| macOS compatibility | Passes | ✅ **FIXED** |
| CI status | Passing | ✅ OK |
| Test suite | 23 passing | ✅ OK |
| sudo calls | ~48 across 4 files | ⚠️ Review needed |

### Critical Fix Required - ✅ RESOLVED
```bash
# FIXED: honeypot.sh now uses file-based cache instead of declare -A
# FIXED: All GNU-only commands replaced with portable alternatives
# FIXED: flock replaced with mkdir-based locking
```

### Commands to verify fixes
```bash
# Run shellcheck
shellcheck --severity=warning nginx-optimizer.sh nginx-optimizer-lib/*.sh

# Test on macOS default bash
/bin/bash nginx-optimizer.sh analyze

# Count remaining issues
shellcheck nginx-optimizer.sh nginx-optimizer-lib/*.sh 2>&1 | grep -c "warning"
```

---

## 12. SUCCESS CRITERIA

nginx-optimizer is ready for open source when:

- [x] `shellcheck` reports zero warnings ✅ (2025-01-09)
- [x] Test suite passes on Ubuntu + macOS ✅ (2025-01-09, 23 tests)
- [ ] Can optimize 50+ real-world configs without breaking them
- [x] Running twice produces identical results (idempotent) ✅ (tested in CI)
- [ ] Rollback restores exact previous state
- [ ] Documentation answers 90% of user questions
- [ ] One-liner install works on fresh Ubuntu
- [ ] No critical/high security issues in manual review

---

## 13. STRATEGIC DECISION POINT

### Three Paths Forward

**Path A: Polish Current Approach (2-4 weeks)**
- Fix bash 3.2 compatibility
- Fix GNU-only commands
- Add test suite
- Add wizard mode
- Accept architectural limitations

*Pros:* Ship faster, learn from real users
*Cons:* Technical debt, may need rewrite later

**Path B: Partial Rewrite with Config Parsing (2-3 months)**
- Keep bash but add proper config parsing (use `awk` AST or call Python crossplane)
- Add conflict detection
- Add profiles (conservative/aggressive)
- Much more robust

*Pros:* Solid foundation, fewer surprises
*Cons:* Longer timeline, more complex

**Path C: Full Rewrite in Python/Go (3-6 months)**
- Use crossplane (Python) or similar for proper parsing
- Match certbot's UX quality
- Support non-WordPress nginx

*Pros:* Professional grade, proper architecture
*Cons:* Essentially a new project, long timeline

### Recommendation

**Start with Path A, design for Path B.**

1. Fix the critical bugs (bash 3.2, GNU commands)
2. Add basic test suite
3. **Limit scope explicitly**: "WordPress on nginx, single-server, wp-test compatible"
4. Document known limitations honestly
5. Ship as v0.x (not 1.0) to signal beta status
6. Gather user feedback
7. Plan Path B based on real usage patterns

### Version Numbering

```
Current: v1.2.0 (too high for current state!)
Recommended: v0.9.0 (signals "almost ready but beta")
After testing: v0.10.0, v0.11.0...
After Path B: v1.0.0 (production ready)
```

---

## 14. NEXT SESSION ACTION ITEMS

### Completed - Phase 1 (2025-01-09)
- [x] Fix bash 3.2: Remove declare -A, add version check at startup
- [x] Fix GNU find: Replace -printf with portable alternatives
- [x] Fix flock: Replace with portable mkdir-based locking
- [x] Install shellcheck in CI
- [x] Create tests/configs/ corpus with 12 real nginx configs
- [x] Add test runner script (15 tests passing)

### Completed - Phase 2 (2025-01-09)
- [x] Fix ALL shellcheck warnings (139 → 0)
- [x] Update version to 0.9.0-beta
- [x] Write CHANGELOG.md
- [x] Enhance test suite with pipefail handling (23 tests passing)
- [x] CI workflow passes on Ubuntu + macOS

### Completed - Phase 3 (2025-01-09)
- [x] Add wizard mode when no args provided (like certbot)
- [x] Fix fastcgi cache path (/var/run → /var/cache/nginx)
- [x] Add automatic health check after optimization
- [x] Add fastcgi_cache_lock to prevent cache stampede
- [x] Add burst parameter documentation to rate limiting config
- [x] Add timeout to nginx -t calls (30s wrapper)
- [x] Create SECURITY.md with disclosure process
- [ ] Add automatic rollback if nginx fails to start (partial - needs enhancement)
- [ ] Add --check mode (validate without changing) (deferred)

### Next Priority - Phase 4: Documentation & Distribution
```
1. [ ] CONTRIBUTING.md with development guidelines
2. [ ] Man page (nginx-optimizer.1)
3. [ ] One-liner install script (curl | bash style)
4. [ ] Homebrew formula
5. [ ] Issue templates (.github/ISSUE_TEMPLATE/)
6. [ ] PR template (.github/PULL_REQUEST_TEMPLATE.md)
```

### Future - Phase 5: Advanced Features
```
1. [ ] Interactive wizard with feature selection menu
2. [ ] JSON output mode (--json)
3. [ ] Self-update command
4. [ ] APT/RPM packages
5. [ ] Ansible role
```
