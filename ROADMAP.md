# nginx-optimizer Roadmap

## Current Status: v0.9.1-beta

The tool is functional for WordPress on nginx optimization with per-site analysis,
input validation, auto-rollback safety, and pre-flight checks.

---

## Recently Completed (v0.9.1-beta - Feb 2025)

- [x] Input validation (site names, timestamps, backup paths)
- [x] Auto-rollback on health check failure
- [x] Transaction wrapping for atomic optimization
- [x] Interrupt safety (Ctrl+C rolls back in-progress changes)
- [x] `check` command for pre-flight readiness
- [x] `--check` flag (shorthand for check command)
- [x] `--no-rate-limit` flag for security config
- [x] CI coverage for `lib/` plugin architecture
- [x] Docker-based nginx config validation tests
- [x] 58 tests passing, 0 shellcheck warnings

## Previously Completed (v0.9.0-beta - Jan 2025)

- [x] Per-site detection and analysis
- [x] Interactive wizard with recommendations
- [x] WWW in SSL detection/fix
- [x] HTTP/3 reuseport duplicate handling
- [x] Analysis caching (hash-based, 33x faster)
- [x] macOS bash 3.2 compatibility
- [x] SECURITY.md, CONTRIBUTING.md, man page
- [x] One-liner install script, Homebrew formula

---

## v0.10.x - Polish & Robustness

### Commands
- [ ] `remove` command - Cleanly uninstall optimizations
- [ ] `diff` command - Show exact changes before applying
- [x] `doctor` command - Diagnose common issues

### Testing
- [x] Rollback verification (apply -> rollback -> compare)
- [x] Real-world config corpus testing — 49 valid configs + 3 negative fixtures across
      10 shape directories, every one validated against real nginx in Docker, with a
      shape checklist (`tests/configs/SHAPES.md`), a provenance manifest and a
      near-duplicate assertion (`tests/test-corpus.sh`) so the count cannot be gamed
- [x] Nginx version matrix testing (1.18, 1.22, 1.25, 1.27) — `tests/test-version-matrix.sh`
      runs `nginx -t` in each official Docker image: a minimal full config and the
      portable http-context templates must pass on all four, while HTTP/3-era
      fixtures skip below their minimum version instead of failing. Wired into
      `tests/run-tests.sh`; skips cleanly without Docker or a missing Hub tag

### UX
- [ ] `--no-color` flag for CI environments
- [ ] Better progress indicators
- [x] Full JSON output (not placeholder)
- [ ] Clean up dry-run output in interactive mode

### Bug Fixes
- [x] Review sudo usage (~48 calls, minimize surface) — features and template
      deployment now go through `smart_copy`/`smart_mkdir`/`smart_write` in
      `lib/core/helpers.sh` (sudo only when the target isn't writable).
      honeypot/compiler/warning-fixer/install/backup sudo remains — those
      targets are genuinely root-owned (issue #14 scope).

---

## v0.11.x - Smart Config Parsing (Path B)

### Architecture
- [ ] **AWK-based config AST parsing** - Analyze before modifying
- [ ] **Conflict detection** - Warn if directive already exists.
      *Blocked on the AST parser.* Grep-based conflict detection is exactly how the
      existing detectors ended up host-scoped rather than file-scoped; doing it
      again without a parser repeats that mistake.
- [ ] **Profile system** - `--profile conservative|balanced|aggressive`.
      Not started (`grep -c profile nginx-optimizer.sh` = 0). Self-contained — no
      parser dependency, can land independently of the AST work.
- [x] **Server sizing detection** - Auto-adjust values based on RAM/CPU.
      **Shipped** as `lib/core/sysinfo.sh`: the RAM-tier ladder driving
      server-tuning, php-fpm-tuning, opcache, keys_zone and worker_connections,
      with a shared `sysinfo_ram_budget_php()` so the tiers cannot over-commit.

### Features
- [ ] Partial rollback (undo single feature).
      **Partly built, further from done than it looks.** `cmd_remove()` delegates to
      `feature_remove()`, which only deletes one template file and sed-drops lines
      naming it. Three holes: no `feature_remove_custom_*` exists anywhere in the
      tree; multi-template features are unremovable because `FEATURE_TEMPLATE` is a
      comma-joined string that `feature_remove` never splits (security,
      fastcgi-cache); template-less features hard-fail (server-tuning,
      php-fpm-tuning, redis). It also reverses no in-place edits at all.
- [ ] Config diff visualization
- [x] Missing core optimizations (worker_processes, open_file_cache, sendfile, etc.)
      — **shipped** as the `server-tuning` and `open-file-cache` features.
- [x] Early Hints (HTTP 103) forwarding — `early_hints on;` for LCP win on dynamic pages (nginx >= 1.29)

### Distribution
- [ ] APT/DEB package
- [ ] RPM package

---

## v1.0.0 - Production Ready (Path C)

### Integration
- [ ] **Python crossplane integration** - Proper nginx config parsing
- [ ] **Ansible role/playbook** - For automated deployments
- [ ] Terraform provider (stretch goal)
- [ ] Prometheus metrics export

### Advanced
- [ ] Multi-server support
- [ ] Kubernetes Ingress nginx support
- [ ] Non-WordPress nginx support

---

## Strategic Direction

### Focus: WordPress on nginx (single-server)

Not trying to be a general nginx tool. Our value proposition:
> "One command to make WordPress on nginx fast and secure"

### Three Paths (from PRODUCTION-READINESS.md)

**Path A (Complete):** Polish bash approach - Ship faster, learn from users
**Path B (Next):** Add AWK-based parsing - More robust, fewer surprises
**Path C (Future):** Python/Go rewrite with crossplane - Professional grade

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development guidelines.
See [docs/PRODUCTION-READINESS.md](docs/PRODUCTION-READINESS.md) for detailed technical debt analysis.
