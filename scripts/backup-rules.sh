#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# USBGuard Approval Manager - Backup Rules
# Version: 2.2
# ═══════════════════════════════════════════════════════════════
# סקריפט לגיבוי יזום של קבצי rules.d/
# ═══════════════════════════════════════════════════════════════

# ─── Source libraries ─────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

for lib in config-reader.sh logger.sh lock.sh backup.sh validators.sh; do
    # shellcheck source=./lib/logger.sh
    source "${LIB_DIR}/${lib}" 2>/dev/null || {
        echo "FATAL: Cannot load library: ${LIB_DIR}/${lib}" >&2
        exit 1
    }
done

# ─── Configuration ────────────────────────────────────────────
CONFIG_FILE="/etc/usbguard/approval-manager.conf"
BACKUP_DIR=$(get_conf "BACKUP_DIR" "${CONFIG_FILE}") || BACKUP_DIR="/etc/usbguard/backups"
RULES_DIR=$(get_conf "RULES_SYSTEM" "${CONFIG_FILE}") && RULES_DIR="$(dirname "$RULES_DIR")"
if [[ -z "$RULES_DIR" ]]; then
    RULES_DIR="/etc/usbguard/rules.d"
fi
LOG_FILE=$(get_conf "LOG_FILE" "${CONFIG_FILE}") || LOG_FILE="/var/log/usbguard-approval.log"
LOCK_FILE=$(get_conf "LOCK_FILE" "${CONFIG_FILE}") || LOCK_FILE="/var/lock/usbguard-manager.lock"
BACKUP_KEEP=$(get_conf_int "BACKUP_KEEP" 5 "${CONFIG_FILE}")

# ═══════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════
main() {
    local start_time end_time duration
    start_time=$(date +%s 2>/dev/null || echo 0)
    local exit_code=0
    local backup_file

    # ── Initialize logger ──────────────────────────────────────
    init_logger "$LOG_FILE" 2>/dev/null
    log_info "BACKUP" "Manual backup initiated"

    # ── STAGE 1: Pre-flight checks ──────────────────────────────
    if ! check_root; then
        log_error "BACKUP" "Not running as root"
        exit 1
    fi

    if ! check_rules_files_exist "$RULES_DIR"; then
        log_warn "BACKUP" "Some rules files missing - continuing anyway"
    fi

    # ── STAGE 2: Acquire lock (non-blocking) ────────────────────
    if ! acquire_lock "$LOCK_FILE" "nowait"; then
        log_error "BACKUP" "Cannot acquire lock - another process is running"
        echo "ERROR: Another USBGuard management process is running. Try again later." >&2
        exit 1
    fi

    # ── STAGE 3: Create backup ──────────────────────────────────
    log_info "BACKUP" "Creating backup of: $RULES_DIR"

    backup_file=$(create_backup "$BACKUP_DIR" "$RULES_DIR" "$BACKUP_KEEP") || {
        log_error "BACKUP" "Backup creation failed"
        echo "ERROR: Backup creation failed." >&2
        release_lock
        exit 1
    }

    # ── STAGE 4: Rotation ───────────────────────────────────────
    rotate_backups "$BACKUP_DIR" "$BACKUP_KEEP"

    # ── Done ────────────────────────────────────────────────────
    release_lock

    end_time=$(date +%s 2>/dev/null || echo 0)
    duration=$((end_time - start_time))

    log_audit "BACKUP" "Manual backup created: $(basename "$backup_file")"
    log_session_summary "BACKUP" "Created: $(basename "$backup_file")" 0 "$duration"

    echo "Backup completed: $backup_file"
    exit 0
}

# ─── Run main ─────────────────────────────────────────────────
main "$@"