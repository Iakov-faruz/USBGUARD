#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# USBGuard Approval Manager - Restore Rules
# Version: 2.2 (Fixed for USBGuard 1.1.2)
# ═══════════════════════════════════════════════════════════════
# סקריפט לשחזור קבצי rules.d/ מגיבוי
# כולל גיבוי אוטומטי לפני שחזור, בדיקת תחביר (מושבתת), 
# וטעינה מחדש של הדמון באמצעות SIGHUP (pkill -HUP)
# ═══════════════════════════════════════════════════════════════

# ─── שלב 1: טעינת ספריות בסיס ──────────────────────────────────
# טוען את כל ספריות העזר הנדרשות: קריאת קונפיג, לוגים, נעילה, גיבויים, ולידציה
# ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

for lib in config-reader.sh logger.sh lock.sh backup.sh validators.sh; do
    source "${LIB_DIR}/${lib}" 2>/dev/null || {
        echo "FATAL: Cannot load library: ${LIB_DIR}/${lib}" >&2
        exit 1
    }
done

# ─── שלב 2: קריאת תצורה מקובץ ההגדרות ──────────────────────────
# טוען נתיבים: BACKUP_DIR, RULES_DIR, LOG_FILE, LOCK_FILE
CONFIG_FILE="/etc/usbguard/approval-manager.conf"
BACKUP_DIR=$(get_conf "BACKUP_DIR" "${CONFIG_FILE}") || BACKUP_DIR="/etc/usbguard/backups"
RULES_DIR=$(dirname "$(get_conf "RULES_SYSTEM" "${CONFIG_FILE}" 2>/dev/null)" 2>/dev/null)
if [[ -z "$RULES_DIR" ]]; then
    RULES_DIR="/etc/usbguard/rules.d"
fi
LOG_FILE=$(get_conf "LOG_FILE" "${CONFIG_FILE}") || LOG_FILE="/var/log/usbguard-approval.log"
LOCK_FILE=$(get_conf "LOCK_FILE" "${CONFIG_FILE}") || LOCK_FILE="/var/lock/usbguard-manager.lock"
RELOAD_TIMEOUT=$(get_conf_int "RELOAD_TIMEOUT" 5 "${CONFIG_FILE}")

# ═══════════════════════════════════════════════════════════════
# MAIN – תהליך השחזור הראשי
# ═══════════════════════════════════════════════════════════════
main() {
    local start_time end_time duration
    start_time=$(date +%s 2>/dev/null || echo 0)
    local exit_code=0
    local backup_file

    # ── שלב 3: אתחול מערכת הלוגים ────────────────────────────────
    init_logger "$LOG_FILE" 2>/dev/null
    log_info "RESTORE" "Manual restore initiated"

    # ── שלב 4: בדיקות מקדימות (Pre-flight) ──────────────────────
    # 4.1: הרצה כ-root (הכרחי לשינוי קבצי מערכת)
    if ! check_root; then
        log_error "RESTORE" "Not running as root"
        exit 1
    fi

    # 4.2: בדיקה שתיקיית הגיבויים קיימת
    if [[ ! -d "$BACKUP_DIR" ]]; then
        log_error "RESTORE" "Backup directory not found: $BACKUP_DIR"
        echo "ERROR: Backup directory not found: $BACKUP_DIR" >&2
        exit 1
    fi

    # ── שלב 5: הצגת רשימת גיבויים זמינים לבחירה ─────────────────
    echo "Available backups in: $BACKUP_DIR"
    echo "──────────────────────────────────────────"

    local backup_list=()
    local index=0

    # סריקת כל קבצי הגיבוי בפורמט rules_*.tar.gz (ממוינים מהחדש לישן)
    while IFS= read -r backup_file_path; do
        local size
        size=$(du -h "$backup_file_path" 2>/dev/null | cut -f1)
        echo "$index) $(basename "$backup_file_path") (${size})"
        backup_list+=("$backup_file_path")
        ((index++))
    done < <(ls -1t "${BACKUP_DIR}/rules_"*.tar.gz 2>/dev/null)

    # אם אין גיבויים – יציאה עם שגיאה
    if [[ ${#backup_list[@]} -eq 0 ]]; then
        echo "No backups found in: $BACKUP_DIR"
        log_error "RESTORE" "No backups found"
        exit 1
    fi

    # ── שלב 6: בחירת גיבוי לשחזור (אינטראקטיבי או אוטומטי) ──────
    local selected_index=0
    local max_index=$(( ${#backup_list[@]} - 1 ))

    if [[ -t 0 ]]; then
        # מצב אינטראקטיבי – המשתמש בוחר מספר
        echo ""
        echo "Enter the number of the backup to restore (0-${max_index}):"
        read -r user_input
        if [[ "$user_input" =~ ^[0-9]+$ ]] && [[ $user_input -ge 0 ]] && [[ $user_input -le $max_index ]]; then
            selected_index=$user_input
        else
            echo "Invalid selection. Exiting."
            exit 1
        fi
    else
        # מצב לא אינטראקטיבי – שימוש בגיבוי האחרון (אינדקס 0)
        selected_index=0
        echo "Non-interactive mode: using latest backup"
    fi

    backup_file="${backup_list[$selected_index]}"
    echo "Selected: $(basename "$backup_file")"

    # ── שלב 7: אישור המשתמש (במצב אינטראקטיבי בלבד) ──────────────
    if [[ -t 0 ]]; then
        echo ""
        echo "WARNING: This will OVERWRITE all current rules in: $RULES_DIR"
        echo "A backup of the CURRENT state will be created automatically."
        echo ""
        echo "Are you sure you want to proceed? (yes/no):"
        read -r confirm
        if [[ "$confirm" != "yes" ]]; then
            echo "Restore cancelled."
            log_info "RESTORE" "Restore cancelled by user"
            exit 0
        fi
    fi

    # ── שלב 8: נעילת המערכת (מניעת התנגשויות עם תהליכים אחרים) ──
    # ממתין עד 30 שניות לקבלת הנעילה
    if ! acquire_lock "$LOCK_FILE" "wait" 30; then
        log_error "RESTORE" "Cannot acquire lock after 30s timeout"
        echo "ERROR: Could not acquire lock. Another process is running." >&2
        exit 1
    fi

    # ── שלב 9: גיבוי אוטומטי של המצב הנוכחי (לפני השחזור) ────────
    # מאפשר חזרה למצב הקודם אם משהו משתבש
    log_info "RESTORE" "Creating backup of current state before restore"
    local pre_restore_backup
    pre_restore_backup=$(create_backup "$BACKUP_DIR" "$RULES_DIR" 0) || {
        log_warn "RESTORE" "Pre-restore backup failed - continuing"
    }

    # ── שלב 10: שחזור מהגיבוי הנבחר ─────────────────────────────
    log_info "RESTORE" "Restoring from: $(basename "$backup_file")"

    # יצירת תיקייה זמנית לחילוץ הגיבוי
    local temp_restore_dir
    temp_restore_dir=$(mktemp -d -t usbguard_restore_XXXXXX 2>/dev/null) || {
        log_error "RESTORE" "Cannot create temp directory"
        release_lock
        exit 1
    }

    # חילוץ קובץ ה‑tar.gz לתיקייה הזמנית
    if ! tar -xzf "$backup_file" -C "$temp_restore_dir" 2>/dev/null; then
        log_error "RESTORE" "Failed to extract backup: $backup_file"
        rm -rf "$temp_restore_dir" 2>/dev/null
        release_lock
        exit 1
    fi

    # איתור תיקיית rules.d בתוך החילוץ (השם תואם לשם המקורי)
    local extracted_rules="${temp_restore_dir}/$(basename "$RULES_DIR")"
    if [[ ! -d "$extracted_rules" ]]; then
        log_error "RESTORE" "Extracted rules directory not found"
        rm -rf "$temp_restore_dir" 2>/dev/null
        release_lock
        exit 1
    fi

    # העתקת קבצי החוקים מהגיבוי לתיקיית היעד (מחליף את הקיימים)
    if ! cp -f "${extracted_rules}"/*.rules "$RULES_DIR/" 2>/dev/null; then
        log_error "RESTORE" "Failed to copy rules files from backup"
        rm -rf "$temp_restore_dir" 2>/dev/null
        release_lock
        exit 1
    fi

    rm -rf "$temp_restore_dir" 2>/dev/null

    # ── שלב 11: וידוא שהרשאות הקבצים תקינות ────────────────────
    # USBGuard דורש הרשאות 600 על כל קובץ חוקים
    chmod 600 "${RULES_DIR}"/*.rules 2>/dev/null || true

    # ── שלב 12: טעינה מחדש של הדמון (באמצעות SIGHUP) ────────────
    # הערה: usbguard reload-rules לא קיים בגרסה 1.1.2
    # לכן אנו שולחים אות HUP לתהליך הדמון כדי שיטען מחדש את החוקים
    log_info "RESTORE" "Reloading usbguard daemon via SIGHUP"

    pkill -HUP usbguard-daemon 2>/dev/null || true
    sleep 1

    # בדיקה שהדמון עדיין חי (אות HUP לא הורג את התהליך)
    if ! pgrep usbguard-daemon >/dev/null; then
        log_error "RESTORE" "Reload failed - rolling back"

        # ── ROLLBACK: שחזור למצב הקודם במקרה של כשל ──────────────
        if [[ -n "$pre_restore_backup" ]] && [[ -f "$pre_restore_backup" ]]; then
            log_info "RESTORE" "Rolling back to pre-restore backup"
            restore_latest_backup "$BACKUP_DIR" "$RULES_DIR" || {
                log_critical "RESTORE" "Rollback also failed"
                release_lock
                exit 2
            }

            # ניסיון נוסף לטעון מחדש (גם אחרי rollback)
            pkill -HUP usbguard-daemon 2>/dev/null || true
            sleep 1

            if ! pgrep usbguard-daemon >/dev/null; then
                log_critical "RESTORE" "Rollback reload failed"
                release_lock
                exit 2
            fi
        fi

        release_lock
        exit 1
    fi

    # ── שלב 13: שחרור הנעילה ורישום אירוע ביקורת ─────────────────
    release_lock

    end_time=$(date +%s 2>/dev/null || echo 0)
    duration=$((end_time - start_time))

    log_audit "RESTORE" "Restored from backup: $(basename "$backup_file")"
    log_session_summary "RESTORE" "Restored from: $(basename "$backup_file")" 0 "$duration"

    echo ""
    echo "✅ Restore completed successfully from: $(basename "$backup_file")"
    echo "   A backup of the previous state was saved (if successful)."
    exit 0
}

# ─── הפעלת הפונקציה הראשית ──────────────────────────────────────
main "$@"