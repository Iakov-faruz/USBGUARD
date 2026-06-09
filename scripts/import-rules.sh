#!/usr/bin/env bash
# ==============================================================================
# USBGuard Approval Manager - Import Rules (With Deduplication)
# Version: 2.3
# ==============================================================================
# ייבוא חוקים מקובץ JSON תוך בדיקת כפילויות ומניעת הזרקת קוד זדוני.
# משתמש ב-validators.sh לבדיקת כפילויות וב-Python לפענוח JSON בטוח.
# ==============================================================================

set -euo pipefail

# ─── Load Libraries & Validators ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# טעינת validators.sh חיונית לפונקציית check_rule_duplicate
if [[ -f "${LIB_DIR}/validators.sh" ]]; then
    source "${LIB_DIR}/validators.sh"
else
    echo -e "\033[0;31mFATAL: validators.sh not found in ${LIB_DIR}\033[0m" >&2
    exit 1
fi

# ─── Configuration ────────────────────────────────────────────────────────────
CONFIG_FILE="/etc/usbguard/approval-manager.conf"
INPUT_FILE=""
DRY_RUN=false
FORCE=false

# ─── Colors ───────────────────────────────────────────────────────────────────
readonly COLOR_RESET='\033[0m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_BOLD='\033[1m'

# ─── Helpers ──────────────────────────────────────────────────────────────────
get_conf() { 
    grep -oP "^${1}=\K.*" "$2" 2>/dev/null || echo "" 
}

# קריאת נתיבי חוקים מהקונפיגורציה
RULES_SYSTEM=$(get_conf "RULES_SYSTEM" "$CONFIG_FILE")      || RULES_SYSTEM="/etc/usbguard/rules.d/00-system.rules"
RULES_PERMANENT=$(get_conf "RULES_PERMANENT" "$CONFIG_FILE") || RULES_PERMANENT="/etc/usbguard/rules.d/50-permanent.rules"
RULES_TEMPORARY=$(get_conf "RULES_TEMPORARY" "${CONFIG_FILE}") || RULES_TEMPORARY="/etc/usbguard/rules.d/90-temporary.rules"

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

validate_json() {
    if ! python3 -c "import sys, json; data=json.load(open(sys.argv[1])); assert 'rules' in data" "$INPUT_FILE" 2>/dev/null; then
        return 1
    fi
    return 0
}

import_category() {
    local category="$1"
    local target_file="$2"
    local imported_count=0
    local skipped_count=0

    echo -e "${COLOR_CYAN}Processing category: ${category}...${COLOR_RESET}"

    # יצירת קובץ זמני לחוקים שחולצו
    local tmp_rules
    tmp_rules=$(mktemp)
    
    # חילוץ חוקים באמצעות Python (אמין יותר מ-sed/grep ל-JSON)
    python3 - <<PYEOF "$INPUT_FILE" "$category" > "$tmp_rules"
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

    if [[ $? -ne 0 ]]; then
        echo -e "${COLOR_RED}  Failed to extract rules for ${category}${COLOR_RESET}"
        rm -f "$tmp_rules"
        return 1
    fi

    # מעבר על כל חוק ובדיקת כפילות
    while IFS= read -r rule; do
        local clean_rule
        clean_rule=$(echo "$rule" | xargs) # ניקוי רווחים מיותרים
        
        [[ -z "$clean_rule" ]] && continue

        # שימוש בפונקציה מ-validateors.sh לבדיקת כפילות
        if check_rule_duplicate "$clean_rule" "$(dirname "$target_file")"; then
            echo -e "  ${COLOR_YELLOW}↳ Skipping duplicate: ${clean_rule}${COLOR_RESET}"
            ((skipped_count++))
        else
            if [[ "$DRY_RUN" == "true" ]]; then
                echo -e "  ${COLOR_CYAN}↳ [DRY RUN] Would import: ${clean_rule}${COLOR_RESET}"
            else
                echo "$clean_rule" >> "$target_file"
                echo -e "  ${COLOR_GREEN}↳ Imported: ${clean_rule}${COLOR_RESET}"
            fi
            ((imported_count++))
        fi
    done < "$tmp_rules"

    rm -f "$tmp_rules"

    # עדכון הרשאות רק אם לא Dry Run
    if [[ "$DRY_RUN" != "true" ]] && [[ $imported_count -gt 0 ]]; then
        chmod 600 "$target_file" 2>/dev/null
        chown root:root "$target_file" 2>/dev/null
    fi

    echo -e "${COLOR_GREEN}  Summary: ${imported_count} imported, ${skipped_count} skipped.${COLOR_RESET}\n"
    return 0
}

# ─── MAIN ─────────────────────────────────────────────────────────────────────
main() {
    # בדיקת הרשאות Root
    if [[ $EUID -ne 0 ]]; then
        echo -e "${COLOR_RED}ERROR: Must run as root (use sudo)${COLOR_RESET}" >&2
        exit 1
    fi

    echo -e "${COLOR_BOLD}USBGuard Rules Import Tool v2.3${COLOR_RESET}"
    echo -e "${COLOR_CYAN}Source: ${INPUT_FILE}${COLOR_RESET}\n"

    # אימות JSON
    echo "Validating JSON structure..."
    if ! validate_json; then
        echo -e "${COLOR_RED}ERROR: Invalid JSON or missing 'rules' key${COLOR_RESET}" >&2
        exit 1
    fi
    echo -e "${COLOR_GREEN}✓ JSON is valid${COLOR_RESET}\n"

    # מצב Dry Run
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${COLOR_YELLOW}--- DRY RUN MODE ---${COLOR_RESET}"
    fi

    # גיבוי לפני ייבוא (אוטומטי)
    if [[ "$DRY_RUN" != "true" ]]; then
        local backup_dir="/etc/usbguard/backups"
        mkdir -p "$backup_dir"
        local backup_file="${backup_dir}/pre-import-$(date +%s).tar.gz"
        echo -e "${COLOR_CYAN}Creating backup of current rules...${COLOR_RESET}"
        if tar -czf "$backup_file" /etc/usbguard/rules.d/ 2>/dev/null; then
            echo -e "${COLOR_GREEN}✓ Backup saved to: $(basename "$backup_file")${COLOR_RESET}\n"
        else
            echo -e "${COLOR_YELLOW}⚠ Warning: Could not create backup${COLOR_RESET}\n"
        fi
    fi

    # ייבוא קטגוריות
    import_category "system" "$RULES_SYSTEM"
    import_category "permanent" "$RULES_PERMANENT"
    import_category "temporary" "$RULES_TEMPORARY"

    # סיום
    if [[ "$DRY_RUN" != "true" ]]; then
        echo -e "\n${COLOR_GREEN}${COLOR_BOLD}Import completed successfully!${COLOR_RESET}"
        echo -e "${COLOR_CYAN}Reloading USBGuard daemon...${COLOR_RESET}"
        
        # ניסיון Reload via systemctl, fallback ל-pkill
        if systemctl reload usbguard 2>/dev/null; then
            echo -e "${COLOR_GREEN}✓ Daemon reloaded via systemctl${COLOR_RESET}"
        elif pkill -HUP usbguard-daemon 2>/dev/null; then
            echo -e "${COLOR_GREEN}✓ Daemon reloaded via SIGHUP${COLOR_RESET}"
        else
            echo -e "${COLOR_YELLOW}⚠ Could not reload daemon automatically. Please restart manually.${COLOR_RESET}"
        fi
    else
        echo -e "\n${COLOR_YELLOW}Dry run finished. No changes were made.${COLOR_RESET}"
    fi
}

main "$@"