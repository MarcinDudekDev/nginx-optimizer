#!/bin/bash
################################################################################
# honeypot.sh - Honeypot Tarpit Management Module
#
# Features:
# - Generate unique canary tokens per site
# - Create fake credential files (.env, .git/config, backup.sql)
# - Log analysis and threat intelligence
# - fail2ban integration
# - Canary token alerting via webhook
#
# Part of nginx-optimizer
################################################################################

# Honeypot directory
HONEYPOT_DIR="/var/www/honeypot"
HONEYPOT_LOG="/var/log/nginx/honeypot.log"
HONEYPOT_CANARY_LOG="/var/log/nginx/honeypot-canary.log"
HONEYPOT_CONFIG_DIR="${DATA_DIR}/honeypot"
CANARY_TOKENS_FILE="${HONEYPOT_CONFIG_DIR}/canary-tokens.json"

################################################################################
# Initialization
################################################################################

init_honeypot() {
    log_info "Initializing honeypot system..."

    # Create directories
    sudo mkdir -p "$HONEYPOT_DIR"
    mkdir -p "$HONEYPOT_CONFIG_DIR"

    # Create log files with proper permissions
    sudo touch "$HONEYPOT_LOG" "$HONEYPOT_CANARY_LOG"
    sudo chown www-data:adm "$HONEYPOT_LOG" "$HONEYPOT_CANARY_LOG" 2>/dev/null || \
    sudo chown nginx:adm "$HONEYPOT_LOG" "$HONEYPOT_CANARY_LOG" 2>/dev/null || true
    sudo chmod 640 "$HONEYPOT_LOG" "$HONEYPOT_CANARY_LOG"

    # Initialize canary tokens file
    if [[ ! -f "$CANARY_TOKENS_FILE" ]]; then
        echo '{"tokens": {}, "sites": {}}' > "$CANARY_TOKENS_FILE"
    fi

    log_success "Honeypot system initialized"
}

################################################################################
# Canary Token Generation
################################################################################

generate_canary_token() {
    # Generate a unique token for tracking
    local prefix="${1:-CANARY}"
    local token=$(openssl rand -hex 16)
    echo "${prefix}_${token}"
}

generate_fake_aws_key() {
    # Generate fake AWS access key (AKIA format)
    local random_part=$(openssl rand -hex 8 | tr '[:lower:]' '[:upper:]')
    echo "AKIA${random_part}FAKE"
}

generate_fake_aws_secret() {
    # Generate fake AWS secret (40 chars, base64-ish)
    openssl rand -base64 30 | tr -d '\n' | head -c 40
}

# Cross-platform md5 hash (works on both macOS and Linux)
get_md5_hash() {
    local input="$1"
    if command -v md5sum &>/dev/null; then
        echo "$input" | md5sum | cut -c1-8
    elif command -v md5 &>/dev/null; then
        echo "$input" | md5 | cut -c1-8
    else
        # Fallback: use openssl
        echo "$input" | openssl md5 | awk '{print $2}' | cut -c1-8
    fi
}

