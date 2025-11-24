#!/bin/bash

################################################################################
# monitoring.sh - Nginx Monitoring Setup Functions
################################################################################

################################################################################
# Monitoring Setup Functions
################################################################################

setup_monitoring() {
    local target_site="$1"

    log_info "Setting up nginx monitoring..."

    # Enable nginx status page
    enable_nginx_status

    # Setup cache monitoring
    setup_cache_monitoring

    # Setup log monitoring
    setup_log_monitoring

    # Create monitoring dashboard script
    create_monitoring_dashboard

    log_success "Monitoring setup complete"
}

enable_nginx_status() {
    log_info "Enabling nginx status page..."

    local status_conf="${TEMPLATE_DIR}/nginx-status.conf"

    cat > "$status_conf" << 'EOF'
# Nginx Status Page Configuration

location /nginx_status {
    stub_status on;
    access_log off;
    allow 127.0.0.1;
    allow ::1;
    deny all;
}

# OpCache status (if using PHP-FPM)
location /opcache_status {
    access_log off;
    allow 127.0.0.1;
    allow ::1;
    deny all;
}
EOF

    if [ "$DRY_RUN" = false ]; then
        # Copy to nginx config
        if [ -d "${WP_TEST_NGINX}/conf.d" ]; then
            cp "$status_conf" "${WP_TEST_NGINX}/conf.d/"
            log_success "Status page enabled for wp-test"
        fi

        if [ -d "/etc/nginx/conf.d" ]; then
            sudo cp "$status_conf" "/etc/nginx/conf.d/" 2>/dev/null || true
            log_success "Status page enabled for system nginx"
        fi
    fi

    log_info "Access status at: http://localhost/nginx_status"
}

setup_cache_monitoring() {
    log_info "Setting up cache monitoring..."

    local cache_monitor="${DATA_DIR}/scripts/monitor-cache.sh"

    mkdir -p "${DATA_DIR}/scripts"

    cat > "$cache_monitor" << 'EOF'
#!/bin/bash

# Cache Monitoring Script
# Usage: ./monitor-cache.sh

CACHE_DIR="/var/run/nginx-cache"

if [ ! -d "$CACHE_DIR" ]; then
    echo "Cache directory not found: $CACHE_DIR"
    exit 1
fi

echo "Nginx FastCGI Cache Statistics"
echo "==============================="
echo ""

# Cache size
echo "Cache Size:"
du -sh "$CACHE_DIR"
echo ""

# Number of cached files
echo "Cached Files:"
find "$CACHE_DIR" -type f | wc -l
echo ""

# Cache hit rate (from access log)
if [ -f /var/log/nginx/access.log ]; then
    echo "Cache Hit Rate (last 1000 requests):"
    tail -1000 /var/log/nginx/access.log | grep -o 'X-FastCGI-Cache: [A-Z]*' | sort | uniq -c
    echo ""
fi

# Disk usage
echo "Disk Usage:"
df -h "$CACHE_DIR"
echo ""
EOF

    chmod +x "$cache_monitor"

    log_success "Cache monitoring script created: $cache_monitor"
}

setup_log_monitoring() {
    log_info "Setting up log monitoring..."

    local log_analyzer="${DATA_DIR}/scripts/analyze-logs.sh"

    mkdir -p "${DATA_DIR}/scripts"

    cat > "$log_analyzer" << 'EOF'
#!/bin/bash

# Nginx Log Analyzer
# Usage: ./analyze-logs.sh [access|error]

LOG_TYPE="${1:-access}"
ACCESS_LOG="/var/log/nginx/access.log"
ERROR_LOG="/var/log/nginx/error.log"

if [ "$LOG_TYPE" = "access" ]; then
    if [ ! -f "$ACCESS_LOG" ]; then
        echo "Access log not found: $ACCESS_LOG"
        exit 1
    fi

    echo "Nginx Access Log Analysis"
    echo "========================="
    echo ""

    echo "Top 10 IP Addresses:"
    awk '{print $1}' "$ACCESS_LOG" | sort | uniq -c | sort -rn | head -10
    echo ""

    echo "Top 10 Requested URLs:"
    awk '{print $7}' "$ACCESS_LOG" | sort | uniq -c | sort -rn | head -10
    echo ""

    echo "Status Code Distribution:"
    awk '{print $9}' "$ACCESS_LOG" | sort | uniq -c | sort -rn
    echo ""

    echo "User Agent Summary:"
    awk -F'"' '{print $6}' "$ACCESS_LOG" | sort | uniq -c | sort -rn | head -10
    echo ""

elif [ "$LOG_TYPE" = "error" ]; then
    if [ ! -f "$ERROR_LOG" ]; then
        echo "Error log not found: $ERROR_LOG"
        exit 1
    fi

    echo "Nginx Error Log Analysis"
    echo "========================"
    echo ""

    echo "Recent Errors (last 20):"
    tail -20 "$ERROR_LOG"
    echo ""

    echo "Error Frequency:"
    sed -n 's/.*\[error\] [0-9]*#[0-9]*: \*[0-9]* \([^,]*\).*/\1/p' "$ERROR_LOG" | sort | uniq -c | sort -rn | head -10
    echo ""

else
    echo "Usage: $0 [access|error]"
    exit 1
fi
EOF

    chmod +x "$log_analyzer"

    log_success "Log analyzer script created: $log_analyzer"
}

