#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# USBGuard Approval Manager - Consolidated Deployment Script
# Version: 2.2
# ═══════════════════════════════════════════════════════════════
# סקריפט התקנה מלא ואוטומטי - מאחד את deploy.sh ו-start.sh
# תומך בבעיות וירטואליזציה (VM), הרשאות מחמירות וגרסה 1.1.2
# הרצה: sudo ./deploy.sh
# ═══════════════════════════════════════════════════════════════
# הערה: פונקציות עזר נמצאות ב-deploy-lib.sh, uninstall ב-deploy-uninstall.sh
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

# Error and Warning counters
ERRORS=0
WARNINGS=0

# ─── Source library ───────────────────────────────────────────
source "$SCRIPT_DIR/deploy-lib.sh"

# ═══════════════════════════════════════════════════════════════
# STAGE 1: Pre-flight Checks & Time Synchronization
# ═══════════════════════════════════════════════════════════════
stage_preflight() {
    log_header "Stage 1/8: Pre-flight Checks & Time Sync"

    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        return 1
    fi
    log_ok "Running as root"

    if [[ -f /etc/os-release ]]; then
        local os_name os_version
        os_name=$(grep -oP '^ID="?\K[^"]+' /etc/os-release 2>/dev/null || echo "unknown")
        os_version=$(grep -oP '^VERSION_ID="?\K[^"]+' /etc/os-release 2>/dev/null || echo "unknown")
        log_ok "OS: ${os_name} ${os_version}"
    else
        log_warn "Cannot detect OS (no /etc/os-release)"
    fi

    log_info "Synchronizing system time..."
    if command -v ntpdate &>/dev/null; then
        ntpdate -u ntp.ubuntu.com || ntpdate -u pool.ntp.org || log_warn "ntpdate failed to sync time"
    else
        if command -v apt-get &>/dev/null; then
            apt-get update -qq || true
            apt-get install -y ntpdate -qq || true
            if command -v ntpdate &>/dev/null; then
                ntpdate -u ntp.ubuntu.com || ntpdate -u pool.ntp.org || log_warn "ntpdate failed to sync time after install"
            fi
        fi
    fi
    log_ok "System time: $(date)"
    return 0
}

