#!/bin/bash
################################################################################
# core/sysinfo.sh - System Information Detection
################################################################################
# Cross-platform (macOS + Linux) detection of RAM and CPU for RAM-aware
# nginx tuning. All functions are pure helpers with no side effects.
#
# Inspired by easyinstallvps RAM-tier approach, but applied specifically
# to nginx tuning parameters.
#
# RAM Tiers:
#   Tier 1: ≤512MB   (micro VPS, $2.50/mo)
#   Tier 2: ≤1GB     (small VPS, $5/mo)
#   Tier 3: ≤2GB     (standard VPS, $10/mo)
#   Tier 4: ≤4GB     (performance VPS)
#   Tier 5: ≤8GB     (high-traffic)
#   Tier 6: >8GB     (dedicated/large)
################################################################################

# Cache detected values to avoid repeated syscalls
_SYSINFO_RAM_MB=""
_SYSINFO_CPU_CORES=""

################################################################################
# Detection Functions
################################################################################

# Get total system RAM in megabytes
# Prints: integer MB value
# Returns: 0 on success, 1 on failure
sysinfo_ram_mb() {
    # Return cached value if available
    if [[ -n "$_SYSINFO_RAM_MB" ]]; then
        echo "$_SYSINFO_RAM_MB"
        return 0
    fi

    local ram_mb=0

    case "$(uname -s)" in
        Darwin)
            # macOS: sysctl returns bytes
            local ram_bytes
            ram_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
            ram_mb=$((ram_bytes / 1024 / 1024))
            ;;
        Linux)
            # Linux: /proc/meminfo returns kB
            local ram_kb
            ram_kb=$(grep -m1 '^MemTotal:' /proc/meminfo 2>/dev/null | awk '{print $2}')
            ram_mb=$(( ${ram_kb:-0} / 1024 ))
            ;;
        *)
            # Fallback: assume 2GB (safe default)
            ram_mb=2048
            ;;
    esac

    # Sanity check
    if [[ $ram_mb -lt 128 ]]; then
        ram_mb=2048  # Fallback if detection failed
    fi

    _SYSINFO_RAM_MB="$ram_mb"
    echo "$ram_mb"
}

# Get CPU core count
# Prints: integer core count
# Returns: 0 on success
sysinfo_cpu_cores() {
    # Return cached value if available
    if [[ -n "$_SYSINFO_CPU_CORES" ]]; then
        echo "$_SYSINFO_CPU_CORES"
        return 0
    fi

    local cores=1

    case "$(uname -s)" in
        Darwin)
            cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 1)
            ;;
        Linux)
            cores=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
            ;;
    esac

    # Sanity check
    if [[ $cores -lt 1 ]]; then
        cores=1
    fi

    _SYSINFO_CPU_CORES="$cores"
    echo "$cores"
}

# Get RAM tier (1-6)
# Prints: tier number
sysinfo_ram_tier() {
    local ram_mb
    ram_mb=$(sysinfo_ram_mb)

    if [[ $ram_mb -le 512 ]]; then
        echo 1
    elif [[ $ram_mb -le 1024 ]]; then
        echo 2
    elif [[ $ram_mb -le 2048 ]]; then
        echo 3
    elif [[ $ram_mb -le 4096 ]]; then
        echo 4
    elif [[ $ram_mb -le 8192 ]]; then
        echo 5
    else
        echo 6
    fi
}

################################################################################
# Nginx Tuning Values (RAM-aware)
################################################################################

# Get recommended worker_connections based on RAM
# Prints: integer value
sysinfo_worker_connections() {
    local tier
    tier=$(sysinfo_ram_tier)

    case $tier in
        1) echo 512 ;;
        2) echo 1024 ;;
        3) echo 2048 ;;
        4) echo 4096 ;;
        5) echo 8192 ;;
        6) echo 16384 ;;
    esac
}

# Get recommended worker_rlimit_nofile based on RAM
# Should be at least 2x worker_connections
# Prints: integer value
sysinfo_worker_rlimit_nofile() {
    local connections
    connections=$(sysinfo_worker_connections)
    echo $((connections * 2))
}

# Get recommended fastcgi_cache keys_zone size
# NOTE: keys_zone is shared memory allocated at nginx startup.
# Each cached URL uses ~120 bytes in the zone. 10m ≈ 80K URLs.
# Budget conservatively: nginx gets ~10-15% of total RAM for zones.
# The rest goes to PHP-FPM, MySQL, Redis, OS.
# Prints: string like "10m" or "256m"
sysinfo_fastcgi_keys_zone() {
    local tier
    tier=$(sysinfo_ram_tier)

    case $tier in
        1) echo "10m" ;;   # 512MB VPS: ~1.9% of RAM, ~80K URLs
        2) echo "20m" ;;   # 1GB VPS:   ~1.9% of RAM, ~160K URLs
        3) echo "50m" ;;   # 2GB VPS:   ~2.4% of RAM, ~400K URLs
        4) echo "100m" ;;  # 4GB VPS:   ~2.4% of RAM, ~800K URLs
        5) echo "128m" ;;  # 8GB VPS:   ~1.5% of RAM
        6) echo "256m" ;;  # 16GB+:     plenty of headroom
    esac
}

# Get recommended fastcgi_cache max_size (disk-based, not RAM)
# This is disk usage, so can be more generous than keys_zone.
# Prints: string like "128m" or "2g"
sysinfo_fastcgi_max_size() {
    local tier
    tier=$(sysinfo_ram_tier)

    case $tier in
        1) echo "64m" ;;   # micro VPS often has small disks too
        2) echo "128m" ;;
        3) echo "256m" ;;
        4) echo "512m" ;;
        5) echo "1g" ;;
        6) echo "2g" ;;
    esac
}

# Get recommended open_file_cache max entries
# Prints: integer value
sysinfo_open_file_cache_max() {
    local tier
    tier=$(sysinfo_ram_tier)

    case $tier in
        1) echo 2000 ;;
        2) echo 5000 ;;
        3) echo 10000 ;;
        4) echo 20000 ;;
        5) echo 50000 ;;
        6) echo 100000 ;;
    esac
}

# Get recommended upstream keepalive connections
# Prints: integer value
sysinfo_keepalive_connections() {
    local tier
    tier=$(sysinfo_ram_tier)

    case $tier in
        1) echo 8 ;;
        2) echo 12 ;;
        3) echo 16 ;;
        4) echo 24 ;;
        5) echo 32 ;;
        6) echo 48 ;;
    esac
}

# Get recommended PHP-FPM max_children
# Budget: 50% of total RAM for PHP, 40MB per worker average
# Prints: integer value
sysinfo_fpm_max_children() {
    local ram_mb
    ram_mb=$(sysinfo_ram_mb)
    local php_ram=$(( ram_mb / 2 ))
    local children=$(( php_ram / 40 ))

    # Sanity bounds
    if [[ $children -lt 3 ]]; then
        children=3
    elif [[ $children -gt 200 ]]; then
        children=200
    fi

    echo "$children"
}

# Get recommended per-IP connection limit
# Prints: integer value
sysinfo_conn_limit_per_ip() {
    local tier
    tier=$(sysinfo_ram_tier)

    case $tier in
        1) echo 20 ;;    # micro VPS: tight
        2) echo 30 ;;
        3) echo 50 ;;
        4) echo 75 ;;
        5) echo 100 ;;
        6) echo 150 ;;
    esac
}

# Get recommended per-server total connection limit
# Prints: integer value
sysinfo_conn_limit_per_server() {
    local tier
    tier=$(sysinfo_ram_tier)

    case $tier in
        1) echo 500 ;;    # 512MB: can't handle more
        2) echo 1000 ;;
        3) echo 3000 ;;
        4) echo 5000 ;;
        5) echo 10000 ;;
        6) echo 20000 ;;
    esac
}

# Print a human-readable summary of detected system info and tuning values
# Used by "check" and "status" commands
sysinfo_summary() {
    local ram_mb cores tier
    ram_mb=$(sysinfo_ram_mb)
    cores=$(sysinfo_cpu_cores)
    tier=$(sysinfo_ram_tier)

    local tier_name
    case $tier in
        1) tier_name="Micro (≤512MB)" ;;
        2) tier_name="Small (≤1GB)" ;;
        3) tier_name="Standard (≤2GB)" ;;
        4) tier_name="Performance (≤4GB)" ;;
        5) tier_name="High-Traffic (≤8GB)" ;;
        6) tier_name="Large (>8GB)" ;;
    esac

    local keys_zone
    keys_zone=$(sysinfo_fastcgi_keys_zone)
    local keys_zone_num="${keys_zone%m}"
    # Multiply first to avoid rounding to 0 on large RAM systems
    local nginx_ram_pct=$(( (keys_zone_num * 1000 / ram_mb + 5) / 10 ))

    echo "System: ${ram_mb}MB RAM, ${cores} CPU cores → Tier ${tier} (${tier_name})"
    echo "  worker_connections: $(sysinfo_worker_connections)"
    echo "  worker_rlimit_nofile: $(sysinfo_worker_rlimit_nofile)"
    echo "  fastcgi_cache zone: ${keys_zone} (~${nginx_ram_pct}% of RAM), disk max: $(sysinfo_fastcgi_max_size)"
    echo "  open_file_cache max: $(sysinfo_open_file_cache_max)"
    echo "  upstream keepalive: $(sysinfo_keepalive_connections)"
    echo "  php-fpm max_children: $(sysinfo_fpm_max_children) (~$((ram_mb / 2))MB for PHP @ 40MB/worker)"
    echo "  conn limit per IP: $(sysinfo_conn_limit_per_ip), per server: $(sysinfo_conn_limit_per_server)"
    echo "  RAM budget: ~50% PHP-FPM, ~20% MySQL, ~15% OS, ~15% nginx/Redis/buffers"
}
