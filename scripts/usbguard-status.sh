#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# USBGuard Approval Manager - Status Dashboard (CLI)
# Version: 1.0
# ═══════════════════════════════════════════════════════════════
# מציג סטטוס מלא של מערכת USBGuard Approval Manager
# הרצה: sudo ./usbguard-status.sh
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────
CONFIG_FILE="/etc/usbguard/approval-manager.conf"
SLEEP_INTERVAL=5
WATCH_MODE=false

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

get_conf_int() {
    local key="$1"
    local default="$2"
    local file="$3"
    local val
    val=$(grep -oP "^${key}=\K.*" "$file" 2>/dev/null || echo "$default")
    echo "$val"
}

# ─── Parse arguments ─────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --watch|-w)
            WATCH_MODE=true
            if [[ $# -gt 1 && "$2" =~ ^[0-9]+$ ]]; then
                SLEEP_INTERVAL="$2"
                shift
            fi
            shift
            ;;
        --help|-h)
            echo "Usage: sudo $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --watch, -w [SEC]    Watch mode (refresh every SEC seconds, default 5)"
            echo "  --help, -h           Show this help"
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

# ═══════════════════════════════════════════════════════════════
# Dashboard Functions
# ═══════════════════════════════════════════════════════════════

check_daemon_status() {
    local status=""
    local color="$COLOR_GREEN"

    if command -v systemctl &>/dev/null; then
        if systemctl is-active --quiet usbguard 2>/dev/null; then
            status="Running"
            color="$COLOR_GREEN"
        elif systemctl is-enabled usbguard 2>/dev/null | grep -q "enabled"; then
            status="Stopped (enabled)"
            color="$COLOR_YELLOW"
        else
            status="Stopped (disabled)"
            color="$COLOR_RED"
        fi
    else
        if pgrep usbguard-daemon &>/dev/null; then
            status="Running (pgrep)"
            color="$COLOR_GREEN"
        else
            status="Unknown"
            color="$COLOR_YELLOW"
        fi
    fi

    echo -e "${color}${status}${COLOR_RESET}"
}

check_timer_status() {
    local status=""
    local color="$COLOR_GREEN"

    if command -v systemctl &>/dev/null; then
        if systemctl is-active --quiet usbguard-ttl-reaper.timer 2>/dev/null; then
            status="Active"
            color="$COLOR_GREEN"
        elif systemctl list-units --full -all 2>/dev/null | grep -q 'usbguard-ttl-reaper.timer'; then
            status="Inactive"
            color="$COLOR_YELLOW"
        else
            status="Not installed"
            color="$COLOR_RED"
        fi
    else
        status="Unknown"
        color="$COLOR_YELLOW"
    fi

    echo -e "${color}${status}${COLOR_RESET}"
}

check_timer_next_run() {
    if command -v systemctl &>/dev/null; then
        local next
        next=$(systemctl list-timers --all 2>/dev/null | grep usbguard-ttl-reaper | awk '{print $3, $4, $5}' || echo "N/A")
        echo "$next"
    else
        echo "N/A"
    fi
}

check_rules_count() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local count
        count=$(grep -cE 'allow' "$file" 2>/dev/null || echo "0")
        echo "$count"
    else
        echo "0"
    fi
}

check_rules_permissions() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo -e "${COLOR_YELLOW}Missing${COLOR_RESET}"
        return
    fi

    local perms owner group
    if command -v stat &>/dev/null; then
        perms=$(stat -L -c "%a" "$file" 2>/dev/null || echo "???")
        owner=$(stat -L -c "%U:%G" "$file" 2>/dev/null || echo "???")
    else
        echo -e "${COLOR_YELLOW}Unknown${COLOR_RESET}"
        return
    fi

    if [[ "$perms" == "600" ]] && [[ "$owner" == "root:root" ]]; then
        echo -e "${COLOR_GREEN}${perms} ${owner}${COLOR_RESET}"
    else
        echo -e "${COLOR_RED}${perms} ${owner}${COLOR_RESET} ⚠"
    fi
}

check_ipc_access() {
    if usbguard list-devices >/dev/null 2>&1; then
        echo -e "${COLOR_GREEN}OK${COLOR_RESET}"
    else
        echo -e "${COLOR_RED}FAIL${COLOR_RESET}"
    fi
}

check_group_status() {
    if getent group usbadmins >/dev/null; then
        local members
        members=$(getent group usbadmins | cut -d: -f4)
        if [[ -n "$members" ]]; then
            echo -e "${COLOR_GREEN}Exists (members: $members)${COLOR_RESET}"
        else
            echo -e "${COLOR_YELLOW}Exists (no members)${COLOR_RESET}"
        fi
    else
        echo -e "${COLOR_RED}Missing${COLOR_RESET}"
    fi
}

check_log_size() {
    local log_file="/var/log/usbguard-approval.log"
    if [[ -f "$log_file" ]]; then
        local size
        size=$(du -h "$log_file" 2>/dev/null | cut -f1 || echo "?")
        echo "$size"
    else
        echo "0"
    fi
}

