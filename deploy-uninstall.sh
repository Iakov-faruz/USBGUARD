#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# USBGuard Approval Manager - Uninstall
# Version: 2.2
# ═══════════════════════════════════════════════════════════════
# הרצה: sudo ./deploy.sh --uninstall
# או:   sudo bash deploy-uninstall.sh
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_LOG="/tmp/usbguard-deploy-$(date '+%Y%m%d_%H%M%S').log"

# Colors
readonly COLOR_RESET='\033[0m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_BOLD='\033[1m'

ERRORS=0
WARNINGS=0

# ─── Source lib (if exists) ───────────────────────────────────
if [[ -f "$SCRIPT_DIR/deploy-lib.sh" ]]; then
    source "$SCRIPT_DIR/deploy-lib.sh"
fi

# ═══════════════════════════════════════════════════════════════
# STAGE: Uninstall
# ═══════════════════════════════════════════════════════════════
stage_uninstall_all() {
    log_header "Stage: Full Uninstall"

    local backup_dir="/tmp/usbguard-uninstall-backup-$(date '+%Y%m%d_%H%M%S')"
    mkdir -p "$backup_dir"
    log_info "Backup saved to: $backup_dir"

    # Backup critical files
    for item in /etc/usbguard /var/lib/usbguard-manager /var/log/usbguard-approval.log \
                /etc/logrotate.d/usbguard-approval /etc/sudoers.d/usbguard-approval \
                /etc/systemd/system/usbguard-ttl-reaper.* /etc/systemd/system/usbguard-web.service; do
        if [[ -f "$item" || -d "$item" ]]; then
            local dest="${backup_dir}/${item#/}"
            mkdir -p "$(dirname "$dest")" 2>/dev/null
            cp -r "$item" "$dest" 2>/dev/null
        fi
    done

    # Stop and disable services
    for svc in usbguard-web.service usbguard-ttl-reaper.timer usbguard-ttl-reaper.service usbguard; do
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
    done
    systemctl daemon-reload

    # Remove files
    for item in /etc/usbguard/approval-manager.conf /etc/usbguard/scripts \
                /etc/usbguard/rules.d/50-permanent.rules /etc/usbguard/rules.d/90-temporary.rules \
                /etc/usbguard/backups /var/lib/usbguard-manager /var/log/usbguard-approval.log \
                /etc/logrotate.d/usbguard-approval /etc/sudoers.d/usbguard-approval \
                /etc/systemd/system/usbguard-ttl-reaper.* /etc/systemd/system/usbguard-web.service; do
        rm -rf "$item" 2>/dev/null && log_ok "Removed: $item" || true
    done

    # Restore minimal usbguard.conf
    if command -v usbguard &>/dev/null; then
        cat > /etc/usbguard/usbguard.conf << 'EOF'
RuleFolder=/etc/usbguard/rules.d
ImplicitPolicyTarget=block
PresentDevicePolicy=apply-policy
InsertedDevicePolicy=apply-policy
RestoreControllerDeviceState=true
DeviceManagerBackend=uevent
IPCAllowedUsers=root
IPCAllowedGroups=
AuditBackend=FileAudit
AuditFilePath=/var/log/usbguard/usbguard-audit.log
HidePII=false
EOF
        chmod 600 /etc/usbguard/usbguard.conf
        chown root:root /etc/usbguard/usbguard.conf
        systemctl start usbguard 2>/dev/null || true
        systemctl enable usbguard 2>/dev/null || true
    fi

    # Remove usbadmins group
    if getent group usbadmins >/dev/null; then
        for user in $(getent group usbadmins | cut -d: -f4 | tr ',' ' '); do
            gpasswd -d "$user" usbadmins 2>/dev/null || true
        done
        groupdel usbadmins 2>/dev/null || log_warn "Could not remove usbadmins group"
    fi

    log_ok "Uninstall completed. Backup saved to: $backup_dir"
}

# ═══════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════
if [[ $EUID -ne 0 ]]; then
    echo -e "${COLOR_RED}ERROR: Must run as root (use sudo)${COLOR_RESET}" >&2
    exit 1
fi

echo -e "${COLOR_BOLD}USBGuard Approval Manager - Uninstall${COLOR_RESET}"
echo ""
echo -e "${COLOR_YELLOW}This will remove all USBGuard Approval Manager components.${COLOR_RESET}"
echo -e "${COLOR_YELLOW}A backup will be saved to /tmp/usbguard-uninstall-backup-*${COLOR_RESET}"
echo ""
read -r -p "Are you sure? (yes/no): " confirm
if [[ "$confirm" != "yes" ]]; then
    echo "Cancelled."
    exit 0
fi

stage_uninstall_all