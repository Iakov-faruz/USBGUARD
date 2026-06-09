#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# USBGuard Approval Manager - TTL Reaper (Cleanup Expired Rules)
# Version: 2.2 (Fixed)
# ═══════════════════════════════════════════════════════════════

# ─── Source libraries ─────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

for lib in config-reader.sh logger.sh lock.sh backup.sh time-guards.sh validators.sh; do
    source "${LIB_DIR}/${lib}" 2>/dev/null || {
        echo "FATAL: Cannot load library: ${LIB_DIR}/${lib}" >&2
        exit 1
    }
done

# ─── Configuration ─────────────────────────────────────────────
CONFIG_FILE="/etc/usbguard/approval-manager.conf"
RULES_TEMPORARY=$(get_conf "RULES_TEMPORARY" "${CONFIG_FILE}") || RULES_TEMPORARY="/etc/usbguard/rules.d/90-temporary.rules"
RULES_PERMANENT=$(get_conf "RULES_PERMANENT" "${CONFIG_FILE}") || RULES_PERMANENT="/etc/usbguard/rules.d/50-permanent.rules"
BACKUP_DIR=$(get_conf "BACKUP_DIR" "${CONFIG_FILE}") || BACKUP_DIR="/etc/usbguard/backups"
LOG_FILE=$(get_conf "LOG_FILE" "${CONFIG_FILE}") || LOG_FILE="/var/log/usbguard-approval.log"
LOCK_FILE=$(get_conf "LOCK_FILE" "${CONFIG_FILE}") || LOCK_FILE="/var/lock/usbguard-manager.lock"
STATE_DIR=$(get_conf "STATE_DIR" "${CONFIG_FILE}") || STATE_DIR="/var/lib/usbguard-manager"
STATE_FILE="${STATE_DIR}/last_run_epoch"
MAX_CLOCK_JUMP=$(get_conf_int "MAX_CLOCK_JUMP_SECONDS" 3600 "${CONFIG_FILE}")
BACKUP_KEEP=$(get_conf_int "BACKUP_KEEP" 5 "${CONFIG_FILE}")

# ─── Temporary files ──────────────────────────────────────────
TMP_FILE=""
BACKUP_FILE=""
AWK_STDERR=""

_cleanup_temp() {
    [[ -n "$TMP_FILE" ]] && rm -f "$TMP_FILE" 2>/dev/null
    [[ -n "$AWK_STDERR" ]] && rm -f "$AWK_STDERR" 2>/dev/null
}
trap '_cleanup_temp' EXIT

# ═══════════════════════════════════════════════════════════════
# AWK State Machine
# ═══════════════════════════════════════════════════════════════
_awk_ttl_filter() {
    local now="$1"
    local temp_rules_file="$2"

    awk -v now="$now" '
    BEGIN { state = 0; buffer = ""; expired_count = 0; }
    {
        if (state == 0) {
            if ($0 ~ /^[[:space:]]*allow/) {
                buffer = $0
                state = 1
            } else {
                print $0
            }
        } else if (state == 1) {
            if ($0 ~ /^[[:space:]]*# ttl_epoch:[[:space:]]*[0-9]+/) {
                buffer = buffer ORS $0
                state = 2
            } else if ($0 ~ /^[[:space:]]*allow/) {
                expired_count++
                print "WARN: Discarded orphaned allow rule: " buffer > "/dev/stderr"
                buffer = $0
                state = 1
            } else if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) {
                buffer = buffer ORS $0
            } else {
                expired_count++
                print "WARN: Discarded orphaned allow rule (unexpected): " buffer > "/dev/stderr"
                buffer = ""
                print $0
                state = 0
            }
        } else if (state == 2) {
            split(buffer, lines, ORS)
            comment_line = lines[2]
            gsub(/^[[:space:]]*# ttl_epoch:[[:space:]]*/, "", comment_line)
            gsub(/[[:space:]]*$/, "", comment_line)
            epoch = int(comment_line)

            if (epoch <= now) {
                expired_count++
                state = 0
                buffer = ""
            } else {
                print buffer
                state = 3
                buffer = ""
            }
        } else if (state == 3) {
            print $0
            state = 0
        }
    }
    END {
        if (state == 1 && length(buffer) > 0) {
            expired_count++
            print "WARN: Discarded trailing orphaned allow rule: " buffer > "/dev/stderr"
        }
        print "EXPIRED_COUNT=" expired_count > "/dev/stderr"
    }
    ' "$temp_rules_file" 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════
# Reload function
# ═══════════════════════════════════════════════════════════════
_reload_daemon_verified() {
    if systemctl reload usbguard 2>/dev/null; then
        return 0
    fi
    pkill -HUP usbguard-daemon 2>/dev/null || true
    sleep 1
    systemctl is-active --quiet usbguard 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════
main() {
    local start_time end_time duration
    start_time=$(date +%s 2>/dev/null || echo 0)
    local exit_code=0
    local now
    local expired_count=0

    init_logger "$LOG_FILE" 2>/dev/null
    log_info "CLEANUP" "USBGuard TTL Reaper started"

    # Stage 1: Time Guards
    log_info "CLEANUP" "Stage 1/5: Time guards"

    now=$(get_epoch_now) || {
        log_error "CLEANUP" "Cannot get current time"
        exit 1
    }

    if ! check_clock_reasonable; then
        log_error "CLEANUP" "Clock check failed - aborting"
        exit 1
    fi

    if ! detect_clock_jump_backward "$MAX_CLOCK_JUMP" "$STATE_FILE"; then
        log_warn "CLEANUP" "Clock jump detected - skipping cleanup"
        log_session_summary "CLEANUP" "Skipped (clock jump)" 0 0
        exit 0
    fi

    # Stage 2: Acquire Lock
    log_info "CLEANUP" "Stage 2/5: Acquiring lock"
    if ! acquire_lock "$LOCK_FILE" "nowait"; then
        log_warn "CLEANUP" "Lock held by another process - skipping"
        log_session_summary "CLEANUP" "Skipped (locked)" 0 0
        exit 0
    fi

    # Stage 3: Check if temporary rules file exists
    log_info "CLEANUP" "Stage 3/5: Checking temporary rules"
    if [[ ! -f "$RULES_TEMPORARY" ]]; then
        log_info "CLEANUP" "Temporary rules file does not exist: $RULES_TEMPORARY"
        release_lock
        exit 0
    fi

    # Stage 4: Create backup before cleanup
    log_info "CLEANUP" "Stage 4/5: Creating backup before cleanup"
    BACKUP_FILE=$(create_backup "$BACKUP_DIR" "$(dirname "$RULES_TEMPORARY")" "$BACKUP_KEEP") || {
        log_warn "CLEANUP" "Backup creation failed, continuing without rollback capability"
    }

    # Stage 5: Process with AWK
    log_info "CLEANUP" "Stage 5/5: Processing expired rules"

    TMP_FILE=$(mktemp -t usbguard_cleanup_XXXXXX 2>/dev/null)
    AWK_STDERR=$(mktemp -t usbguard_awk_stderr_XXXXXX 2>/dev/null)

    _awk_ttl_filter "$now" "$RULES_TEMPORARY" > "$TMP_FILE" 2> "$AWK_STDERR"

    # Check if any change was made
    if ! cmp -s "$RULES_TEMPORARY" "$TMP_FILE"; then
        # Replace with cleaned file
        mv "$TMP_FILE" "$RULES_TEMPORARY"
        chmod 600 "$RULES_TEMPORARY"
        chown root:root "$RULES_TEMPORARY"

        # Reload daemon
        if _reload_daemon_verified; then
            log_info "CLEANUP" "Rules reloaded successfully"
        else
            log_error "CLEANUP" "Failed to reload usbguard rules"

            # Point rollback if backup exists
            if [[ -n "$BACKUP_FILE" ]] && [[ -f "$BACKUP_FILE" ]]; then
                log_info "CLEANUP" "Performing point rollback"
                local point_restore_dir
                point_restore_dir=$(mktemp -d /var/tmp/usbguard_rollback_XXXXXX 2>/dev/null)

                if tar -xzf "$BACKUP_FILE" -C "$point_restore_dir" 2>/dev/null; then
                    local extracted_temp
                    extracted_temp=$(find "$point_restore_dir" -type f -name "$(basename "$RULES_TEMPORARY")" | head -n 1)
                    if [[ -f "$extracted_temp" ]]; then
                        cp -f "$extracted_temp" "$RULES_TEMPORARY"
                        _reload_daemon_verified
                    fi
                fi
                rm -rf "$point_restore_dir" 2>/dev/null
            fi

            release_lock
            exit 1
        fi
    else
        log_info "CLEANUP" "No expired rules found"
        rm -f "$TMP_FILE" 2>/dev/null
    fi

    expired_count=$(grep -oP 'EXPIRED_COUNT=\K[0-9]+' "$AWK_STDERR" 2>/dev/null || echo 0)
    rm -f "$AWK_STDERR" 2>/dev/null
    TMP_FILE=""

    write_last_run_epoch "$(get_epoch_now)" "$STATE_FILE" 2>/dev/null || true
    release_lock

    end_time=$(date +%s 2>/dev/null || echo 0)
    duration=$((end_time - start_time))

    log_audit "CLEANUP" "Cleaned ${expired_count} expired temporary rule(s)"
    log_session_summary "CLEANUP" "Cleaned ${expired_count} rules" 0 "$duration"
    exit 0
}

main "$@"