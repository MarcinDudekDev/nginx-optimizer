```
           _                       _   _       _
 _ _  __ _(_)_ _ __ _____ ___ _ __| |_(_)_ __ (_)______ _ _
| ' \/ _` | | ' \\ \ /___/ _ \ '_ \  _| | '  \| |_ / -_) '_|
|_||_\__, |_|_||_/_\_\   \___/ .__/\__|_|_|_|_|_/__\___|_|
     |___/                   |_|
```

# nginx-optimizer

[![CI](https://github.com/MarcinDudekDev/nginx-optimizer/actions/workflows/ci.yml/badge.svg)](https://github.com/MarcinDudekDev/nginx-optimizer/actions/workflows/ci.yml)
[![Version](https://img.shields.io/badge/version-0.10.0--beta-blue)]()
[![License](https://img.shields.io/badge/license-MIT-green)]()
[![Bash](https://img.shields.io/badge/bash-3.2%2B-orange)]()

**One command to optimize your entire server stack.** HTTP/3, Brotli, FastCGI cache, Redis, security headers, DDoS protection, bad bot blocking, and WordPress-specific optimizations — with RAM-aware tuning, automatic backup, and rollback.

**Version:** 0.10.0-beta | **Status:** Beta (production-ready for WordPress sites)

<p align="center">
  <img src="docs/screenshots/analyze.svg" alt="nginx-optimizer analyze" width="700">
</p>

<details>
<summary><strong>More screenshots</strong></summary>

### Pre-flight Check
<p align="center">
  <img src="docs/screenshots/check.svg" alt="nginx-optimizer check" width="700">
</p>

### Dry Run Preview
<p align="center">
  <img src="docs/screenshots/optimize-dry-run.svg" alt="nginx-optimizer optimize --dry-run" width="700">
</p>

</details>

## Installation

### One-liner (Recommended)
```bash
curl -fsSL https://raw.githubusercontent.com/MarcinDudekDev/nginx-optimizer/main/install.sh | bash
```

### Homebrew (macOS)
```bash
brew install --HEAD MarcinDudekDev/tap/nginx-optimizer
```

### Manual
```bash
git clone https://github.com/MarcinDudekDev/nginx-optimizer.git ~/Tools/nginx-optimizer
chmod +x ~/Tools/nginx-optimizer/nginx-optimizer.sh
echo 'export PATH="$PATH:$HOME/Tools/nginx-optimizer"' >> ~/.zshrc
source ~/.zshrc
```

### Man Page
```bash
sudo cp docs/nginx-optimizer.1 /usr/share/man/man1/
man nginx-optimizer
```

## Features

| Feature | What it does | Impact |
|---------|-------------|--------|
| **HTTP/3 (QUIC)** | Modern protocol with 0-RTT connection resumption | 15-25% faster on mobile |
| **FastCGI Full-Page Cache** | Serves static HTML, bypasses PHP entirely | TTFB: 400ms -> 15ms |
| **Redis Object Cache** | Database query caching for logged-in users | 30% fewer DB queries |
| **Brotli + Gzip** | Dual compression with 30+ MIME types | 60-70% bandwidth savings |
| **Security Headers** | HSTS, CSP, X-Frame-Options, rate limiting | F -> A+ security grade |
| **WordPress Hardening** | Block xmlrpc, protect wp-config, wp-includes | Closes OWASP Top 10 vectors |
| **PHP OpCache** | JIT-enabled with optimized buffer sizes | 20-40% faster uncached PHP |
| **WooCommerce Detection** | Auto-applies cart/checkout cache bypass rules | Zero cache poisoning |

**Also included:** Performance benchmarks, monitoring dashboard, bot blocker auto-updates, timestamped backups with one-command rollback, state tracking, and config diff.

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

### Interactive Mode (Recommended)
```bash
nginx-optimizer  # Launches interactive wizard
```

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
| `diff [timestamp]` | Show changes between backup and current config |
| `remove [site]` | Remove applied optimizations (with `--feature`) |
| `verify [site]` | Verify applied optimizations match running config |
| `test [site]` | Test nginx configuration |
| `status [site]` | Show optimization status |
| `list` | List all detected nginx installations |
| `benchmark [site]` | Run performance tests |
| `check [site]` | Pre-flight readiness check (deps, config, features) |
| `update` | Self-update from GitHub |
| `help` | Show help message |

## Options

| Option | Description |
|--------|-------------|
| `--dry-run` | Preview changes without applying |
| `--force` | Skip confirmations |
| `--feature <name>` | Apply specific feature only |
| `--exclude <name>` | Skip specific feature |
| `--backup-dir <path>` | Custom backup location |
| `--quiet` | Suppress output (for scripting) |
| `--json` | Output JSON (for status, list, analyze, check) |
| `--no-color` | Disable colored output (also respects `NO_COLOR` env var) |
| `--system-only` | Only operate on system nginx (skip wp-test) |
| `--no-rate-limit` | Disable rate limiting in security config |
| `--check` | Pre-flight check (shorthand for `check` command) |
| `-v, --version` | Show version |

## Available Features

### Performance
| Feature | Aliases | Description |
|---------|---------|-------------|
| `http3` | `quic` | HTTP/3 QUIC with `ssl_early_data` (0-RTT) |
| `fastcgi-cache` | `cache` | Full-page caching with cache lock, purge support, and `stale-while-revalidate` |
| `open-file-cache` | `filecache` | File descriptor caching (RAM-tuned `max` entries) |
| `early-hints` | `103`, `hints` | HTTP 103 Early Hints forwarding for LCP win (nginx >= 1.29) |
| `upstream-keepalive` | `keepalive`, `phpfpm` | Persistent PHP-FPM connections (RAM-tuned pool size) |
| `brotli` | `compression` | Brotli + Gzip compression for 30+ MIME types |
| `log-tuning` | `logs` | Custom log format with upstream timing + buffered writes |

### RAM-Aware Stack Tuning
| Feature | Aliases | Description |
|---------|---------|-------------|
| `server-tuning` | `workers`, `tuning` | `worker_processes auto`, `worker_connections`, `worker_rlimit_nofile` |
| `php-fpm-tuning` | `fpm`, `php-workers` | `pm.max_children` based on RAM budget (50% for PHP @ 40MB/worker) |
| `opcache` | `php` | PHP OpCache + JIT tuning |

### Security & Protection
| Feature | Aliases | Description |
|---------|---------|-------------|
| `security` | `headers` | HSTS, CSP, rate limiting with 429 responses, DDoS connection limits |
| `wordpress` | `wp` | xmlrpc blocking, wp-config protection, upload PHP execution denied |
| `bad-bot-blocker` | `bots` | Block scanners (nikto, sqlmap, wpscan), scrapers (AhrefsBot, SemrushBot) |
| `cloudflare-realip` | `cloudflare` | Restore real visitor IP behind Cloudflare (all IPv4/IPv6 ranges) |
| `honeypot` | | Bot tarpit with canary tokens and fail2ban integration |

### Caching & Infrastructure
| Feature | Aliases | Description |
|---------|---------|-------------|
| `redis` | | Redis object cache container for WordPress |

## RAM-Aware Tuning

The optimizer detects your system's RAM and CPU, then tunes every component to fit — no manual sizing needed. On a $5 VPS, you get conservative values that prevent OOM. On a dedicated server, you get aggressive values that maximize throughput.

```
$ nginx-optimizer check
System: 1024MB RAM, 1 CPU cores → Tier 2 (Small)
  worker_connections: 1024
  fastcgi_cache zone: 20m (~2% of RAM), disk max: 128m
  open_file_cache max: 5000
  php-fpm max_children: 12 (~512MB for PHP @ 40MB/worker)
  conn limit per IP: 30, per server: 1000
  RAM budget: ~50% PHP-FPM, ~20% MySQL, ~15% OS, ~15% nginx/Redis/buffers
