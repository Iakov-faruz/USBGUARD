#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════
# USBGuard Approval Manager – Audit Logger
# Version: 3.2.1 (Zero‑Subprocess, Structured, Production‑Grade)
# ════════════════════════════════════════════════════════════════════════
#
# תכונות ליבה:
#   • Zero‑Subprocess (ללא tr/awk/sed/grep) - ביצועים מקסימליים.
#   • Early-Exit חכם - מניעת הרצת פקודות מערכת (whoami) כשהלוגר כבוי.
#   • תאימות אבטחה מורחבת ל-Syslog (כולל Priority מותאם ו-Component בטאג).
#   • ניהול הרשאות קשיח (chmod 660, root:usbadmins).
#   • פורמט מובנה: [TIMESTAMP] [LEVEL] [USER] [COMPONENT] MESSAGE
#
# דרישות מערכת:
#   • Bash גרסה 4.2 ומעלה (עבור מנגנון ה-Timestamp המובנה ב-printf).
#     בגרסאות ישנות יותר, המערכת תבצע Fallback אוטומטי לפקודת date.
#
# ════════════════════════════════════════════════════════════════════════

readonly LOGGER_DEFAULT_LOG="/var/log/usbguard-approval.log"
LOGGER_INITIALIZED=0
LOGGER_ACTIVE_LOG="$LOGGER_DEFAULT_LOG"

# ─── רמות לוג מספריות (להשוואה מהירה בזיכרון) ──────────────────────────
readonly LOG_LEVEL_DEBUG=0
readonly LOG_LEVEL_INFO=1
readonly LOG_LEVEL_WARN=2
readonly LOG_LEVEL_ERROR=3
readonly LOG_LEVEL_CRITICAL=4

# ───────────────────────────────────────────────────────────────────────
# פונקציה: _get_log_level_num
# תפקיד: המרת שם רמה מטקסט (מהקונפיג) למספר (ללא Subprocess)
# ───────────────────────────────────────────────────────────────────────
_get_log_level_num() {
    case "${1,,}" in
        debug)    echo "$LOG_LEVEL_DEBUG" ;;
        info)     echo "$LOG_LEVEL_INFO" ;;
        warn)     echo "$LOG_LEVEL_WARN" ;;
        error)    echo "$LOG_LEVEL_ERROR" ;;
        critical) echo "$LOG_LEVEL_CRITICAL" ;;
        *)        echo "$LOG_LEVEL_INFO" ;; # ברירת מחדל במקרה של ערך שגוי
    esac
}

# ───────────────────────────────────────────────────────────────────────
# פונקציה: _level_num_to_name
# תפקיד: המרת מספר רמה חזרה לשם טקסטואלי עבור פורמט הלוג
# ───────────────────────────────────────────────────────────────────────
_level_num_to_name() {
    case "$1" in
        0) echo "DEBUG" ;;
        1) echo "INFO" ;;
        2) echo "WARN" ;;
        3) echo "ERROR" ;;
        4) echo "CRITICAL" ;;
        *) echo "UNKNOWN" ;;
    esac
}

