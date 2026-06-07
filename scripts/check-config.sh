#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# USBGuard Approval Manager - Configuration Check
# Version: 1.0
# ═══════════════════════════════════════════════════════════════
# בודק תקינות התקנת USBGuard Approval Manager
# הרצה: sudo ./usbguard-check-config.sh
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────
CONFIG_FILE="/etc/usbguard/approval-manager.conf"

# ─── Colors ──────────────────────────────────────────────────
readonly COLOR_RESET='\033[0m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_BOLD='\033[1m'

# Counters
PASSED=0
FAILED=0
WARNINGS=0

# ─── Helper functions ────────────────────────────────────────
get_conf() {
    local key="$1"
    local file="$2"
    grep -oP "^${key}=\K.*" "$file" 2>/dev/null || echo ""
}

check() {
    local name="$1"
    local status="$2"  # pass, fail, warn
    local message="$3"

    case "$status" in
        pass)
            echo -e "  ${COLOR_GREEN}✓${COLOR_RESET} $name: $message"
            ((PASSED++))
            ;;
        fail)
            echo -e "  ${COLOR_RED}✗${COLOR_RESET} $name: $message"
            ((FAILED++))
            ;;
        warn)
            echo -e "  ${COLOR_YELLOW}⚠${COLOR_RESET} $name: $message"
            ((WARNINGS++))
            ;;
    esac
}

check_file_perms() {
    local file="$1"
    local expected_perms="$2"

    if [[ ! -f "$file" ]]; then
        echo "missing"
        return
    fi

    local perms owner
    perms=$(stat -L -c "%a" "$file" 2>/dev/null || echo "???")
    owner=$(stat -L -c "%U:%G" "$file" 2>/dev/null || echo "???:???")

    if [[ "$perms" == "$expected_perms" ]] && [[ "$owner" == "root:root" ]]; then
        echo "ok"
    elif [[ "$perms" != "$expected_perms" ]]; then
        echo "bad_perms:${perms}"
    elif [[ "$owner" != "root:root" ]]; then
        echo "bad_owner:${owner}"
    fi
}

# ═══════════════════════════════════════════════════════════════
# Get config values
# ═══════════════════════════════════════════════════════════════
RULES_SYSTEM=$(get_conf "RULES_SYSTEM" "$CONFIG_FILE")     || RULES_SYSTEM="/etc/usbguard/rules.d/00-system.rules"
RULES_PERMANENT=$(get_conf "RULES_PERMANENT" "$CONFIG_FILE") || RULES_PERMANENT="/etc/usbguard/rules.d/50-permanent.rules"
RULES_TEMPORARY=$(get_conf "RULES_TEMPORARY" "$CONFIG_FILE") || RULES_TEMPORARY="/etc/usbguard/rules.d/90-temporary.rules"
BACKUP_DIR=$(get_conf "BACKUP_DIR" "$CONFIG_FILE")         || BACKUP_DIR="/etc/usbguard/backups"
LOG_FILE=$(get_conf "LOG_FILE" "$CONFIG_FILE")             || LOG_FILE="/var/log/usbguard-approval.log"
LOCK_FILE=$(get_conf "LOCK_FILE" "${CONFIG_FILE}")         || LOCK_FILE="/var/lock/usbguard-manager.lock"
STATE_DIR=$(get_conf "STATE_DIR" "${CONFIG_FILE}")         || STATE_DIR="/var/lib/usbguard-manager"

# ═══════════════════════════════════════════════════════════════
# Check stages
# ═══════════════════════════════════════════════════════════════

check_root() {
    echo ""
    echo -e "${COLOR_BOLD}── Root / Sudo ───────────────────────────────────────────${COLOR_RESET}"

    if [[ $EUID -ne 0 ]]; then
        check "Root" "fail" "Must run as root (use sudo)"
    else
        check "Root" "pass" "Running as root"
    fi
}

check_os() {
    echo ""
    echo -e "${COLOR_BOLD}── Operating System ──────────────────────────────────────${COLOR_RESET}"

    if [[ -f /etc/os-release ]]; then
        local os_name os_version
        os_name=$(grep -oP '^ID="?\K[^"]+' /etc/os-release 2>/dev/null || echo "unknown")
        os_version=$(grep -oP '^VERSION_ID="?\K[^"]+' /etc/os-release 2>/dev/null || echo "unknown")
        check "OS" "pass" "${os_name} ${os_version}"
    else
        check "OS" "warn" "Cannot detect OS"
    fi

    # Check architecture
    local arch
    arch=$(uname -m 2>/dev/null || echo "unknown")
    check "Architecture" "pass" "$arch"
}

check_dependencies() {
    echo ""
    echo -e "${COLOR_BOLD}── Dependencies ──────────────────────────────────────────${COLOR_RESET}"

    local required_cmds=(usbguard whiptail systemctl)
    for cmd in "${required_cmds[@]}"; do
        if command -v "$cmd" &>/dev/null; then
            check "$cmd" "pass" "Installed"
        else
            check "$cmd" "fail" "NOT FOUND - required"
        fi
    done

    local optional_cmds=(dos2unix notify-send python3)
    for cmd in "${optional_cmds[@]}"; do
        if command -v "$cmd" &>/dev/null; then
            check "$cmd (optional)" "pass" "Installed"
        else
            check "$cmd (optional)" "warn" "Not installed"
        fi
    done
}

check_daemon() {
    echo ""
    echo -e "${COLOR_BOLD}── USBGuard Daemon ───────────────────────────────────────${COLOR_RESET}"

    # Check if usbguard is installed
    if command -v usbguard &>/dev/null; then
        check "usbguard binary" "pass" "$(usbguard --version 2>/dev/null || echo "version unknown")"
    else
        check "usbguard binary" "fail" "NOT FOUND"
    fi

    # Check daemon status
    if systemctl is-active --quiet usbguard 2>/dev/null; then
        check "Daemon status" "pass" "Running"
    else
        check "Daemon status" "fail" "NOT RUNNING"
    fi

    # Check daemon enabled
    if systemctl is-enabled --quiet usbguard 2>/dev/null; then
        check "Daemon enabled" "pass" "Enabled"
    else
        check "Daemon enabled" "warn" "Not enabled"
    fi

    # IPC check
    if usbguard list-devices >/dev/null 2>&1; then
        check "IPC channel" "pass" "Responding"
    else
        check "IPC channel" "fail" "NOT RESPONDING"
    fi
}

check_config_file() {
    echo ""
    echo -e "${COLOR_BOLD}── Config File ───────────────────────────────────────────${COLOR_RESET}"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        check "approval-manager.conf" "fail" "FILE NOT FOUND: $CONFIG_FILE"
        return
    fi

    local perms_status
    perms_status=$(check_file_perms "$CONFIG_FILE" "640")
    case "$perms_status" in
        ok) check "approval-manager.conf" "pass" "Exists, permissions 640, root:root" ;;
        missing) check "approval-manager.conf" "fail" "FILE NOT FOUND" ;;
        bad_perms:*) check "approval-manager.conf" "warn" "Bad permissions: ${perms_status#bad_perms:} (expected 640)" ;;
        bad_owner:*) check "approval-manager.conf" "warn" "Bad owner: ${perms_status#bad_owner:} (expected root:root)" ;;
    esac

    # Validate config keys
    local required_keys=(
        "RULES_SYSTEM" "RULES_PERMANENT" "RULES_TEMPORARY"
        "BACKUP_DIR" "LOG_FILE" "STATE_DIR" "LOCK_FILE"
        "BACKUP_KEEP" "TEMP_TTL_SECONDS"
        "ALLOWED_USERS" "ALLOWED_GROUPS"
        "CHECK_DUPLICATES" "LOG_LEVEL"
    )

    for key in "${required_keys[@]}"; do
        local val
        val=$(get_conf "$key" "$CONFIG_FILE")
        if [[ -n "$val" ]]; then
            check "Config key: $key" "pass" "$val"
        else
            check "Config key: $key" "warn" "Missing or empty"
        fi
    done
}

check_usbguard_conf() {
    echo ""
    echo -e "${COLOR_BOLD}── USBGuard Daemon Config ────────────────────────────────${COLOR_RESET}"

    local conf_file="/etc/usbguard/usbguard.conf"
    if [[ ! -f "$conf_file" ]]; then
        check "usbguard.conf" "fail" "FILE NOT FOUND"
        return
    fi

    check "usbguard.conf" "pass" "Exists"

    # Check RuleFolder/RuleDirectory
    if grep -qP '^RuleFolder=' "$conf_file" 2>/dev/null; then
        check "RuleFolder setting" "pass" "$(grep -oP '^RuleFolder=.*' "$conf_file")"
    elif grep -qP '^RuleDirectory=' "$conf_file" 2>/dev/null; then
        check "RuleDirectory setting" "pass" "$(grep -oP '^RuleDirectory=.*' "$conf_file")"
    else
        check "RuleFolder/RuleDirectory" "fail" "MISSING"
    fi

    # Check IPCAllowedGroups
    if grep -qP '^IPCAllowedGroups=usbadmins' "$conf_file" 2>/dev/null; then
        check "IPC groups" "pass" "usbadmins group allowed"
    else
        check "IPC groups" "warn" "usbadmins not in IPCAllowedGroups"
    fi

    # Check permissions
    local perms
    perms=$(stat -L -c "%a" "$conf_file" 2>/dev/null || echo "???")
    if [[ "$perms" == "600" ]]; then
        check "Config permissions" "pass" "600"
    else
        check "Config permissions" "warn" "Bad: $perms (expected 600)"
    fi
}

check_rules_files() {
    echo ""
    echo -e "${COLOR_BOLD}── Rules Files ───────────────────────────────────────────${COLOR_RESET}"

    local files=(
        "$RULES_SYSTEM:00-system.rules:600"
        "$RULES_PERMANENT:50-permanent.rules:600"
        "$RULES_TEMPORARY:90-temporary.rules:600"
    )

    for entry in "${files[@]}"; do
        local file="${entry%%:*}"
        local rest="${entry#*:}"
        local name="${rest%%:*}"
        local expected_perms="${rest##*:}"

        if [[ ! -f "$file" ]]; then
            check "$name" "warn" "File not found (will be created on first run)"
            continue
        fi

        local count
        count=$(grep -cE 'allow' "$file" 2>/dev/null || echo "0")

        local perms_status
        perms_status=$(check_file_perms "$file" "$expected_perms")
        case "$perms_status" in
            ok) check "$name" "pass" "$count rules, permissions $expected_perms, root:root" ;;
            bad_perms:*) check "$name" "warn" "$count rules, bad permissions: ${perms_status#bad_perms:} (expected $expected_perms)" ;;
            bad_owner:*) check "$name" "warn" "$count rules, bad owner: ${perms_status#bad_owner:} (expected root:root)" ;;
        esac
    done
}

check_directories() {
    echo ""
    echo -e "${COLOR_BOLD}── Directories ───────────────────────────────────────────${COLOR_RESET}"

    local dirs=(
        "/etc/usbguard:700"
        "$(dirname "$RULES_SYSTEM"):700"
        "/etc/usbguard/scripts:755"
        "/etc/usbguard/scripts/lib:600"
        "$BACKUP_DIR:700"
        "$STATE_DIR:700"
    )

    for entry in "${dirs[@]}"; do
        local dir="${entry%%:*}"
        local expected_perms="${entry##*:}"

        if [[ ! -d "$dir" ]]; then
            check "$(basename "$dir")" "warn" "Directory not found: $dir"
            continue
        fi

        local perms owner
        perms=$(stat -L -c "%a" "$dir" 2>/dev/null || echo "???")
        owner=$(stat -L -c "%U:%G" "$dir" 2>/dev/null || echo "???:???")

        if [[ "$perms" == "$expected_perms" ]] && [[ "$owner" == "root:root" ]]; then
            check "$(basename "$dir")" "pass" "Exists, permissions $expected_perms"
        else
            check "$(basename "$dir")" "warn" "Exists but perms=$perms owner=$owner (expected $expected_perms root:root)"
        fi
    done
}