```

| Tier | RAM | PHP Workers | Cache Zone | Conn/IP | Conn/Server |
|------|-----|-------------|-----------|---------|-------------|
| 1 | ≤512MB | 6 | 10m | 20 | 500 |
| 2 | ≤1GB | 12 | 20m | 30 | 1,000 |
| 3 | ≤2GB | 25 | 50m | 50 | 3,000 |
| 4 | ≤4GB | 51 | 100m | 75 | 5,000 |
| 5 | ≤8GB | 102 | 128m | 100 | 10,000 |
| 6 | >8GB | 200 | 256m | 150 | 20,000 |

Under DDoS or heavy load, rate-limited requests return **429 Too Many Requests** (not 503), so monitoring tools see "load shedding" instead of "server down."

## Directory Structure

```
nginx-optimizer/
├── nginx-optimizer.sh           # Main executable
├── nginx-optimizer-lib/         # Legacy library modules
│   ├── detector.sh             # Detection & analysis
│   ├── backup.sh               # Backup management
│   ├── optimizer.sh            # Core optimization logic
│   ├── validator.sh            # Testing & validation
│   ├── compiler.sh             # Brotli nginx compilation
│   ├── docker.sh               # Docker image builder
│   ├── monitoring.sh           # Monitoring setup
│   └── benchmark.sh            # Performance testing
├── lib/                         # Plugin architecture
│   ├── registry.sh             # Feature registration API
│   ├── core/
│   │   ├── sysinfo.sh         # RAM/CPU detection & tuning values
│   │   └── templates.sh       # Template deployment helpers
│   └── features/               # Self-contained feature modules (14)
│       ├── http3.sh           # HTTP/3 QUIC + early data
│       ├── fastcgi-cache.sh   # Full-page cache + purge
│       ├── brotli.sh          # Compression
│       ├── security.sh        # Headers + DDoS protection
│       ├── wordpress.sh       # WP hardening
│       ├── redis.sh           # Object cache
│       ├── opcache.sh         # PHP OpCache
│       ├── upstream-keepalive.sh
│       ├── open-file-cache.sh
│       ├── server-tuning.sh   # RAM-aware worker tuning
│       ├── php-fpm-tuning.sh  # RAM-aware FPM tuning
│       ├── bad-bot-blocker.sh
│       ├── cloudflare-realip.sh
│       └── log-tuning.sh
└── nginx-optimizer-templates/   # Config templates (20+)

