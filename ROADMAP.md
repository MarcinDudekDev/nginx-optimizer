# nginx-optimizer Roadmap

## Current Status: v0.9.0-beta

The tool is functional for WordPress on nginx optimization with per-site analysis.

---

## Recently Completed (Phase 6 - Jan 2025)

- [x] Per-site detection and analysis
- [x] Interactive wizard with recommendations
- [x] Persistent interactive loop
- [x] WWW in SSL detection/fix
- [x] HTTP/3 reuseport duplicate handling
- [x] Analysis caching (hash-based)
- [x] 33x faster analysis (batch feature extraction)

---

## Short-term Fixes (Next Session)

### UX Improvements
- [ ] **Clean up dry-run output** in interactive mode (currently cluttered)
- [ ] Better progress indicators
- [ ] Cleaner recommendation display

### Bug Fixes
- [ ] Review sudo usage (~48 calls, minimize surface)
- [ ] Verify rollback restores exact state

---

## Medium-term (Phase 7)

### Architecture
- [ ] **AWK-based config AST parsing** - Don't blindly append, analyze first
- [ ] **Profile system** - `--profile conservative|balanced|aggressive`
- [ ] **Server sizing detection** - Auto-adjust values based on RAM/CPU
- [ ] **Conflict detection** - Warn if directive already exists

### Features
- [ ] Full JSON output mode (not placeholder)
- [ ] `--check` mode (validate without changing)
- [ ] Partial rollback (undo single feature)
- [ ] `doctor` command (diagnose issues)

### Distribution
- [ ] APT/DEB package
- [ ] RPM package
- [ ] Improved one-liner installer

---

## Long-term (Phase 8+)

### Integration
- [ ] **Ansible role/playbook** - For automated deployments
- [ ] Terraform provider (stretch goal)
- [ ] Prometheus metrics export

### Advanced
- [ ] **Python crossplane integration** - Proper nginx config parsing
- [ ] Multi-server support
- [ ] Kubernetes Ingress nginx support
- [ ] Config diff visualization

---

## Strategic Direction

### Focus: WordPress on nginx (single-server)

Not trying to be a general nginx tool. Our value proposition:
> "One command to make WordPress on nginx fast and secure"

### Three Paths (from PRODUCTION-READINESS.md)

**Path A (Current):** Polish bash approach - Ship faster, learn from users
**Path B (Next):** Add AWK-based parsing - More robust, fewer surprises
**Path C (Future):** Python/Go rewrite with crossplane - Professional grade

**Current approach:** Path A, designing for Path B.

---

## Version Plan

```
v0.9.x  - Current beta, gathering feedback
v0.10.x - UX polish, dry-run cleanup
v0.11.x - AWK parsing foundation
v1.0.0  - Production ready (after Path B basics)
```

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development guidelines.
See [docs/PRODUCTION-READINESS.md](docs/PRODUCTION-READINESS.md) for detailed technical debt analysis.
