#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# USBGuard Approval Manager - Audit Logger
# Version: 2.2
# ═══════════════════════════════════════════════════════════════
# מערכת לוג מרכזית עם 5 רמות + audit trail
# פורמט: [YYYY-MM-DD HH:MM:SS] [LEVEL] [USER] [COMPONENT] MESSAGE
# ═══════════════════════════════════════════════════════════════

# ─── Default Configuration ────────────────────────────────────
readonly LOGGER_DEFAULT_LOG="/var/log/usbguard-approval.log"
readonly LOGGER_DEFAULT_LEVEL="INFO"

# ─── Log Levels (numeric) ─────────────────────────────────────
readonly LOG_LEVEL_DEBUG=0
readonly LOG_LEVEL_INFO=1
readonly LOG_LEVEL_WARN=2
readonly LOG_LEVEL_ERROR=3
readonly LOG_LEVEL_CRITICAL=4

# ─── Level Names ──────────────────────────────────────────────
_log_level_name() {
    local level="$1"
    case "$level" in
        "$LOG_LEVEL_DEBUG")    echo "DEBUG" ;;
        "$LOG_LEVEL_INFO")     echo "INFO" ;;
        "$LOG_LEVEL_WARN")     echo "WARN" ;;
        "$LOG_LEVEL_ERROR")    echo "ERROR" ;;
        "$LOG_LEVEL_CRITICAL") echo "CRITICAL" ;;
        *)                     echo "UNKNOWN" ;;
    esac
}

# ═══════════════════════════════════════════════════════════════
# פונקציה: _get_log_level_num
# תפקיד: המרת רמת לוג טקסטואלית למספר
# ═══════════════════════════════════════════════════════════════
_get_log_level_num() {
    local level_name
    level_name=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    case "$level_name" in
        debug)    echo "$LOG_LEVEL_DEBUG" ;;
        info)     echo "$LOG_LEVEL_INFO" ;;
        warn)     echo "$LOG_LEVEL_WARN" ;;
        error)    echo "$LOG_LEVEL_ERROR" ;;
        critical) echo "$LOG_LEVEL_CRITICAL" ;;
        *)        echo "$LOG_LEVEL_INFO" ;;
    esac
}

# ═══════════════════════════════════════════════════════════════
# פונקציה: _log
# תפקיד: פונקציית הליבה לכתיבת לוג
# ═══════════════════════════════════════════════════════════════
_log() {
    local level="$1"
    local component="$2"
    local message="$3"
    local log_file="${4:-$LOGGER_DEFAULT_LOG}"
    local user="${5:-$(whoami 2>/dev/null || echo 'unknown')}"

    # ── Skip DEBUG if LOG_LEVEL is higher ──────────────────────
    local config_level_name
    config_level_name=$(get_conf "LOG_LEVEL" 2>/dev/null || echo "$LOGGER_DEFAULT_LEVEL")
    local config_level_num
    config_level_num=$(_get_log_level_num "$config_level_name")
    local msg_level_num
    msg_level_num=$(_get_log_level_num "$(_log_level_name "$level")")

    if [[ $msg_level_num -lt $config_level_num ]]; then
        return 0
    fi

    # ── Format timestamp ───────────────────────────────────────
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "0000-00-00 00:00:00")

    local level_name
    level_name=$(_log_level_name "$level")

    local log_line
    log_line="[${timestamp}] [${level_name}] [${user}] [${component}] ${message}"

    # ── Write to log file ──────────────────────────────────────
    # Append with fallback to syslog if file is not writable
    if echo "$log_line" >> "$log_file" 2>/dev/null; then
        :
    else
        # Fallback to syslog
        logger -t "usbguard-approval[${component}]" -p "user.${level_name,,}" "$message" 2>/dev/null || true
    fi

    # ── Also output to stderr for ERROR and above ─────────────
    if [[ $level -ge $LOG_LEVEL_ERROR ]]; then
        echo "$log_line" >&2
    fi
}

# ═══════════════════════════════════════════════════════════════
# פונקציות ציבוריות
# ═══════════════════════════════════════════════════════════════

log_debug() {
    _log "$LOG_LEVEL_DEBUG" "$@"
}

log_info() {
    _log "$LOG_LEVEL_INFO" "$@"
}

log_warn() {
    _log "$LOG_LEVEL_WARN" "$@"
}

log_error() {
    _log "$LOG_LEVEL_ERROR" "$@"
}

log_critical() {
    _log "$LOG_LEVEL_CRITICAL" "$@"
}

# ═══════════════════════════════════════════════════════════════
# פונקציה: log_audit
# תפקיד: תיעוד אירוע ביקורת (approval, cleanup, rollback)
# ═══════════════════════════════════════════════════════════════
log_audit() {
    local action="$1"        # APPROVE | CLEANUP | ROLLBACK | BACKUP | RESTORE | DENIED
    local details="$2"
    local log_file="${3:-$LOGGER_DEFAULT_LOG}"

    log_info "AUDIT" "[${action}] ${details}" "$log_file"
}

# ═══════════════════════════════════════════════════════════════
# פונקציה: log_session_summary
# תפקיד: תיעוד סיכום session בסיום הרצת הסקריפט
# ═══════════════════════════════════════════════════════════════
log_session_summary() {
    local action="$1"
    local summary="$2"
    local exit_code="${3:-0}"
    local duration_sec="$4"

    if [[ $exit_code -eq 0 ]]; then
        log_info "SESSION" "Completed ${action}: ${summary} (duration: ${duration_sec}s)"
    else
        log_error "SESSION" "Failed ${action}: ${summary} (duration: ${duration_sec}s, exit: ${exit_code})"
    fi
}

# ═══════════════════════════════════════════════════════════════
# פונקציה: init_logger
# תפקיד: אתחול מערכת הלוג (יצירת תיקיית לוג אם לא קיימת)
# ═══════════════════════════════════════════════════════════════
init_logger() {
    local log_file="${1:-$LOGGER_DEFAULT_LOG}"
    local log_dir

    log_dir=$(dirname "$log_file" 2>/dev/null)

    if [[ ! -d "$log_dir" ]]; then
        mkdir -p "$log_dir" 2>/dev/null || {
            echo "WARN: Could not create log directory: $log_dir" >&2
        }
    fi

    # Try to create file if not exists
    if [[ ! -f "$log_file" ]]; then
        touch "$log_file" 2>/dev/null || {
            echo "WARN: Could not create log file: $log_file" >&2
        }
    fi

    # Ensure correct ownership and permissions for multi-user logging
    # Both root (systemd timer) and usbadmins group (TUI via sudo) must write
    chown root:usbadmins "$log_file" 2>/dev/null || true
    chmod 660 "$log_file" 2>/dev/null || true

    log_info "LOGGER" "Logger initialized (log file: ${log_file})"
}