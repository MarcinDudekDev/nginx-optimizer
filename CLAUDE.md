# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## BEFORE PUSHING - MANDATORY

**ALWAYS run shellcheck and fix issues before pushing:**
```bash
shellcheck --severity=warning nginx-optimizer.sh nginx-optimizer-lib/*.sh
```
A pre-push hook enforces this, but run manually to catch issues early.

## Project Overview

nginx-optimizer is a bash-based CLI tool for optimizing nginx configurations. It supports HTTP/3, FastCGI caching, Redis, Brotli compression, security headers, and WordPress-specific optimizations. Works with system nginx, Docker containers, and wp-test environments.

## Common Commands

```bash
# Analyze current configuration
./nginx-optimizer.sh analyze
./nginx-optimizer.sh analyze mysite.local

# Apply optimizations
./nginx-optimizer.sh optimize --dry-run       # Preview changes
./nginx-optimizer.sh optimize                  # Apply all
./nginx-optimizer.sh optimize --feature http3  # Single feature
./nginx-optimizer.sh optimize --exclude brotli # Skip feature

# Other operations
./nginx-optimizer.sh status                    # Check optimization status
./nginx-optimizer.sh benchmark mysite.local    # Performance test
./nginx-optimizer.sh rollback 20250124-143022  # Restore backup
./nginx-optimizer.sh honeypot mysite.com       # Deploy bot tarpit
```

## Architecture

### Entry Point
`nginx-optimizer.sh` - Main script that parses arguments, initializes directories, sources libraries, and dispatches to command functions.

### Plugin Architecture (lib/) - NEW
Modular feature system where each feature is a self-contained module:

```
lib/
├── registry.sh          # Feature registration API
├── core/
│   └── templates.sh     # Template deployment helpers
└── features/
    ├── http3.sh         # HTTP/3 QUIC
    ├── fastcgi-cache.sh # FastCGI caching
    ├── brotli.sh        # Brotli compression
    ├── security.sh      # Security headers
    ├── wordpress.sh     # WordPress exclusions
    ├── redis.sh         # Redis object cache
    └── opcache.sh       # PHP OpCache
```

**Registry API:**
- `feature_register()` - Register a feature module
- `feature_detect()` - Check if feature is enabled
- `feature_apply()` - Apply a feature optimization
- `feature_list()` - List all registered features
- `feature_get()` - Get feature metadata

**Adding a new feature:**
1. Create `lib/features/myfeature.sh`
2. Define `FEATURE_ID`, `FEATURE_DISPLAY`, `FEATURE_DETECT_PATTERN`
3. Optionally add `feature_detect_custom_myfeature()` or `feature_apply_custom_myfeature()`
4. Call `feature_register` at the end

### Legacy Library Modules (nginx-optimizer-lib/)
- `detector.sh` - Uses registry for detection via `detect_all_features_for_site()`
- `optimizer.sh` - Uses registry for optimization via `feature_apply()` loop
- `backup.sh` - Timestamped backup/restore with rsync
- `validator.sh` - Tests nginx config validity and reloads
- `compiler.sh` - Compiles nginx from source with Brotli
- `benchmark.sh` - Performance testing with curl timing
- `monitoring.sh` - Sets up monitoring dashboard scripts
- `honeypot.sh` - Bot tarpit with canary tokens and fail2ban integration
- `docker.sh` - Docker image building
- `warning-fixer.sh` - Auto-fix nginx config warnings

### Templates (nginx-optimizer-templates/)
Config snippets that get copied/included into nginx configurations:
- `http3-quic.conf`, `fastcgi-cache.conf`, `compression.conf`
- `security-headers.conf`, `wordpress-exclusions.conf`
- `honeypot-tarpit.conf`, `rate-limiting.conf`

### Data Storage
`~/.nginx-optimizer/` contains:
- `backups/` - Timestamped configuration backups
- `logs/` - Operation logs
- `honeypot/` - Canary tokens and attacker IPs

## Key Patterns

### Instance Detection
The detector maintains `DETECTED_INSTANCES` array with entries as `type:name:path`:
- `system:nginx:/etc/nginx/nginx.conf`
- `docker:container-name:container-name`
- `wp_test:domain.local:path/to/site`

### Dry Run Mode
All optimization functions check `$DRY_RUN` global and log "[DRY RUN] Would..." instead of making changes.

### wp-test Integration
Sites live in `~/.wp-test/sites/`, nginx config in `~/.wp-test/nginx/`. The optimizer adds vhost.d configs and conf.d includes for each site.

### Server Block Injection
`inject_server_includes()` in optimizer.sh uses awk to safely inject include directives after the first uncommented `server {` block, with nginx -t validation.

### Transaction Pattern
optimizer.sh implements atomic file operations via `transaction_start/add_file/commit/rollback` for multi-file changes.

## Available Features

| Feature | Description |
|---------|-------------|
| `http3` / `quic` | HTTP/3 QUIC support (nginx >= 1.25) |
| `fastcgi-cache` / `cache` | Full-page caching for WordPress |
| `redis` | Redis object cache container |
| `brotli` / `compression` | Brotli + Gzip compression |
| `security` / `headers` | HSTS, CSP, rate limiting |
| `wordpress` / `wp` | xmlrpc blocking, wp-config protection |
| `opcache` / `php` | PHP OpCache tuning |
| `honeypot` | Bot tarpit with canary tokens |

## Testing Changes

After modifying optimization logic:
```bash
# Test on a wp-test site
./nginx-optimizer.sh optimize quiz-test.local --dry-run

# Verify nginx config is valid
nginx -t

# Check applied optimizations
./nginx-optimizer.sh status quiz-test.local
```

## Global Variables

Key globals used across modules:
- `$DRY_RUN`, `$FORCE`, `$QUIET` - Operation mode flags
- `$TARGET_SITE` - Specific site to operate on
- `$SPECIFIC_FEATURE`, `$EXCLUDE_FEATURE` - Feature filtering
- `$TEMPLATE_DIR`, `$DATA_DIR`, `$BACKUP_DIR` - Path constants
- `$WP_TEST_SITES`, `$WP_TEST_NGINX` - wp-test paths
