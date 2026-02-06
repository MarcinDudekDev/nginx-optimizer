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
- [ ] `doctor` command - Diagnose common issues

### Testing
- [ ] Rollback verification (apply -> rollback -> compare)
- [ ] Real-world config corpus testing (50+ configs)
- [ ] Nginx version matrix testing (1.18, 1.22, 1.25, 1.27)

### UX
- [ ] `--no-color` flag for CI environments
- [ ] Better progress indicators
- [ ] Full JSON output (not placeholder)
- [ ] Clean up dry-run output in interactive mode

### Bug Fixes
- [ ] Review sudo usage (~48 calls, minimize surface)

---

## v0.11.x - Smart Config Parsing (Path B)

### Architecture
- [ ] **AWK-based config AST parsing** - Analyze before modifying
- [ ] **Conflict detection** - Warn if directive already exists
- [ ] **Profile system** - `--profile conservative|balanced|aggressive`
- [ ] **Server sizing detection** - Auto-adjust values based on RAM/CPU

### Features
- [ ] Partial rollback (undo single feature)
- [ ] Config diff visualization
- [ ] Missing core optimizations (worker_processes, open_file_cache, sendfile, etc.)

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
