# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.9.0-beta] - 2025-01-09

### Added
- Comprehensive test suite with 15 passing tests
- Test configuration corpus with 12 real-world nginx configs
- CI workflow with ShellCheck integration
- Bash version check at startup (requires bash 3.2+)
- Portable file locking using mkdir-based mechanism
- Support for macOS and BSD systems

### Changed
- Version bumped to 0.9.0-beta to reflect beta status
- Replaced bash 4+ associative arrays with portable alternatives
- Replaced GNU-specific find commands with portable alternatives
- Replaced flock with cross-platform mkdir-based locking
- Improved shellcheck compliance (fixed 139 SC2155 warnings)

### Fixed
- **Critical**: macOS bash 3.2 compatibility (removed `declare -A`)
- **Critical**: GNU find dependency (replaced `-printf` with portable alternatives)
- **Critical**: flock dependency (not available on macOS/BSD)
- Shellcheck warnings reduced from 139 to 0
- Variable declaration now properly separated from command execution (SC2155)

### Security
- Added version check to prevent execution on incompatible bash versions
- Improved input validation in backup and optimizer modules

## [1.2.0] - 2025-01-09

### Added
- Bot tarpit feature with canary tokens for honeypot detection
- HTTP basic auth protection for honeypot endpoints
- Automatic credential generation for honeypot traps

### Security
- Honeypot module to detect and tarpit malicious bots
- Canary token system for intrusion detection

## [1.1.0] - 2025-01-09

### Added
- Quiet mode (`--quiet`) for scripting support
- Machine-readable output support for automation
- Exit code standardization for CI/CD integration

### Changed
- Improved output handling for non-interactive environments
- Enhanced logging for automated workflows

### Fixed
- UX issues in optimize command
- Output formatting in quiet mode

## [1.0.0] - 2025-01-08

### Added
- HTTP/3 (QUIC) support with 0-RTT
- FastCGI full-page caching with WordPress-aware bypass rules
- Redis object cache integration
- Brotli compression with automatic nginx compilation
- Gzip compression configuration
- Security headers (HSTS, CSP, X-Frame-Options)
- Rate limiting for brute force protection
- WordPress-specific exclusions (xmlrpc, wp-config protection)
- WooCommerce detection and cache rules
- PHP OpCache balanced configuration with JIT support
- Performance benchmarking (before/after metrics)
- Real-time monitoring dashboard
- Auto-update bot blocker with malicious bot lists
- Comprehensive backup system with timestamped snapshots
- Rollback functionality
- wp-test integration for local WordPress development
- Docker image builder for custom nginx builds
- Dry-run mode for previewing changes
- Feature-specific optimization (`--feature` flag)
- Feature exclusion (`--exclude` flag)

### Commands
- `analyze` - Show current optimization status
- `optimize` - Apply optimizations to sites
- `rollback` - Restore previous configurations
- `test` - Test nginx configuration validity
- `status` - Show optimization status
- `list` - List detected nginx installations
- `benchmark` - Run performance tests
- `help` - Display help message

### Documentation
- Comprehensive README with usage examples
- Known limitations section (HTTP/3 with self-signed certificates)
- Integration guide for wp-test
- Troubleshooting section
- Performance improvement expectations

[Unreleased]: https://github.com/MarcinDudekDev/nginx-optimizer/compare/v0.9.0-beta...HEAD
[0.9.0-beta]: https://github.com/MarcinDudekDev/nginx-optimizer/compare/v1.2.0...v0.9.0-beta
[1.2.0]: https://github.com/MarcinDudekDev/nginx-optimizer/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/MarcinDudekDev/nginx-optimizer/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/MarcinDudekDev/nginx-optimizer/releases/tag/v1.0.0
