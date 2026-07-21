#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# USBGuard Approval Manager - Learning Mode (Propose-Only)
# Version: 1.0
# ═══════════════════════════════════════════════════════════════════════════════
# מצב למידה: סורק את התקני ה-USB המחוברים, מזהה התקנים חדשים ומדפיס
# המלצות (REVIEW / DO_NOT_APPROVE) - ללא אישור אוטומטי.
#
# זהה לרעיון learn() בקוד המקורי (USBGuard Protector v1.1):
#   • APPEARED_DURING_LEARNING  -> דורש אימות פיזי לפני אישור
#   • COMPOSITE_UNEXPECTED      -> HID+MassStorage / HID+CDC -> אל תאשר
#
# שימוש:
#   sudo usb-learn.sh [--duration SEC] [--json]
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
CONFIG_FILE="${CONFIG_FILE:-/etc/usbguard/approval-manager.conf}"

# ─── טעינת ספריות עזר ──────────────────────────────────────────────────────────
for lib in config-reader.sh logger.sh; do
    if [[ -f "${LIB_DIR}/${lib}" ]]; then
        # shellcheck source=/dev/null
        source "${LIB_DIR}/${lib}" 2>/dev/null || true
    fi
done

# ─── צבעים ────────────────────────────────────────────────────────────────────
readonly COLOR_RESET='\033[0m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_BOLD='\033[1m'

DURATION=30
AS_JSON=false

# ─── פענוח שורת התקן usbguard (regex, ללא subprocess חיצוני) ──────────────────
parse_field() {
    local line="$1" field="$2" result=""
    case "$field" in
        device_id) [[ $line =~ ^([0-9]+): ]] && result="${BASH_REMATCH[1]}" ;;
        id)         [[ $line =~ id\ ([0-9a-fA-F]{4}:[0-9a-fA-F]{4}) ]] && result="${BASH_REMATCH[1]}" ;;
        name)       [[ $line =~ name\ \"([^\"]+)\" ]] && result="${BASH_REMATCH[1]}" ;;
        serial)     [[ $line =~ serial\ \"?([^\"\ ]+) ]] && result="${BASH_REMATCH[1]}" ;;
        hash)       [[ $line =~ hash\ \"?([^\"\ ]+) ]] && result="${BASH_REMATCH[1]}" ;;
        port)       [[ $line =~ via-port\ \"?([^\"\ ]+) ]] && result="${BASH_REMATCH[1]}" ;;
    esac
    echo "$result"
}

# ─── זיהוי התקן קומפוזיט חשוד (HID + MassStorage / HID + CDC) ──────────────────
is_composite_unexpected() {
    local line="$1"
    local hid=false ms=false cdc=false
    [[ $line =~ 03: ]] && hid=true
    [[ $line =~ 08:06:50 ]] && ms=true
    [[ $line =~ 02:02:01 ]] && cdc=true
    if $hid && $ms; then return 0; fi
    if $hid && $cdc; then return 0; fi
    return 1
}

# ─── המרת שורת התקן ל-JSON object ────────────────────────────────────────────
device_to_json() {
    local line="$1" flags_csv="$2"
    local id dev name serial hash port
    id=$(parse_field "$line" id)
    dev=$(parse_field "$line" device_id)
    name=$(parse_field "$line" name)
    serial=$(parse_field "$line" serial)
    hash=$(parse_field "$line" hash)
    port=$(parse_field "$line" port)
    python3 -c "
import json, sys
print(json.dumps({
    'device_id': sys.argv[1], 'id': sys.argv[2],
    'name': sys.argv[3], 'serial': sys.argv[4],
    'hash': sys.argv[5], 'port': sys.argv[6],
    'flags': sys.argv[7].split(',') if sys.argv[7] else []
}))" "$dev" "$id" "$name" "$serial" "$hash" "$port" "$flags_csv"
}

# ─── MAIN ─────────────────────────────────────────────────────────────────────
main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --duration) DURATION="$2"; shift 2 ;;
            --json) AS_JSON=true; shift ;;
            -h|--help|help)
                echo "Usage: sudo $0 [--duration SEC] [--json]"
                echo "  --duration SEC   Watch window in seconds (default 30)"
                echo "  --json           Output proposals as JSON"
                exit 0 ;;
            *) shift ;;
        esac
    done

    if [[ $EUID -ne 0 ]]; then
        echo -e "${COLOR_RED}WARN: Some device info may be unavailable without root${COLOR_RESET}" >&2
    fi

    if ! command -v usbguard &>/dev/null; then
        echo -e "${COLOR_RED}ERROR: usbguard command not found${COLOR_RESET}" >&2
        exit 1
    fi

    if ! $AS_JSON; then
        echo -e "${COLOR_BOLD}══════════════════════════════════════════════════════${COLOR_RESET}"
        echo -e "${COLOR_BOLD} USBGuard Learning Mode (propose-only)${COLOR_RESET}"
        echo -e "${COLOR_BOLD}══════════════════════════════════════════════════════${COLOR_RESET}"
        echo -e " Scanning for ${COLOR_CYAN}${DURATION}s${COLOR_RESET}... (no devices will be approved)"
    fi

    local before after
    before=$(usbguard list-devices 2>/dev/null || true)
    sleep "$DURATION"
    after=$(usbguard list-devices 2>/dev/null || true)

    local proposals=()
    local delim=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local fp
        fp=$(parse_field "$line" id)
        [[ -z "$fp" ]] && fp=$(parse_field "$line" device_id)

        local flags=""
        if ! echo "$before" | grep -q "^${fp}:" 2>/dev/null && ! echo "$before" | grep -q "id ${fp}"; then
            flags+="APPEARED_DURING_LEARNING"
        fi
        if is_composite_unexpected "$line"; then
            [[ -n "$flags" ]] && flags+=","
            flags+="COMPOSITE_UNEXPECTED"
        fi

        local recommendation="REVIEW_REQUIRED"
        if [[ "$flags" == *"COMPOSITE_UNEXPECTED"* ]]; then
            recommendation="DO_NOT_APPROVE"
        elif [[ "$flags" == *"APPEARED_DURING_LEARNING"* ]]; then
            recommendation="REVIEW_PHYSICAL_VERIFICATION"
        fi

        if $AS_JSON; then
            proposals+=("${delim}$(device_to_json "$line" "$flags")")
            delim=","
        else
            local dev name
            dev=$(parse_field "$line" device_id)
            name=$(parse_field "$line" name)
            echo ""
            echo -e " ${COLOR_CYAN}Device ${dev}${COLOR_RESET} (${name:-Unknown})"
            echo -e "   id      : $(parse_field "$line" id)"
            echo -e "   flags   : ${flags:-none}"
            if [[ "$recommendation" == "DO_NOT_APPROVE" ]]; then
                echo -e "   ${COLOR_RED}➜ ${recommendation}${COLOR_RESET}"
            else
                echo -e "   ${COLOR_YELLOW}➜ ${recommendation}${COLOR_RESET}"
            fi
        fi
    done <<< "$after"

    if $AS_JSON; then
        echo -e "{\"proposals\":[${proposals[*]:-}]}"
    else
        echo ""
        echo -e "${COLOR_BOLD}══════════════════════════════════════════════════════${COLOR_RESET}"
        echo -e "${COLOR_GREEN}Learning scan complete. No devices were approved.${COLOR_RESET}"
        echo -e "Use ${COLOR_BOLD}usb-approve.sh${COLOR_RESET} to approve reviewed devices."
    fi
}

main "$@"
