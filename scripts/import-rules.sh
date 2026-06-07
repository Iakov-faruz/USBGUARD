#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# USBGuard Approval Manager - Import Rules
# Version: 1.0
# ═══════════════════════════════════════════════════════════════
# ייבוא חוקי USB מקובץ JSON (מיוצא מ-usbguard-export.sh)
# הרצה: sudo ./usbguard-import.sh --file rules.json [--dry-run]
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

# ─── Default Configuration ───────────────────────────────────
CONFIG_FILE="/etc/usbguard/approval-manager.conf"
INPUT_FILE=""
DRY_RUN=false
FORCE=false

# ─── Colors ──────────────────────────────────────────────────
readonly COLOR_RESET='\033[0m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_BOLD='\033[1m'

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

# Validate required tools
for cmd in python3 usbguard; do
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${COLOR_RED}ERROR: Required command '$cmd' not found${COLOR_RESET}" >&2
        exit 1
    fi
done

# ─── Parse arguments ─────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --file|-f)
            INPUT_FILE="$2"
            shift 2
            ;;
        --dry-run|-n)
            DRY_RUN=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --help|-h)
            echo "Usage: sudo $0 --file FILE [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --file, -f FILE       Input JSON file (required)"
            echo "  --dry-run, -n         Show what would be imported without making changes"
            echo "  --force               Skip confirmation prompt"
            echo "  --help, -h            Show this help"
            echo ""
            echo "Example:"
            echo "  sudo ./usbguard-import.sh -f backup-rules.json"
            echo "  sudo ./usbguard-import.sh -f rules.json --dry-run"
            exit 0
            ;;
        *)
            echo -e "${COLOR_YELLOW}Unknown option: $1${COLOR_RESET}" >&2
            exit 1
            ;;
    esac
done

# ─── Validate input ──────────────────────────────────────────
if [[ -z "$INPUT_FILE" ]]; then
    echo -e "${COLOR_RED}ERROR: --file is required${COLOR_RESET}" >&2
    exit 1
fi

if [[ ! -f "$INPUT_FILE" ]]; then
    echo -e "${COLOR_RED}ERROR: File not found: $INPUT_FILE${COLOR_RESET}" >&2
    exit 1
fi

# ═══════════════════════════════════════════════════════════════
# Helper functions using temp python scripts
# ═══════════════════════════════════════════════════════════════

