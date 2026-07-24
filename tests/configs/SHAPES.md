# Corpus shape checklist

The corpus is judged by **shape coverage**, not file count. A shape is a
structural pattern that makes a parser or an injector behave differently — not a
brand, not a hostname. Forty WordPress vhosts that differ only in domain name are
one shape, and the near-duplicate check in `tests/test-corpus.sh` exists to say so.

`tests/test-corpus.sh` enforces this file mechanically:

| Rule | Enforced how |
|---|---|
| Every required shape has ≥1 config | shape ids in the table below vs `# Shape:` headers |
| Every config declares its shape and provenance | `# Shape:` + `# Provenance:` in the first 12 lines |
| Every shape directory is non-empty | directory scan |
| Hard floor of 30 valid configs | count |
| No two configs are near-duplicates | pairwise Jaccard over directive-name sets, threshold 0.92 |

Plus `tests/test-with-nginx.sh`: every valid config must pass `nginx -t` against a
real nginx, and every file in `invalid/` must **fail** it.

## Provenance types

- **fleet** — copied off a live server (host and path recorded). Adaptations to
  make the file parse standalone are listed in its header.
- **upstream** — reproduced from a named upstream project or vendor doc, with URL.
- **derived** — written from a documented pattern where no canonical file exists.
  Deliberately marked so nobody mistakes it for something found in the wild.
- **crafted** — a regression fixture written to exercise one behaviour. Legitimate
  for edge cases; **not** legitimate as a substitute for a real-world shape.

## Required shapes

Each row must be matched by at least one `# Shape: <id>` header in the corpus.

### Distro and vendor defaults
| Shape id | Exercises |
|---|---|
| `minimal-upstream-default` | the shipped nginx.org default, everything commented out |
| `minimal-http-fragment` | an http-context fragment with no server block at all |
| `minimal-static-with-php` | smallest realistic static vhost with one PHP location |
| `distro-default-debian` | Debian/Ubuntu layout: tabs, sites-enabled split, gzip on |
| `distro-default-gzip-disabled` | the same layout with gzip **commented out** — must not read as enabled |
| `distro-default-alpine` | Alpine: `http.d/`, tiny worker_connections, non-standard pid path |

### Control-panel generated
| Shape id | Exercises |
|---|---|
| `panel-main-config` | a panel's own main nginx.conf (cPanel EA4) |
| `panel-default-vhost` | a panel service vhost proxying to Apache, driven by panel-supplied map variables |

### WordPress
| Shape id | Exercises |
|---|---|
| `wordpress-plain-http` | the textbook unoptimised WP vhost |
| `wordpress-tls-partially-optimized` | TLS + gzip + expires already present — add without duplicating |
| `wordpress-missing-front-controller` | no `try_files`, so permalinks 404 |
| `wordpress-fastcgi-microcache` | microcache with a bypass map and per-site fpm socket |
| `woocommerce-upstream-keepalive` | a named fpm upstream rather than a direct socket |
| `woocommerce-microcache-cart-bypass` | cart/checkout cookie bypass, country-keyed cache key |
| `wordpress-multisite-subdomain` | wildcard `server_name`, no rewrite block |
| `wordpress-multisite-subdir-ms-files` | chained maps, `if (!-e ...)` rewrites, `internal` alias |
| `wordpress-bedrock` | web root is `web/`, core lives in `wp/`, `.env` above the root |
| `wordpress-behind-ipv6-proxy` | WP served through a proxy over IPv6 loopback |

### Reverse proxy
| Shape id | Exercises |
|---|---|
| `proxy-basic-keepalive` | one upstream, keepalive, standard X-Forwarded set |
| `proxy-least-conn-weighted` | least_conn across weighted backends |
| `proxy-sticky-upstream-hash` | consistent hashing for affinity, `down` servers, weights |
| `proxy-websocket-upgrade` | the `map $http_upgrade $connection_upgrade` idiom |
| `proxy-grpc` | `grpc_pass`, mandatory HTTP/2, gRPC error passthrough |
| `proxy-sse` | Server-Sent Events: buffering off, chunked off, long read timeout |
| `proxy-unix-socket` | upstream over a UNIX socket, not TCP |
| `proxy-named-location-fallback` | `@named` location fallback after a static try_files |
| `proxy-ipv6-only-alias` | IPv6-only listen plus `alias` for static |

