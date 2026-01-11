#!/bin/bash
# warning-fixer.sh - Parse and fix nginx configuration warnings
# Part of nginx-optimizer

################################################################################
# Warning Detection
################################################################################

# Get all nginx warnings
# Returns: list of warnings, one per line
get_nginx_warnings() {
    nginx -t 2>&1 | grep -E "^\s*nginx: \[warn\]" || true
}

# Count warnings
count_warnings() {
    local count
    count=$(get_nginx_warnings | wc -l | tr -d ' ')
    echo "$count"
}

################################################################################
# Warning Parsers
################################################################################

# Parse "listen ... http2" deprecation warning
# Input: nginx: [warn] the "listen ... http2" directive is deprecated, use the "http2" directive instead in /etc/nginx/sites-enabled/the-throne:9
# Output: /etc/nginx/sites-enabled/the-throne
parse_http2_deprecation() {
    local warning="$1"
    echo "$warning" | grep -oE '/[^:]+' | head -1
}

# Parse "conflicting server name" warning
# Input: nginx: [warn] conflicting server name "www.example.com" on 0.0.0.0:80, ignored
# Output: www.example.com
parse_conflicting_servername() {
    local warning="$1"
    echo "$warning" | grep -oE '"[^"]+"' | tr -d '"' | head -1
}

# Parse file path from warning
# Input: any warning with file:line format
# Output: /path/to/file
parse_warning_file() {
    local warning="$1"
    echo "$warning" | grep -oE ' in /[^:]+' | sed 's/ in //'
}

################################################################################
# Fixers
################################################################################

# Fix http2 deprecation: "listen 443 ssl http2" -> "listen 443 ssl" + "http2 on;"
fix_http2_deprecation() {
    local file="$1"

    if [ ! -f "$file" ]; then
        log_error "File not found: $file"
        return 1
    fi

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would fix http2 deprecation in: $file"
        return 0
    fi

    # Backup
    sudo cp "$file" "${file}.http2bak"

    # Replace "listen ... ssl http2" with "listen ... ssl"
    sudo sed -i 's/\(listen [^;]*\) http2;/\1;/g' "$file"

    # Add "http2 on;" if not present (after ssl_certificate or first location block)
    if ! grep -q "http2 on;" "$file"; then
        # Try to add after ssl_certificate line
        if grep -q "ssl_certificate" "$file"; then
            sudo sed -i '/ssl_certificate[^_]/a\    http2 on;' "$file"
        else
            # Add after first server { line
            sudo awk 'BEGIN{done=0} /server\s*\{/ && !done {print; print "    http2 on;"; done=1; next} {print}' "$file" > /tmp/http2fix.tmp
            sudo mv /tmp/http2fix.tmp "$file"
        fi
    fi

    # Verify
    if nginx -t 2>&1 | grep -q "test.*ok\|successful"; then
        log_success "Fixed http2 deprecation in: $(basename "$file")"
        sudo rm -f "${file}.http2bak"
        return 0
    else
        log_error "Fix failed, restoring backup"
        sudo mv "${file}.http2bak" "$file"
        return 1
    fi
}

# Fix conflicting server_name by finding and offering to remove duplicates
fix_conflicting_servername() {
    local domain="$1"
    local port="${2:-80}"

    # Find all files with this server_name on this port
    local files
    files=$(grep -rl "server_name.*${domain}" /etc/nginx/sites-enabled/ 2>/dev/null)

    if [ -z "$files" ]; then
        log_warn "Could not find files with server_name: $domain"
        return 1
    fi

    local count
    count=$(echo "$files" | wc -l | tr -d ' ')

    if [ "$count" -lt 2 ]; then
        # Check if same file has multiple server blocks with same name
        for f in $files; do
            local occurrences
            occurrences=$(grep -c "server_name.*${domain}" "$f" 2>/dev/null || echo 0)
            if [ "$occurrences" -gt 1 ]; then
                log_info "Found $occurrences occurrences of $domain in: $f"
                if [ "$DRY_RUN" = true ]; then
                    log_info "[DRY RUN] Would remove duplicate server_name entries"
                else
                    # This needs manual review - just report
                    log_warn "Multiple server_name entries for $domain in $f - manual review needed"
                    grep -n "server_name.*${domain}" "$f"
                fi
            fi
        done
        return 0
    fi

    log_info "Found $domain in $count files:"
    echo "$files" | while read -r f; do
        echo "  - $f"
    done

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would prompt to remove duplicate"
    else
        log_warn "Manual review needed - server_name $domain appears in multiple files"
    fi

    return 0
}

