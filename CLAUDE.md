# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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

### Library Modules (nginx-optimizer-lib/)
- `detector.sh` - Detects nginx installations (system, Docker, wp-test) and analyzes config status
- `optimizer.sh` - Core optimization logic, applies features to nginx configs
- `backup.sh` - Timestamped backup/restore with rsync
- `validator.sh` - Tests nginx config validity and reloads
- `compiler.sh` - Compiles nginx from source with Brotli
- `benchmark.sh` - Performance testing with curl timing
- `monitoring.sh` - Sets up monitoring dashboard scripts
- `honeypot.sh` - Bot tarpit with canary tokens and fail2ban integration
- `docker.sh` - Docker image building

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