generate_site_canary_tokens() {
    local site_domain="$1"
    local force_regenerate="${2:-false}"

    # Ensure config directory exists
    mkdir -p "$HONEYPOT_CONFIG_DIR" 2>/dev/null || true

    # Initialize tokens file if needed
    if [[ ! -f "$CANARY_TOKENS_FILE" ]]; then
        echo '{"tokens": {}, "sites": {}}' > "$CANARY_TOKENS_FILE"
    fi

    # File-based cache (bash 3.2 compatible)
    local cache_file="${HONEYPOT_CONFIG_DIR}/.token-cache-$(echo "$site_domain" | tr '.' '_')"

    # Return cached tokens if already generated this session
    if [[ -f "$cache_file" && "$force_regenerate" != "true" ]]; then
        cat "$cache_file"
        return 0
    fi

    local site_id=$(get_md5_hash "$site_domain")

    # Check if tokens already exist on disk
    if [[ -f "$CANARY_TOKENS_FILE" ]] && command -v jq &>/dev/null; then
        local existing_tokens=$(jq -r ".sites[\"$site_domain\"].tokens // empty" "$CANARY_TOKENS_FILE" 2>/dev/null)
        if [[ -n "$existing_tokens" && "$force_regenerate" != "true" ]]; then
            local aws_key=$(echo "$existing_tokens" | jq -r '.aws_access_key')
            local aws_secret=$(echo "$existing_tokens" | jq -r '.aws_secret_key')
            local db_pass=$(echo "$existing_tokens" | jq -r '.db_password')
            local api_key=$(echo "$existing_tokens" | jq -r '.api_key')
            local canary=$(echo "$existing_tokens" | jq -r '.canary_callback')

            local result="AWS_KEY=$aws_key
AWS_SECRET=$aws_secret
DB_PASS=$db_pass
API_KEY=$api_key
CANARY_CALLBACK=$canary"
            echo "$result" > "$cache_file"
            echo "$result"
            return 0
        fi
    fi

    log_info "Generating canary tokens for $site_domain..."

    # Generate unique tokens
    local aws_key=$(generate_fake_aws_key)
    local aws_secret=$(generate_fake_aws_secret)
    local db_pass=$(openssl rand -base64 16 | tr -d '\n')
    local api_key=$(openssl rand -hex 32)
    local canary_callback="/.h0n3yp0t/${site_id}_$(openssl rand -hex 4)"

    # Store tokens in JSON
    local token_data=$(cat <<EOF
{
    "site": "$site_domain",
    "site_id": "$site_id",
    "created": "$(date -Iseconds)",
    "tokens": {
        "aws_access_key": "$aws_key",
        "aws_secret_key": "$aws_secret",
        "db_password": "$db_pass",
        "api_key": "$api_key",
        "canary_callback": "$canary_callback"
    }
}
EOF
)

    # Update canary tokens file
    if command -v jq &>/dev/null; then
        local existing=$(cat "$CANARY_TOKENS_FILE")
        echo "$existing" | jq --arg site "$site_domain" --argjson data "$token_data" \
            '.sites[$site] = $data' > "${CANARY_TOKENS_FILE}.tmp"
        mv "${CANARY_TOKENS_FILE}.tmp" "$CANARY_TOKENS_FILE"
    else
        # Fallback: append to simple file
        echo "$token_data" >> "${HONEYPOT_CONFIG_DIR}/tokens-${site_domain}.json"
    fi

    # Cache and return tokens
    local result="AWS_KEY=$aws_key
AWS_SECRET=$aws_secret
DB_PASS=$db_pass
API_KEY=$api_key
CANARY_CALLBACK=$canary_callback"
    echo "$result" > "$cache_file"
    echo "$result"
}

################################################################################
# Fake File Generation
################################################################################