# Fix "ssl" directive deprecation
fix_ssl_directive() {
    local file="$1"

    if [ ! -f "$file" ]; then
        log_error "File not found: $file"
        return 1
    fi

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would fix ssl directive in: $file"
        return 0
    fi

    sudo cp "$file" "${file}.sslbak"

    # Replace "ssl on;" with nothing (remove it)
    sudo sed -i '/^\s*ssl\s\+on\s*;/d' "$file"

    # Ensure listen has ssl flag
    sudo sed -i 's/listen 443;/listen 443 ssl;/g' "$file"
    sudo sed -i 's/listen \[::\]:443;/listen [::]:443 ssl;/g' "$file"

    if nginx -t 2>&1 | grep -q "test.*ok\|successful"; then
        log_success "Fixed ssl directive in: $(basename "$file")"
        sudo rm -f "${file}.sslbak"
        return 0
    else
        log_error "Fix failed, restoring backup"
        sudo mv "${file}.sslbak" "$file"
        return 1
    fi
}

# Fix types_hash warning
fix_types_hash() {
    local nginx_conf="/etc/nginx/nginx.conf"

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would increase types_hash_max_size in nginx.conf"
        return 0
    fi

    if grep -q "types_hash_max_size" "$nginx_conf"; then
        # Increase existing value
        sudo sed -i 's/types_hash_max_size [0-9]\+;/types_hash_max_size 4096;/g' "$nginx_conf"
    else
        # Add after http {
        sudo sed -i '/http\s*{/a\    types_hash_max_size 4096;' "$nginx_conf"
    fi

    if nginx -t 2>&1 | grep -q "test.*ok\|successful"; then
        log_success "Fixed types_hash_max_size"
        return 0
    else
        log_error "Fix failed"
        return 1
    fi
}

################################################################################
# Main Command
################################################################################

# Fix all detected warnings
cmd_fix_warnings() {
    log_info "Scanning for nginx warnings..."

    local warnings
    warnings=$(get_nginx_warnings)

    if [ -z "$warnings" ]; then
        log_success "No warnings detected!"
        return 0
    fi

    local count
    count=$(echo "$warnings" | wc -l | tr -d ' ')
    log_info "Found $count warning(s)"
    echo ""

    local fixed=0
    local skipped=0

    # Process each warning
    while IFS= read -r warning; do
        [ -z "$warning" ] && continue

        echo "  $warning"

        # Match warning type and apply fix
        if echo "$warning" | grep -q "listen.*http2.*deprecated"; then
            local file
            file=$(parse_warning_file "$warning")
            if [ -n "$file" ]; then
                fix_http2_deprecation "$file" && ((fixed++)) || ((skipped++))
            fi

        elif echo "$warning" | grep -q "conflicting server name"; then
            local domain
            domain=$(parse_conflicting_servername "$warning")
            if [ -n "$domain" ]; then
                fix_conflicting_servername "$domain" && ((fixed++)) || ((skipped++))
            fi

        elif echo "$warning" | grep -q "\"ssl\" directive is deprecated"; then
            local file
            file=$(parse_warning_file "$warning")
            if [ -n "$file" ]; then
                fix_ssl_directive "$file" && ((fixed++)) || ((skipped++))
            fi

        elif echo "$warning" | grep -q "types_hash"; then
            fix_types_hash && ((fixed++)) || ((skipped++))

        elif echo "$warning" | grep -q "protocol options redefined"; then
            log_warn "Protocol redefinition - usually harmless, skipping"
            ((skipped++))

        else
            log_warn "Unknown warning type - skipping"
            ((skipped++))
        fi

        echo ""
    done <<< "$warnings"

    echo "═══════════════════════════════════════════════════════════"
    log_info "Summary: $fixed fixed, $skipped skipped"

    # Final test
    local remaining
    remaining=$(count_warnings)
    if [ "$remaining" -eq 0 ]; then
        log_success "All warnings resolved!"
    else
        log_warn "$remaining warning(s) remaining"
    fi

    return 0
}
