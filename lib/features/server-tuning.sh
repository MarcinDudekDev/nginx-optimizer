#!/bin/bash
################################################################################
# features/server-tuning.sh - RAM-Aware Server Tuning
################################################################################
# Tunes nginx core directives (worker_processes, worker_connections,
# worker_rlimit_nofile) based on detected system RAM and CPU cores.
# Modifies nginx.conf directly since these directives live in main
# and events contexts (not in http/conf.d).
#
# With thanks to easyinstallvps RAM-tier approach -- https://github.com/sugan0927/easyinstallvps
################################################################################

# Ensure registry is loaded
if ! type -t feature_register &>/dev/null; then
    echo "Error: registry.sh must be sourced before feature modules" >&2
    return 1
fi

################################################################################
# Feature Definition
################################################################################

# shellcheck disable=SC2034  # FEATURE_* vars consumed by feature_register() in registry.sh
FEATURE_ID="server-tuning"
# shellcheck disable=SC2034
FEATURE_DISPLAY="Server Tuning (RAM-aware)"
# shellcheck disable=SC2034
FEATURE_DETECT_PATTERN="worker_processes[[:space:]]+auto"
# shellcheck disable=SC2034
FEATURE_SCOPE="global"
# shellcheck disable=SC2034
FEATURE_TEMPLATE=""
# shellcheck disable=SC2034
FEATURE_TEMPLATE_CONTEXT="main"
# shellcheck disable=SC2034
FEATURE_ALIASES="workers,tuning"
# shellcheck disable=SC2034
FEATURE_NGINX_MIN_VERSION=""
# shellcheck disable=SC2034
FEATURE_PREREQ_CHECK=""

################################################################################
# Custom Detection Logic
################################################################################

# Detect if worker_processes auto is set (indicates tuning was applied)
# Args: $1 = config_file, $2 = site_name (optional)
# Returns: 0 if detected, 1 if not
feature_detect_custom_server_tuning() {
    # shellcheck disable=SC2034  # config_file part of detection API
    local config_file="$1"
    # shellcheck disable=SC2034  # site_name reserved for API compatibility
    local site_name="${2:-}"

    local nginx_conf
    if type -t get_nginx_main_conf &>/dev/null; then
        nginx_conf=$(get_nginx_main_conf)
    fi

    if [[ -z "${nginx_conf:-}" ]]; then
        # Try common locations
        for conf in /etc/nginx/nginx.conf /opt/homebrew/etc/nginx/nginx.conf /usr/local/etc/nginx/nginx.conf; do
            if [[ -f "$conf" ]]; then
                nginx_conf="$conf"
                break
            fi
        done
    fi

    if [[ -z "${nginx_conf:-}" ]] || [[ ! -f "$nginx_conf" ]]; then
        return 1
    fi

    # Check for worker_processes auto (our signature)
    if grep -qE '^[[:space:]]*worker_processes[[:space:]]+auto;' "$nginx_conf" 2>/dev/null; then
        # shellcheck disable=SC2034  # LAST_DIRECTIVE_SOURCE consumed by registry.sh
        LAST_DIRECTIVE_SOURCE="$nginx_conf"
        return 0
    fi

    return 1
}

################################################################################
# Custom Apply Logic
################################################################################

