#!/usr/bin/env bash
# ==============================================================================
# USBGuard Approval Manager - Main TUI & CLI Entrance
# Version: 3.0 (Hardened, Structured, Enterprise-Grade)
# ==============================================================================
# תפקיד: נקודת הכניסה המרכזית (Main Entry Point) למערכת ניהול ההתקנים.
#        הסקריפט תומך הן בהפעלה אוטומטית מהירה מה-CLI (עבור חסימות ופקודות נפח)
#        והן בממשק משתמש טקסטואלי (TUI) אינטראקטיבי מבוסס שלבים (Stages).
# ==============================================================================

# הקשחת ריצה: עצירה מיידית בכל שגיאה (e), משתנה לא מוגדר (u), או כשל ב-Pipe (o)
set -euo pipefail

# קביעת נתיבי עבודה יחסיים למיקום הסקריפט
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# ─── טעינת ספריות עזר (Modular Architecture) ──────────────────────────────────
# כל ספרייה מטפלת באחריות נפרדת (Separation of Concerns)
for lib in config-reader.sh logger.sh lock.sh backup.sh time-guards.sh \
           validators.sh device-utils.sh retry.sh telemetry.sh \
           rules-validator.sh policy-sync.sh stages-core.sh stages-io.sh; do
    source "${LIB_DIR}/${lib}" 2>/dev/null || {
        echo "FATAL: Cannot load library: ${LIB_DIR}/${lib}" >&2
        exit 1
    }
done

# ─── קריאת קונפיגורציה (Configuration Layer) ──────────────────────────────────
CONFIG_FILE="/etc/usbguard/approval-manager.conf"

# שליפת נתיבים ופרמטרים מתוך קובץ ההגדרות עם Fallback ערכים קשיח וקנוני
RULES_SYSTEM=$(get_conf "RULES_SYSTEM" "${CONFIG_FILE}")         || RULES_SYSTEM="/etc/usbguard/rules.d/00-system.rules"
RULES_PERMANENT=$(get_conf "RULES_PERMANENT" "${CONFIG_FILE}")   || RULES_PERMANENT="/etc/usbguard/rules.d/50-permanent.rules"
RULES_TEMPORARY=$(get_conf "RULES_TEMPORARY" "${CONFIG_FILE}")   || RULES_TEMPORARY="/etc/usbguard/rules.d/90-temporary.rules"
BACKUP_DIR=$(get_conf "BACKUP_DIR" "${CONFIG_FILE}")             || BACKUP_DIR="/etc/usbguard/backups"
LOG_FILE=$(get_conf "LOG_FILE" "${CONFIG_FILE}")                 || LOG_FILE="/var/log/usbguard-approval.log"
LOCK_FILE=$(get_conf "LOCK_FILE" "${CONFIG_FILE}")               || LOCK_FILE="/var/lib/usbguard-manager/usbguard-manager.lock"

# הגדרות התנהגות ומדיניות (סוגי משתנים מותאמים: אינטג'ר ובוליאני)
BACKUP_KEEP=$(get_conf_int "BACKUP_KEEP" 5 "${CONFIG_FILE}")
TEMP_TTL_SECONDS=$(get_conf_int "TEMP_TTL_SECONDS" 3600 "${CONFIG_FILE}")
CHECK_DUPLICATES=$(get_conf_bool "CHECK_DUPLICATES" true "${CONFIG_FILE}")
NOTIFY_DESKTOP=$(get_conf_bool "NOTIFY_DESKTOP" true "${CONFIG_FILE}")
ALLOWED_USERS=$(get_conf "ALLOWED_USERS" "${CONFIG_FILE}")       || ALLOWED_USERS="root"
ALLOWED_GROUPS=$(get_conf "ALLOWED_GROUPS" "${CONFIG_FILE}")     || ALLOWED_GROUPS="wheel"

# גזירת תיקיית חוקי הליבה מנתיב קובץ החוקים הקיים
RULES_DIR="$(dirname "$RULES_PERMANENT")"

