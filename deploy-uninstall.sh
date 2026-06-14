#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# USBGuard Approval Manager - Full Uninstall
# Version: 3.0
# ═══════════════════════════════════════════════════════════════
# הרצה: sudo ./deploy.sh --uninstall
# או:   sudo bash deploy-uninstall.sh
# ═══════════════════════════════════════════════════════════════
# מסיר לחלוטין את כל רכיבי המערכת:
#   • USBGuard daemon + packages + binaries
#   • Approval Manager (scripts, lib, config)
#   • Web Interface (Flask API + frontend + venv)
#   • BadUSB Behavioral Monitor
#   • Systemd services & timers + symlinks
#   • Logrotate configuration
#   • Sudoers authorization
#   • usbadmins group
#   • Log files
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
readonly COLOR_RESET='\033[0m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_BOLD='\033[1m'

ERRORS=0
WARNINGS=0

# ─── Helper Functions ─────────────────────────────────────────
log_info()    { echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET} $*"; }
log_ok()      { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET} $*"; }
log_warn()    { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"; }
log_error()   { echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*"; }
log_section() { echo -e "\n${COLOR_BOLD}═══════════════════════════════════════════════════${COLOR_RESET}"; echo -e "${COLOR_BOLD}  $*${COLOR_RESET}"; echo -e "${COLOR_BOLD}═══════════════════════════════════════════════════${COLOR_RESET}"; }

# ═══════════════════════════════════════════════════════════════
# STAGE: Full Uninstall
# ═══════════════════════════════════════════════════════════════
stage_uninstall_all() {
    log_section "Stage: Full Uninstall"

    # ─── Step 1: Stop and disable all services ──────────────────────
    log_section "Step 1/8: Stopping and disabling services"

    local all_services=(
        "usbguard-web.service"
        "usbguard-behavioral.service"
        "usbguard-ttl-reaper.timer"
        "usbguard-ttl-reaper.service"
        "usbguard"
    )

    for svc in "${all_services[@]}"; do
        if systemctl list-units --full -all 2>/dev/null | grep -q "$svc"; then
            systemctl stop "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
            log_ok "Stopped and disabled: $svc"
        fi
    done

    systemctl daemon-reload
    log_ok "Systemd daemon reloaded"

    # ─── Step 2: Remove systemd service files + symlinks ────────────
    log_section "Step 2/8: Removing systemd service files and symlinks"

    local service_files=(
        "/etc/systemd/system/usbguard-ttl-reaper.service"
        "/etc/systemd/system/usbguard-ttl-reaper.timer"
        "/etc/systemd/system/usbguard-web.service"
        "/etc/systemd/system/usbguard-behavioral.service"
        "/lib/systemd/system/usbguard.service"
        "/etc/systemd/system/usbguard.service"
    )

    for svc_file in "${service_files[@]}"; do
        if [[ -f "$svc_file" ]]; then
            rm -f "$svc_file"
            log_ok "Removed: $svc_file"
        fi
    done

    # Remove systemd symlinks
    local symlinks=(
        "/etc/systemd/system/multi-user.target.wants/usbguard.service"
        "/etc/systemd/system/multi-user.target.wants/usbguard-ttl-reaper.service"
        "/etc/systemd/system/multi-user.target.wants/usbguard-web.service"
        "/etc/systemd/system/multi-user.target.wants/usbguard-behavioral.service"
        "/etc/systemd/system/timers.target.wants/usbguard-ttl-reaper.timer"
    )

    for symlink in "${symlinks[@]}"; do
        if [[ -L "$symlink" ]] || [[ -f "$symlink" ]]; then
            rm -f "$symlink"
            log_ok "Removed symlink: $symlink"
        fi
    done

    systemctl daemon-reload
    log_ok "All systemd service files and symlinks removed"

    # ─── Step 3: Remove USBGuard binaries and libraries ─────────────
    log_section "Step 3/8: Removing USBGuard binaries and libraries"

    local binaries=(
        "/usr/sbin/usbguard"
        "/usr/bin/usbguard"
        "/usr/lib/usbguard"
        "/usr/local/bin/usbguard"
    )

    for bin in "${binaries[@]}"; do
        if [[ -f "$bin" ]] || [[ -d "$bin" ]]; then
            rm -rf "$bin"
            log_ok "Removed: $bin"
        fi
    done

    log_ok "USBGuard binaries and libraries removed"

    # ─── Step 4: Remove USBGuard + Python packages ──────────────────
    log_section "Step 4/8: Removing packages"

    if command -v dpkg &>/dev/null; then
        for pkg in usbguard python3-usbguard python3-evdev python3-flask dos2unix ntpdate; do
            if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q " installed$"; then
                apt-get remove -y "$pkg" 2>/dev/null || true
                apt-get purge -y "$pkg" 2>/dev/null || true
                log_ok "Removed package: $pkg"
            fi
        done
    fi

    # Remove pip packages
    if command -v pip3 &>/dev/null; then
        for pip_pkg in usbguard flask flask-limiter; do
            if pip3 list 2>/dev/null | grep -qi "^$pip_pkg "; then
                pip3 uninstall -y "$pip_pkg" 2>/dev/null || true
                log_ok "Removed pip package: $pip_pkg"
            fi
        done
    fi

    log_ok "Packages removed"

    # ─── Step 5: Remove sudoers and logrotate ───────────────────────
    log_section "Step 5/8: Removing sudoers and logrotate configuration"

    local sudoers_file="/etc/sudoers.d/usbguard-approval"
    if [[ -f "$sudoers_file" ]]; then
        rm -f "$sudoers_file"
        log_ok "Removed: $sudoers_file"
    fi

    local logrotate_file="/etc/logrotate.d/usbguard-approval"
    if [[ -f "$logrotate_file" ]]; then
        rm -f "$logrotate_file"
        log_ok "Removed: $logrotate_file"
    fi

    # ─── Step 6: Remove all USBGuard Manager files and directories ──
    log_section "Step 6/8: Removing USBGuard Manager files and directories"

    local remove_paths=(
        "/etc/usbguard"
        "/var/lib/usbguard-manager"
        "/var/log/usbguard"
        "/var/lock/usbguard"
        "/var/run/usbguard-badusb.pid"
        "/var/run/usbguard-web.pid"
    )

    for path in "${remove_paths[@]}"; do
        if [[ -f "$path" ]] || [[ -d "$path" ]]; then
            rm -rf "$path"
            log_ok "Removed: $path"
        fi
    done

    # Remove individual log files
    local log_files=(
        "/var/log/usbguard-approval.log"
        "/var/log/usbguard-badusb.log"
        "/var/log/usbguard-web.log"
        "/var/log/usbguard/usbguard-audit.log"
    )

    for logf in "${log_files[@]}"; do
        if [[ -f "$logf" ]]; then
            rm -f "$logf"
            log_ok "Removed: $logf"
        fi
    done

    log_ok "All USBGuard Manager files and directories removed"

    # ─── Step 7: Remove usbadmins group ─────────────────────────────
    log_section "Step 7/8: Removing usbadmins group"

    if getent group usbadmins >/dev/null 2>&1; then
        local members
        members=$(getent group usbadmins | cut -d: -f4)
        if [[ -n "$members" ]]; then
            for user in $(echo "$members" | tr ',' ' '); do
                gpasswd -d "$user" usbadmins 2>/dev/null || true
                log_info "Removed user '$user' from usbadmins group"
            done
        fi
        groupdel usbadmins 2>/dev/null && log_ok "Group 'usbadmins' removed" || log_warn "Could not remove usbadmins group (may have other members)"
    else
        log_info "Group 'usbadmins' not found, skipping"
    fi

    # ─── Step 8: Final systemd reload ───────────────────────────────
    log_section "Step 8/8: Final cleanup"

    systemctl daemon-reload 2>/dev/null || true
    log_ok "Systemd daemon reloaded"

    # ─── Summary ───────────────────────────────────────────────────
    echo ""
    echo -e "${COLOR_BOLD}═══════════════════════════════════════════════════${COLOR_RESET}"
    echo -e "${COLOR_GREEN}${COLOR_BOLD}  ✅ Uninstall completed successfully!${COLOR_RESET}"
    echo -e "${COLOR_BOLD}  USBGuard Manager has been fully removed.${COLOR_RESET}"
    echo -e "${COLOR_BOLD}═══════════════════════════════════════════════════${COLOR_RESET}"
    echo ""
}

# ═══════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════
if [[ $EUID -ne 0 ]]; then
    echo -e "${COLOR_RED}ERROR: Must run as root (use sudo)${COLOR_RESET}" >&2
    exit 1
fi

echo -e "${COLOR_BOLD}USBGuard Approval Manager - Full Uninstall${COLOR_RESET}"
echo ""
echo -e "${COLOR_YELLOW}This will COMPLETELY REMOVE:${COLOR_RESET}"
echo -e "  • USBGuard daemon, packages, and binaries"
echo -e "  • Approval Manager (all scripts, config, rules)"
echo -e "  • Web Interface (Flask + frontend + venv)"
echo -e "  • BadUSB Behavioral Monitor"
echo -e "  • Systemd services, timers, and symlinks"
echo -e "  • Sudoers and logrotate configurations"
echo -e "  • usbadmins group"
echo -e "  • All log files"
echo ""
echo -e "${COLOR_RED}${COLOR_BOLD}⚠️  No backup will be made. This is irreversible!${COLOR_RESET}"
echo ""
read -r -p "Are you sure you want to completely remove everything? (yes/no): " confirm
if [[ "$confirm" != "yes" ]]; then
    echo "Cancelled."
    exit 0
fi

stage_uninstall_all