check_scripts() {
    echo ""
    echo -e "${COLOR_BOLD}── Scripts ───────────────────────────────────────────────${COLOR_RESET}"

    local scripts=(
        "/etc/usbguard/scripts/usb-approve.sh:755"
        "/etc/usbguard/scripts/cleanup-expired.sh:755"
        "/etc/usbguard/scripts/backup-rules.sh:755"
        "/etc/usbguard/scripts/restore-rules.sh:755"
    )

    for entry in "${scripts[@]}"; do
        local file="${entry%%:*}"
        local expected_perms="${entry##*:}"

        if [[ ! -f "$file" ]]; then
            check "$(basename "$file")" "fail" "FILE NOT FOUND"
            continue
        fi

        local perms
        perms=$(stat -L -c "%a" "$file" 2>/dev/null || echo "???")
        if [[ "$perms" == "$expected_perms" ]]; then
            check "$(basename "$file")" "pass" "Exists, permissions $expected_perms"
        else
            check "$(basename "$file")" "warn" "Bad permissions: $perms (expected $expected_perms)"
        fi
    done

    # Library files
    local lib_files=(
        "/etc/usbguard/scripts/lib/config-reader.sh"
        "/etc/usbguard/scripts/lib/logger.sh"
        "/etc/usbguard/scripts/lib/lock.sh"
        "/etc/usbguard/scripts/lib/backup.sh"
        "/etc/usbguard/scripts/lib/time-guards.sh"
        "/etc/usbguard/scripts/lib/validators.sh"
    )

    for file in "${lib_files[@]}"; do
        if [[ -f "$file" ]]; then
            check "lib/$(basename "$file")" "pass" "Exists"
        else
            check "lib/$(basename "$file")" "warn" "Missing"
        fi
    done
}

check_systemd_services() {
    echo ""
    echo -e "${COLOR_BOLD}── Systemd Services ──────────────────────────────────────${COLOR_RESET}"

    local services=(
        "usbguard-ttl-reaper.timer"
        "usbguard-ttl-reaper.service"
    )

    for service in "${services[@]}"; do
        if systemctl list-units --full -all 2>/dev/null | grep -q "$service"; then
            if systemctl is-active --quiet "$service" 2>/dev/null; then
                check "$service" "pass" "Active"
            else
                check "$service" "warn" "Installed but inactive"
            fi
        else
            check "$service" "warn" "Not installed"
        fi
    done
}

check_sudoers() {
    echo ""
    echo -e "${COLOR_BOLD}── Sudoers ───────────────────────────────────────────────${COLOR_RESET}"

    local sudoers_file="/etc/sudoers.d/usbguard-approval"
    if [[ -f "$sudoers_file" ]]; then
        local perms
        perms=$(stat -L -c "%a" "$sudoers_file" 2>/dev/null || echo "???")
        if [[ "$perms" == "440" ]]; then
            check "sudoers config" "pass" "Exists, permissions 440"
        else
            check "sudoers config" "warn" "Bad permissions: $perms (expected 440)"
        fi
    else
        check "sudoers config" "warn" "Not installed"
    fi
}

check_logging() {
    echo ""
    echo -e "${COLOR_BOLD}── Logging ───────────────────────────────────────────────${COLOR_RESET}"

    # Check approval log
    if [[ -f "$LOG_FILE" ]]; then
        local perms owner size
        perms=$(stat -L -c "%a" "$LOG_FILE" 2>/dev/null || echo "???")
        owner=$(stat -L -c "%U:%G" "$LOG_FILE" 2>/dev/null || echo "???:???")
        size=$(du -h "$LOG_FILE" 2>/dev/null | cut -f1 || echo "?")
        check "Approval log" "pass" "Exists, $size, perms $perms, owner $owner"
    else
        check "Approval log" "warn" "Not found (will be created on first run)"
    fi

    # Check logrotate
    if [[ -f "/etc/logrotate.d/usbguard-approval" ]]; then
        check "Logrotate config" "pass" "Exists"
    else
        check "Logrotate config" "warn" "Not installed"
    fi

    # Check USBGuard audit log
    if [[ -f "/var/log/usbguard/usbguard-audit.log" ]]; then
        check "USBGuard audit log" "pass" "Exists"
    else
        check "USBGuard audit log" "warn" "Not found"
    fi
}