create_fake_env_file() {
    local site_domain="$1"
    local output_file="${HONEYPOT_DIR}/fake-env.txt"

    # Get or generate tokens
    local tokens=$(generate_site_canary_tokens "$site_domain")
    local aws_key=$(echo "$tokens" | grep AWS_KEY | cut -d= -f2)
    local aws_secret=$(echo "$tokens" | grep AWS_SECRET | cut -d= -f2)
    local db_pass=$(echo "$tokens" | grep DB_PASS | cut -d= -f2)
    local api_key=$(echo "$tokens" | grep API_KEY | cut -d= -f2)
    local canary=$(echo "$tokens" | grep CANARY_CALLBACK | cut -d= -f2)

    log_info "Creating fake .env file..."

    sudo tee "$output_file" > /dev/null <<EOF
# Production Environment Configuration
# Last updated: $(date -Iseconds)
# WARNING: Keep this file secure!

APP_NAME="${site_domain}"
APP_ENV=production
APP_DEBUG=false
APP_URL=https://${site_domain}

# Database Configuration
DB_CONNECTION=mysql
DB_HOST=db.${site_domain}
DB_PORT=3306
DB_DATABASE=${site_domain//./_}_production
DB_USERNAME=admin
DB_PASSWORD=${db_pass}

# Redis Cache
REDIS_HOST=redis.${site_domain}
REDIS_PASSWORD=${db_pass}
REDIS_PORT=6379

# AWS Credentials
AWS_ACCESS_KEY_ID=${aws_key}
AWS_SECRET_ACCESS_KEY=${aws_secret}
AWS_DEFAULT_REGION=us-east-1
AWS_BUCKET=${site_domain//./-}-assets

# Stripe (Live Keys)
STRIPE_KEY=pk_live_$(openssl rand -hex 24)
STRIPE_SECRET=sk_live_$(openssl rand -hex 24)

# Mail Configuration
MAIL_MAILER=smtp
MAIL_HOST=smtp.${site_domain}
MAIL_PORT=587
MAIL_USERNAME=noreply@${site_domain}
MAIL_PASSWORD=${db_pass}

# API Keys
API_SECRET=${api_key}
JWT_SECRET=$(openssl rand -hex 32)

# Internal tracking (do not remove)
_INTERNAL_TRACKING=https://${site_domain}${canary}
EOF

    sudo chmod 644 "$output_file"
    log_success "Created fake .env at $output_file"
}

create_fake_git_config() {
    local site_domain="$1"
    local output_file="${HONEYPOT_DIR}/fake-git-config.txt"

    local tokens=$(generate_site_canary_tokens "$site_domain")
    local api_key=$(echo "$tokens" | grep API_KEY | cut -d= -f2)
    local canary=$(echo "$tokens" | grep CANARY_CALLBACK | cut -d= -f2)

    log_info "Creating fake .git/config file..."

    sudo tee "$output_file" > /dev/null <<EOF
[core]
	repositoryformatversion = 0
	filemode = true
	bare = false
	logallrefupdates = true
[remote "origin"]
	url = https://deploy:${api_key}@github.com/company/${site_domain//./-}.git
	fetch = +refs/heads/*:refs/remotes/origin/*
[remote "backup"]
	url = https://admin:${api_key}@gitlab.com/company/${site_domain//./-}-backup.git
	fetch = +refs/heads/*:refs/remotes/backup/*
[branch "main"]
	remote = origin
	merge = refs/heads/main
[user]
	name = Deploy Bot
	email = deploy@${site_domain}
[credential]
	helper = store
[url "https://${site_domain}${canary}"]
	insteadOf = https://internal.${site_domain}
EOF

    sudo chmod 644 "$output_file"
    log_success "Created fake git config at $output_file"
}

create_fake_database_dump() {
    local site_domain="$1"
    local output_file="${HONEYPOT_DIR}/fake-database.sql"

    local tokens=$(generate_site_canary_tokens "$site_domain")
    local db_pass=$(echo "$tokens" | grep DB_PASS | cut -d= -f2)
    local canary=$(echo "$tokens" | grep CANARY_CALLBACK | cut -d= -f2)

    log_info "Creating fake database dump..."

    sudo tee "$output_file" > /dev/null <<EOF
-- MySQL dump 10.13  Distrib 8.0.32
-- Host: localhost    Database: ${site_domain//./_}_production
-- Server version: 8.0.32

/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET NAMES utf8mb4 */;

--
-- Table structure for table \`users\`
--

DROP TABLE IF EXISTS \`users\`;
CREATE TABLE \`users\` (
  \`id\` int NOT NULL AUTO_INCREMENT,
  \`email\` varchar(255) NOT NULL,
  \`password\` varchar(255) NOT NULL,
  \`api_key\` varchar(64) DEFAULT NULL,
  \`created_at\` timestamp NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (\`id\`),
  UNIQUE KEY \`email\` (\`email\`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

--
-- Dumping data for table \`users\`
--

INSERT INTO \`users\` VALUES
(1,'admin@${site_domain}','${db_pass}','$(openssl rand -hex 32)','2024-01-15 10:30:00'),
(2,'developer@${site_domain}','devpass123','$(openssl rand -hex 32)','2024-02-20 14:45:00'),
(3,'support@${site_domain}','support2024!','$(openssl rand -hex 32)','2024-03-10 09:15:00');

--
-- Table structure for table \`api_keys\`
--

DROP TABLE IF EXISTS \`api_keys\`;
CREATE TABLE \`api_keys\` (
  \`id\` int NOT NULL AUTO_INCREMENT,
  \`user_id\` int NOT NULL,
  \`key\` varchar(64) NOT NULL,
  \`secret\` varchar(128) NOT NULL,
  \`permissions\` text,
  PRIMARY KEY (\`id\`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

INSERT INTO \`api_keys\` VALUES
(1,1,'pk_live_$(openssl rand -hex 16)','sk_live_$(openssl rand -hex 32)','admin,read,write'),
(2,1,'tracking_key','https://${site_domain}${canary}','internal');

--
-- Table structure for table \`settings\`
--

DROP TABLE IF EXISTS \`settings\`;
CREATE TABLE \`settings\` (
  \`key\` varchar(100) NOT NULL,
  \`value\` text,
  PRIMARY KEY (\`key\`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

INSERT INTO \`settings\` VALUES
('stripe_secret','sk_live_$(openssl rand -hex 24)'),
('aws_key','$(generate_fake_aws_key)'),
('aws_secret','$(generate_fake_aws_secret)'),
('smtp_password','${db_pass}');

/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
-- Dump completed on $(date '+%Y-%m-%d %H:%M:%S')
EOF

    sudo chmod 644 "$output_file"
    log_success "Created fake database dump at $output_file"
}

create_fake_admin_page() {
    local output_file="${HONEYPOT_DIR}/fake-admin.html"

    log_info "Creating fake admin login page..."

    sudo tee "$output_file" > /dev/null <<'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>phpMyAdmin</title>
    <style>
        body { font-family: sans-serif; background: #f4f4f4; margin: 50px; }
        .login-box { background: white; padding: 30px; max-width: 400px; margin: auto; border-radius: 5px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        h1 { color: #333; font-size: 24px; }
        input { width: 100%; padding: 10px; margin: 10px 0; box-sizing: border-box; }
        button { background: #f60; color: white; padding: 12px 30px; border: none; cursor: pointer; width: 100%; }
        .error { color: #c00; display: none; }
    </style>
</head>
<body>
    <div class="login-box">
        <h1>phpMyAdmin</h1>
        <form id="login" method="post">
            <input type="text" name="pma_username" placeholder="Username" required>
            <input type="password" name="pma_password" placeholder="Password" required>
            <select name="pma_servername">
                <option>localhost</option>
            </select>
            <button type="submit">Log in</button>
            <p class="error" id="error">Cannot log in to the MySQL server</p>
        </form>
    </div>
    <script>
        document.getElementById('login').onsubmit = function(e) {
            e.preventDefault();
            // Log attempt (server will capture via POST)
            setTimeout(function() {
                document.getElementById('error').style.display = 'block';
            }, 2000);
        };
    </script>
</body>
</html>
EOF

    sudo chmod 644 "$output_file"
    log_success "Created fake admin page at $output_file"
}

################################################################################
# Deploy Honeypot Files
################################################################################

deploy_honeypot() {
    local site_domain="$1"

    if [[ -z "$site_domain" ]]; then
        log_error "Site domain required for honeypot deployment"
        return 1
    fi

    log_info "Deploying honeypot for $site_domain..."

    # Initialize
    init_honeypot

    # Create all fake files
    create_fake_env_file "$site_domain"
    create_fake_git_config "$site_domain"
    create_fake_database_dump "$site_domain"
    create_fake_admin_page

    # Set ownership
    sudo chown -R www-data:www-data "$HONEYPOT_DIR" 2>/dev/null || \
    sudo chown -R nginx:nginx "$HONEYPOT_DIR" 2>/dev/null || true

    log_success "Honeypot deployed for $site_domain"

    # Show canary tokens location
    log_info "Canary tokens saved to: $CANARY_TOKENS_FILE"

    return 0
}

################################################################################
# Log Analysis
################################################################################

analyze_honeypot_logs() {
    local hours="${1:-24}"

    if [[ ! -f "$HONEYPOT_LOG" ]]; then
        log_warn "No honeypot log found at $HONEYPOT_LOG"
        return 1
    fi

    log_info "Analyzing honeypot logs (last ${hours}h)..."

    echo ""
    echo "=== HONEYPOT ACTIVITY SUMMARY ==="
    echo ""

    # Total hits
    local total=$(sudo wc -l < "$HONEYPOT_LOG" 2>/dev/null || echo 0)
    echo "Total honeypot hits: $total"
    echo ""

    # Top attacking IPs (portable: sed instead of grep -oP)
    echo "Top 10 attacking IPs:"
    sudo sed -n 's/.*ip=\([0-9.]*\).*/\1/p' "$HONEYPOT_LOG" 2>/dev/null | \
        sort | uniq -c | sort -rn | head -10 | \
        while read count ip; do
            printf "  %6d  %s\n" "$count" "$ip"
        done
    echo ""

    # Most targeted paths (portable)
    echo "Most targeted paths:"
    sudo sed -n 's/.*path=\([^ ]*\).*/\1/p' "$HONEYPOT_LOG" 2>/dev/null | \
        sort | uniq -c | sort -rn | head -10 | \
        while read count path; do
            printf "  %6d  %s\n" "$count" "$path"
        done
    echo ""

    # Top user agents (portable)
    echo "Top User-Agents:"
    sudo sed -n 's/.*ua="\([^"]*\)".*/\1/p' "$HONEYPOT_LOG" 2>/dev/null | \
        sort | uniq -c | sort -rn | head -5 | \
        while read count ua; do
            printf "  %6d  %.60s\n" "$count" "$ua"
        done
    echo ""

    # Canary token callbacks (critical!)
    if [[ -f "$HONEYPOT_CANARY_LOG" ]]; then
        local canary_hits=$(sudo wc -l < "$HONEYPOT_CANARY_LOG" 2>/dev/null || echo 0)
        if [[ "$canary_hits" -gt 0 ]]; then
            echo "!!! CANARY TOKEN CALLBACKS DETECTED !!!"
            echo "Someone used your fake credentials!"
            echo ""
            sudo tail -20 "$HONEYPOT_CANARY_LOG"
        fi
    fi
}

################################################################################
# fail2ban Integration
################################################################################

create_fail2ban_config() {
    log_info "Creating fail2ban configuration for honeypot..."

    # Filter
    sudo tee /etc/fail2ban/filter.d/nginx-honeypot.conf > /dev/null <<'EOF'
[Definition]
failregex = ^.* ip=<HOST> .*$
ignoreregex =
EOF

    # Jail
    sudo tee /etc/fail2ban/jail.d/nginx-honeypot.conf > /dev/null <<EOF
[nginx-honeypot]
enabled = true
filter = nginx-honeypot
logpath = /var/log/nginx/honeypot.log
maxretry = 1
findtime = 86400
bantime = 604800
action = iptables-multiport[name=nginx-honeypot, port="80,443"]
EOF

    log_success "fail2ban honeypot config created"
    log_info "Restart fail2ban: sudo systemctl restart fail2ban"
}

################################################################################
# Webhook Alerting
################################################################################

setup_webhook_alerting() {
    local webhook_url="$1"

    if [[ -z "$webhook_url" ]]; then
        log_error "Webhook URL required"
        return 1
    fi

    # Create monitoring script
    local alert_script="${HONEYPOT_CONFIG_DIR}/canary-alert.sh"

    cat > "$alert_script" <<EOF
#!/bin/bash
# Canary Token Alert Script
# Monitors honeypot-canary.log for new hits

WEBHOOK_URL="$webhook_url"
CANARY_LOG="/var/log/nginx/honeypot-canary.log"
LAST_POS_FILE="${HONEYPOT_CONFIG_DIR}/.canary-last-pos"

# Get last position
last_pos=0
[[ -f "\$LAST_POS_FILE" ]] && last_pos=\$(cat "\$LAST_POS_FILE")

# Get current size
current_size=\$(stat -f%z "\$CANARY_LOG" 2>/dev/null || stat -c%s "\$CANARY_LOG" 2>/dev/null || echo 0)

if [[ "\$current_size" -gt "\$last_pos" ]]; then
    # New entries! Send alert
    new_entries=\$(tail -c +\$((last_pos + 1)) "\$CANARY_LOG")

    curl -s -X POST "\$WEBHOOK_URL" \\
        -H "Content-Type: application/json" \\
        -d "{
            \"text\": \"CANARY TOKEN TRIGGERED!\",
            \"attachments\": [{
                \"color\": \"danger\",
                \"text\": \"\$new_entries\"
            }]
        }"

    echo "\$current_size" > "\$LAST_POS_FILE"
fi
EOF

    chmod +x "$alert_script"

    # Create cron job
    local cron_entry="* * * * * $alert_script"
    (crontab -l 2>/dev/null | grep -v canary-alert; echo "$cron_entry") | crontab -

    log_success "Webhook alerting configured"
    log_info "Alerts will be sent to: $webhook_url"
}

################################################################################
# Export IP list for blocklists
################################################################################

export_attacker_ips() {
    local output_file="${1:-${HONEYPOT_CONFIG_DIR}/attacker-ips.txt}"

    log_info "Exporting attacker IPs to $output_file..."

    # Portable extraction (no grep -oP)
    sudo sed -n 's/.*ip=\([0-9.]*\).*/\1/p' "$HONEYPOT_LOG" 2>/dev/null | \
        sort -u > "$output_file"

    local count=$(wc -l < "$output_file" | tr -d ' ')
    log_success "Exported $count unique IPs to $output_file"
}