### Application stacks
| Shape id | Exercises |
|---|---|
| `app-laravel` | `public/` root, single front-controller location, `error_page 404 /index.php` |
| `app-django-uwsgi` | `uwsgi_pass` — invisible to any detector keyed on `fastcgi_pass` |
| `app-node-nonstandard-port` | a Node service on a non-80/443 port, no TLS at all |
| `app-static-spa-fallback` | `try_files ... /index.html`, no PHP anywhere |
| `app-nextjs-immutable-assets` | `/_next/static/` long-cache — hash is in the path, not the extension |

### TLS
| Shape id | Exercises |
|---|---|
| `tls-shared-cert-hostname-mismatch` | a host served off another site's Certbot cert |
| `tls-cloudflare-origin-cert` | a Cloudflare Origin CA cert, :80 and :443 in one server |
| `tls-le-dns01-with-realip` | Let's Encrypt + `real_ip` + a location-scoped SSE stream |
| `tls-http3-quic` | `listen 443 quic`, `http3 on`, Alt-Svc |
| `tls-mutual-auth` | client-certificate verification, `$ssl_client_*` forwarded upstream |
| `tls-ocsp-stapling-hsts` | OCSP stapling with a trusted chain and an explicit resolver |

### Complex / multi-server
| Shape id | Exercises |
|---|---|
| `complex-modular-includes` | a full nginx.conf whose content lives behind includes |
| `complex-multisite-subdir-map` | multisite subdirectory with a `$blogname`/`$blogid` map pair |
| `complex-multi-server-api-gateway` | three server blocks fanning seven prefixes across four upstreams |

### Edge cases
| Shape id | Exercises |
|---|---|
| `edge-empty-server` | a server block with no location, no root, no content |
| `edge-comment-dense` | more comments than directives, including commented-out directives |
| `edge-already-optimized` | everything already applied — the idempotency fixture |
| `edge-redirect-only` | a server that only returns 301 |
| `edge-duplicate-server-name` | two servers claiming the same name — nginx warns and uses the first |
| `edge-deeply-nested-locations` | four levels of nested location, plus an `if` inside them |
| `edge-crlf-line-endings` | CRLF throughout — `$`-anchored rewriters append after the `\r` |
| `edge-mixed-indentation` | tabs, 2/4/8-space indent, one-line blocks, brace on its own line |

### Negative fixtures (must FAIL `nginx -t`)
| Shape id | Exercises |
|---|---|
| `invalid-unbalanced-braces` | an unclosed block |
| `invalid-missing-semicolon` | a directive that swallows the next one |
| `invalid-unknown-directive` | malformed vs "needs a module we do not have" |

## Backlog — wanted shapes not yet sourced

These are **not** enforced. They are listed so the gap stays visible instead of
being quietly forgotten. Each needs a real source; inventing one would teach the
parser to handle configs nobody writes.

| Shape | Blocker |
|---|---|
| Plesk-generated vhost | no Plesk box in the fleet; the shipped templates are PHP-templated, not rendered nginx |
| DirectAdmin-generated vhost | `cyberfolks` runs DirectAdmin but on LiteSpeed, so no nginx config exists there |
| CyberPanel / OpenLiteSpeed-fronting vhost | CyberPanel's repo ships no plain nginx vhost |
| Webmin / Virtualmin vhost | no box available |
| RHEL / Alma / Amazon Linux default | fleet is Debian/Ubuntu/Alpine only |
| Rails / Passenger | needs `passenger_enabled`, a third-party module stock nginx lacks |
| 5000-line monolith | worth having, but must come from a real host, not be generated |
| Non-UTF8 / BOM-prefixed config | belongs in `invalid/` or a byte-level fixture set; nginx's own behaviour here needs checking first |
