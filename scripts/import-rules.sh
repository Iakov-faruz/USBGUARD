#!/usr/bin/env bash
# ==============================================================================
# USBGuard Approval Manager - Import Rules (With Deduplication)
# Version: 3.0 (Hardened, Telemetry-Enabled, Production-Grade)
# ==============================================================================
# ייבוא חוקים מקובץ JSON תוך בדיקת כפילויות, מניעת הזרקת קוד זדוני,
# רישום אירועי אבטחה (Audit) וסנכרון אטומי מול ה-Daemon.
# ==============================================================================

set -euo pipefail

# ─── Load Libraries & Validators ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# טעינת כל ספריות החובה באופן מאובטח (מחליף את הבדיקות הפרטניות הישנות)
for lib in config-reader.sh logger.sh lock.sh backup.sh validators.sh telemetry.sh; do
    if [[ -f "${LIB_DIR}/${lib}" ]]; then
        source "${LIB_DIR}/${lib}"
    else
        echo -e "\033[0;31mFATAL: Cannot load library: ${LIB_DIR}/${lib}\033[0m" >&2
        exit 1
    fi
done

# ─── Configuration & Defaults ──────────────────────────────────────────────────
CONFIG_FILE="/etc/usbguard/approval-manager.conf"
INPUT_FILE=""
DRY_RUN=false
FORCE=false

# קבועי צבעים ותצוגה
readonly COLOR_RESET='\033[0m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_BOLD='\033[1m'

# קריאת נתיבי חוקים מהקונפיגורציה (באמצעות config-reader.sh ללא grep מקומי)
RULES_SYSTEM=$(get_conf "RULES_SYSTEM" "$CONFIG_FILE" 2>/dev/null)    || RULES_SYSTEM="/etc/usbguard/rules.d/00-system.rules"
RULES_PERMANENT=$(get_conf "RULES_PERMANENT" "$CONFIG_FILE" 2>/dev/null) || RULES_PERMANENT="/etc/usbguard/rules.d/50-permanent.rules"
RULES_TEMPORARY=$(get_conf "RULES_TEMPORARY" "$CONFIG_FILE" 2>/dev/null) || RULES_TEMPORARY="/etc/usbguard/rules.d/90-temporary.rules"

# ─── Argument Parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --file|-f) INPUT_FILE="$2"; shift 2 ;;
        --dry-run|-n) DRY_RUN=true; shift ;;
        --force) FORCE=true; shift ;;
        --help|-h)
            echo "Usage: sudo $0 --file <json_file> [OPTIONS]"
            echo "Options:"
            echo "  --dry-run   Show what would be imported without changes"
            echo "  --force     Skip confirmation prompt"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

[[ -z "$INPUT_FILE" ]] && { echo -e "${COLOR_RED}ERROR: --file is required${COLOR_RESET}"; exit 1; }
[[ ! -f "$INPUT_FILE" ]] && { echo -e "${COLOR_RED}ERROR: File not found: $INPUT_FILE${COLOR_RESET}"; exit 1; }

# ─── Core Functions ───────────────────────────────────────────────────────────

# וידוא מבנה ה-JSON באמצעות Python לפני תחילת עבודה
validate_json() {
    if ! python3 -c "import sys, json; data=json.load(open(sys.argv[1])); assert 'rules' in data" "$INPUT_FILE" 2>/dev/null; then
        return 1
    fi
    return 0
}

