# nginx-optimizer

Comprehensive NGINX optimization tool with HTTP/3, Brotli, FastCGI cache, Redis, security headers, and WordPress-specific optimizations.

## Installation

Clone or download to your preferred location:
```bash
git clone https://github.com/MarcinDudekDev/nginx-optimizer.git ~/Tools/nginx-optimizer
```

Make sure it's executable:
```bash
chmod +x ~/Tools/nginx-optimizer/nginx-optimizer.sh
```

Add to PATH (optional):
```bash
echo 'export PATH="$PATH:$HOME/Tools/nginx-optimizer"' >> ~/.zshrc
source ~/.zshrc
```

## Features

✅ **HTTP/3 (QUIC)** - Modern protocol support with 0-RTT
✅ **FastCGI Full-Page Cache** - Bypass PHP for 99% of visitors
✅ **Redis Object Cache** - Database query caching for logged-in users
✅ **Brotli + Gzip Compression** - Auto-compile nginx with Brotli if needed
✅ **Security Headers** - HSTS, CSP, X-Frame-Options, rate limiting
✅ **WordPress Exclusions** - Block xmlrpc, protect wp-config, cache bypass rules
✅ **WooCommerce Detection** - Auto-applies specific cache rules
✅ **PHP OpCache** - Balanced mode with JIT support (PHP 8.0+)
✅ **Performance Benchmarks** - Before/after testing with detailed metrics
✅ **Monitoring Dashboard** - Real-time nginx status and cache metrics
✅ **Auto-Update Bot Blocker** - Keep malicious bot lists current
✅ **Comprehensive Backups** - Timestamped snapshots with rollback

## Known Limitations

### HTTP/3 and Self-Signed Certificates

The nginx-optimizer correctly applies HTTP/3 (QUIC) configuration and the server properly sends the `alt-svc: h3=":443"` header. However, modern browsers (Chrome, Brave, Safari) enforce a security restriction that prevents HTTP/3 connections when using self-signed or mkcert-generated certificates.