# Apply RAM-aware server tuning to nginx.conf
# Args: $1 = target_site (optional, ignored for global feature)
# Returns: 0 on success, 1 on failure
feature_apply_custom_server_tuning() {
    # shellcheck disable=SC2034  # target_site reserved for global features
    local target_site="${1:-}"

    if type -t log_to_file &>/dev/null; then
        log_to_file "INFO" "Applying Server Tuning (RAM-aware)..."
    fi

    # Get system info
    local ram_mb cores worker_conn rlimit_nofile
    if type -t sysinfo_ram_mb &>/dev/null; then
        ram_mb=$(sysinfo_ram_mb)
        cores=$(sysinfo_cpu_cores)
        worker_conn=$(sysinfo_worker_connections)
        rlimit_nofile=$(sysinfo_worker_rlimit_nofile)
    else
        # Fallback defaults if sysinfo not loaded
        ram_mb="unknown"
        cores=1
        worker_conn=2048
        rlimit_nofile=4096
    fi

    # Find nginx.conf
    local nginx_conf=""
    if type -t get_nginx_main_conf &>/dev/null; then
        nginx_conf=$(get_nginx_main_conf)
    fi
    if [[ -z "$nginx_conf" ]]; then
        for conf in /etc/nginx/nginx.conf /opt/homebrew/etc/nginx/nginx.conf /usr/local/etc/nginx/nginx.conf; do
            if [[ -f "$conf" ]]; then
                nginx_conf="$conf"
                break
            fi
        done
    fi

    if [[ -z "$nginx_conf" ]] || [[ ! -f "$nginx_conf" ]]; then
        if type -t log_warn &>/dev/null; then
            log_warn "Cannot find nginx.conf — skipping server tuning"
        fi
        return 1
    fi

    if [ "${DRY_RUN:-false}" = true ]; then
        if type -t ui_step_path &>/dev/null; then
            ui_step_path "Would tune" "nginx.conf (${ram_mb}MB RAM, ${cores} cores)"
            ui_step_path "  worker_processes" "auto (${cores} cores)"
            ui_step_path "  worker_connections" "$worker_conn"
            ui_step_path "  worker_rlimit_nofile" "$rlimit_nofile"
        fi
        return 0
    fi

    # Create temp file for awk output
    local temp_file
    if type -t secure_mktemp &>/dev/null; then
        temp_file=$(secure_mktemp)
    else
        temp_file=$(mktemp)
    fi

    # Apply tuning with awk:
    # 1. Set worker_processes auto (or replace existing value)
    # 2. Add worker_rlimit_nofile after worker_processes
    # 3. Set worker_connections inside events block
    awk -v worker_conn="$worker_conn" -v rlimit="$rlimit_nofile" '
    BEGIN { rlimit_done = 0; in_events = 0; events_brace = 0 }
    {
        line = $0

        # Replace worker_processes with auto
        if (line ~ /^[[:space:]]*worker_processes/) {
            sub(/worker_processes[[:space:]]+[^;]+/, "worker_processes auto", line)
            print line
            # Add rlimit_nofile right after if not already present
            if (!rlimit_done) {
                print "worker_rlimit_nofile " rlimit ";"
                rlimit_done = 1
            }
            next
        }

        # Skip existing worker_rlimit_nofile (we add our own)
        if (line ~ /^[[:space:]]*worker_rlimit_nofile/) {
            rlimit_done = 1
            next
        }

        # Track events block
        if (line ~ /^[[:space:]]*events[[:space:]]*\{/) {
            in_events = 1
            events_brace = 1
        }

        # Replace worker_connections inside events block
        if (in_events && line ~ /^[[:space:]]*worker_connections/) {
            sub(/worker_connections[[:space:]]+[^;]+/, "worker_connections " worker_conn, line)
            print line

            # Add multi_accept if not present nearby
            next
        }

        # Track brace depth in events
        if (in_events) {
            # Count opening braces (excluding the events line itself which we already counted)
            if (line ~ /\{/ && !(line ~ /^[[:space:]]*events/)) {
                events_brace++
            }
            if (line ~ /\}/) {
                events_brace--
                if (events_brace <= 0) {
                    in_events = 0
                }
            }
        }

        print line
    }' "$nginx_conf" > "$temp_file"

    # Smart sudo: only use if file not writable
    local SUDO=""
    if [[ ! -w "$nginx_conf" ]]; then
        SUDO="sudo"
    fi

    # Backup original
    $SUDO cp "$nginx_conf" "${nginx_conf}.tuning-bak"

    # Apply changes
    $SUDO cp "$temp_file" "$nginx_conf"
    rm -f "$temp_file"

    # Validate
    if command -v nginx &>/dev/null; then
        if ! nginx -t 2>&1 | grep -q "test is successful\|syntax is ok"; then
            # Rollback on failure
            $SUDO mv "${nginx_conf}.tuning-bak" "$nginx_conf"
            if type -t log_warn &>/dev/null; then
                log_warn "nginx -t failed after tuning, rolled back"
            fi
            return 1
        fi
    fi

    $SUDO rm -f "${nginx_conf}.tuning-bak"

    if type -t ui_step_path &>/dev/null; then
        ui_step_path "Tuned nginx.conf" "${ram_mb}MB RAM → worker_connections ${worker_conn}"
    fi

    return 0
}

################################################################################
# Custom Remove Logic
################################################################################

# Remove server tuning written by feature_apply_custom_server_tuning.
#
# Apply rewrites nginx.conf in place: worker_processes -> auto plus a net-new
# worker_rlimit_nofile line after it, and worker_connections inside events{}.
# The pre-apply values are only in the safety backup cmd_remove() took, so
# removal strips the three tuned lines and lets nginx fall back to its own
# defaults. A leftover ${nginx_conf}.tuning-bak from an interrupted apply is
# a pristine pre-tuning copy and is restored whole instead.
# Args: $1 = target_site (optional, ignored for global feature)
# Returns: 0 on success, 1 if nothing was applied
feature_remove_custom_server_tuning() {
    # shellcheck disable=SC2034  # target_site reserved for API compatibility (global feature)
    local target_site="${1:-}"

    local nginx_conf=""
    if type -t get_nginx_main_conf &>/dev/null; then
        nginx_conf=$(get_nginx_main_conf)
    fi
    if [[ -z "$nginx_conf" ]]; then
        for conf in /etc/nginx/nginx.conf /opt/homebrew/etc/nginx/nginx.conf /usr/local/etc/nginx/nginx.conf; do
            if [[ -f "$conf" ]]; then
                nginx_conf="$conf"
                break
            fi
        done
    fi

    # Signature of an applied (or interrupted) run: worker_processes auto in
    # nginx.conf, or a .tuning-bak apply left behind when it was interrupted.
    local tuning_bak=""
    if [[ -n "$nginx_conf" ]] && [[ -f "${nginx_conf}.tuning-bak" ]]; then
        tuning_bak="${nginx_conf}.tuning-bak"
    fi

    if [[ -z "$tuning_bak" ]] && { [[ ! -f "$nginx_conf" ]] || \
        ! grep -qE '^[[:space:]]*worker_processes[[:space:]]+auto;' "$nginx_conf" 2>/dev/null; }; then
        if [ "${DRY_RUN:-false}" = true ]; then
            return 0
        fi
        if type -t log_info &>/dev/null; then
            log_info "Server tuning not applied — nothing to remove"
        fi
        return 1
    fi

    if [ "${DRY_RUN:-false}" = true ]; then
        if type -t ui_step_path &>/dev/null; then
            if [[ -n "$tuning_bak" ]]; then
                ui_step_path "Would restore" "nginx.conf from ${tuning_bak}"
            else
                ui_step_path "Would revert" "$nginx_conf (worker_processes, worker_rlimit_nofile, worker_connections → nginx defaults)"
            fi
        fi
        return 0
    fi

    local SUDO=""
    [[ ! -w "$nginx_conf" ]] && SUDO="sudo"

    # Interrupted apply: .tuning-bak is the pristine copy — restore it whole.
    if [[ -n "$tuning_bak" ]]; then
        if $SUDO mv "$tuning_bak" "$nginx_conf"; then
            if type -t ui_step_path &>/dev/null; then
                ui_step_path "Restored" "nginx.conf from interrupted-apply backup"
            fi
            return 0
        fi
        return 1
    fi

    if ! $SUDO cp "$nginx_conf" "${nginx_conf}.remove-bak"; then
        return 1
    fi

    # worker_connections is only valid inside events{} — no context tracking
    # needed to find the lines this feature manages.
    $SUDO sed -i.rmback \
        -e '/^[[:space:]]*worker_processes[[:space:]][[:space:]]*auto[[:space:]]*;/d' \
        -e '/^[[:space:]]*worker_rlimit_nofile[[:space:]]/d' \
        -e '/^[[:space:]]*worker_connections[[:space:]]/d' \
        "$nginx_conf" 2>/dev/null || \
        $SUDO sed -i '' \
        -e '/^[[:space:]]*worker_processes[[:space:]][[:space:]]*auto[[:space:]]*;/d' \
        -e '/^[[:space:]]*worker_rlimit_nofile[[:space:]]/d' \
        -e '/^[[:space:]]*worker_connections[[:space:]]/d' \
        "$nginx_conf" 2>/dev/null
    $SUDO rm -f "${nginx_conf}.rmback" 2>/dev/null

    # Validate, mirroring apply's rollback-on-failure
    if command -v nginx &>/dev/null; then
        if ! nginx -t 2>&1 | grep -q "test is successful\|syntax is ok"; then
            $SUDO mv "${nginx_conf}.remove-bak" "$nginx_conf"
            if type -t log_warn &>/dev/null; then
                log_warn "nginx -t failed after removing tuning, rolled back"
            fi
            return 1
        fi
    fi

    $SUDO rm -f "${nginx_conf}.remove-bak"

    if type -t ui_step_path &>/dev/null; then
        ui_step_path "Reverted server tuning" "$nginx_conf → nginx defaults"
    fi

    return 0
}

################################################################################
# Register Feature
################################################################################

feature_register