# עיבוד וייבוא קטגוריה ספציפית מתוך ה-JSON
import_category() {
    local category="$1"
    local target_file="$2"
    local imported_count=0
    local skipped_count=0

    echo -e "${COLOR_CYAN}Processing category: ${category}...${COLOR_RESET}"

    # יצירת קובץ זמני מאובטח לחוקים המפולטרים
    local tmp_rules
    tmp_rules=$(mktemp -t usbguard_import_XXXXXX 2>/dev/null) || return 1

    # חילוץ חוקים אמין באמצעות Python ומניעת הזרקות קוד
    if ! python3 - "$INPUT_FILE" "$category" > "$tmp_rules" <<'PYEOF'
import sys, json
try:
    data = json.load(open(sys.argv[1]))
    rules = data.get("rules", {}).get(sys.argv[2], [])
    for rule in rules:
        if isinstance(rule, str) and rule.strip():
            print(rule.strip())
except Exception as e:
    print(f"Error parsing JSON: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
    then
        echo -e "${COLOR_RED}  Failed to extract rules for ${category}${COLOR_RESET}"
        rm -f "$tmp_rules" 2>/dev/null
        return 1
    fi

    # מעבר על כל חוק שחולץ לבדיקת כפילויות ואינטגרציה
    local rule
    while IFS= read -r rule; do
        # ניקוי רווחים מתקדמים בתחילת ובסוף שורה באמצעות Bash Parameter Expansion
        local clean_rule="${rule#"${rule%%[![:space:]]*}"}"
        clean_rule="${clean_rule%"${clean_rule##*[![:space:]]}"}"
        
        [[ -z "$clean_rule" ]] && continue

        # בדיקת כפילויות מול קבצי המקור הקיימים במערכת
        if check_rule_duplicate "$clean_rule" "$(dirname "$target_file")"; then
            echo -e "  ${COLOR_YELLOW}↳ Skipping duplicate: ${clean_rule}${COLOR_RESET}"
            skipped_count=$((skipped_count + 1)) # תיקון אריתמטי מאובטח ללא סב-של
        else
            if [[ "$DRY_RUN" == "true" ]]; then
                echo -e "  ${COLOR_CYAN}↳ [DRY RUN] Would import: ${clean_rule}${COLOR_RESET}"
            else
                printf '%s\n' "$clean_rule" >> "$target_file"
                echo -e "  ${COLOR_GREEN}↳ Imported: ${clean_rule}${COLOR_RESET}"
            fi
            imported_count=$((imported_count + 1))
        fi
    done < "$tmp_rules"

    rm -f "$tmp_rules" 2>/dev/null

    # הקשחת הרשאות לקובץ היעד רק במידה ונוספו חוקים חדשים בפועל
    if [[ "$DRY_RUN" != "true" ]] && [[ $imported_count -gt 0 ]]; then
        chmod 600 "$target_file" 2>/dev/null || true
        chown root:root "$target_file" 2>/dev/null || true
    fi

    echo -e "${COLOR_GREEN}  Summary: ${imported_count} imported, ${skipped_count} skipped.${COLOR_RESET}\n"
    return 0
}

# ─── MAIN ─────────────────────────────────────────────────────────────────────
main() {
    local start_time end_time duration
    start_time=$(date +%s 2>/dev/null || echo 0)

    # 1. בדיקת הרשאות Root (חובה לשינוי חוקי מערכת)
    if [[ $EUID -ne 0 ]]; then
        echo -e "${COLOR_RED}ERROR: Must run as root (use sudo)${COLOR_RESET}" >&2
        exit 1
    fi

    # 2. אתחול הלוגר ורישום אירוע ה-Audit הראשון בטלמטריה
    init_logger "$(get_conf "LOG_FILE" "$CONFIG_FILE" 2>/dev/null || echo "/var/log/usbguard-approval.log")"
    emit_audit_event "import" "session_start" "started" "input_file=$INPUT_FILE"

    echo -e "${COLOR_BOLD}USBGuard Rules Import Tool v3.0${COLOR_RESET}"
    echo -e "${COLOR_CYAN}Source: ${INPUT_FILE}${COLOR_RESET}\n"

    # 3. אימות מבנה קובץ ה-JSON
    echo "Validating JSON structure..."
    if ! validate_json; then
        echo -e "${COLOR_RED}ERROR: Invalid JSON or missing 'rules' key${COLOR_RESET}" >&2
        emit_operation_result "import" "import_rules" "failure" 0 "reason=invalid_json"
        exit 1
    fi
    echo -e "${COLOR_GREEN}✓ JSON is valid${COLOR_RESET}\n"

    # 4. בקשת אישור מהמשתמש (במידה ולא הועבר דגל --force או --dry-run)
    if [[ "$DRY_RUN" != "true" && "$FORCE" != "true" ]]; then
        echo -e "${COLOR_YELLOW}WARNING: This will add rules to the system.${COLOR_RESET}"
        echo -e "Do you want to continue? (yes/no):"
        read -r confirm
        if [[ "$confirm" != "yes" ]]; then
            echo -e "${COLOR_CYAN}Import cancelled.${COLOR_RESET}"
            emit_audit_event "import" "session_cancel" "cancelled" "input_file=$INPUT_FILE"
            exit 0
        fi
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${COLOR_YELLOW}--- DRY RUN MODE ---${COLOR_RESET}"
    fi

    # 5. ביצוע גיבוי חוקים נוכחיים באופן אוטומטי (לפני דריסה)
    if [[ "$DRY_RUN" != "true" ]]; then
        local backup_dir="/etc/usbguard/backups"
        mkdir -p "$backup_dir" 2>/dev/null || true
        local backup_file="${backup_dir}/pre-import-$(date +%s).tar.gz"
        echo -e "${COLOR_CYAN}Creating backup of current rules...${COLOR_RESET}"
        if tar -czf "$backup_file" /etc/usbguard/rules.d/ 2>/dev/null; then
            echo -e "${COLOR_GREEN}✓ Backup saved to: $(basename "$backup_file")${COLOR_RESET}\n"
        else
            echo -e "${COLOR_YELLOW}⚠ Warning: Could not create backup${COLOR_RESET}\n"
        fi
    fi

    # 6. הרצת ייבוא מופרד לקטגוריות השונות
    import_category "system" "$RULES_SYSTEM"
    import_category "permanent" "$RULES_PERMANENT"
    import_category "temporary" "$RULES_TEMPORARY"

    # 7. קומפילציה, סינכרון וריענון אקטיבי של ה-Daemon
    if [[ "$DRY_RUN" != "true" ]]; then
        echo -e "\n${COLOR_GREEN}${COLOR_BOLD}Import completed successfully!${COLOR_RESET}"
        echo -e "${COLOR_CYAN}Syncing policy and reloading USBGuard daemon...${COLOR_RESET}"
        
        # שימוש במודול ה-policy-sync לרענון מדורג ובדיקת סטטוס אקטיבי
        if policy_sync_reload_daemon "$(dirname "$RULES_SYSTEM")" "/etc/usbguard/rules.conf"; then
            echo -e "${COLOR_GREEN}✓ Daemon reloaded successfully${COLOR_RESET}"
        else
            echo -e "${COLOR_RED}ERROR: Failed to reload daemon${COLOR_RESET}" >&2
            end_time=$(date +%s 2>/dev/null || echo 0)
            duration=$((end_time - start_time))
            emit_operation_result "import" "import_rules" "failure" "$duration" "reason=daemon_reload_failed"
            exit 1
        fi
    else
        echo -e "\n${COLOR_YELLOW}Dry run finished. No changes were made.${COLOR_RESET}"
    fi

    # 8. חיתום ושידור מדדי טלמטריה וסיכום סשן
    end_time=$(date +%s 2>/dev/null || echo 0)
    duration=$((end_time - start_time))
    
    emit_operation_result "import" "import_rules" "success" "$duration" "input_file=$INPUT_FILE"
    log_session_summary "IMPORT" "Import completed" 0 "$duration"
}

main "$@"