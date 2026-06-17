#!/usr/bin/env bash
# ==============================================================================
# USBGuard Approval Manager - Export Rules
# Version: 3.0 (Enterprise-Grade, Safe-Serialization)
# ==============================================================================
# ייצוא כל חוקי ה-USB לפורמט JSON או YAML מובנה ומאובטח.
# משתמש ב-Python לצורך Serialization אמין של המבנים ומניעת שבירת תווים.
# ==============================================================================

set -euo pipefail

# ─── Load Libraries & Configuration ───────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# טעינת ספריות חובה
for lib in config-reader.sh logger.sh telemetry.sh; do
    if [[ -f "${LIB_DIR}/${lib}" ]]; then
        source "${LIB_DIR}/${lib}"
    else
        echo -e "\033[0;31mFATAL: Cannot load library: ${LIB_DIR}/${lib}\033[0m" >&2
        exit 1
    fi
done

CONFIG_FILE="/etc/usbguard/approval-manager.conf"
OUTPUT_FORMAT="json"
OUTPUT_FILE=""

# קבועי צבעים ותצוגה (תיקון שגיאת תחביר ב-COLOR_GREEN)
readonly COLOR_RESET='\033[0m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'

# קריאת נתיבי חוקים מהקונפיגורציה (באמצעות config-reader.sh)
RULES_SYSTEM=$(get_conf "RULES_SYSTEM" "$CONFIG_FILE" 2>/dev/null)    || RULES_SYSTEM="/etc/usbguard/rules.d/00-system.rules"
RULES_PERMANENT=$(get_conf "RULES_PERMANENT" "$CONFIG_FILE" 2>/dev/null) || RULES_PERMANENT="/etc/usbguard/rules.d/50-permanent.rules"
RULES_TEMPORARY=$(get_conf "RULES_TEMPORARY" "$CONFIG_FILE" 2>/dev/null) || RULES_TEMPORARY="/etc/usbguard/rules.d/90-temporary.rules"

# ─── Argument Parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --format|-f) OUTPUT_FORMAT="${2,,}"; shift 2 ;; # המרה ל-lowercase ליתר ביטחון
        --output|-o) OUTPUT_FILE="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: sudo $0 [OPTIONS]"
            echo "Options:"
            echo "  --format, -f FORMAT   Output format: json (default) or yaml"
            echo "  --output, -o FILE     Write to file instead of stdout"
            exit 0
            ;;
        *) echo -e "${COLOR_YELLOW}Unknown option: $1${COLOR_RESET}" >&2; exit 1 ;;
    esac
done

# ─── Core Functions ───────────────────────────────────────────────────────────

# קריאת חוקים מקובץ והמרתם למערך JSON זמני בצורה בטוחה
read_rules_json() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo "[]"
        return
    fi
    
    python3 - "$file" <<'PY'
import json, sys
from pathlib import Path
try:
    path = Path(sys.argv[1])
    rules = []
    if path.exists():
        for line in path.read_text(errors='replace').splitlines():
            stripped = line.strip()
            if stripped and not stripped.startswith('#'):
                rules.append(stripped)
    print(json.dumps(rules, ensure_ascii=False))
except Exception as e:
    print("[]", file=sys.stderr)
    sys.exit(1)
PY
}

# ג'נרור האקספורט המלא בפורמט המבוקש
generate_export() {
    local system_rules permanent_rules temporary_rules
    system_rules=$(read_rules_json "$RULES_SYSTEM")
    permanent_rules=$(read_rules_json "$RULES_PERMANENT")
    temporary_rules=$(read_rules_json "$RULES_TEMPORARY")

    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        python3 - "$system_rules" "$permanent_rules" "$temporary_rules" <<'PY'
import json, socket, sys
from datetime import datetime, timezone
try:
    rules = {
        'system': json.loads(sys.argv[1]),
        'permanent': json.loads(sys.argv[2]),
        'temporary': json.loads(sys.argv[3]),
    }
    payload = {
        'export_version': '1.0',
        'export_date': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'hostname': socket.gethostname() or 'unknown',
        'rules': rules,
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2))
except Exception as e:
    print(f"ERROR: Failed to generate JSON export ({e})", file=sys.stderr)
    sys.exit(1)
PY
    elif [[ "$OUTPUT_FORMAT" == "yaml" ]]; then
        python3 - "$system_rules" "$permanent_rules" "$temporary_rules" <<'PY'
import json, socket, sys
from datetime import datetime, timezone

def yaml_scalar(value): 
    return json.dumps(value, ensure_ascii=False)

def print_list(name, items):
    print(f'{name}:')
    if not items:
        print('    []')
        return
    for item in items: 
        print(f'    - {yaml_scalar(item)}')

try:
    rules = {
        'system': json.loads(sys.argv[1]),
        'permanent': json.loads(sys.argv[2]),
        'temporary': json.loads(sys.argv[3]),
    }
    print('# USBGuard Rules Export')
    print(f'# Date: {datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}')
    print(f'# Host: {socket.gethostname() or "unknown"}')
    print('---')
    print('export_version: "1.0"')
    print('rules:')
    print_list('  system', rules['system'])
    print_list('  permanent', rules['permanent'])
    print_list('  temporary', rules['temporary'])
except Exception as e:
    print(f"ERROR: Failed to generate YAML export ({e})", file=sys.stderr)
    sys.exit(1)
PY
    else
        echo -e "${COLOR_RED}Unsupported output format: $OUTPUT_FORMAT${COLOR_RESET}" >&2
        exit 1
    fi
}

# ─── MAIN ─────────────────────────────────────────────────────────────────────
main() {
    # וידוא הרשאות ריצה כ-root
    if [[ $EUID -ne 0 ]]; then
        echo -e "${COLOR_RED}ERROR: Must run as root (use sudo)${COLOR_RESET}" >&2
        exit 1
    fi

    # אתחול לוגר וטלמטריה
    init_logger 2>/dev/null || true
    
    local start_time
    start_time=$(date +%s 2>/dev/null || echo 0)

    local output
    if ! output=$(generate_export); then
        log_error "EXPORT" "Export generation failed"
        emit_operation_result "export" "export_rules" "failure" 0 "reason=generation_failed"
        echo -e "${COLOR_RED}ERROR: Export generation failed.${COLOR_RESET}" >&2
        exit 1
    fi
    
    # כתיבה לקובץ או הדפסה ל-stdout
    if [[ -n "$OUTPUT_FILE" ]]; then
        # יצירת תיקיית יעד במידה ואינה קיימת
        mkdir -p "$(dirname "$OUTPUT_FILE")" 2>/dev/null || true
        printf '%s\n' "$output" > "$OUTPUT_FILE"
        chmod 600 "$OUTPUT_FILE" 2>/dev/null || true # הגנה על קובץ הייצוא (מכיל מזהי חומרה)
        
        local end_time
        end_time=$(date +%s 2>/dev/null || echo 0)
        local duration=$((end_time - start_time))
        
        log_audit "EXPORT" "Rules exported to: $OUTPUT_FILE"
        emit_operation_result "export" "export_rules" "success" "$duration" "output_file=$OUTPUT_FILE" "format=$OUTPUT_FORMAT"
        
        echo -e "${COLOR_GREEN}Export written to: $OUTPUT_FILE${COLOR_RESET}"
    else
        printf '%s\n' "$output"
        # גם אם מדפיסים ל-stdout, נרשום אירוע טלמטריה
        emit_operation_result "export" "export_rules_stdout" "success" 0 "format=$OUTPUT_FORMAT"
    fi
}

main "$@"