# ─── ניהול סטייט גלובלי (Global State Management) ────────────────────────────
BLOCKED_DEVICES=()       # מערך שורות גולמיות של התקנים חסומים מתוך ה-Daemon
SELECTED_DEVICES=()      # מזהי ההתקנים (IDs) שנבחרו לעיבוד בסבב הנוכחי
APPROVAL_TYPE=""         # סוג האישור שנבחר: קבוע (P) או זמני (T)
CREATED_RULES=()         # מערך החוקים החדשים שנבנו ומוכנים לכתיבה
BACKUP_FILE=""           # נתיב לקובץ הגיבוי שנוצר בטרם ביצוע שינויים בדיסק
SESSION_START_TIME=""    # חותמת זמן תחילת הסשן (לצורך מטריקות וטלמטריה)
SESSION_EXIT_CODE=0      # קוד היציאה הסופי של הריצה כולה
DRY_RUN_ACTIVE=false     # דגל סימולציה - מונע שינויים פיזיים במערכת

# ─── הגדרת צבעים לממשק המשתמש (ANSI Escapes עבור TUI) ──────────────────────────
readonly COLOR_RESET='\033[0m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_BOLD='\033[1m'

# ─── פונקציות עזר לאימות קלט (CLI Input Validation Helpers) ───────────────────
validate_device_id() {
    local value="$1"
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        echo -e "${COLOR_RED}ERROR: Invalid USBGuard device ID: $value${COLOR_RESET}" >&2
        return 1
    fi
}

validate_vidpid() {
    local value="$1"
    if [[ ! "$value" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]]; then
        echo -e "${COLOR_RED}ERROR: Invalid VID:PID format: $value${COLOR_RESET}" >&2
        return 1
    fi
}

validate_approval_type() {
    local value="$1"
    if [[ "$value" != "P" && "$value" != "T" ]]; then
        echo -e "${COLOR_RED}ERROR: Approval type must be P or T${COLOR_RESET}" >&2
        return 1
    fi
}

validate_ttl_seconds() {
    local value="$1"
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        echo -e "${COLOR_RED}ERROR: TTL must be a non-negative integer${COLOR_RESET}" >&2
        return 1
    fi
    if [[ "$value" -gt 315360000 ]]; then
        echo -e "${COLOR_RED}ERROR: TTL must not exceed 10 years${COLOR_RESET}" >&2
        return 1
    fi
}

# ==============================================================================
# פונקציה ראשית: main
# ==============================================================================
main() {
    # אתחול זמן התחלה ואיסוף טלמטריה ראשונית
    SESSION_START_TIME=$(date +%s 2>/dev/null || echo 0)
    local block_device_id=""
    local block_vid_pid=""

    # אתחול מיידי של מערכת הלוגים ואירועי הביקורת של הסשן
    init_logger "$LOG_FILE"
    emit_audit_event "approve" "session_start" "started" "dry_run=false"

    # ─── שלב א': ניתוח ארגומנטים (CLI Argument Parsing Loop) ───────────────────
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --list-rules)
                # שליפת החוקים הקיימים והחזרתם כפורמט JSON מובנה בצורה מאובטחת (Safe Environment)
                python3 - "$RULES_SYSTEM" "$RULES_PERMANENT" "$RULES_TEMPORARY" <<'PY'
import json, sys
from pathlib import Path
paths = {'system': Path(sys.argv[1]), 'permanent': Path(sys.argv[2]), 'temporary': Path(sys.argv[3])}
result = {}
for category, path in paths.items():
    lines = [line.strip() for line in path.read_text(errors='replace').splitlines() if line.strip() and not line.strip().startswith('#')]
    result[category] = lines
print(json.dumps(result, ensure_ascii=False, indent=2))
PY
                exit 0
                ;;
            --device|-d)
                IFS=',' read -r -a SELECTED_DEVICES <<< "$2"
                for selected_id in "${SELECTED_DEVICES[@]}"; do
                    validate_device_id "$selected_id" || exit 1
                done
                shift 2
                ;;
            --type|-t)
                APPROVAL_TYPE="$2"
                validate_approval_type "$APPROVAL_TYPE" || exit 1
                shift 2
                ;;
            --ttl)
                validate_ttl_seconds "$2" || exit 1
                TEMP_TTL_SECONDS="$2"
                shift 2
                ;;
            --dry-run|-n)
                DRY_RUN_ACTIVE=true; shift ;;
            --block)
                validate_device_id "$2" || exit 1
                block_device_id="$2"
                shift 2
                ;;
            --vidpid)
                validate_vidpid "$2" || exit 1
                block_vid_pid="${2,,}"
                shift 2
                ;;
            *) shift ;;
        esac
    done

    # ─── שלב ב': טיפול בפעולת חסימה יזומה (CLI Block Action Flow) ─────────────
    if [[ -n "${block_device_id:-}" || -n "${block_vid_pid:-}" ]]; then
        # וידוא הרשאות ריצה של משתמש על (Root)
        check_root || exit 1
        
        # אתחול לוגר ורישום בקשת החסימה מה-CLI
        init_logger "$LOG_FILE"
        log_info "APPROVE" "CLI Block request: Device ID=${block_device_id:-N/A}, VID:PID=${block_vid_pid:-N/A}"
        
        # השגת נעילה אקסקלוסיבית למניעת Race Conditions מול קריאות מקבילות
        acquire_lock "$LOCK_FILE" "wait" 10 || { log_error "APPROVE" "Lock failed"; exit 1; }
        
        # 1. חסימה ישירה ודינמית ברמת ה-IPC של הדימון (Runtime Block)
        if [[ -n "${block_device_id:-}" ]]; then
            if ! usbguard block-device "$block_device_id" 2>/dev/null; then
                log_error "APPROVE" "Failed to block device $block_device_id via IPC"
                release_lock
                exit 1
            fi
            log_info "APPROVE" "Blocked device $block_device_id via IPC"
        fi
        
        # 2. הסרת חוקים תואמים מקבצי המדיניות הפרססיסטנטיים (Permanent & Temporary)
        if [[ -n "${block_vid_pid:-}" ]]; then
            local tmp_rules
            for file in "$RULES_PERMANENT" "$RULES_TEMPORARY"; do
                [[ -f "$file" ]] || continue
                
                # יצירת קובץ זמני מאובטח לעיבוד השינויים
                tmp_rules=$(mktemp -t usbguard_rules_delete_XXXXXX 2>/dev/null) || {
                    log_error "APPROVE" "Cannot create temporary rules file"
                    release_lock
                    exit 1
                }
                
                # עיבוד מאובטח של הקובץ בלולאת awk המנקה את החוק וגם את ה-TTL המשויך אליו
                if ! awk -v vidpid="$block_vid_pid" '
                    BEGIN { skip_next = 0 }
                    { 
                        if (skip_next == 1) { 
                            skip_next = 0; 
                            if ($0 ~ /^[[:space:]]*# ttl_epoch:/) next 
                        }
                        if ($0 ~ "allow id " vidpid) { 
                            skip_next = 1; 
                            next 
                        } 
                        print $0 
                    }' "$file" > "$tmp_rules" 2>/dev/null; then
                    rm -f "$tmp_rules" 2>/dev/null
                    log_error "APPROVE" "Failed to update rules file: $file"
                    release_lock
                    exit 1
                fi
                
                # החלפה אטומית של קובץ המקור בקובץ המעודכן
                if ! mv "$tmp_rules" "$file" 2>/dev/null; then
                    rm -f "$tmp_rules" 2>/dev/null
                    log_error "APPROVE" "Failed to replace rules file: $file"
                    release_lock
                    exit 1
                fi
                
                # קביעת בעלות והרשאות קשיחות (הדימון רץ כ-root)
                chmod 600 "$file" 2>/dev/null
                chown root:root "$file" 2>/dev/null
            done
            log_info "APPROVE" "Deleted rules matching VID:PID $block_vid_pid"
        fi
        
        # 3. סינכרון המדיניות ורענון הדימון בצורה אטומית (תומך במבנה RuleFolder)
        if ! policy_sync_reload_daemon "$(dirname "$RULES_PERMANENT")" "/etc/usbguard/rules.conf"; then
            log_error "APPROVE" "Policy sync / reload failed after block"
        fi
        
        # שחרור נעילות, רישום אירוע אבטחה, דיווח טלמטריה ויציאה נקייה
        release_lock
        log_audit "BLOCK" "Blocked device ${block_vid_pid:-ID: $block_device_id}"
        emit_operation_result "approve" "block_device" "success" 0 "device_id=${block_device_id:-none}" "vidpid=${block_vid_pid:-none}"
        exit 0
    fi

    # ─── שלב ג': זרימת ממשק אינטראקטיבי (Normal TUI Approval Flow) ─────────────
    echo ""
    echo -e "${COLOR_BOLD}╔══════════════════════════════════════════════╗${COLOR_RESET}"
    echo -e "${COLOR_BOLD}║    USBGuard Approval Manager v3.0            ║${COLOR_RESET}"
    echo -e "${COLOR_BOLD}╚══════════════════════════════════════════════╝${COLOR_RESET}"
    echo ""
    log_info "APPROVE" "USBGuard Approval Manager started"
    [[ "$DRY_RUN_ACTIVE" == "true" ]] && echo -e "${COLOR_YELLOW}  DRY RUN MODE${COLOR_RESET}" && echo ""

    # שלבים 1-3: הכנת תשתית, השגת נעילה וגילוי חומרה
    echo ""; stage_preflight || { SESSION_EXIT_CODE=1; log_session_summary "APPROVE" "Pre-flight failed" "$SESSION_EXIT_CODE" 0; exit "$SESSION_EXIT_CODE"; }
    echo ""; stage_acquire_lock || { SESSION_EXIT_CODE=1; log_session_summary "APPROVE" "Lock failed" "$SESSION_EXIT_CODE" 0; exit "$SESSION_EXIT_CODE"; }
    echo ""; stage_discover_devices || { SESSION_EXIT_CODE=0; release_lock; log_session_summary "APPROVE" "No devices" "$SESSION_EXIT_CODE" 0; exit "$SESSION_EXIT_CODE"; }
    echo ""
    
    # שלב 4: בחירת התקנים (אינטראקטיבי או קביעה מראש מה-CLI)
    if [[ ${#SELECTED_DEVICES[@]} -eq 0 ]]; then
        stage_multiselect_tui || { SESSION_EXIT_CODE=0; release_lock; log_session_summary "APPROVE" "Cancelled" "$SESSION_EXIT_CODE" 0; exit "$SESSION_EXIT_CODE"; }
    else
        echo -e "${COLOR_GREEN}  ✓ Device list pre-selected via CLI${COLOR_RESET}"
    fi
    echo ""
    
    # שלב 5: בחירת סוג אישור (קבוע / זמני עם תוקף מוגדר)
    if [[ -z "$APPROVAL_TYPE" ]]; then
        stage_choose_type || { SESSION_EXIT_CODE=0; release_lock; log_session_summary "APPROVE" "Cancelled" "$SESSION_EXIT_CODE" 0; exit "$SESSION_EXIT_CODE"; }
    else
        echo -e "${COLOR_GREEN}  ✓ Approval type pre-selected: ${APPROVAL_TYPE}${COLOR_RESET}"
    fi

    # שלבים 6-7: ביצוע גיבוי מלא ויצירת מערך החוקים החדש בזיכרון
    echo ""; stage_backup || { SESSION_EXIT_CODE=1; log_error "APPROVE" "Backup failed"; release_lock; log_session_summary "APPROVE" "Backup failed" "$SESSION_EXIT_CODE" 0; exit "$SESSION_EXIT_CODE"; }
    echo ""; stage_build_rules || {
        # אם לא נוצרו חוקים חדשים, יוצאים בצורה נקייה ללא צורך בביצוע רולבק
        if [[ ${#CREATED_RULES[@]} -eq 0 ]]; then
            SESSION_EXIT_CODE=0; release_lock; log_session_summary "APPROVE" "No new rules" "$SESSION_EXIT_CODE" 0; exit "$SESSION_EXIT_CODE"
        fi
        # במקרה של כשל בבנייה, מפעילים מנגנון Rollback לשחזור המצב המקורי בדיסק
        SESSION_EXIT_CODE=1; rollback; release_lock; log_session_summary "APPROVE" "Build failed" "$SESSION_EXIT_CODE" 0; exit "$SESSION_EXIT_CODE"
    }

    # ─── שלב ד': טיפול במצב סימולציה (Dry-Run Shortcut) ────────────────────────
    if [[ "$DRY_RUN_ACTIVE" == "true" ]]; then
        echo ""
        echo -e "${COLOR_YELLOW}╔══════════════════════════════════════════════╗${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}║  DRY RUN - No changes were made              ║${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}╚══════════════════════════════════════════════╝${COLOR_RESET}"
        echo ""
        stage_audit_and_release "true"
        exit 0
    fi

    # ─── שלב ה': כתיבה, אימות, ורענון המערכת (Commit Phase) ────────────────────
    # הגנה קשיחה: כל כשל באחד משלבי הכתיבה או בדיקת התקינות גורר שחזור מלא (Rollback)
    echo ""; stage_write_rules || { SESSION_EXIT_CODE=1; rollback; release_lock; log_session_summary "APPROVE" "Write failed" "$SESSION_EXIT_CODE" 0; exit "$SESSION_EXIT_CODE"; }
    echo ""; stage_verify_syntax || { SESSION_EXIT_CODE=1; rollback; release_lock; log_session_summary "APPROVE" "Syntax failed" "$SESSION_EXIT_CODE" 0; exit "$SESSION_EXIT_CODE"; }
    echo ""; stage_reload_daemon || { SESSION_EXIT_CODE=1; rollback; release_lock; log_session_summary "APPROVE" "Reload failed" "$SESSION_EXIT_CODE" 0; exit "$SESSION_EXIT_CODE"; }
    
    # שלבים אופציונליים וסגירת סשן
    echo ""; stage_desktop_notification || true
    echo ""; stage_audit_and_release "true"

    # ─── שלב ו': סיכום ומטריקות ריצה (Session Summary Display) ─────────────────
    local end_time=$(date +%s 2>/dev/null || echo 0)
    local duration=$((end_time - SESSION_START_TIME))
    echo ""
    echo -e "${COLOR_GREEN}${COLOR_BOLD}✓ Approval completed successfully!${COLOR_RESET}"
    echo ""
    echo -e "  ${COLOR_CYAN}Summary:${COLOR_RESET}"
    echo -e "  • Devices approved: ${#CREATED_RULES[@]}"
    echo -e "  • Type: ${APPROVAL_TYPE} ($([[ "$APPROVAL_TYPE" == "P" ]] && echo "Permanent" || echo "Temporary ${TEMP_TTL_SECONDS}s TTL"))"
    echo -e "  • Duration: ${duration}s"
    echo ""
    
    # רישום האירוע הסופי ושיגור מטריקות הצלחה ללוגר ולמערכת הטלמטריה
    log_session_summary "APPROVE" "Approved ${#CREATED_RULES[@]} devices" 0 "$duration"
    emit_operation_result "approve" "approve_devices" "success" "$duration" "approval_type=$APPROVAL_TYPE" "device_count=${#CREATED_RULES[@]}"
    exit 0
}

# הפעלת פונקציית הליבה והעברת כל הארגומנטים החיצוניים שנתקבלו מהמשתמש
main "$@"