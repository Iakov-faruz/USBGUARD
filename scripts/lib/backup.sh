#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# USBGuard Approval Manager - Backup Manager
# Version: 2.2
# ═══════════════════════════════════════════════════════════════
# ניהול גיבויים אטומיים + רוטציה
# ═══════════════════════════════════════════════════════════════

# ─── Default Configuration ────────────────────────────────────
readonly BACKUP_DEFAULT_DIR="/etc/usbguard/backups"
readonly BACKUP_DEFAULT_RULES_DIR="/etc/usbguard/rules.d"
readonly BACKUP_DEFAULT_KEEP=5

# ═══════════════════════════════════════════════════════════════
# פונקציה: create_backup
# תפקיד: יצירת גיבוי tar.gz של rules.d/ עם timestamp
# שימוש: backup_file=$(create_backup)
# ═══════════════════════════════════════════════════════════════
create_backup() {
    local backup_dir="${1:-$BACKUP_DEFAULT_DIR}"
    local rules_dir="${2:-$BACKUP_DEFAULT_RULES_DIR}"
    local keep="${3:-$BACKUP_DEFAULT_KEEP}"
    local timestamp
    local backup_file
    local temp_file

    # ── Ensure backup directory exists ─────────────────────────
    if [[ ! -d "$backup_dir" ]]; then
        mkdir -p "$backup_dir" 2>/dev/null || {
            log_error "BACKUP" "Cannot create backup directory: $backup_dir"
            return 1
        }
    fi

    # ── Generate timestamped filename ──────────────────────────
    timestamp=$(date '+%Y%m%d_%H%M%S' 2>/dev/null || echo '00000000_000000')
    backup_file="${backup_dir}/rules_${timestamp}.tar.gz"

    # ── Create temp backup first (atomic via mv) ──────────────
    temp_file=$(mktemp -t usbguard_backup_XXXXXX.tar.gz 2>/dev/null) || {
        log_error "BACKUP" "Cannot create temp file for backup"
        return 1
    }

    if ! tar -czf "$temp_file" -C "$(dirname "$rules_dir")" "$(basename "$rules_dir")" 2>/dev/null; then
        log_error "BACKUP" "Failed to create backup archive"
        rm -f "$temp_file" 2>/dev/null
        return 1
    fi

    # ── Atomic move to final location ─────────────────────────
    if ! mv "$temp_file" "$backup_file" 2>/dev/null; then
        log_error "BACKUP" "Failed to move backup to: $backup_file"
        rm -f "$temp_file" 2>/dev/null
        return 1
    fi

    # ── Set secure permissions ────────────────────────────────
    chmod 600 "$backup_file" 2>/dev/null

    log_info "BACKUP" "Backup created: $(basename "$backup_file")"
    echo "$backup_file"
    return 0
}

# ═══════════════════════════════════════════════════════════════
# פונקציה: rotate_backups
# תפקיד: רוטציה - השארת KEEP האחרונים, מחיקת הישנים
# שימוש: rotate_backups ["/path/to/backups"] [keep]
# ═══════════════════════════════════════════════════════════════
rotate_backups() {
    local backup_dir="${1:-$BACKUP_DEFAULT_DIR}"
    local keep="${2:-$BACKUP_DEFAULT_KEEP}"
    local count

    if [[ ! -d "$backup_dir" ]]; then
        log_debug "BACKUP" "Backup directory does not exist, no rotation needed"
        return 0
    fi

    # Count existing backups
    count=$(ls -1 "${backup_dir}/rules_"*.tar.gz 2>/dev/null | wc -l)

    if [[ $count -le $keep ]]; then
        log_debug "BACKUP" "No rotation needed (${count} <= ${keep})"
        return 0
    fi

    # Remove oldest backups beyond keep limit (safe for paths with spaces)
    local to_delete=$((count - keep))
    while IFS= read -r old_backup; do
        [[ -z "$old_backup" ]] && continue
        rm -f "$old_backup" 2>/dev/null && \
            log_info "BACKUP" "Rotated out old backup: $(basename "$old_backup")"
    done < <(ls -1t "${backup_dir}/rules_"*.tar.gz 2>/dev/null | tail -n "$to_delete")

    return 0
}

# ═══════════════════════════════════════════════════════════════
# פונקציה: restore_latest_backup
# תפקיד: שחזור מהגיבוי האחרון
# שימוש: restore_latest_backup || rollback_failed
# ═══════════════════════════════════════════════════════════════
restore_latest_backup() {
    local backup_dir="${1:-$BACKUP_DEFAULT_DIR}"
    local rules_dir="${2:-$BACKUP_DEFAULT_RULES_DIR}"
    local temp_restore_dir
    local latest_backup

    if [[ ! -d "$backup_dir" ]]; then
        log_error "BACKUP" "Cannot restore: backup directory missing: $backup_dir"
        return 1
    fi

    # Find latest backup
    latest_backup=$(ls -1t "${backup_dir}/rules_"*.tar.gz 2>/dev/null | head -1)

    if [[ -z "$latest_backup" ]]; then
        log_error "BACKUP" "Cannot restore: no backups found in: $backup_dir"
        return 1
    fi

    # ── Create temp directory for extraction ──────────────────
    temp_restore_dir=$(mktemp -d -t usbguard_restore_XXXXXX 2>/dev/null) || {
        log_error "BACKUP" "Cannot create temp directory for restore"
        return 1
    }

    # ── Extract backup ────────────────────────────────────────
    if ! tar -xzf "$latest_backup" -C "$temp_restore_dir" 2>/dev/null; then
        log_error "BACKUP" "Failed to extract backup: $latest_backup"
        rm -rf "$temp_restore_dir" 2>/dev/null
        return 1
    fi

    # ── Copy files from temp to rules directory ───────────────
    local extracted_rules="${temp_restore_dir}/$(basename "$rules_dir")"
    if [[ ! -d "$extracted_rules" ]]; then
        log_error "BACKUP" "Extracted rules directory not found: $extracted_rules"
        rm -rf "$temp_restore_dir" 2>/dev/null
        return 1
    fi

    if ! cp -f "${extracted_rules}"/*.rules "$rules_dir/" 2>/dev/null; then
        log_error "BACKUP" "Failed to copy rules files from backup"
        rm -rf "$temp_restore_dir" 2>/dev/null
        return 1
    fi

    # ── Cleanup ───────────────────────────────────────────────
    rm -rf "$temp_restore_dir" 2>/dev/null

    log_audit "RESTORE" "Restored from backup: $(basename "$latest_backup")"
    log_info "BACKUP" "Successfully restored from: $(basename "$latest_backup")"
    echo "$latest_backup"
    return 0
}

# ═══════════════════════════════════════════════════════════════
# פונקציה: list_backups
# תפקיד: הצגת כל הגיבויים הקיימים
# שימוש: list_backups ["/path/to/backups"]
# ═══════════════════════════════════════════════════════════════
list_backups() {
    local backup_dir="${1:-$BACKUP_DEFAULT_DIR}"

    if [[ ! -d "$backup_dir" ]]; then
        echo "No backups directory: $backup_dir"
        return 1
    fi

    local backups
    backups=$(ls -1t "${backup_dir}/rules_"*.tar.gz 2>/dev/null)

    if [[ -z "$backups" ]]; then
        echo "No backups found in: $backup_dir"
        return 1
    fi

    echo "$backups" | while read -r backup_file; do
        local size
        size=$(du -h "$backup_file" 2>/dev/null | cut -f1)
        echo "$(basename "$backup_file") (${size})"
    done

    return 0
}

# ═══════════════════════════════════════════════════════════════
# פונקציה: create_and_rotate
# תפקיד: יצירת גיבוי + רוטציה בפעולה אחת
# שימוש: create_and_rotate ["/backup/dir"] ["/rules/dir"] [keep]
# ═══════════════════════════════════════════════════════════════
create_and_rotate() {
    local backup_dir="${1:-$BACKUP_DEFAULT_DIR}"
    local rules_dir="${2:-$BACKUP_DEFAULT_RULES_DIR}"
    local keep="${3:-$BACKUP_DEFAULT_KEEP}"
    local backup_file

    backup_file=$(create_backup "$backup_dir" "$rules_dir" "$keep") || return 1
    rotate_backups "$backup_dir" "$keep" || true
    echo "$backup_file"
    return 0
}