# ───────────────────────────────────────────────────────────────────────
# פונקציה: _log
# תפקיד: פונקציית הליבה המרכזית לכתיבת לוגים ואירועי ביקורת
# ───────────────────────────────────────────────────────────────────────
_log() {
    # 1. Early-Exit מיידי: מונע תקורה והרצת Subprocesses כשהלוגר אינו פעיל
    [[ "$LOGGER_INITIALIZED" -eq 1 ]] || return 0

    local level="$1"
    local component="$2"
    local message="$3"
    local log_file="${4:-$LOGGER_ACTIVE_LOG}"
    local user="${5:-$(whoami 2>/dev/null || echo 'unknown')}"

    # 2. שליפת רמת הלוג המבוקשת מהקונפיגורציה (אם פונקציית get_conf קיימת)
    local config_level_name="INFO"
    if declare -F get_conf >/dev/null 2>&1; then
        config_level_name=$(get_conf "LOG_LEVEL" 2>/dev/null || echo "INFO")
    fi

    local config_level_num
    config_level_num=$(_get_log_level_num "$config_level_name")

    # 3. סינון הודעות מתחת לרף המוגדר בקונפיג
    [[ "$level" -lt "$config_level_num" ]] && return 0

    # 4. הפקת Timestamp מהיר ללא תהליך חיצוני (נתמך ב-Bash 4.2+)
    local timestamp
    if ! printf -v timestamp '%(%Y-%m-%d %H:%M:%S)T' -1 2>/dev/null; then
        timestamp=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "0000-00-00 00:00:00")
    fi

    local level_name
    level_name=$(_level_num_to_name "$level")
    
    local log_line="[${timestamp}] [${level_name}] [${user}] [${component}] ${message}"

    # 5. כתיבה לקובץ עם Fallback מועשר ל-Syslog במקרה של כשל בהרשאות לקובץ
    if ! echo "$log_line" >> "$log_file" 2>/dev/null; then
        local sys_prio="${level_name,,}"
        # התאמת רמת critical לסטנדרט ה-Facility הרשמי של Syslog (crit)
        [[ "$sys_prio" == "critical" ]] && sys_prio="crit"

        logger -t "usbguard-approval[${component}]" -p "user.${sys_prio}" "$message" 2>/dev/null || true
    fi

    # 6. פלט ל-Console (שגיאות ומעלה ל-stderr, מידע רגיל ל-stdout רק אם ה-Terminal מחובר)
    if [[ "$level" -ge "$LOG_LEVEL_ERROR" ]]; then
        echo "$log_line" >&2
    elif [[ -t 1 ]]; then
        echo "$log_line"
    fi
}

# ─── עטיפות נוחות (Public API) ─────────────────────────────────────────
log_debug()    { _log "$LOG_LEVEL_DEBUG" "$@"; }
log_info()     { _log "$LOG_LEVEL_INFO" "$@"; }
log_warn()     { _log "$LOG_LEVEL_WARN" "$@"; }
log_error()    { _log "$LOG_LEVEL_ERROR" "$@"; }
log_critical() { _log "$LOG_LEVEL_CRITICAL" "$@"; }

log_audit() {
    local component="$1"
    shift || true
    if declare -F emit_audit_event >/dev/null 2>&1; then
        emit_audit_event "$component" "log" "info" "$*"
        return $?
    fi
    printf '[AUDIT] [%s] %s\n' "$component" "$*" >> "$LOGGER_ACTIVE_LOG" 2>/dev/null || true
}

log_session_summary() {
    local component="$1"
    local message="$2"
    local exit_code="${3:-0}"
    local duration_sec="${4:-0}"
    log_info "$component" "SESSION_SUMMARY message=${message} exit_code=${exit_code} duration_sec=${duration_sec}"
}

# ───────────────────────────────────────────────────────────────────────
# פונקציה: init_logger
# תפקיד: אתחול מערכת הלוג, יצירת מבנה התיקיות והקשחת הרשאות
# ───────────────────────────────────────────────────────────────────────
init_logger() {
    local log_file="${1:-$LOGGER_DEFAULT_LOG}"
    LOGGER_ACTIVE_LOG="$log_file"

    local log_dir
    log_dir=$(dirname "$log_file")

    # יצירת התיקייה והקובץ במידה ואינם קיימים
    mkdir -p "$log_dir" 2>/dev/null || true
    [[ -f "$log_file" ]] || touch "$log_file" 2>/dev/null || true

    # הקשחת אבטחה: בעלות ל-root, הרשאות קריאה/כתיבה לקבוצת המנהלים המורשית בלבד
    chown root:usbadmins "$log_file" 2>/dev/null || true
    chmod 660 "$log_file" 2>/dev/null || true

    LOGGER_INITIALIZED=1
}