tests/
├── run-tests.sh                # Unit test suite
├── test-with-nginx.sh          # Docker-based nginx config validation
├── test-corpus.sh              # Corpus shape coverage + near-duplicate assertions
└── configs/                    # 49 test configs + 3 negative fixtures
    ├── SHAPES.md               # The shape checklist test-corpus.sh enforces
    ├── MANIFEST.tsv            # Generated: path, shape, provenance type, source
    ├── minimal/                # Stock nginx, H5BP baseline, smallest static vhost
    ├── distro-defaults/        # Debian/Ubuntu, gzip-commented Ubuntu, Alpine
    ├── panel-generated/        # cPanel EA4 main config + service vhost
    ├── wordpress/              # Plain, TLS, microcache, WooCommerce, multisite, Bedrock
    ├── reverse-proxy/          # Keepalive, LB, sticky hash, WebSocket, gRPC, SSE, unix socket
    ├── app-stacks/             # Laravel, Django/uWSGI, Node, SPA, Next.js
    ├── tls/                    # Certbot, Cloudflare origin, HTTP/3, mTLS, OCSP stapling
    ├── complex/                # Multisite maps, modular includes, multi-server API gateway
    ├── edge-cases/             # Already-optimized, comment-dense, CRLF, nested, duplicate names
    └── invalid/                # Negative fixtures — these MUST fail `nginx -t`

~/.nginx-optimizer/              # Data directory
├── backups/                    # Timestamped backups
├── state.json                  # Applied optimization state
├── logs/                       # Optimization logs
├── benchmarks/                 # Performance test results
└── scripts/                    # Monitoring scripts
```

## Architecture

```mermaid
graph TB
    CLI["nginx-optimizer.sh<br/><i>CLI Entry Point</i>"]

    subgraph Libraries ["nginx-optimizer-lib/"]
        DET["detector.sh<br/>Instance Detection"]
        OPT["optimizer.sh<br/>Apply & State Tracking"]
        BAK["backup.sh<br/>Backup & Rollback"]
        VAL["validator.sh<br/>nginx -t & Reload"]
        UI["ui.sh<br/>Clean Output"]
    end

    subgraph Core ["lib/core/"]
        SYS["sysinfo.sh<br/>RAM/CPU Detection"]
        TPL["templates.sh<br/>Deployment"]
    end

    subgraph Plugins ["lib/features/ — 14 Feature Modules"]
        REG["registry.sh<br/>Feature Registry API"]
        HTTP3["http3 · cache · brotli"]
        SEC["security · wordpress · bots"]
        TUNE["server-tuning · php-fpm"]
        INFRA["redis · opcache · keepalive"]
        EXTRA["cloudflare · logs · filecache"]
    end

    subgraph Targets ["Detected Environments"]
        SYS["System nginx"]
        DOCK["Docker Containers"]
        WPTEST["wp-test Sites"]
    end

    CLI --> DET
    CLI --> OPT
    CLI --> BAK
    OPT --> REG
    REG --> HTTP3 & SEC & TUNE & INFRA & EXTRA
    TUNE --> SYS
    DET --> SYS & DOCK & WPTEST
    OPT --> VAL
    BAK --> VAL

    style CLI fill:#61AFEF,stroke:#528CC7,color:#fff
    style REG fill:#C678DD,stroke:#A55FBB,color:#fff
    style DET fill:#98C379,stroke:#7BA35F,color:#fff
    style OPT fill:#E5C07B,stroke:#C4A35E,color:#fff
    style BAK fill:#E06C75,stroke:#C0535C,color:#fff
```

### Optimization Workflow

```mermaid
flowchart LR
    A["1. analyze"] --> B["2. check"]
    B --> C["3. optimize\n--dry-run"]
    C --> D["4. optimize"]
    D --> E["5. verify"]
    E --> F{Issues?}
    F -->|No| G["Done"]
    F -->|Yes| H["rollback"]
    H --> A
    D -.->|auto| BAK["backup\ncreated"]
    D -.->|auto| STATE["state.json\nupdated"]

    style A fill:#61AFEF,stroke:#528CC7,color:#fff
    style D fill:#98C379,stroke:#7BA35F,color:#fff
    style H fill:#E06C75,stroke:#C0535C,color:#fff
    style G fill:#98C379,stroke:#7BA35F,color:#fff
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

## Before & After: Test Config Comparisons

The test suite includes real-world nginx configurations representing common deployment patterns. Below is what each config is missing and what nginx-optimizer applies, with the performance impact of each optimization.

### 1. Basic WordPress (`basic-wordpress.conf`)

A typical WordPress site with PHP-FPM on port 80 — no SSL, no compression, no caching, no security headers.

| Area | Before | After nginx-optimizer |
|------|--------|----------------------|
| **Protocol** | HTTP/1.1 only (port 80) | HTTP/3 QUIC + TLS 1.3 with 0-RTT resumption |
| **Compression** | None | Brotli (level 6) + Gzip fallback for 30+ MIME types |
| **Page caching** | Every request hits PHP-FPM | FastCGI cache serves static HTML for anonymous visitors |
| **Object caching** | None (every page = full DB round-trip) | Redis object cache reduces MySQL queries by ~30% |
| **Security headers** | None | HSTS, X-Frame-Options, X-Content-Type-Options, CSP, Referrer-Policy, Permissions-Policy |
| **Rate limiting** | None | Login: 5 req/min, API: 30 req/s, General: 10 req/s |
| **WordPress hardening** | Basic `.` and upload PHP deny | + xmlrpc.php blocked (return 444), wp-config.php protected, wp-includes PHP denied |
| **PHP tuning** | Default OpCache | JIT-enabled OpCache with optimized buffer sizes |
| **Static assets** | 30-day expiry | 1-year expiry with `immutable` flag |

**Impact:** Page load drops from ~800ms (uncached PHP) to ~50ms (cache HIT). TTFB goes from 400ms to <20ms for cached pages. Bandwidth reduced 60-70% via Brotli. SecurityHeaders.com grade goes from F to A+.

---

### 2. WooCommerce High-Traffic (`woocommerce-high-traffic.conf`)

An e-commerce site with SSL, FastCGI cache, and WooCommerce-specific cache bypass rules already configured.

| Area | Before | After nginx-optimizer |
|------|--------|----------------------|
| **Protocol** | TLS 1.2/1.3 over HTTP/1.1 | + HTTP/3 QUIC with `Alt-Svc` header and 0-RTT |
| **Compression** | None | Brotli + Gzip — compresses API responses, CSS/JS, fonts |
| **Page caching** | FastCGI cache present (60min TTL) | Already optimal — optimizer detects and skips |
| **Security headers** | None | Full header suite (HSTS, CSP, X-Frame-Options, etc.) |
| **Rate limiting** | None | Login throttling prevents brute-force on `/wp-login.php` |
| **WordPress hardening** | xmlrpc.php denied | + wp-config.php, wp-includes PHP, hidden files |
| **PHP tuning** | Default OpCache | JIT-enabled OpCache — speeds up uncached WooCommerce requests |

**Impact:** HTTP/3 eliminates head-of-line blocking — improves load times by 15-25% on lossy mobile connections. Brotli compresses product page HTML from ~120KB to ~25KB. Security headers close XSS/clickjacking attack vectors that payment processors (Stripe, PayPal) audit for.

---

### 3. WordPress SSL Optimized (`wordpress-ssl-optimized.conf`)

A production WordPress site with proper SSL settings, HSTS, and basic security rules.

| Area | Before | After nginx-optimizer |
|------|--------|----------------------|
| **Protocol** | TLS 1.2/1.3 with strong ciphers | + HTTP/3 QUIC with 0-RTT connection resumption |
| **Compression** | None | Brotli + Gzip for all text-based content |
| **Page caching** | None — every request hits PHP | FastCGI full-page cache (60min TTL, stale serving) |
| **Object caching** | None | Redis object cache for database queries |
| **Security headers** | HSTS only (`max-age=63072000`) | + X-Frame-Options, X-Content-Type-Options, Referrer-Policy, Permissions-Policy |
| **Rate limiting** | None | Zone-based rate limiting (login, API, general) |
| **WordPress hardening** | xmlrpc + wp-config denied | + wp-includes PHP denied, hidden files return 404 |
| **PHP tuning** | Default OpCache | JIT + optimized interned strings buffer |

**Impact:** FastCGI cache takes TTFB from ~350ms to <15ms for 95%+ of page views. Compression saves ~65% bandwidth on text content. Complete security header suite closes 5 OWASP Top 10 attack vectors.

---

### 4. Basic Reverse Proxy (`basic-proxy.conf`)

A plain HTTP reverse proxy forwarding to a backend on port 8080.

| Area | Before | After nginx-optimizer |
|------|--------|----------------------|
| **Protocol** | HTTP/1.1 to clients and backend | HTTP/3 QUIC to clients, HTTP/1.1 keepalive to backend |
| **Compression** | None | Brotli + Gzip — compresses proxied responses before sending to client |
| **Security headers** | None | Full header suite added to proxied responses |
| **Rate limiting** | None | General rate limiting protects backend from traffic spikes |
| **Timeouts** | 60s connect/send/read | Unchanged (already reasonable) |
| **Buffering** | 4k buffer, 8x4k proxy buffers | Unchanged (already tuned) |

**Impact:** Compression alone reduces transferred bytes by 60-70% for text-heavy API responses. HTTP/3 benefits mobile and high-latency clients significantly. Security headers protect against downstream XSS/clickjacking even when the backend doesn't set them.

---

### 5. Load Balancer (`load-balancer.conf`)

An SSL-terminated load balancer with weighted backends, `least_conn` strategy, and automatic failover.

| Area | Before | After nginx-optimizer |
|------|--------|----------------------|
| **Protocol** | TLS 1.x (default ciphers) | + HTTP/3 QUIC, TLS 1.3 only, AEAD ciphers |
| **Compression** | None | Brotli + Gzip on responses before forwarding to client |
| **Security headers** | None | HSTS, X-Frame-Options, X-Content-Type-Options, etc. |
| **Rate limiting** | None | Connection + request rate limiting protects all backends |
| **Health check** | `/health` endpoint (200 OK) | Unchanged — already present |
| **Failover** | `proxy_next_upstream` with 3 retries | Unchanged (already configured) |

**Impact:** TLS 1.3 reduces handshake latency by one round-trip (1-RTT vs 2-RTT). HTTP/3 0-RTT means returning visitors skip the handshake entirely. Rate limiting at the load balancer protects all 3 backend servers simultaneously.

---

### 6. WordPress Multisite (`multi-site-wordpress.conf`)

WordPress Multisite with subdirectory routing, map-based blog detection, and SSL.

| Area | Before | After nginx-optimizer |
|------|--------|----------------------|
| **Protocol** | TLS (default settings) | + HTTP/3 QUIC, optimized TLS session cache |
| **Compression** | None | Brotli + Gzip for all subsites simultaneously |
| **Page caching** | None — every subsite request hits PHP | FastCGI cache with per-URI keys (isolates subsites) |
| **Security headers** | None | Full header suite applied across all subsites |
| **Rate limiting** | None | Shared zones protect the entire multisite installation |
| **Static assets** | 24h expiry | 1-year expiry with `immutable` — eliminates revalidation |
| **WordPress hardening** | Hidden files denied | + xmlrpc blocked, wp-config protected, wp-includes locked |

**Impact:** Multisite installations are especially sensitive to caching — each subsite multiplies uncached PHP load. FastCGI cache reduces server CPU by 80-90% for anonymous traffic across all subsites. Extending static asset expiry from 24h to 1yr eliminates 304 revalidation requests.

---

### 7. Modular Config with Includes (`nginx-with-includes.conf`)

A full `nginx.conf` with `http {}` block, gzip configured, rate limiting zones, and SSL settings. Represents a production-grade modular setup.

| Area | Before | After nginx-optimizer |
|------|--------|----------------------|
| **Compression** | Gzip only (level 6, limited types) | + Brotli (20-30% better ratios than Gzip for text) |
| **Rate limiting** | Basic zones defined (10r/s) | + Login-specific zone (5r/min) to prevent brute force |
| **SSL** | TLS 1.2/1.3, 10m session cache | + OCSP stapling, session tickets disabled for forward secrecy |
| **Performance** | `sendfile`, `tcp_nopush`, `tcp_nodelay` | Unchanged — already tuned |
| **Security headers** | None at http level | Full header suite added to all server blocks |

**Impact:** Brotli provides 15-25% better compression than Gzip for HTML/CSS/JS — meaningful for high-traffic sites. Login rate limiting (5r/min) stops credential stuffing attacks that basic 10r/s limits miss.

---

### 8. Already Optimized (`already-optimized.conf`)

A fully optimized config with HTTP/3, Brotli, Gzip, security headers, rate limiting, FastCGI cache, and WordPress security — **the target state**.