check_last_reaper_run() {
    local state_file="/var/lib/usbguard-manager/last_run_epoch"
    if [[ -f "$state_file" ]]; then
        local epoch
        epoch=$(cat "$state_file" 2>/dev/null || echo "0")
        if [[ "$epoch" -gt 0 ]]; then
            local last_run
            last_run=$(date -d "@$epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
            echo "$last_run"
        else
            echo "Never"
        fi
    else
        echo "N/A"
    fi
}

# ═══════════════════════════════════════════════════════════════
# Display Dashboard
# ═══════════════════════════════════════════════════════════════
show_dashboard() {
    # Clear screen in watch mode
    if [[ "$WATCH_MODE" == "true" ]]; then
        clear 2>/dev/null || true
    fi

    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")

    # Detect rules files
    local rules_system rules_permanent rules_temporary
    rules_system=$(get_conf "RULES_SYSTEM" "$CONFIG_FILE")     || rules_system="/etc/usbguard/rules.d/00-system.rules"
    rules_permanent=$(get_conf "RULES_PERMANENT" "$CONFIG_FILE") || rules_permanent="/etc/usbguard/rules.d/50-permanent.rules"
    rules_temporary=$(get_conf "RULES_TEMPORARY" "$CONFIG_FILE") || rules_temporary="/etc/usbguard/rules.d/90-temporary.rules"

    local temp_ttl
    temp_ttl=$(get_conf_int "TEMP_TTL_SECONDS" 3600 "$CONFIG_FILE")

    echo -e "${COLOR_BOLD}╔══════════════════════════════════════════════════════════════╗${COLOR_RESET}"
    echo -e "${COLOR_BOLD}║              USBGuard Approval Manager Status               ║${COLOR_RESET}"
    echo -e "${COLOR_BOLD}╚══════════════════════════════════════════════════════════════╝${COLOR_RESET}"
    echo ""
    echo -e " ${COLOR_CYAN}Last updated:${COLOR_RESET} $timestamp"
    if [[ "$WATCH_MODE" == "true" ]]; then
        echo -e " ${COLOR_CYAN}Watch mode:${COLOR_RESET} refreshing every ${SLEEP_INTERVAL}s (Ctrl+C to exit)"
    fi
    echo ""

    # ── Section 1: Services ──────────────────────────────────
    echo -e "${COLOR_BOLD}── Services ──────────────────────────────────────────────${COLOR_RESET}"
    printf "  %-30s : %b\n" "usbguard daemon" "$(check_daemon_status)"
    printf "  %-30s : %b\n" "TTL Reaper timer" "$(check_timer_status)"
    printf "  %-30s : %s\n" "Timer next run" "$(check_timer_next_run)"
    printf "  %-30s : %b\n" "IPC access" "$(check_ipc_access)"
    echo ""

    # ── Section 2: Rules Files ───────────────────────────────
    echo -e "${COLOR_BOLD}── Rules Files ────────────────────────────────────────────${COLOR_RESET}"

    printf "  %-20s %-12s %-20s %b\n" "File" "Rules" "Permissions" "Status"
    printf "  %-20s %-12s %-20s %b\n" "────" "─────" "───────────" "──────"

    local sys_count perm_count temp_count
    sys_count=$(check_rules_count "$rules_system")
    perm_count=$(check_rules_count "$rules_permanent")
    temp_count=$(check_rules_count "$rules_temporary")

    printf "  %-20s %-12s %-20s %b\n" "00-system.rules" "$sys_count" "$(check_rules_permissions "$rules_system")" ""
    printf "  %-20s %-12s %-20s %b\n" "50-permanent.rules" "$perm_count" "$(check_rules_permissions "$rules_permanent")" ""
    printf "  %-20s %-12s %-20s %b\n" "90-temporary.rules" "$temp_count" "$(check_rules_permissions "$rules_temporary")" ""

    local total=$((sys_count + perm_count + temp_count))
    echo -e "  ${COLOR_BOLD}Total rules: $total${COLOR_RESET}"
    echo ""

    # ── Section 3: Configuration ─────────────────────────────
    echo -e "${COLOR_BOLD}── Configuration ──────────────────────────────────────────${COLOR_RESET}"
    printf "  %-30s : %b\n" "usbadmins group" "$(check_group_status)"
    printf "  %-30s : %s\n" "Temporary TTL" "${temp_ttl}s"
    printf "  %-30s : %s\n" "Config file" "$CONFIG_FILE"
    echo ""

    # ── Section 4: Logging & State ───────────────────────────
    echo -e "${COLOR_BOLD}── Logging & State ────────────────────────────────────────${COLOR_RESET}"
    printf "  %-30s : %s\n" "Approval log size" "$(check_log_size)"
    printf "  %-30s : %s\n" "Last reaper run" "$(check_last_reaper_run)"
    printf "  %-30s : %s\n" "State directory" "/var/lib/usbguard-manager"
    echo ""

    # ── Section 5: Connected Devices ─────────────────────────
    echo -e "${COLOR_BOLD}── Connected USB Devices ──────────────────────────────────${COLOR_RESET}"
    if command -v usbguard &>/dev/null; then
        local allowed blocked
        allowed=$(usbguard list-devices --allowed 2>/dev/null | grep -cE '^[0-9]+:' || echo "0")
        blocked=$(usbguard list-devices --blocked 2>/dev/null | grep -cE '^[0-9]+:' || echo "0")
        printf "  %-30s : %s\n" "Allowed devices" "$allowed"
        printf "  %-30s : %s\n" "Blocked devices" "$blocked"
    else
        echo -e "  ${COLOR_YELLOW}usbguard command not available${COLOR_RESET}"
    fi
    echo ""
    echo -e "${COLOR_BOLD}══════════════════════════════════════════════════════════════${COLOR_RESET}"
}

# ═══════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════
main() {
    # Root check (needed for some operations)
    if [[ $EUID -ne 0 ]]; then
        echo -e "${COLOR_YELLOW}WARN: Some information may not be available without root${COLOR_RESET}" >&2
    fi

    if [[ "$WATCH_MODE" == "true" ]]; then
        # Trap Ctrl+C to exit cleanly
        trap 'echo -e "\n${COLOR_CYAN}Exiting watch mode.${COLOR_RESET}"; exit 0' INT

        while true; do
            show_dashboard
            sleep "$SLEEP_INTERVAL"
        done
    else
        show_dashboard
    fi
}

main "$@"