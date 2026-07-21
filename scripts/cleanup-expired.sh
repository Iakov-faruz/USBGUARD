#!/usr/bin/env bash
# ==============================================================================
# USBGuard Approval Manager - TTL Reaper (Cleanup Expired Rules)
# Version: 3.0 (Hardened, Structured, Enterprise-Grade)
# ==============================================================================
# תפקיד: סריקה תקופתית (לרוב דרך Cron/Systemd Timer) וניקוי חוקים זמניים
#        שתוקפם פג (Expired TTL), תוך שימוש במכונת מצבים מבוססת AWK.
# ==============================================================================

# הקשחת ריצה: עצירה מיידית בכל שגיאה (e), משתנה לא מוגדר (u), או כשל ב-Pipe (o)
set -euo pipefail

# קביעת נתיבי עבודה יחסיים למיקום הסקריפט
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# ─── טעינת ספריות עזר (Modular Architecture) ──────────────────────────────────
for lib in config-reader.sh logger.sh lock.sh backup.sh time-guards.sh \
           validators.sh rules-validator.sh telemetry.sh policy-sync.sh; do
    source "${LIB_DIR}/${lib}" 2>/dev/null || {
        echo "FATAL: Cannot load library: ${LIB_DIR}/${lib}" >&2
        exit 1
    }
done

# ─── קריאת קונפיגורציה (Configuration Layer) ──────────────────────────────────
CONFIG_FILE="/etc/usbguard/approval-manager.conf"
RULES_TEMPORARY=$(get_conf "RULES_TEMPORARY" "${CONFIG_FILE}") || RULES_TEMPORARY="/etc/usbguard/rules.d/90-temporary.rules"
BACKUP_DIR=$(get_conf "BACKUP_DIR" "${CONFIG_FILE}")             || BACKUP_DIR="/etc/usbguard/backups"
LOG_FILE=$(get_conf "LOG_FILE" "${CONFIG_FILE}")                 || LOG_FILE="/var/log/usbguard-approval.log"
LOCK_FILE=$(get_conf "LOCK_FILE" "${CONFIG_FILE}")               || LOCK_FILE="/var/lib/usbguard-manager/usbguard-manager.lock"
STATE_DIR=$(get_conf "STATE_DIR" "${CONFIG_FILE}")               || STATE_DIR="/var/lib/usbguard-manager"
STATE_FILE="${STATE_DIR}/last_run_epoch"
MAX_CLOCK_JUMP=$(get_conf_int "MAX_CLOCK_JUMP_SECONDS" 3600 "${CONFIG_FILE}")
BACKUP_KEEP=$(get_conf_int "BACKUP_KEEP" 5 "${CONFIG_FILE}")
RULES_DIR="$(dirname "$RULES_TEMPORARY")"

# ─── ניהול וניקוי קבצים זמניים (Safe Temp Files Cleanup) ─────────────────────
TMP_FILE=""
AWK_STDERR=""

_cleanup_temp() {
    [[ -n "${TMP_FILE:-}" && -f "$TMP_FILE" ]] && rm -f "$TMP_FILE" 2>/dev/null || true
    [[ -n "${AWK_STDERR:-}" && -f "$AWK_STDERR" ]] && rm -f "$AWK_STDERR" 2>/dev/null || true
}
trap '_cleanup_temp' EXIT

# ═══════════════════════════════════════════════════════════════
# מכונת מצבים AWK לפילטור חוקי פקועי תוקף
# ═══════════════════════════════════════════════════════════════
_awk_ttl_filter() {
    local now="$1"
    local temp_rules_file="$2"
    awk -v now="$now" '
    BEGIN { state = 0; buffer = ""; expired_count = 0; }
    {
        if (state == 0) {
            if ($0 ~ /^[[:space:]]*(allow|block|reject)/) { buffer = $0; state = 1 } else { print $0 }
        } else if (state == 1) {
            if ($0 ~ /^[[:space:]]*# ttl_epoch:[[:space:]]*[0-9]+/) {
                buffer = buffer ORS $0
                comment_line = $0
                gsub(/^[[:space:]]*# ttl_epoch:[[:space:]]*/, "", comment_line)
                gsub(/[[:space:]]*$/, "", comment_line)
                epoch = int(comment_line)
                if (epoch <= now) { expired_count++ } else { print buffer }
                state = 0; buffer = ""
            } else if ($0 ~ /^[[:space:]]*(allow|block|reject)/) {
                expired_count++
                print "WARN: Discarded orphaned rule: " buffer > "/dev/stderr"
                buffer = $0; state = 1
            } else if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) {
                buffer = buffer ORS $0
            } else {
                expired_count++
                print "WARN: Discarded orphaned rule (unexpected): " buffer > "/dev/stderr"
                buffer = ""; print $0; state = 0
            }
        }
    }
    END {
        if (state == 1 && length(buffer) > 0) {
            expired_count++
            print "WARN: Discarded trailing orphaned rule: " buffer > "/dev/stderr"
        }
        print "EXPIRED_COUNT=" expired_count > "/dev/stderr"
    }' "$temp_rules_file"
}

