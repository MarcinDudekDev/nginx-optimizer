# nginx-optimizer Test Configuration Corpus

Real nginx configurations the optimizer is tested against — 49 valid configs plus
3 negative fixtures that must **fail** to parse.

The corpus is judged by **shape coverage**, not file count. See
[SHAPES.md](SHAPES.md) for the checklist and
[MANIFEST.tsv](MANIFEST.tsv) for where every file came from.

## Structure

```
configs/
├── SHAPES.md          # The required-shape checklist (enforced)
├── MANIFEST.tsv       # Generated: path, shape id, provenance type, source
├── minimal/           # Stock nginx default, H5BP fragment, smallest static+PHP vhost
├── distro-defaults/   # Debian/Ubuntu, Ubuntu with gzip commented out, Alpine
├── panel-generated/   # cPanel EA4 main config and service vhost
├── wordpress/         # Plain, TLS, no-rewrite, microcache, WooCommerce,
│                      # multisite (subdomain + legacy subdir), Bedrock, behind-proxy
├── reverse-proxy/     # Keepalive, least_conn LB, sticky hash, WebSocket, gRPC,
│                      # SSE, UNIX socket, named-location fallback, IPv6-only alias
├── app-stacks/        # Laravel, Django/uWSGI, Node, static SPA, Next.js
├── tls/               # Certbot, shared cert, Cloudflare origin CA, HTTP/3 QUIC,
│                      # mutual TLS, OCSP stapling
├── complex/           # Multisite maps, modular includes, multi-server API gateway
├── edge-cases/        # Already-optimized, comment-dense, empty server, redirect-only,
│                      # duplicate server_name, 4-deep nesting, CRLF, mixed indentation
└── invalid/           # Negative fixtures — asserted to FAIL nginx -t
```

## Every config carries its own header

```nginx
# Provenance: anna152:/etc/nginx/sites-available/makewpfast.com.conf (live production)
# Shape: wordpress-fastcgi-microcache — microcache with bypass map, ...
```

Both lines are mandatory and machine-checked. Where a fleet config had to be
altered to parse standalone (external `include`s resolved or dropped, log paths
repointed), the header says so explicitly with an `ADAPTED:` note at the change.

## What enforces what

| Script | Asserts |
|---|---|
| `tests/test-with-nginx.sh` | every valid config passes `nginx -t` against real nginx in Docker; every `invalid/` fixture fails it |
| `tests/test-corpus.sh` | shape headers present, every required shape covered, no empty shape directory, ≥30 valid configs, no near-duplicates (Jaccard ≥ 0.92 over directive names), manifest in sync |

```bash
./tests/test-with-nginx.sh              # needs Docker
./tests/test-corpus.sh                  # pure bash, no Docker
./tests/test-corpus.sh --write-manifest # regenerate MANIFEST.tsv after adding a config
```

## Adding a config

1. Prefer a **real** config — off the fleet or from a named upstream project. An
   invented config teaches the parser to handle files nobody writes.
2. Give it a `# Provenance:` and a `# Shape: <id>` header.
3. Add the shape id to `SHAPES.md` if it is new.
4. If it is a full `nginx.conf` (has `events`/`http`), add its basename to
   `FULL_NGINX_CONFIGS` in `tests/test-with-nginx.sh`, or it will be mounted as a
   conf.d include and fail confusingly. Same for `BROTLI_CONFIGS`.
5. Run `./tests/test-corpus.sh --write-manifest`, then both test scripts.
