#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# USBGuard Approval Manager - TTL Reaper (Cleanup Expired Rules)
# Version: 2.2
# ═══════════════════════════════════════════════════════════════
#
# AWK State Machine: Parsing 90-temporary.rules
# ─────────────────────────────────────────────────────────────
# State 0: IDLE (searching for 'allow' rule)
# State 1: RULE_FOUND (buffer contains allow rule, checking for ttl_epoch)
# State 2: TTL_FOUND (ttl_epoch comment found, checking expiry)
# State 3: PRINT (will print the pair if TTL not expired)
# State 4: SKIP (TTL expired or invalid - skip the pair)
#
# Every 'allow' rule starts a new pair; the NEXT line (# ttl_epoch:)
# completes it. Non-matching lines are passed through unchanged.
# ═══════════════════════════════════════════════════════════════

# ─── Source libraries ─────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

for lib in config-reader.sh logger.sh lock.sh backup.sh time-guards.sh validators.sh; do
    # shellcheck source=./lib/logger.sh
    source "${LIB_DIR}/${lib}" 2>/dev/null || {
        echo "FATAL: Cannot load library: ${LIB_DIR}/${lib}" >&2
        exit 1
    }
done

# ─── Configuration (from config file) ─────────────────────────
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

# ─── Cleanup function ─────────────────────────────────────────
_cleanup_temp() {
    if [[ -n "$TMP_FILE" ]] && [[ -f "$TMP_FILE" ]]; then
        rm -f "$TMP_FILE" 2>/dev/null
    fi
    if [[ -n "$AWK_STDERR" ]] && [[ -f "$AWK_STDERR" ]]; then
        rm -f "$AWK_STDERR" 2>/dev/null
    fi
}
trap '_cleanup_temp' EXIT

# ═══════════════════════════════════════════════════════════════
# AWK State Machine for TTL parsing
# ═══════════════════════════════════════════════════════════════
# States:
#   0 = IDLE       - searching for 'allow' rule
#   1 = RULE_FOUND - buffered an allow rule, expecting ttl_epoch comment next
#   2 = TTL_FOUND  - found ttl_epoch, deciding print or skip
#   3 = PRINT      - pair is valid (TTL not expired), print both lines
#   4 = SKIP       - pair is expired/invalid, print nothing
#
# Global awk variables:
#   now            - current epoch time (passed from shell)
#   buffer         - holds the allow rule line when in state 1
#   state          - current state (0-4)
#   expired_count  - counter for expired rules removed
# ─────────────────────────────────────────────────────────────
_awk_ttl_filter() {
    local now="$1"
    local temp_rules_file="$2"

    awk -v now="$now" '
    BEGIN {
        state = 0
        buffer = ""
        expired_count = 0
        line_count = 0
    }

    # ─── State machine ─────────────────────────────────────────
    {
        line_count++

        if (state == 0) {
            # ── IDLE State ────────────────────────────────────
            if ($0 ~ /^[[:space:]]*allow/) {
                buffer = $0
                state = 1
            } else {
                print $0
            }

        } else if (state == 1) {
            # ── RULE_FOUND State ──────────────────────────────
            if ($0 ~ /^[[:space:]]*# ttl_epoch:[[:space:]]*[0-9]+/) {
                # Found ttl_epoch
                buffer = buffer ORS $0
                state = 2

            } else if ($0 ~ /^[[:space:]]*allow/) {
                # FAIL-CLOSED: orphaned rule (new allow before ttl_epoch)
                expired_count++
                print "WARN: Discarded orphaned allow rule (no ttl_epoch): " buffer > "/dev/stderr"
                buffer = $0
                state = 1

            } else if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) {
                # תיקון: התעלמות משורות ריקות או הערות בין allow ל‑ttl_epoch
                buffer = buffer ORS $0

            } else {
                # FAIL-CLOSED: unexpected content
                expired_count++
                print "WARN: Discarded orphaned allow rule (unexpected content): " buffer > "/dev/stderr"
                buffer = ""
                print $0
                state = 0
            }

        } else if (state == 2) {
            # ── TTL_FOUND State ───────────────────────────────
            split(buffer, lines, ORS)
            comment_line = lines[2]
            gsub(/^[[:space:]]*# ttl_epoch:[[:space:]]*/, "", comment_line)
            gsub(/[[:space:]]*$/, "", comment_line)
            epoch = int(comment_line)

            if (epoch <= now) {
                # Rule expired
                expired_count++
                state = 0
                buffer = ""
            } else {
                # Rule still valid
                print buffer
                state = 3
                buffer = ""
            }

        } else if (state == 3) {
            # ── PRINT State ───────────────────────────────────
            print $0
            state = 0

        } else if (state == 4) {
            # ── SKIP State (unused fallback) ──────────────────
            state = 0
            if ($0 ~ /^[[:space:]]*allow/) {
                buffer = $0
                state = 1
            } else {
                print $0
            }
        }
    }

    END {
        # FAIL-CLOSED: discard trailing orphaned allow rule (no ttl_epoch)
        if (state == 1 && length(buffer) > 0) {
            expired_count++
            print "WARN: Discarded trailing orphaned allow rule: " buffer > "/dev/stderr"
        }

        print "EXPIRED_COUNT=" expired_count > "/dev/stderr"
    }
    ' "$temp_rules_file" 2>/dev/null
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

    # ── Initialize logger ──────────────────────────────────────
    init_logger "$LOG_FILE" 2>/dev/null
    log_info "CLEANUP" "USBGuard TTL Reaper started"

    # ── STAGE 1: Time Guards ─────────────────────────────────────
    log_info "CLEANUP" "Stage 1/7: Time guards"

    now=$(get_epoch_now) || {
        log_error "CLEANUP" "Cannot get current time"
        exit_code=1
        log_session_summary "CLEANUP" "Failed" "$exit_code" 0
        exit "$exit_code"
    }

    if ! check_clock_reasonable; then
        log_error "CLEANUP" "Clock check failed - aborting"
        exit_code=1
        log_session_summary "CLEANUP" "Clock check failed" "$exit_code" 0
        exit "$exit_code"
    fi

    if ! detect_clock_jump_backward "$MAX_CLOCK_JUMP" "$STATE_FILE"; then
        log_warn "CLEANUP" "Clock jump detected - skipping cleanup"
        exit_code=0
        log_session_summary "CLEANUP" "Skipped (clock jump)" "$exit_code" 0
        exit "$exit_code"
    fi

    # ── STAGE 2: Acquire Lock ───────────────────────────────────
    # IMPORTANT: Lock must be acquired BEFORE reading the rules file
    # to prevent race conditions with usb-approve.sh
    log_info "CLEANUP" "Stage 2/7: Acquiring lock"

    if ! acquire_lock "$LOCK_FILE" "nowait"; then
        log_warn "CLEANUP" "Lock held by another process - skipping (will retry in 5 minutes)"
        exit_code=0
        log_session_summary "CLEANUP" "Skipped (locked)" "$exit_code" 0
        exit "$exit_code"
    fi

    # ── STAGE 3: Parse with AWK State Machine ────────────────────
    log_info "CLEANUP" "Stage 3/7: Parsing temporary rules with AWK state machine"

    if [[ ! -f "$RULES_TEMPORARY" ]]; then
        log_info "CLEANUP" "Temporary rules file does not exist: $RULES_TEMPORARY"
        exit_code=    TMP_FILE=""

    # ── STAGE 7: Reload Daemon ──────────────────────────────────────────
    # USBGuard 1.1.2 does not support \`usbguard reload-rules\`.
    # Primary: systemctl reload (sends SIGHUP internally and verifies via unit state).
    # Fallback: direct SIGHUP + systemctl is-active verification.
    log_info "CLEANUP" "Stage 7/7: Reloading usbguard daemon"

    _reload_daemon_verified() {
        if systemctl reload usbguard 2>/dev/null; then
            return 0
        fi
        pkill -HUP usbguard-daemon 2>/dev/null || true
        sleep 1
        systemctl is-active --quiet usbguard 2>/dev/null
    }

    if _reload_daemon_verified; then
        log_info "CLEANUP" "Rules reloaded successfully"
    else
        log_error "CLEANUP" "Failed to reload usbguard rules - attempting point rollback"

        # ── POINT ROLLBACK ───────────────────────────────────────────────
        # Restore only 90-temporary.rules from the latest backup
        # (NOT a full restore, which may re-introduce already-expired rules)
        if [[ -n "$BACKUP_FILE" ]] && [[ -f "$BACKUP_FILE" ]]; then
            log_info "CLEANUP" "Point rollback from: $BACKUP_FILE"

            local point_restore_dir
            # Use /var/tmp so it survives PrivateTmp=true in systemd
            point_restore_dir=$(mktemp -d /var/tmp/usbguard_point_rollback_XXXXXX 2>/dev/null)

            if tar -xzf "$BACKUP_FILE" -C "$point_restore_dir" 2>/dev/null; then
                local extracted_temp
                extracted_temp=$(find "$point_restore_dir" -type f \
                    -name "$(basename "$RULES_TEMPORARY")" | head -n 1)

                if [[ -f "$extracted_temp" ]]; then
                    cp -f "$extracted_temp" "$RULES_TEMPORARY" 2>/dev/null
                    chmod 600 "$RULES_TEMPORARY" 2>/dev/null
                    chown root:root "$RULES_TEMPORARY" 2>/dev/null

                    # Retry reload after restoring
                    if ! _reload_daemon_verified; then
                        log_critical "CLEANUP" "Point rollback reload also failed!"
                        rm -rf "$point_restore_dir" 2>/dev/null
                        rm -f "$AWK_STDERR" 2>/dev/null
                        exit_code=2
                        release_lock
                        log_session_summary "CLEANUP" "CRITICAL: point rollback failed" "$exit_code" 0
                        exit "$exit_code"
                    fi

                    log_info "CLEANUP" "Point rollback successful"
                else
                    log_critical "CLEANUP" "Cannot find temp rules in backup for point rollback"
                fi
            fi

            rm -rf "$point_restore_dir" 2>/dev/null
        else
            log_critical "CLEANUP" "No backup available for point rollback!"
        fi

        rm -f "$AWK_STDERR" 2>/dev/null
        exit_code=1
        release_lock
        log_session_summary "CLEANUP" "Failed (reload)" "$exit_code" 0
        exit "$exit_code"
    fi

    # ── Success ──────────────────────────────────────────────────────────
    expired_count=$(grep -oP 'EXPIRED_COUNT=\K[0-9]+' "$AWK_STDERR" 2>/dev/null || echo 0)
    rm -f "$AWK_STDERR" 2>/dev/null

    write_last_run_epoch "$(get_epoch_now)" "$STATE_FILE" 2>/dev/null || true
    release_lock

    end_time=$(date +%s 2>/dev/null || echo 0)
    duration=$((end_time - start_time))

    log_audit "CLEANUP" "Cleaned ${expired_count:-0} expired temporary rule(s)"
    log_session_summary "CLEANUP" "Cleaned ${expired_count:-0} rules" 0 "$duration"
    exit 0
}� POINT ROLLBACK ───────────────────────────────────────────────
        # משחזרים רק את 90-temporary.rules מהגיבוי האחרון
        # כדי לא לשחזר חוקים שפג תוקפם.
        if [[ -n "$BACKUP_FILE" ]] && [[ -f "$BACKUP_FILE" ]]; then
            log_info "CLEANUP" "Point rollback from: $BACKUP_FILE"

            local point_restore_dir
            point_restore_dir=$(mktemp -d -t usbguard_point_rollback_XXXXXX 2>/dev/null)

            # חילוץ הגיבוי לתיקייה זמנית
            if tar -xzf "$BACKUP_FILE" -C "$point_restore_dir" 2>/dev/null; then

                # איתור קובץ temporary rules מתוך הגיבוי
                local extracted_temp
                extracted_temp=$(find "$point_restore_dir" -type f -name "$(basename "$RULES_TEMPORARY")" | head -n 1)

                if [[ -f "$extracted_temp" ]]; then
                    # שחזור הקובץ
                    cp -f "$extracted_temp" "$RULES_TEMPORARY" 2>/dev/null

                    # ניסיון נוסף לטעינת חוקים (שוב דרך HUP)
                    pkill -HUP usbguard-daemon 2>/dev/null || true
                    sleep 1

                    if ! pgrep usbguard-daemon >/dev/null; then
                        log_critical "CLEANUP" "Point rollback reload also failed!"
                        rm -rf "$point_restore_dir" 2>/dev/null
                        rm -f "$AWK_STDERR" 2>/dev/null
                        exit_code=2
                        release_lock
                        log_session_summary "CLEANUP" "CRITICAL: point rollback failed" "$exit_code" 0
                        exit "$exit_code"
                    fi

                    log_info "CLEANUP" "Point rollback successful"
                else
                    log_critical "CLEANUP" "Cannot find temp rules in backup for point rollback"
                fi
            fi

            rm -rf "$point_restore_dir" 2>/dev/null
        else
            log_critical "CLEANUP" "No backup available for point rollback!"
        fi

        rm -f "$AWK_STDERR" 2>/dev/null
        exit_code=1
        release_lock
        log_session_summary "CLEANUP" "Failed (reload)" "$exit_code" 0
        exit "$exit_code"
    fi

    # ── Success ─────────────────────────────────────────────────────────
    expired_count=$(grep -oP 'EXPIRED_COUNT=\K[0-9]+' "$AWK_STDERR" 2>/dev/null || echo 0)
    rm -f "$AWK_STDERR" 2>/dev/null

    write_last_run_epoch "$(get_epoch_now)" "$STATE_FILE" 2>/dev/null || true
    release_lock

    end_time=$(date +%s 2>/dev/null || echo 0)
    duration=$((end_time - start_time))

    log_audit "CLEANUP" "Cleaned ${expired_count:-0} expired temporary rule(s)"
    log_session_summary "CLEANUP" "Cleaned ${expired_count:-0} rules" 0 "$duration"
    exit 0
}


# ─── Run main ─────────────────────────────────────────────────
main "$@"