| Area | Before | After nginx-optimizer |
|------|--------|----------------------|
| **All features** | Present and configured | **No changes** — optimizer detects existing optimizations |

**Impact:** The optimizer's detection system (`feature_detect()`) checks for each optimization pattern before applying. This config validates that the tool is non-destructive — it won't duplicate `add_header` directives, cache zones, or security rules that already exist. Running `nginx-optimizer analyze` on this config reports all features as "detected."

---

### 9. Stock nginx Default (`nginx-official-default.conf`)

The `nginx.conf` shipped with a fresh nginx install. Single worker, gzip commented out, minimal configuration.

| Area | Before | After nginx-optimizer |
|------|--------|----------------------|
| **Workers** | 1 (hardcoded) | `auto` (matches CPU cores) |
| **Compression** | Gzip commented out (`#gzip on;`) | Brotli + Gzip enabled with 30+ MIME types |
| **Keepalive** | 65s (reasonable) | Unchanged |
| **Security** | `server_tokens` visible | `server_tokens off` + full security headers |
| **Caching** | None | FastCGI cache zone + page caching rules |
| **Protocol** | HTTP/1.1 on port 80 | HTTP/3 QUIC + TLS 1.3 |

**Impact:** This is the maximum transformation — from a stock install to a fully optimized stack. Page load times improve 5-10x for dynamic content. The `worker_processes auto` change alone doubles throughput on multi-core servers. Compression + caching reduce both bandwidth and server CPU load dramatically.

---

### 10. H5BP Compression Baseline (`h5bp-compression.conf`)

The HTML5 Boilerplate gzip configuration — comprehensive MIME type list with gzip level 5.

| Area | Before | After nginx-optimizer |
|------|--------|----------------------|
| **Gzip** | Level 5, extensive MIME list | Level 6 with additional types (geo+json, wasm, ld+json) |
| **Brotli** | Not present | Added — 20-30% better compression for text content |
| **Min length** | 256 bytes | Unchanged (already optimal) |
| **Proxied** | `any` | Unchanged |

**Impact:** The H5BP config is a solid baseline. The optimizer adds Brotli for browsers that support it (95%+ of modern browsers) while keeping Gzip as fallback. Brotli at level 6 compresses a typical WordPress page from 45KB to ~12KB vs Gzip's ~16KB — a 25% improvement at similar CPU cost.

---

### Optimization Summary

| Config | Optimizations Applied | Estimated Improvement |
|--------|----------------------|----------------------|
| Basic WordPress | 7 features (full suite) | **5-10x** faster page loads |
| WooCommerce | 5 features (cache already present) | **15-25%** faster + security |
| WordPress SSL | 6 features (HSTS already present) | **3-5x** faster + full security |
| Basic Reverse Proxy | 3 features (compression, headers, H3) | **60-70%** bandwidth savings |
| Load Balancer | 3 features (compression, headers, H3) | **1-RTT savings** + protection |
| WordPress Multisite | 6 features (full WordPress suite) | **80-90%** CPU reduction |
| Modular Config | 2 features (Brotli, login rate limit) | **15-25%** better compression |
| Already Optimized | 0 features (all detected) | No changes needed |
| Stock nginx Default | 7 features (full suite) | **5-10x** improvement |
| H5BP Compression | 1 feature (Brotli) | **20-30%** better compression |

## Troubleshooting

### Bash Version
nginx-optimizer supports bash 3.2+ (macOS default) and bash 4+/5+. No special installation needed.

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

## Security

See [SECURITY.md](SECURITY.md) for:
- Vulnerability disclosure process
- Security considerations
- Best practices

**Built-in protections:**
- All sensitive files (wp-config.php, .env) are protected
- xmlrpc.php is blocked by default
- Rate limiting prevents brute force attacks (returns 429, not 503)
- Per-IP and per-server connection limits prevent socket exhaustion
- Bad bot blocker drops scanners/scrapers with 444 (no response)
- Security headers provide XSS/clickjacking protection
- HSTS enforces HTTPS connections
- Cloudflare real IP restoration for accurate rate limiting behind proxy
- RAM-aware tuning prevents OOM by budgeting PHP-FPM workers to fit available memory
- Automatic health checks after optimization

