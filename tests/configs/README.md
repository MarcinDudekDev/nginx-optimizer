# nginx-optimizer Test Configuration Corpus

This directory contains real-world nginx configurations for testing the optimizer.

## Structure

```
configs/
├── minimal/          # Bare minimum valid configs
│   ├── nginx-official-default.conf  # Official nginx default
│   └── h5bp-compression.conf        # H5BP compression settings
├── wordpress/        # WordPress-specific configs
│   ├── basic-wordpress.conf         # Basic WP setup
│   ├── wordpress-ssl-optimized.conf # WP with SSL + basics
│   └── woocommerce-high-traffic.conf # WooCommerce with caching
├── reverse-proxy/    # Pure proxy configs
│   ├── basic-proxy.conf             # Simple reverse proxy
│   └── load-balancer.conf           # Multi-backend LB
├── complex/          # Multi-site, includes, maps
│   ├── multi-site-wordpress.conf    # WP Multisite subdirectory
│   └── nginx-with-includes.conf     # Modular production setup
└── edge-cases/       # Weird but valid configs
    ├── empty-server-block.conf      # Minimal server block
    ├── comments-heavy.conf          # Many comments
    └── already-optimized.conf       # Already has all optimizations
```

## Test Requirements

1. **Syntax validation**: All configs must pass `nginx -t` (with mock includes)
2. **Idempotency**: Running optimizer twice produces identical results
3. **No breakage**: Optimized config still passes syntax check
4. **Detection**: Already-optimized configs should not be modified

## Usage

```bash
# Run all tests
./tests/run-tests.sh

# Validate single config
nginx -t -c tests/configs/wordpress/basic-wordpress.conf
```

## Sources

- `nginx-official-default.conf` - https://github.com/nginx/nginx
- `h5bp-compression.conf` - https://github.com/h5bp/server-configs-nginx
- WordPress configs - Common production patterns
- Edge cases - Crafted for regression testing