validate_json() {
    local tmpfile
    tmpfile=$(mktemp -t usbguard_validate_XXXXXX.py 2>/dev/null)
    cat > "$tmpfile" << 'PYEOF'
import sys, json
try:
    with open(sys.argv[1], 'r') as f:
        data = json.load(f)
    if 'rules' not in data:
        print('ERROR: Missing "rules" key', file=sys.stderr)
        sys.exit(1)
    for cat in ['system', 'permanent', 'temporary']:
        if cat not in data['rules']:
            print('WARN: Missing rules category: %s' % cat, file=sys.stderr)
            data['rules'][cat] = []
        for i, rule in enumerate(data['rules'][cat]):
            if not isinstance(rule, str):
                print('ERROR: Rule %d in %s is not a string' % (i, cat), file=sys.stderr)
                sys.exit(1)
    print('OK')
    sys.exit(0)
except json.JSONDecodeError as e:
    print('ERROR: Invalid JSON: %s' % str(e), file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print('ERROR: %s' % str(e), file=sys.stderr)
    sys.exit(1)
PYEOF
    python3 "$tmpfile" "$INPUT_FILE" 2>&1
    local rc=$?
    rm -f "$tmpfile"
    return $rc
}

count_rules() {
    local tmpfile
    tmpfile=$(mktemp -t usbguard_count_XXXXXX.py 2>/dev/null)
    cat > "$tmpfile" << 'PYEOF'
import sys, json
with open(sys.argv[1], 'r') as f:
    data = json.load(f)
for cat in ['system', 'permanent', 'temporary']:
    count = len(data['rules'].get(cat, []))
    print('%s:%d' % (cat, count))
PYEOF
    python3 "$tmpfile" "$INPUT_FILE"
    rm -f "$tmpfile"
}

get_rules_for_category() {
    local category="$1"
    local tmpfile
    tmpfile=$(mktemp -t usbguard_getrules_XXXXXX.py 2>/dev/null)
    cat > "$tmpfile" << 'PYEOF'
import sys, json
with open(sys.argv[1], 'r') as f:
    data = json.load(f)
rules = data['rules'].get(sys.argv[2], [])
for rule in rules:
    print(rule)
PYEOF
    python3 "$tmpfile" "$INPUT_FILE" "$category"
    rm -f "$tmpfile"
}

# ═══════════════════════════════════════════════════════════════
# Backup current rules before import
# ═══════════════════════════════════════════════════════════════
do_backup() {
    local backup_dir="/etc/usbguard/backups"
    mkdir -p "$backup_dir" 2>/dev/null

    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S' 2>/dev/null || echo "unknown")
    local backup_file="${backup_dir}/pre-import-${timestamp}.tar.gz"

    local files_to_backup=()
    [[ -f "$RULES_SYSTEM" ]] && files_to_backup+=("$RULES_SYSTEM")
    [[ -f "$RULES_PERMANENT" ]] && files_to_backup+=("$RULES_PERMANENT")
    [[ -f "$RULES_TEMPORARY" ]] && files_to_backup+=("$RULES_TEMPORARY")

    if [[ ${#files_to_backup[@]} -eq 0 ]]; then
        echo ""
        return
    fi

    tar -czf "$backup_file" "${files_to_backup[@]}" 2>/dev/null || {
        echo ""
        return
    }

    echo "$backup_file"
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

    echo -e "${COLOR_BOLD}USBGuard Rules Import Tool${COLOR_RESET}"
    echo ""

    # Validate JSON
    echo -e "${COLOR_CYAN}Validating import file: $INPUT_FILE${COLOR_RESET}"
    if ! validate_json; then
        echo -e "${COLOR_RED}ERROR: JSON validation failed${COLOR_RESET}" >&2
        exit 1
    fi
    echo -e "${COLOR_GREEN}  ✓ JSON is valid${COLOR_RESET}"
    echo ""

    # Count rules
    echo -e "${COLOR_CYAN}Analyzing import file...${COLOR_RESET}"
    local counts
    counts=$(count_rules)
    local total=0

    echo "Rules found:"
    while IFS=: read -r cat count; do
        printf "  %-10s : %d rules\n" "$cat" "$count"
        total=$((total + count))
    done <<< "$counts"
    echo ""
    echo -e "${COLOR_BOLD}Total: $total rules${COLOR_RESET}"
    echo ""

    if [[ $total -eq 0 ]]; then
        echo -e "${COLOR_YELLOW}No rules to import.${COLOR_RESET}"
        exit 0
    fi

    # Dry run
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${COLOR_YELLOW}DRY RUN: No changes were made.${COLOR_RESET}"
        echo "To actually import, run without --dry-run."
        exit 0
    fi

    # Confirmation
    if [[ "$FORCE" != "true" ]]; then
        echo -e "${COLOR_YELLOW}  This will APPEND $total rule(s) to the existing rules files.${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}  A backup will be created before import.${COLOR_RESET}"
        echo ""
        read -r -p "Are you sure you want to continue? (yes/no): " confirm
        if [[ "$confirm" != "yes" ]]; then
            echo -e "${COLOR_RED}Import cancelled.${COLOR_RESET}"
            exit 0
        fi
        echo ""
    fi

    # Backup
    echo -e "${COLOR_CYAN}Creating backup...${COLOR_RESET}"
    local backup_file
    backup_file=$(do_backup)
    if [[ -n "$backup_file" ]]; then
        echo -e "${COLOR_GREEN}  Backup: $(basename "$backup_file")${COLOR_RESET}"
    else
        echo -e "${COLOR_YELLOW}  No existing rules to backup${COLOR_RESET}"
    fi
    echo ""

    # Import each category
    local imported_total=0

    echo -e "${COLOR_CYAN}Importing rules...${COLOR_RESET}"

    local cat_count
    cat_count=$(echo "$counts" | grep "^system:" | cut -d: -f2 || echo "0")
    if [[ "$cat_count" -gt 0 ]]; then
        mkdir -p "$(dirname "$RULES_SYSTEM")" 2>/dev/null
        touch "$RULES_SYSTEM" 2>/dev/null || true
        get_rules_for_category "system" >> "$RULES_SYSTEM" 2>/dev/null || {
            echo -e "${COLOR_RED}Failed to write system rules${COLOR_RESET}" >&2
        }
        chmod 600 "$RULES_SYSTEM" 2>/dev/null
        chown root:root "$RULES_SYSTEM" 2>/dev/null
        echo -e "${COLOR_GREEN}  Imported $cat_count rule(s) to system${COLOR_RESET}"
        imported_total=$((imported_total + cat_count))
    fi

    cat_count=$(echo "$counts" | grep "^permanent:" | cut -d: -f2 || echo "0")
    if [[ "$cat_count" -gt 0 ]]; then
        mkdir -p "$(dirname "$RULES_PERMANENT")" 2>/dev/null
        touch "$RULES_PERMANENT" 2>/dev/null || true
        get_rules_for_category "permanent" >> "$RULES_PERMANENT" 2>/dev/null || {
            echo -e "${COLOR_RED}Failed to write permanent rules${COLOR_RESET}" >&2
        }
        chmod 600 "$RULES_PERMANENT" 2>/dev/null
        chown root:root "$RULES_PERMANENT" 2>/dev/null
        echo -e "${COLOR_GREEN}  Imported $cat_count rule(s) to permanent${COLOR_RESET}"
        imported_total=$((imported_total + cat_count))
    fi

    cat_count=$(echo "$counts" | grep "^temporary:" | cut -d: -f2 || echo "0")
    if [[ "$cat_count" -gt 0 ]]; then
        mkdir -p "$(dirname "$RULES_TEMPORARY")" 2>/dev/null
        touch "$RULES_TEMPORARY" 2>/dev/null || true
        get_rules_for_category "temporary" >> "$RULES_TEMPORARY" 2>/dev/null || {
            echo -e "${COLOR_RED}Failed to write temporary rules${COLOR_RESET}" >&2
        }
        chmod 600 "$RULES_TEMPORARY" 2>/dev/null
        chown root:root "$RULES_TEMPORARY" 2>/dev/null
        echo -e "${COLOR_GREEN}  Imported $cat_count rule(s) to temporary${COLOR_RESET}"
        imported_total=$((imported_total + cat_count))
    fi

    echo ""
    echo -e "${COLOR_GREEN}${COLOR_BOLD}Import completed!${COLOR_RESET}"
    echo -e "  Total rules imported: $imported_total"

    # Reload usbguard daemon
    echo ""
    echo -e "${COLOR_CYAN}Reloading usbguard daemon...${COLOR_RESET}"
    if pkill -HUP usbguard-daemon 2>/dev/null; then
        sleep 1
        if pgrep usbguard-daemon >/dev/null; then
            echo -e "${COLOR_GREEN}  Daemon reloaded${COLOR_RESET}"
        fi
    else
        echo -e "${COLOR_YELLOW}  Daemon reload failed (try: sudo systemctl reload usbguard)${COLOR_RESET}"
    fi

    echo ""
    echo -e "To verify: ${COLOR_CYAN}sudo usbguard list-devices${COLOR_RESET}"
}

main "$@"