## Support

For issues or questions:
- Check logs: `~/.nginx-optimizer/logs/`
- Test config: `nginx -t`
- Rollback: `nginx-optimizer rollback`

## Version

nginx-optimizer v0.10.0-beta

## Roadmap

> **Current version: v0.10.0-beta** — We're here.

### v0.10.x - Polish & Robustness &nbsp; ✅ Done
- ~~`remove` command to cleanly uninstall optimizations~~
- ~~`diff` command to show exact changes before applying~~
- ~~Rollback verification (apply -> rollback -> compare)~~
- ~~`verify` command to check applied state vs running config~~
- ~~`--no-color` flag for CI environments~~
- ~~State tracking file (`state.json`) for persistent optimization records~~
- ~~Full JSON output for `analyze`, `status`, `list`, `check` commands~~
- ~~Real-world test configs with Docker-based nginx validation~~

### v0.11.x - Smart Config Parsing
- ~~Server sizing auto-detection (adjust values based on RAM/CPU)~~ — shipped as
  `lib/core/sysinfo.sh`; drives server-tuning, php-fpm-tuning, opcache and keys_zone
- ~~Expand the test corpus~~ — 49 configs + 3 negative fixtures across 10 shape
  directories, with a shape checklist, provenance manifest and near-duplicate
  assertion (`tests/configs/SHAPES.md`, `tests/test-corpus.sh`)
- AWK-based config AST parsing (analyze before modifying)
- Conflict detection (warn if directive already exists) — **blocked on the AST parser**
- Profile system (`--profile conservative|balanced|aggressive`) — not started, and
  independent of the parser work
- Partial rollback (undo single feature) — **partly built**: `feature_remove()` deletes
  one template file and its include line. It cannot remove multi-template features,
  hard-fails on template-less ones, and reverses no in-place edits. See ROADMAP.md.

### v1.0.0 - Production Release
- Python crossplane integration for proper nginx config parsing
- Multi-server support
- Ansible role/playbook
- APT/DEB and RPM packages

See [ROADMAP.md](ROADMAP.md) and [docs/PRODUCTION-READINESS.md](docs/PRODUCTION-READINESS.md) for full details.

## Credits & Inspiration

This tool stands on other people's measurements. Kudos where it's due:

- **[easyinstallvps](https://github.com/sugan0927/easyinstallvps)** — the RAM-tier
  approach at the heart of `lib/core/sysinfo.sh`. The idea that a VPS should be
  tuned by *bracket* rather than by a single copy-pasted config is theirs; the
  tier ladder, `worker_connections`, `open_file_cache`, log tuning, the bad-bot
  blocker and the Cloudflare real-IP handling all trace back to that project.
  Thank you — it turned a pile of one-off snippets into something a 512MB box and
  a 16GB box can both run safely.
- **SHIFT64 — ["1,200 Recompiles per Page View: The OPcache Failure No Hosting
  Dashboard Will Show You"](https://shift64.com/blog/opcache-silent-killer-woocommerce-benchmark)**
  (2026-07-22) — the benchmark that drove every tier value in
  `sysinfo_opcache_*()`. Three findings we'd have missed on our own: that a store
  can sit above a 99% OpCache "hit rate" while silently recompiling ~1,200 PHP
  files on *every* page view; that hit rate is a vanity metric because OpCache
  never evicts, it just quietly stops caching once any ceiling is hit; and that
  `max_accelerated_files` — file count, not megabytes — is the ceiling that
  actually binds on a plugin-equipped store, which is precisely the number every
  tuning guide reasons about last. Measured, not guessed, and it cost us a
  29%-throughput bug we didn't know we had. Kudos.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

MIT License - Created for use with wp-test and general nginx optimization.