check_group() {
    echo ""
    echo -e "${COLOR_BOLD}── usbadmins Group ───────────────────────────────────────${COLOR_RESET}"

    if getent group usbadmins >/dev/null; then
        local members
        members=$(getent group usbadmins | cut -d: -f4)
        if [[ -n "$members" ]]; then
            check "usbadmins group" "pass" "Exists with members: $members"
        else
            check "usbadmins group" "warn" "Exists but has no members"
        fi
    else
        check "usbadmins group" "fail" "DOES NOT EXIST"
    fi
}

check_clock() {
    echo ""
    echo -e "${COLOR_BOLD}── System Clock ──────────────────────────────────────────${COLOR_RESET}"

    local current_epoch
    current_epoch=$(date +%s 2>/dev/null || echo "0")

    if [[ "$current_epoch" -gt 1577836800 ]]; then
        local current_date
        current_date=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
        check "System time" "pass" "$current_date"
    else
        check "System time" "fail" "Clock seems incorrect (epoch: $current_epoch)"
    fi
}

check_state() {
    echo ""
    echo -e "${COLOR_BOLD}── State Files ───────────────────────────────────────────${COLOR_RESET}"

    local state_file="${STATE_DIR}/last_run_epoch"
    if [[ -f "$state_file" ]]; then
        local epoch
        epoch=$(cat "$state_file" 2>/dev/null || echo "0")
        if [[ "$epoch" -gt 0 ]]; then
            local last_run
            last_run=$(date -d "@$epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
            check "Last run epoch" "pass" "$last_run"
        else
            check "Last run epoch" "warn" "Invalid value: $epoch"
        fi
    else
        check "Last run epoch" "warn" "Not found (will be created on first run)"
    fi
}

# ═══════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════
show_summary() {
    echo ""
    echo -e "${COLOR_BOLD}════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo -e "  ${COLOR_GREEN}Passed: $PASSED${COLOR_RESET}"
    echo -e "  ${COLOR_YELLOW}Warnings: $WARNINGS${COLOR_RESET}"
    echo -e "  ${COLOR_RED}Failed: $FAILED${COLOR_RESET}"
    echo ""

    if [[ $FAILED -eq 0 ]] && [[ $WARNINGS -eq 0 ]]; then
        echo -e "  ${COLOR_GREEN}${COLOR_BOLD}✅ All checks passed! System is properly configured.${COLOR_RESET}"
    elif [[ $FAILED -eq 0 ]]; then
        echo -e "  ${COLOR_YELLOW}${COLOR_BOLD}⚠ All critical checks passed, but there are warnings.${COLOR_RESET}"
    else
        echo -e "  ${COLOR_RED}${COLOR_BOLD}❌ Some checks failed. Review the issues above.${COLOR_RESET}"
    fi

    echo -e "${COLOR_BOLD}════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo ""
}

# ═══════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════
main() {
    echo ""
    echo -e "${COLOR_BOLD}╔══════════════════════════════════════════════╗${COLOR_RESET}"
    echo -e "${COLOR_BOLD}║  USBGuard Config Validation Tool             ║${COLOR_RESET}"
    echo -e "${COLOR_BOLD}╚══════════════════════════════════════════════╝${COLOR_RESET}"

    check_root
    check_os
    check_dependencies
    check_daemon
    check_config_file
    check_usbguard_conf
    check_rules_files
    check_directories
    check_scripts
    check_systemd_services
    check_sudoers
    check_logging
    check_group
    check_clock
    check_state

    show_summary

    # Exit with error if any critical failures
    if [[ $FAILED -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

main "$@"