# ==============================================================================
# פונקציה ראשית: main
# ==============================================================================
main() {
    local start_time end_time duration
    start_time=$(date +%s 2>/dev/null || echo 0)
    local expired_count=0

    # אתחול לוגר ואירועי טלמטריה
    init_logger "$LOG_FILE"
    emit_audit_event "cleanup" "session_start" "started"

    log_info "CLEANUP" "USBGuard TTL Reaper started"

    # ─── שלב 1: אימותי זמנים ושעון מערכת (Time Guards) ────────────────────────
    log_info "CLEANUP" "Stage 1/5: Time guards"
    local now
    now=$(get_epoch_now) || { log_error "CLEANUP" "Cannot get current time"; exit 1; }
    if ! check_clock_reasonable; then
        log_error "CLEANUP" "Clock check failed - aborting"; exit 1
    fi
    if ! detect_clock_jump_backward "$MAX_CLOCK_JUMP" "$STATE_FILE"; then
        log_warn "CLEANUP" "Clock jump detected - skipping cleanup"
        log_session_summary "CLEANUP" "Skipped (clock jump)" 0 0; exit 0
    fi

    # ─── שלב 2: השגת נעילה אקסקלוסיבית (Acquire Lock) ─────────────────────────
    log_info "CLEANUP" "Stage 2/5: Acquiring lock"
    if ! acquire_lock "$LOCK_FILE" "nowait"; then
        log_warn "CLEANUP" "Lock held by another process - skipping"
        log_session_summary "CLEANUP" "Skipped (locked)" 0 0; exit 0
    fi

    # ─── שלב 3: וידוא קיום קובץ חוקים זמניים (Check Temporary Rules) ──────────
    log_info "CLEANUP" "Stage 3/5: Checking temporary rules"
    if [[ ! -f "$RULES_TEMPORARY" ]]; then
        log_info "CLEANUP" "Temporary rules file does not exist: $RULES_TEMPORARY"
        release_lock; exit 0
    fi

    # ─── שלב 4: יצירת גיבוי מונע (Create Backup) ──────────────────────────────
    log_info "CLEANUP" "Stage 4/5: Creating backup before cleanup"
    local backup_file
    backup_file=$(create_backup "$BACKUP_DIR" "$RULES_DIR" "$BACKUP_KEEP") || {
        log_warn "CLEANUP" "Backup creation failed, continuing without rollback capability"
    }

    # ─── שלב 5: פילטור חוקים פקועים באמצעות AWK (Process Phase) ───────────────
    log_info "CLEANUP" "Stage 5/5: Processing expired rules"
    TMP_FILE=$(mktemp -t usbguard_cleanup_XXXXXX 2>/dev/null)
    AWK_STDERR=$(mktemp -t usbguard_awk_stderr_XXXXXX 2>/dev/null)
    
    _awk_ttl_filter "$now" "$RULES_TEMPORARY" > "$TMP_FILE" 2> "$AWK_STDERR" || true

    # בדיקה האם אכן בוצעו שינויים בפועל
    if ! cmp -s "$RULES_TEMPORARY" "$TMP_FILE"; then
        # החלפה אטומית של קובץ המדיניות
        mv "$TMP_FILE" "$RULES_TEMPORARY"
        chmod 600 "$RULES_TEMPORARY"
        chown root:root "$RULES_TEMPORARY"
        TMP_FILE="" # מניעת מחיקת הקובץ החדש על ידי ה-trap

        # אימות סינטקסט מקיף לחוקים החדשים טרם הטענה
        if ! validate_rules_dir "$RULES_DIR"; then
            log_error "CLEANUP" "Rules validation failed after cleanup; rolling back"
            if [[ -n "${backup_file:-}" && -f "${backup_file:-}" ]]; then
                restore_latest_backup "$BACKUP_DIR" "$RULES_DIR" || true
            fi
            release_lock; exit 1
        fi

        # רענון הדימון באמצעות שכבת הסנכרון האטומית
        if policy_sync_reload_daemon "$RULES_DIR" "/etc/usbguard/rules.conf"; then
            log_info "CLEANUP" "Rules reloaded successfully via policy-sync"
        else
            log_error "CLEANUP" "Failed to reload usbguard rules; rolling back"
            if [[ -n "${backup_file:-}" && -f "${backup_file:-}" ]]; then
                restore_latest_backup "$BACKUP_DIR" "$RULES_DIR" || true
                policy_sync_reload_daemon "$RULES_DIR" "/etc/usbguard/rules.conf" || true
            fi
            release_lock; exit 1
        fi
    else
        log_info "CLEANUP" "No expired rules found"
        # הקובץ הזמני יימחק אוטומטית ע"י ה-trap בסיום הריצה
    fi

    # חילוץ כמות החוקים שפגו מתוך ערוץ ה-stderr של AWK (פתרון תואם POSIX ללא תלות ב-PCRE)
    if [[ -f "$AWK_STDERR" ]]; then
        local extracted
        extracted=$(sed -n 's/.*EXPIRED_COUNT=\([0-9]*\).*/\1/p' "$AWK_STDERR" 2>/dev/null || echo "0")
        if [[ -n "$extracted" && "$extracted" =~ ^[0-9]+$ ]]; then
            expired_count="$extracted"
        fi
    fi
    rm -f "$AWK_STDERR" 2>/dev/null || true
    AWK_STDERR=""

    # עדכון חותמת זמן ריצה אחרונה
    local last_run_epoch
    last_run_epoch=$(get_epoch_now) || last_run_epoch=""
    if [[ -n "$last_run_epoch" ]]; then
        write_last_run_epoch "$last_run_epoch" "$STATE_FILE" 2>/dev/null || true
    fi

    # שחרור נעילות וסיכום מטריקות
    release_lock
    end_time=$(date +%s 2>/dev/null || echo 0)
    duration=$((end_time - start_time))
    
    log_audit "CLEANUP" "Cleaned ${expired_count} expired temporary rule(s)"
    log_session_summary "CLEANUP" "Cleaned ${expired_count} rules" 0 "$duration"
    emit_operation_result "cleanup" "remove_expired_rules" "success" "$duration" "expired_count=$expired_count"
    exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi