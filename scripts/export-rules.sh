#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# USBGuard Approval Manager - Export Rules
# Version: 1.0
# ═══════════════════════════════════════════════════════════════
# ייצוא כל חוקי ה-USB ל-JSON
# הרצה: sudo ./usbguard-export.sh [--format json|yaml] [--output FILE]
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

# ─── Default Configuration ───────────────────────────────────
CONFIG_FILE="/etc/usbguard/approval-manager.conf"
OUTPUT_FORMAT="json"
OUTPUT_FILE=""

# ─── Colors ──────────────────────────────────────────────────
readonly COLOR_RESET='\033[0m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_CYAN='\033[0;36m'

# ─── Helper: get config value ────────────────────────────────
get_conf() {
    local key="$1"
    local file="$2"
    grep -oP "^${key}=\K.*" "$file" 2>/dev/null || echo ""
}

# ─── Detect rules files ──────────────────────────────────────
RULES_SYSTEM=$(get_conf "RULES_SYSTEM" "$CONFIG_FILE")     || RULES_SYSTEM="/etc/usbguard/rules.d/00-system.rules"
RULES_PERMANENT=$(get_conf "RULES_PERMANENT" "$CONFIG_FILE") || RULES_PERMANENT="/etc/usbguard/rules.d/50-permanent.rules"
RULES_TEMPORARY=$(get_conf "RULES_TEMPORARY" "${CONFIG_FILE}") || RULES_TEMPORARY="/etc/usbguard/rules.d/90-temporary.rules"

# ─── Parse arguments ─────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --format|-f)
            OUTPUT_FORMAT="$2"
            shift 2
            ;;
        --output|-o)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: sudo $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --format, -f FORMAT   Output format: json (default) or yaml"
            echo "  --output, -o FILE     Write to file instead of stdout"
            echo "  --help, -h            Show this help"
            exit 0
            ;;
        *)
            echo -e "${COLOR_YELLOW}Unknown option: $1${COLOR_RESET}" >&2
            exit 1
            ;;
    esac
done

# ═══════════════════════════════════════════════════════════════
# Read rules from file (skip empty lines and comments)
# ═══════════════════════════════════════════════════════════════
read_rules() {
    local file="$1"
    local category="$2"
    local rules=()

    if [[ ! -f "$file" ]]; then
        echo "[]"
        return
    fi

    local current_line=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines
        if [[ -z "$(echo "$line" | xargs)" ]]; then
            continue
        fi
        # Accumulate multi-line rules (lines ending with backslash or starting with #)
        if [[ -z "$current_line" ]]; then
            if echo "$line" | grep -qP '^\s*#'; then
                # Comment line - could be metadata
                current_line="$line"
            else
                current_line="$line"
            fi
        else
            current_line="${current_line}\n${line}"
        fi
    done < "$file"

    # If we have a pending line, add it
    if [[ -n "$current_line" ]]; then
        rules+=("$current_line")
    fi

    # Output JSON array
    local first=true
    echo "["
    for rule in "${rules[@]}"; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            echo ","
        fi
        # Escape for JSON
        local escaped
        escaped=$(echo "$rule" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
        echo "    \"$escaped\""
    done
    echo ""
    echo "]"
}

# ═══════════════════════════════════════════════════════════════
# Generate export
# ═══════════════════════════════════════════════════════════════
generate_export() {
    local system_rules permanent_rules temporary_rules

    system_rules=$(read_rules "$RULES_SYSTEM" "system")
    permanent_rules=$(read_rules "$RULES_PERMANENT" "permanent")
    temporary_rules=$(read_rules "$RULES_TEMPORARY" "temporary")

    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        cat << EOF
{
  "export_version": "1.0",
  "export_date": "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')",
  "hostname": "$(hostname 2>/dev/null || echo 'unknown')",
  "rules": {
    "system": $system_rules,
    "permanent": $permanent_rules,
    "temporary": $temporary_rules
  }
}
EOF
    elif [[ "$OUTPUT_FORMAT" == "yaml" ]]; then
        cat << EOF
# USBGuard Rules Export
# Date: $(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')
# Host: $(hostname 2>/dev/null || echo 'unknown')
---
export_version: "1.0"
rules:
  system:
$(echo "$system_rules" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data:
    print(f'    - \"{item}\"')
" 2>/dev/null || echo "    []")
  permanent:
$(echo "$permanent_rules" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data:
    print(f'    - \"{item}\"')
" 2>/dev/null || echo "    []")
  temporary:
$(echo "$temporary_rules" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data:
    print(f'    - \"{item}\"')
" 2>/dev/null || echo "    []")
EOF
    fi
}

# ═══════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════
main() {
    # Root check
    if [[ $EUID -ne 0 ]]; then
        echo -e "${COLOR_RED}ERROR: Must run as root (use sudo)${COLOR_RESET}" >&2
        exit 1
    fi

    local output
    output=$(generate_export)

    if [[ -n "$OUTPUT_FILE" ]]; then
        echo "$output" > "$OUTPUT_FILE"
        echo -e "${COLOR_GREEN}Export written to: $OUTPUT_FILE${COLOR_RESET}"
    else
        echo "$output"
    fi
}

main "$@"