create_monitoring_dashboard() {
    local dashboard="${DATA_DIR}/scripts/dashboard.sh"

    mkdir -p "${DATA_DIR}/scripts"

    cat > "$dashboard" << 'EOF'
#!/bin/bash

# Nginx Monitoring Dashboard
# Usage: ./dashboard.sh

clear

echo "╔════════════════════════════════════════════════════════════╗"
echo "║          Nginx Optimizer - Monitoring Dashboard           ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Nginx Status
echo "Nginx Status:"
echo "─────────────"
if command -v systemctl &>/dev/null && systemctl is-active --quiet nginx; then
    echo "✓ Running"
    NGINX_VERSION=$(nginx -v 2>&1 | sed -n 's/.*nginx\/\([0-9.]*\).*/\1/p')
    echo "  Version: $NGINX_VERSION"
elif pgrep nginx &>/dev/null; then
    echo "✓ Running"
else
    echo "✗ Not Running"
fi
echo ""

# Server Status (from stub_status)
echo "Server Statistics:"
echo "──────────────────"
if curl -s http://localhost/nginx_status &>/dev/null; then
    curl -s http://localhost/nginx_status
else
    echo "Status page not accessible"
fi
echo ""

# Cache Status
echo "Cache Status:"
echo "─────────────"
CACHE_DIR="/var/run/nginx-cache"
if [ -d "$CACHE_DIR" ]; then
    echo "✓ Enabled"
    echo "  Size: $(du -sh "$CACHE_DIR" 2>/dev/null | cut -f1)"
    echo "  Files: $(find "$CACHE_DIR" -type f 2>/dev/null | wc -l)"
else
    echo "✗ Not Configured"
fi
echo ""

# PHP-FPM Status
echo "PHP-FPM Status:"
echo "───────────────"
if command -v php-fpm &>/dev/null || pgrep php-fpm &>/dev/null; then
    echo "✓ Running"
    if command -v php &>/dev/null; then
        PHP_VERSION=$(php -v | head -1 | sed -n 's/^PHP \([0-9.]*\).*/\1/p')
        echo "  Version: $PHP_VERSION"
    fi
else
    echo "✗ Not Running"
fi
echo ""

# Docker Containers (if applicable)
if command -v docker &>/dev/null; then
    echo "Docker Containers:"
    echo "──────────────────"
    docker ps --filter "ancestor=nginx" --format "table {{.Names}}\t{{.Status}}" 2>/dev/null || echo "None"
    echo ""
fi

# Recent Errors
echo "Recent Errors (last 5):"
echo "───────────────────────"
if [ -f /var/log/nginx/error.log ]; then
    tail -5 /var/log/nginx/error.log 2>/dev/null || echo "No errors"
else
    echo "Error log not found"
fi
echo ""

echo "═══════════════════════════════════════════════════════════"
echo "Refresh: watch -n 5 $0"
echo "═══════════════════════════════════════════════════════════"
EOF

    chmod +x "$dashboard"

    log_success "Monitoring dashboard created: $dashboard"
    log_info "Run with: $dashboard"
}

setup_alerts() {
    log_info "Setting up alerts..."

    local alert_script="${DATA_DIR}/scripts/alerts.sh"

    mkdir -p "${DATA_DIR}/scripts"

    cat > "$alert_script" << 'EOF'
#!/bin/bash

# Nginx Alert Script
# Monitors nginx and sends alerts for issues

# Configuration
ERROR_THRESHOLD=10
CACHE_SIZE_THRESHOLD=1024  # MB

# Check if nginx is running
if ! pgrep nginx &>/dev/null; then
    echo "ALERT: Nginx is not running!"
    # Send notification (customize as needed)
    # mail -s "Nginx Down" admin@example.com <<< "Nginx is not running"
fi

# Check error log for recent issues
if [ -f /var/log/nginx/error.log ]; then
    ERROR_COUNT=$(grep "error" /var/log/nginx/error.log | tail -100 | wc -l)
    if [ "$ERROR_COUNT" -gt "$ERROR_THRESHOLD" ]; then
        echo "ALERT: High error count: $ERROR_COUNT errors in last 100 lines"
    fi
fi

# Check cache size
CACHE_DIR="/var/run/nginx-cache"
if [ -d "$CACHE_DIR" ]; then
    CACHE_SIZE=$(du -sm "$CACHE_DIR" | cut -f1)
    if [ "$CACHE_SIZE" -gt "$CACHE_SIZE_THRESHOLD" ]; then
        echo "WARNING: Cache size exceeds threshold: ${CACHE_SIZE}MB"
    fi
fi

# Check disk space
DISK_USAGE=$(df -h / | tail -1 | awk '{print $5}' | tr -d '%')
if [ "$DISK_USAGE" -gt 90 ]; then
    echo "ALERT: Disk usage critical: ${DISK_USAGE}%"
fi
EOF

    chmod +x "$alert_script"

    log_success "Alert script created: $alert_script"
    log_info "Add to cron: */5 * * * * $alert_script"
}