# ═══════════════════════════════════════════════════════════════
# STAGE 2: Install Dependencies (apt/dnf/yum)
# ═══════════════════════════════════════════════════════════════
stage_install_deps() {
    log_header "Stage 2/8: Installing Dependencies"

    local install_cmd=""
    local packages=(usbguard whiptail util-linux gawk systemd coreutils tar gzip dos2unix)

    if command -v apt-get &>/dev/null; then
        install_cmd="apt-get install -y"
    elif command -v dnf &>/dev/null; then
        install_cmd="dnf install -y"
    elif command -v yum &>/dev/null; then
        install_cmd="yum install -y"
    else
        log_warn "No supported package manager found. Please install manually: ${packages[*]}"
        return 0
    fi

    local install_list=()
    for pkg in "${packages[@]}"; do
        if ! command -v "$pkg" &>/dev/null; then
            install_list+=("$pkg")
        fi
    done

    if ! command -v usbguard &>/dev/null; then
        if ! dpkg -l usbguard 2>/dev/null | grep -q '^ii' && ! rpm -q usbguard 2>/dev/null; then
            install_list+=("usbguard")
        fi
    fi

    if [[ ${#install_list[@]} -gt 0 ]]; then
        log_info "Installing missing packages: ${install_list[*]}"
        if [[ "$install_cmd" == *"apt-get"* ]]; then
            run_cmd "Package database update" apt-get update -qq || true
        fi
        run_cmd "Install packages" $install_cmd "${install_list[@]}" || {
            log_error "Failed to install packages automatically."
            return 1
        }
    else
        log_ok "All required packages are already installed"
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════
# STAGE 3: Directories & Group Authorization
# ═══════════════════════════════════════════════════════════════
stage_directories_and_groups() {
    log_header "Stage 3/8: Directory & Group Setup"

    if ! getent group usbadmins >/dev/null; then
        groupadd usbadmins
        log_ok "Created usbadmins group"
    else
        log_ok "Group usbadmins already exists"
    fi

    local active_user="${SUDO_USER:-}"
    if [[ -n "$active_user" && "$active_user" != "root" ]]; then
        usermod -aG usbadmins "$active_user"
        log_ok "Added user '$active_user' to usbadmins group"
    else
        log_warn "Could not determine non-root SUDO_USER. Group membership must be verified manually."
    fi

    local dirs=(
        "/etc/usbguard/rules.d"
        "/etc/usbguard/scripts/lib"
        "/etc/usbguard/backups"
        "/var/lib/usbguard-manager"
        "/var/lock"
    )
    for dir in "${dirs[@]}"; do
        if mkdir -p "$dir" 2>/dev/null; then
            log_ok "Directory exists/created: $dir"
        else
            log_warn "Failed to create directory: $dir (might already exist)"
        fi
    done

    chown root:root /etc/usbguard/rules.d
    chmod 700 /etc/usbguard/rules.d
    log_ok "Set secure permissions (700) on /etc/usbguard/rules.d"

    if [[ ! -f "/var/lib/usbguard-manager/last_run_epoch" ]]; then
        date +%s > /var/lib/usbguard-manager/last_run_epoch 2>/dev/null || true
    fi
    chmod 600 /var/lib/usbguard-manager/last_run_epoch 2>/dev/null || true

    return 0
}

# ═══════════════════════════════════════════════════════════════
# STAGE 4: Configuration Files & Scripts Deployment
# ═══════════════════════════════════════════════════════════════
stage_deploy_files() {
    log_header "Stage 4/8: Deploying Configurations & Scripts"

    # 1. Write secure Daemon Configuration
    log_info "Writing USBGuard Daemon Config (RuleFolder, usbadmins group IPC)..."
    local daemon_conf_content
    daemon_conf_content="RuleFolder=/etc/usbguard/rules.d
ImplicitPolicyTarget=block
PresentDevicePolicy=apply-policy
InsertedDevicePolicy=apply-policy
RestoreControllerDeviceState=true
DeviceManagerBackend=uevent
IPCAllowedUsers=root
IPCAllowedGroups=usbadmins
AuditBackend=FileAudit
AuditFilePath=/var/log/usbguard/usbguard-audit.log
HidePII=false"

    echo "$daemon_conf_content" > /etc/usbguard/usbguard.conf
    echo "$daemon_conf_content" > /etc/usbguard/usbguard-daemon.conf
    chmod 600 /etc/usbguard/usbguard.conf /etc/usbguard/usbguard-daemon.conf
    chown root:root /etc/usbguard/usbguard.conf /etc/usbguard/usbguard-daemon.conf
    log_ok "Daemon configuration applied to standard paths with strict 600 permissions"

    # 2. Copy Approval Manager config
    run_cmd "Copy approval-manager.conf" \
        cp "$SCRIPT_DIR/conf/approval-manager.conf" "/etc/usbguard/approval-manager.conf"
    chmod 640 "/etc/usbguard/approval-manager.conf"
    chown root:root "/etc/usbguard/approval-manager.conf"

    # 3. Copy base rules
    for rule_file in 50-permanent.rules 90-temporary.rules; do
        run_cmd "Copy ${rule_file}" \
            cp "$SCRIPT_DIR/rules.d/${rule_file}" "/etc/usbguard/rules.d/${rule_file}"
        chmod 600 "/etc/usbguard/rules.d/${rule_file}"
        chown root:root "/etc/usbguard/rules.d/${rule_file}"
    done

    # 4. Copy libraries
    run_cmd "Copy script libraries" \
        cp "$SCRIPT_DIR/scripts/lib/"*.sh "/etc/usbguard/scripts/lib/"
    chmod 600 /etc/usbguard/scripts/lib/*.sh
    chown root:root /etc/usbguard/scripts/lib/*.sh

    # 5. Copy main workflow scripts
    local main_scripts=(usb-approve.sh cleanup-expired.sh backup-rules.sh restore-rules.sh \
                        export-rules.sh import-rules.sh usbguard-status.sh check-config.sh)
    for script in "${main_scripts[@]}"; do
        run_cmd "Copy ${script}" \
            cp "$SCRIPT_DIR/scripts/${script}" "/etc/usbguard/scripts/${script}"
        chmod 755 "/etc/usbguard/scripts/${script}"
        chown root:root "/etc/usbguard/scripts/${script}"
    done

    # Sanitize CRLF
    log_info "Running dos2unix on all scripts and configs..."
    dos2unix /etc/usbguard/scripts/*.sh /etc/usbguard/scripts/lib/*.sh /etc/usbguard/*.conf /etc/usbguard/rules.d/*.rules 2>/dev/null || true

    # 6. Copy Logrotate
    run_cmd "Copy logrotate config" \
        cp "$SCRIPT_DIR/logrotate/usbguard-approval" "/etc/logrotate.d/usbguard-approval"
    chmod 644 /etc/logrotate.d/usbguard-approval 2>/dev/null || true

    # 7. Sudoers Configuration
    if [[ -f "$SCRIPT_DIR/sudoers/usbguard-approval" ]]; then
        run_cmd "Copy sudoers config" \
            cp "$SCRIPT_DIR/sudoers/usbguard-approval" "/etc/sudoers.d/usbguard-approval"
        dos2unix "/etc/sudoers.d/usbguard-approval" 2>/dev/null || true
        chmod 440 "/etc/sudoers.d/usbguard-approval"
        chown root:root "/etc/sudoers.d/usbguard-approval"
        if visudo -c >/dev/null 2>&1; then
            log_ok "Sudoers config verified (visudo OK)"
        else
            log_error "Sudoers validation failed! Removing sudoers file to prevent system locks."
            rm -f "/etc/sudoers.d/usbguard-approval"
            return 1
        fi
    fi

    # 8. Copy Web Systemd Service
    if [[ -f "$SCRIPT_DIR/systemd/usbguard-web.service" ]]; then
        run_cmd "Copy Web service file" \
            cp "$SCRIPT_DIR/systemd/usbguard-web.service" "/etc/systemd/system/usbguard-web.service"
        chmod 644 "/etc/systemd/system/usbguard-web.service"
        chown root:root "/etc/systemd/system/usbguard-web.service"
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════
# STAGE 5: Generate Safe Base Policy (Before Daemon starts!)
# ═══════════════════════════════════════════════════════════════
stage_generate_policy() {
    log_header "Stage 5/8: Generating Safe Base USB Policy"

    local system_rules="/etc/usbguard/rules.d/00-system.rules"

    if [[ -f "$system_rules" ]] && [[ -s "$system_rules" ]]; then
        if grep -qE '^[[:space:]]*allow' "$system_rules" 2>/dev/null; then
            log_ok "Safe system policy already exists with allow rules"
            return 0
        fi
    fi

    log_info "Generating system policy using usbguard..."
    log_info "IMPORTANT: Ensure keyboard and mouse are plugged in!"

    if usbguard generate-policy 2>/dev/null | grep -E '^[[:space:]]*allow' > "$system_rules" 2>/dev/null; then
        if [[ -s "$system_rules" ]]; then
            log_ok "Safe policy generated from system hardware state: $(wc -l < "$system_rules") rules allowed"
        else
            log_warn "Generated policy is empty - applying fallback HID protective rules"
            cat > "$system_rules" << 'EOF'
# Fallback protective rules to prevent keyboard lockout
allow with-interface 03:00:00
allow with-interface 03:01:00
allow with-interface 03:01:01
allow with-interface 03:01:02
EOF
            log_ok "Fallback protective rules applied"
        fi
    else
        log_warn "Could not generate policy via CLI - applying fallback HID protective rules"
        cat > "$system_rules" << 'EOF'
# Fallback protective rules to prevent keyboard lockout
allow with-interface 03:00:00
allow with-interface 03:01:00
allow with-interface 03:01:01
allow with-interface 03:01:02
EOF
        log_ok "Fallback protective rules applied"
    fi

    chmod 600 "$system_rules"
    chown root:root "$system_rules"
    log_ok "System rules secured at $system_rules"
    return 0
}

# ═══════════════════════════════════════════════════════════════
# STAGE 6: Services Activation
# ═══════════════════════════════════════════════════════════════
stage_services() {
    log_header "Stage 6/8: Activating Services"

    run_cmd "Enable usbguard daemon" systemctl enable usbguard
    run_cmd "Start usbguard daemon" systemctl start usbguard
    pkill -HUP usbguard-daemon 2>/dev/null || true
    sleep 1

    if systemctl is-active --quiet usbguard 2>/dev/null; then
        log_ok "USBGuard daemon is active and running"
    else
        log_error "USBGuard daemon failed to start! Checking logs:"
        journalctl -u usbguard --no-pager -n 10 || true
        return 1
    fi

    # TTL Reaper
    run_cmd "Copy TTL Reaper service file" \
        cp "$SCRIPT_DIR/systemd/usbguard-ttl-reaper.service" "/etc/systemd/system/usbguard-ttl-reaper.service"
    run_cmd "Copy TTL Reaper timer file" \
        cp "$SCRIPT_DIR/systemd/usbguard-ttl-reaper.timer" "/etc/systemd/system/usbguard-ttl-reaper.timer"
    run_cmd "Reload systemd configuration" systemctl daemon-reload
    run_cmd "Enable TTL Reaper timer" systemctl enable usbguard-ttl-reaper.timer
    run_cmd "Start TTL Reaper timer" systemctl start usbguard-ttl-reaper.timer

    if systemctl is-active --quiet usbguard-ttl-reaper.timer 2>/dev/null; then
        log_ok "TTL Reaper timer is active and running"
    else
        log_warn "TTL Reaper timer failed to start"
    fi

    # Web Service
    if [[ -f "/etc/systemd/system/usbguard-web.service" ]]; then
        run_cmd "Enable Web service" systemctl enable usbguard-web.service || true
        run_cmd "Start Web service" systemctl start usbguard-web.service || true
        if systemctl is-active --quiet usbguard-web.service 2>/dev/null; then
            log_ok "Web service is active and running"
        else
            log_warn "Web service failed to start"
        fi
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════
# STAGE 7: Validation
# ═══════════════════════════════════════════════════════════════
stage_validation() {
    log_header "Stage 7/8: System Integrity Validation"

    local val_errors=0
    local critical_files=(
        "/etc/usbguard/usbguard.conf" "/etc/usbguard/approval-manager.conf"
        "/etc/usbguard/scripts/usb-approve.sh" "/etc/usbguard/scripts/cleanup-expired.sh"
        "/etc/usbguard/scripts/backup-rules.sh" "/etc/usbguard/scripts/restore-rules.sh"
        "/etc/usbguard/scripts/lib/config-reader.sh" "/etc/usbguard/scripts/lib/logger.sh"
        "/etc/usbguard/scripts/lib/lock.sh" "/etc/usbguard/scripts/lib/validators.sh"
        "/etc/usbguard/rules.d/00-system.rules" "/etc/usbguard/rules.d/50-permanent.rules"
        "/etc/usbguard/rules.d/90-temporary.rules"
    )

    for file in "${critical_files[@]}"; do
        if [[ -f "$file" ]]; then
            log_ok "File exists: $file"
        else
            log_error "CRITICAL file missing: $file"
            ((val_errors++))
        fi
    done

    local scripts=(/etc/usbguard/scripts/*.sh)
    for script in "${scripts[@]}"; do
        if [[ -f "$script" ]]; then
            local perms
            perms=$(stat -L -c "%a" "$script" 2>/dev/null)
            if [[ "$perms" == "755" ]]; then
                log_ok "Permissions OK (755): $script"
            else
                log_warn "Invalid permissions ($perms) on script: $script - fixing..."
                chmod 755 "$script"
            fi
        fi
    done

    local rule_files=(/etc/usbguard/rules.d/*.rules)
    for rule in "${rule_files[@]}"; do
        if [[ -f "$rule" ]]; then
            local perms
            perms=$(stat -L -c "%a" "$rule" 2>/dev/null)
            if [[ "$perms" == "600" ]]; then
                log_ok "Permissions OK (600): $rule"
            else
                log_warn "Invalid permissions ($perms) on rules file: $rule - fixing..."
                chmod 600 "$rule"
                chown root:root "$rule"
            fi
        fi
    done

    if usbguard list-devices >/dev/null 2>&1; then
        log_ok "USBGuard IPC channel responding (IPC OK)"
    else
        log_warn "IPC channel did not respond to standard user request"
    fi

    local log_file="/var/log/usbguard-approval.log"
    if [[ ! -f "$log_file" ]]; then
        touch "$log_file" 2>/dev/null || true
    fi
    if [[ -f "$log_file" ]]; then
        chmod 660 "$log_file" 2>/dev/null || true
        chown root:usbadmins "$log_file" 2>/dev/null || true
        log_ok "Audit log file prepared"
    else
        log_warn "Failed to prepare audit log file"
    fi

    return $val_errors
}

# ═══════════════════════════════════════════════════════════════
# STAGE 8: Completion Summary
# ═══════════════════════════════════════════════════════════════
stage_summary() {
    log_header "Stage 8/8: Deployment Summary"

    echo ""
    echo -e "${COLOR_BOLD}════════════════════════════════════════════════════════════${COLOR_RESET}"
    if [[ $ERRORS -eq 0 ]]; then
        echo -e "${COLOR_GREEN}${COLOR_BOLD}  ✅ DEPLOYMENT COMPLETED SUCCESSFULLY!${COLOR_RESET}"
        echo -e "     Warnings: ${WARNINGS}  Errors: ${ERRORS}"
        echo ""
        echo -e "  ${COLOR_CYAN}How to run:${COLOR_RESET}"
        echo -e "  ${COLOR_BOLD}sudo /etc/usbguard/scripts/usb-approve.sh${COLOR_RESET}"
        echo ""
        echo -e "  ${COLOR_CYAN}Uninstall:${COLOR_RESET} ${COLOR_BOLD}sudo ./deploy-uninstall.sh${COLOR_RESET}"
    else
        echo -e "${COLOR_RED}${COLOR_BOLD}  ❌ DEPLOYMENT COMPLETED WITH ${ERRORS} ERROR(S)${COLOR_RESET}"
        echo -e "     Please inspect: ${COLOR_BOLD}${DEPLOY_LOG}${COLOR_RESET}"
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
    echo -e "${COLOR_BOLD}║  USBGuard Approval Manager - Consolidated    ║${COLOR_RESET}"
    echo -e "${COLOR_BOLD}║  Version: 2.2 Production-Grade Deployment    ║${COLOR_RESET}"
    echo -e "${COLOR_BOLD}╚══════════════════════════════════════════════╝${COLOR_RESET}"
    echo ""
    echo "Writing deploy logs to: $DEPLOY_LOG"
    echo ""
    echo -e "${COLOR_CYAN}Tip:${COLOR_RESET} To uninstall, run: ${COLOR_BOLD}sudo bash deploy-uninstall.sh${COLOR_RESET}"
    echo ""

    stage_preflight || { log_error "Stage 1 failed. Aborting."; exit 1; }
    stage_install_deps || { log_error "Stage 2 failed. Aborting."; exit 1; }
    stage_directories_and_groups || { log_error "Stage 3 failed. Aborting."; exit 1; }
    stage_deploy_files || { log_error "Stage 4 failed. Aborting."; exit 1; }
    stage_generate_policy || { log_warn "Stage 5 had warnings."; }
    stage_services || { log_error "Stage 6 failed. Aborting."; exit 1; }

    local val_res=0
    stage_validation || val_res=$?
    if [[ $val_res -ne 0 ]]; then
        log_error "Stage 7 found critical issues."
    fi

    stage_summary
}

main "$@"