**Key Points:**
- HTTP/3 configuration IS applied correctly by the optimizer
- The server advertises HTTP/3 support via `alt-svc` header
- Browsers refuse to upgrade to HTTP/3 with self-signed/mkcert certificates for security reasons
- This is a browser security restriction, NOT a configuration issue
- HTTP/3 WILL work in production with proper CA-signed certificates (Let's Encrypt, etc.)
- For local development, HTTP/2 is the maximum protocol version achievable in most browsers
- Firefox can be configured to allow HTTP/3 with self-signed certificates via `about:config` (set `network.http.http3.enable_0rtt` and related flags) for testing purposes

**Verification:** You can confirm HTTP/3 is configured correctly by checking response headers (`alt-svc: h3=":443"`) even though the connection remains on HTTP/2 in local development environments.

## Quick Start

### Analyze Current Setup
```bash
nginx-optimizer analyze
```

### Optimize All Sites
```bash
nginx-optimizer optimize --dry-run  # Preview changes first
nginx-optimizer optimize             # Apply optimizations
```

### Optimize Specific wp-test Site
```bash
nginx-optimizer optimize quiz-test.local
```

### Apply Single Feature
```bash
nginx-optimizer optimize --feature http3
nginx-optimizer optimize --feature fastcgi-cache
```

### Exclude Feature
```bash
nginx-optimizer optimize --exclude brotli
```

## Commands

| Command | Description |
|---------|-------------|
| `analyze [site]` | Show current optimization status |
| `optimize [site]` | Apply optimizations (all or specific site) |
| `rollback [timestamp]` | Restore previous configuration |
| `test [site]` | Test nginx configuration |
| `status [site]` | Show optimization status |
| `list` | List all detected nginx installations |
| `benchmark [site]` | Run performance tests |
| `help` | Show help message |

## Options

| Option | Description |
|--------|-------------|
| `--dry-run` | Preview changes without applying |
| `--force` | Skip confirmations |
| `--feature <name>` | Apply specific feature only |
| `--exclude <name>` | Skip specific feature |
| `--backup-dir <path>` | Custom backup location |
| `-v, --version` | Show version |

## Available Features

- `http3` - HTTP/3 (QUIC) support
- `fastcgi-cache` - Full-page FastCGI caching
- `redis` - Redis object caching
- `brotli` - Brotli + Zopfli compression
- `security` - Security headers + rate limiting
- `wordpress` - WordPress-specific exclusions
- `opcache` - PHP OpCache optimization

## Directory Structure

```
nginx-optimizer/
├── nginx-optimizer.sh           # Main executable
├── nginx-optimizer-lib/         # Library modules
│   ├── detector.sh             # Detection & analysis
│   ├── backup.sh               # Backup management
│   ├── optimizer.sh            # Core optimization logic
│   ├── validator.sh            # Testing & validation
│   ├── compiler.sh             # Brotli nginx compilation
│   ├── docker.sh               # Docker image builder
│   ├── monitoring.sh           # Monitoring setup
│   └── benchmark.sh            # Performance testing
└── nginx-optimizer-templates/   # Config templates
    ├── http3-quic.conf
    ├── fastcgi-cache.conf
    ├── redis-cache.conf
    ├── compression.conf
    ├── security-headers.conf
    ├── wordpress-exclusions.conf
    ├── opcache.ini
    └── bot-blocker-update.sh

~/.nginx-optimizer/              # Data directory
├── backups/                    # Timestamped backups
├── logs/                       # Optimization logs
├── benchmarks/                 # Performance test results
└── scripts/                    # Monitoring scripts
```

## Usage Examples

### Complete Optimization Workflow
```bash
# 1. Analyze current state
nginx-optimizer analyze

# 2. Preview changes
nginx-optimizer optimize --dry-run

# 3. Run baseline benchmark
nginx-optimizer benchmark mysite.local

# 4. Apply optimizations
nginx-optimizer optimize mysite.local

# 5. Run post-optimization benchmark
nginx-optimizer benchmark mysite.local

# 6. Check status
nginx-optimizer status mysite.local
```

### Rollback if Needed
```bash
# List available backups
ls -lh ~/.nginx-optimizer/backups/

# Restore specific backup
nginx-optimizer rollback 20250124-143022
```

### Monitoring
```bash
# View monitoring dashboard
~/.nginx-optimizer/scripts/dashboard.sh

# Monitor cache performance
~/.nginx-optimizer/scripts/monitor-cache.sh

# Analyze access logs
~/.nginx-optimizer/scripts/analyze-logs.sh access

# Analyze error logs
~/.nginx-optimizer/scripts/analyze-logs.sh error
```

### Custom Docker Image
```bash
# Build custom nginx image with HTTP/3 + Brotli
nginx-optimizer optimize --feature brotli

# The build process is automatic if Brotli module not found
```

## Integration with wp-test

nginx-optimizer automatically detects wp-test sites and can optimize them:

```bash
# Optimize all wp-test sites
nginx-optimizer optimize

# Optimize specific wp-test site
nginx-optimizer optimize quiz-test.local

# Add Redis to wp-test site
nginx-optimizer optimize quiz-test.local --feature redis
```

After optimization, restart containers:
```bash
cd ~/.wp-test/sites/quiz-test.local
docker-compose restart
```

## Performance Improvements

Expected performance gains:

- **Page Load**: 40-60% faster (cached pages)
- **TTFB**: 30-50% reduction (FirstByte time)
- **Database Queries**: 30% reduction (with Redis)
- **Bandwidth**: 60-70% savings (Brotli compression)
- **Security Score**: A+ (SSL Labs, SecurityHeaders.com)

## Troubleshooting

### Bash Version (macOS)
If you see "declare: -A: invalid option", upgrade to bash 4+:
```bash
brew install bash
# Then use: /usr/local/bin/bash nginx-optimizer
```

### Permission Denied
Some operations require sudo:
```bash
sudo nginx-optimizer optimize
```

### Docker Issues
Ensure Docker is running:
```bash
docker ps
```

### Nginx Not Reloading
Test configuration first:
```bash
nginx -t
```

## Logs

All operations are logged:
```bash
# View latest log
ls -lt ~/.nginx-optimizer/logs/ | head -1

# Tail log in real-time
tail -f ~/.nginx-optimizer/logs/optimization-*.log
```

## Auto-Updates

Update bot blocker rules:
```bash
~/.nginx-optimizer/templates/bot-blocker-update.sh
```

Add to cron for automatic updates:
```bash
# Update bot lists daily at 3 AM
0 3 * * * ~/.nginx-optimizer/templates/bot-blocker-update.sh
```

## Security Notes

- All sensitive files (wp-config.php, .env) are protected
- xmlrpc.php is blocked by default
- Rate limiting prevents brute force attacks
- Security headers provide XSS/clickjacking protection
- HSTS enforces HTTPS connections

## Support

For issues or questions:
- Check logs: `~/.nginx-optimizer/logs/`
- Test config: `nginx -t`
- Rollback: `nginx-optimizer rollback`

## Version

nginx-optimizer v1.0.0

## License

Created for use with wp-test and general nginx optimization.
