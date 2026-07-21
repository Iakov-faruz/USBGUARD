#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# USBGuard Approval Manager - USB Lockdown Controller
# Version: 1.0
# ═══════════════════════════════════════════════════════════════════════════════
# מצב Lockdown שולט במדיניות ברירת המחדל של USBGuard עבור התקנים חדשים:
#   • block   - כל התקן שלא מופיע במפורש ברשימת הכללים יידחה (fail-closed)
#   • allow   - התקנים חדשים יאושרו אוטומטית (מסוכן)
#
# הערך נשמר ב-ImplicitPolicyTarget של usbguard (first-match / ברירת מחדל).
# בעת ביטול lockdown אנו משאירים block כברירת מחדל בטוחה (כמו בקוד המקורי).
#
# שימוש:
#   sudo usb-lockdown.sh enable   # מפעיל USB lockdown (block לכל התקן חדש)
#   sudo usb-lockdown.sh disable  # משחרר (נשאר block כברירת מחדל בטוחה)
#   sudo usb-lockdown.sh status   # מציג את המצב הנוכחי
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
CONFIG_FILE="${CONFIG_FILE:-/etc/usbguard/approval-manager.conf}"
STATE_FILE="/var/lib/usbguard-manager/usb-lockdown.state"

# ─── טעינת ספריות עזר ──────────────────────────────────────────────────────────
for lib in config-reader.sh logger.sh lock.sh; do
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

log_info() {
    if declare -F _log >/dev/null 2>&1; then
        _log 1 "LOCKDOWN" "$*"
    else
        echo -e "${COLOR_CYAN}[LOCKDOWN]${COLOR_RESET} $*"
    fi
}
log_error() { echo -e "${COLOR_RED}[LOCKDOWN ERROR]${COLOR_RESET} $*" >&2; }

# ─── וידוא root ───────────────────────────────────────────────────────────────
require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This command must be run as root (use sudo)"
        exit 1
    fi
}

# ─── קריאת פרמטר נוכחי מ-usbguard ─────────────────────────────────────────────
get_implicit_policy() {
    usbguard get-parameter ImplicitPolicyTarget 2>/dev/null | tr -d '[:space:]' || echo "unknown"
}

# ─── שמירת מצב קודם ──────────────────────────────────────────────────────────
save_previous_policy() {
    local prev="$1"
    mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
    echo "$prev" > "$STATE_FILE" 2>/dev/null || true
    chmod 600 "$STATE_FILE" 2>/dev/null || true
    chown root:root "$STATE_FILE" 2>/dev/null || true
}

# ─── enable ──────────────────────────────────────────────────────────────────
do_enable() {
    require_root
    init_logger "/var/log/usbguard-approval.log" 2>/dev/null || true

    local prev
    prev=$(get_implicit_policy)
    save_previous_policy "$prev"

    if usbguard set-parameter ImplicitPolicyTarget block 2>/dev/null; then
        log_info "${COLOR_GREEN}USB lockdown ENABLED${COLOR_RESET} - new devices default to ${COLOR_BOLD}block${COLOR_RESET}"
        log_info "Previous ImplicitPolicyTarget was: ${prev:-unknown}"
        if declare -F log_audit >/dev/null 2>&1; then
            log_audit "LOCKDOWN" "enabled prev_policy=${prev}"
        fi
    else
        log_error "Failed to set ImplicitPolicyTarget=block (is usbguard running?)"
        exit 1
    fi
}

# ─── disable ─────────────────────────────────────────────────────────────────
do_disable() {
    require_root
    init_logger "/var/log/usbguard-approval.log" 2>/dev/null || true

    # נשאר block כברירת מחדל בטוחה - לא מחזיר ל-allow אוטומטית
    if usbguard set-parameter ImplicitPolicyTarget block 2>/dev/null; then
        log_info "${COLOR_YELLOW}USB lockdown DISABLED${COLOR_RESET} - ImplicitPolicyTarget stays ${COLOR_BOLD}block${COLOR_RESET} (safe default)"
        if declare -F log_audit >/dev/null 2>&1; then
            log_audit "LOCKDOWN" "disabled safe_default=block"
        fi
    else
        log_error "Failed to set ImplicitPolicyTarget=block (is usbguard running?)"
        exit 1
    fi
}

# ─── status ─────────────────────────────────────────────────────────────────
do_status() {
    local policy
    policy=$(get_implicit_policy)
    local prev="unknown"
    [[ -f "$STATE_FILE" ]] && prev="$(cat "$STATE_FILE" 2>/dev/null || echo unknown)"

    echo -e "${COLOR_BOLD}══════════════════════════════════════════════════════${COLOR_RESET}"
    echo -e "${COLOR_BOLD} USB Lockdown Status${COLOR_RESET}"
    echo -e "${COLOR_BOLD}══════════════════════════════════════════════════════${COLOR_RESET}"
    printf "  %-28s : %s\n" "ImplicitPolicyTarget" "$(echo -e "${policy}")"
    printf "  %-28s : %s\n" "Previous policy" "$prev"
    if [[ "$policy" == "block" ]]; then
        echo -e "  ${COLOR_GREEN}✓ Fail-closed: new devices are blocked by default${COLOR_RESET}"
    else
        echo -e "  ${COLOR_RED}⚠ New devices default to '${policy}' - NOT fail-closed${COLOR_RESET}"
    fi
}

# ─── MAIN ─────────────────────────────────────────────────────────────────────
main() {
    local cmd="${1:-status}"
    case "$cmd" in
        enable)  do_enable ;;
        disable) do_disable ;;
        status)  do_status ;;
        -h|--help|help)
            echo "Usage: sudo $0 [enable|disable|status]"
            echo "  enable   Lock down USB (new devices blocked by default)"
            echo "  disable  Release lockdown (safe default 'block' retained)"
            echo "  status   Show current lockdown state"
            ;;
        *)
            log_error "Unknown command: $cmd"
            echo "Usage: sudo $0 [enable|disable|status]" >&2
            exit 1
            ;;
    esac
}

main "$@"
