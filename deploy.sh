#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# USBGuard Approval Manager - Consolidated Deployment Script
# Version: 2.3 (includes Web UI)
# ═══════════════════════════════════════════════════════════════
# הרצה: sudo ./deploy.sh
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

# Error counters
ERRORS=0
WARNINGS=0

# ─── Helper functions (in case deploy-lib.sh missing) ─────────
log_info() { echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET} $*" | tee -a "$DEPLOY_LOG"; }
log_ok() { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET} $*" | tee -a "$DEPLOY_LOG"; }
log_warn() { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*" | tee -a "$DEPLOY_LOG"; ((WARNINGS++)); }
log_error() { echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*" | tee -a "$DEPLOY_LOG"; ((ERRORS++)); }
log_header() { echo ""; echo -e "${COLOR_BOLD}╔══════════════════════════════════════════════╗${COLOR_RESET}"; echo -e "${COLOR_BOLD}║  $*${COLOR_RESET}"; echo -e "${COLOR_BOLD}╚══════════════════════════════════════════════╝${COLOR_RESET}"; echo ""; }
run_cmd() { local desc="$1"; shift; echo -e "  → ${desc}..." | tee -a "$DEPLOY_LOG"; if "$@" 2>&1 | tee -a "$DEPLOY_LOG"; then log_ok "${desc}"; return 0; else log_error "${desc}"; return 1; fi; }

# ─── Source external lib if exists ────────────────────────────
if [[ -f "$SCRIPT_DIR/deploy-lib.sh" ]]; then
    source "$SCRIPT_DIR/deploy-lib.sh"
fi

# ═══════════════════════════════════════════════════════════════
# STAGE 1: Pre-flight Checks
# ═══════════════════════════════════════════════════════════════
stage_preflight() {
    log_header "Stage 1/9: Pre-flight Checks"

    if [[ $EUID -ne 0 ]]; then
        log_error "Must run as root (use sudo)"
        return 1
    fi
    log_ok "Running as root"

    if [[ -f /etc/os-release ]]; then
        local os_name os_version
        os_name=$(grep -oP '^ID="?\K[^"]+' /etc/os-release 2>/dev/null || echo "unknown")
        os_version=$(grep -oP '^VERSION_ID="?\K[^"]+' /etc/os-release 2>/dev/null || echo "unknown")
        log_ok "OS: ${os_name} ${os_version}"
    fi

    # Time sync (best effort)
    if command -v ntpdate &>/dev/null; then
        ntpdate -u ntp.ubuntu.com 2>/dev/null || ntpdate -u pool.ntp.org 2>/dev/null || true
    fi
    log_ok "System time: $(date)"
    return 0
}

# ═══════════════════════════════════════════════════════════════
# STAGE 2: Install Dependencies (apt/dnf/yum)
# ═══════════════════════════════════════════════════════════════
stage_install_deps() {
    log_header "Stage 2/9: Installing Dependencies"

    local install_cmd=""
    local packages=(usbguard whiptail util-linux gawk systemd coreutils tar gzip dos2unix)

    if command -v apt-get &>/dev/null; then
        install_cmd="apt-get install -y"
        packages+=(python3 python3-venv python3-pip)
    elif command -v dnf &>/dev/null; then
        install_cmd="dnf install -y"
        packages+=(python3 python3-virtualenv python3-pip)
    elif command -v yum &>/dev/null; then
        install_cmd="yum install -y"
        packages+=(python3 python3-virtualenv python3-pip)
    else
        log_warn "No supported package manager. Install manually: ${packages[*]}"
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
        log_info "Installing: ${install_list[*]}"
        [[ "$install_cmd" == *"apt-get"* ]] && run_cmd "Update package DB" apt-get update -qq || true
        run_cmd "Install packages" $install_cmd "${install_list[@]}" || return 1
    else
        log_ok "All packages already installed"
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════
# STAGE 3: Directories & Group
# ═══════════════════════════════════════════════════════════════
stage_directories_and_groups() {
    log_header "Stage 3/9: Directory & Group Setup"

    if ! getent group usbadmins >/dev/null; then
        groupadd usbadmins
        log_ok "Created usbadmins group"
    fi

    local active_user="${SUDO_USER:-}"
    if [[ -n "$active_user" && "$active_user" != "root" ]]; then
        usermod -aG usbadmins "$active_user"
        log_ok "Added user '$active_user' to usbadmins"
    fi

    local dirs=(
        "/etc/usbguard/rules.d"
        "/etc/usbguard/scripts/lib"
        "/etc/usbguard/backups"
        "/etc/usbguard/web/templates"
        "/etc/usbguard/web/static/css"
        "/etc/usbguard/web/static/js"
        "/var/lib/usbguard-manager"
        "/var/lock"
    )
    for dir in "${dirs[@]}"; do
        mkdir -p "$dir" 2>/dev/null && log_ok "Created: $dir" || log_warn "Exists: $dir"
    done

    chown root:root /etc/usbguard/rules.d
    chmod 700 /etc/usbguard/rules.d

    if [[ ! -f "/var/lib/usbguard-manager/last_run_epoch" ]]; then
        date +%s > /var/lib/usbguard-manager/last_run_epoch 2>/dev/null || true
    fi
    chmod 600 /var/lib/usbguard-manager/last_run_epoch 2>/dev/null || true

    return 0
}

# ═══════════════════════════════════════════════════════════════
# STAGE 4: Deploy Configs & Scripts
# ═══════════════════════════════════════════════════════════════
stage_deploy_files() {
    log_header "Stage 4/9: Deploying Configurations & Scripts"

    # Daemon config
    local daemon_conf="RuleFolder=/etc/usbguard/rules.d
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
    echo "$daemon_conf" > /etc/usbguard/usbguard.conf
    echo "$daemon_conf" > /etc/usbguard/usbguard-daemon.conf
    chmod 600 /etc/usbguard/usbguard.conf /etc/usbguard/usbguard-daemon.conf
    chown root:root /etc/usbguard/usbguard.conf /etc/usbguard/usbguard-daemon.conf
    log_ok "Daemon config written"

    # Approval config
    [[ -f "$SCRIPT_DIR/conf/approval-manager.conf" ]] && {
        cp "$SCRIPT_DIR/conf/approval-manager.conf" /etc/usbguard/
        chmod 640 /etc/usbguard/approval-manager.conf
        chown root:root /etc/usbguard/approval-manager.conf
        log_ok "Copied approval-manager.conf"
    }

    # Rules files
    for rule in 50-permanent.rules 90-temporary.rules; do
        if [[ -f "$SCRIPT_DIR/rules.d/$rule" ]]; then
            cp "$SCRIPT_DIR/rules.d/$rule" "/etc/usbguard/rules.d/"
            chmod 600 "/etc/usbguard/rules.d/$rule"
            chown root:root "/etc/usbguard/rules.d/$rule"
            log_ok "Copied $rule"
        fi
    done

    # Libraries
    if [[ -d "$SCRIPT_DIR/scripts/lib" ]]; then
        cp "$SCRIPT_DIR/scripts/lib/"*.sh /etc/usbguard/scripts/lib/ 2>/dev/null || true
        chmod 600 /etc/usbguard/scripts/lib/*.sh 2>/dev/null || true
        chown root:root /etc/usbguard/scripts/lib/*.sh 2>/dev/null || true
        log_ok "Copied script libraries"
    fi

    # Main scripts
    for scr in usb-approve.sh cleanup-expired.sh backup-rules.sh restore-rules.sh \
               export-rules.sh import-rules.sh usbguard-status.sh check-config.sh; do
        if [[ -f "$SCRIPT_DIR/scripts/$scr" ]]; then
            cp "$SCRIPT_DIR/scripts/$scr" /etc/usbguard/scripts/
            chmod 755 "/etc/usbguard/scripts/$scr"
            chown root:root "/etc/usbguard/scripts/$scr"
        fi
    done
    log_ok "Main scripts deployed"

    # dos2unix
    dos2unix /etc/usbguard/scripts/*.sh /etc/usbguard/scripts/lib/*.sh \
             /etc/usbguard/*.conf /etc/usbguard/rules.d/*.rules 2>/dev/null || true

    # Logrotate
    [[ -f "$SCRIPT_DIR/logrotate/usbguard-approval" ]] && {
        cp "$SCRIPT_DIR/logrotate/usbguard-approval" /etc/logrotate.d/
        chmod 644 /etc/logrotate.d/usbguard-approval
        log_ok "Copied logrotate config"
    }

    # Sudoers
    if [[ -f "$SCRIPT_DIR/sudoers/usbguard-approval" ]]; then
        cp "$SCRIPT_DIR/sudoers/usbguard-approval" /etc/sudoers.d/
        dos2unix /etc/sudoers.d/usbguard-approval 2>/dev/null || true
        chmod 440 /etc/sudoers.d/usbguard-approval
        chown root:root /etc/sudoers.d/usbguard-approval
        if visudo -c >/dev/null 2>&1; then
            log_ok "Sudoers valid"
        else
            log_error "Sudoers invalid! Removing."
            rm -f /etc/sudoers.d/usbguard-approval
            return 1
        fi
    fi

    # Systemd services
    for svc in usbguard-ttl-reaper.service usbguard-ttl-reaper.timer usbguard-web.service; do
        if [[ -f "$SCRIPT_DIR/systemd/$svc" ]]; then
            cp "$SCRIPT_DIR/systemd/$svc" /etc/systemd/system/
            chmod 644 "/etc/systemd/system/$svc"
            chown root:root "/etc/systemd/system/$svc"
            log_ok "Installed $svc"
        fi
    done

    return 0
}

# ═══════════════════════════════════════════════════════════════
# STAGE 5: Generate Base Policy
# ═══════════════════════════════════════════════════════════════
stage_generate_policy() {
    log_header "Stage 5/9: Generating Base USB Policy"

    local system_rules="/etc/usbguard/rules.d/00-system.rules"
    if [[ -f "$system_rules" ]] && grep -qE '^[[:space:]]*allow' "$system_rules" 2>/dev/null; then
        log_ok "System policy already exists"
        return 0
    fi

    log_info "Generating policy (ensure keyboard/mouse are plugged in)..."
    if usbguard generate-policy 2>/dev/null | grep -E '^[[:space:]]*allow' > "$system_rules" 2>/dev/null; then
        if [[ -s "$system_rules" ]]; then
            log_ok "Generated $(wc -l < "$system_rules") allow rules"
        else
            log_warn "Empty policy - using fallback HID rules"
            cat > "$system_rules" << 'EOF'
allow with-interface 03:00:00
allow with-interface 03:01:00
allow with-interface 03:01:01
allow with-interface 03:01:02
EOF
        fi
    else
        log_warn "Using fallback HID rules"
        cat > "$system_rules" << 'EOF'
allow with-interface 03:00:00
allow with-interface 03:01:00
allow with-interface 03:01:01
allow with-interface 03:01:02
EOF
    fi
    chmod 600 "$system_rules"
    chown root:root "$system_rules"
    log_ok "System rules ready"
    return 0
}

# ═══════════════════════════════════════════════════════════════
# STAGE 6: Activate Services
# ═══════════════════════════════════════════════════════════════
stage_services() {
    log_header "Stage 6/9: Activating Services"

    systemctl enable usbguard
    systemctl start usbguard
    pkill -HUP usbguard-daemon 2>/dev/null || true
    sleep 1

    if systemctl is-active --quiet usbguard; then
        log_ok "USBGuard daemon running"
    else
        log_error "USBGuard daemon failed to start"
        journalctl -u usbguard --no-pager -n 10 || true
        return 1
    fi

    if [[ -f /etc/systemd/system/usbguard-ttl-reaper.service ]]; then
        systemctl daemon-reload
        systemctl enable usbguard-ttl-reaper.timer
        systemctl start usbguard-ttl-reaper.timer
        systemctl is-active --quiet usbguard-ttl-reaper.timer && log_ok "TTL Reaper timer active" || log_warn "TTL Reaper timer failed"
    fi

    if [[ -f /etc/systemd/system/usbguard-web.service ]]; then
        systemctl enable usbguard-web.service || true
        systemctl start usbguard-web.service || true
        systemctl is-active --quiet usbguard-web.service && log_ok "Web service active" || log_warn "Web service failed to start"
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════
# STAGE 7: Web UI Python Environment
# ═══════════════════════════════════════════════════════════════
stage_web_ui() {
    log_header "Stage 7/9: Web UI Python Environment"

    local web_dir="/etc/usbguard/web"
    local venv_dir="${web_dir}/venv"

    mkdir -p "$web_dir"/{templates,static/css,static/js}

    # Copy web files from source if available
    if [[ -d "$SCRIPT_DIR/web" ]]; then
        [[ -f "$SCRIPT_DIR/web/app.py" ]] && cp "$SCRIPT_DIR/web/app.py" "$web_dir/"
        [[ -f "$SCRIPT_DIR/web/start-web.sh" ]] && cp "$SCRIPT_DIR/web/start-web.sh" "$web_dir/"
        [[ -f "$SCRIPT_DIR/web/templates/index.html" ]] && cp "$SCRIPT_DIR/web/templates/index.html" "$web_dir/templates/"
        [[ -f "$SCRIPT_DIR/web/static/css/style.css" ]] && cp "$SCRIPT_DIR/web/static/css/style.css" "$web_dir/static/css/"
        [[ -f "$SCRIPT_DIR/web/static/js/script.js" ]] && cp "$SCRIPT_DIR/web/static/js/script.js" "$web_dir/static/js/"
        chmod 755 "$web_dir/start-web.sh" 2>/dev/null || true
        log_ok "Web files copied"
    else
        log_warn "No web source directory found at $SCRIPT_DIR/web"
    fi

    # Setup venv
    if ! command -v python3 &>/dev/null; then
        log_error "python3 not found - cannot setup web UI"
        return 1
    fi

    if [[ ! -d "$venv_dir" ]]; then
        python3 -m venv "$venv_dir" || { log_error "venv creation failed"; return 1; }
        log_ok "Virtual environment created"
    fi

    source "$venv_dir/bin/activate"
    pip install --upgrade pip -q 2>/dev/null || true
    if ! pip install flask flask-limiter -q; then
        log_error "Flask installation failed"
        deactivate 2>/dev/null || true
        return 1
    fi
    deactivate 2>/dev/null || true
    log_ok "Flask + Flask-Limiter installed"

    chown -R root:usbadmins "$web_dir" 2>/dev/null || true
    return 0
}

# ═══════════════════════════════════════════════════════════════
# STAGE 8: Validation
# ═══════════════════════════════════════════════════════════════
stage_validation() {
    log_header "Stage 8/9: Validation"

    local val_errors=0
    local critical=(
        /etc/usbguard/usbguard.conf
        /etc/usbguard/approval-manager.conf
        /etc/usbguard/scripts/usb-approve.sh
        /etc/usbguard/scripts/cleanup-expired.sh
        /etc/usbguard/scripts/backup-rules.sh
        /etc/usbguard/scripts/restore-rules.sh
        /etc/usbguard/scripts/lib/config-reader.sh
        /etc/usbguard/scripts/lib/logger.sh
        /etc/usbguard/scripts/lib/lock.sh
        /etc/usbguard/scripts/lib/validators.sh
        /etc/usbguard/rules.d/00-system.rules
        /etc/usbguard/rules.d/50-permanent.rules
        /etc/usbguard/rules.d/90-temporary.rules
    )
    for f in "${critical[@]}"; do
        if [[ -f "$f" ]]; then
            log_ok "Exists: $f"
        else
            log_error "Missing: $f"
            ((val_errors++))
        fi
    done

    # Fix permissions on scripts
    for scr in /etc/usbguard/scripts/*.sh; do
        [[ -f "$scr" ]] || continue
        perms=$(stat -L -c "%a" "$scr" 2>/dev/null)
        [[ "$perms" == "755" ]] || { chmod 755 "$scr"; log_warn "Fixed perms on $scr"; }
    done

    # Fix rules permissions
    for rule in /etc/usbguard/rules.d/*.rules; do
        [[ -f "$rule" ]] || continue
        perms=$(stat -L -c "%a" "$rule" 2>/dev/null)
        [[ "$perms" == "600" ]] || { chmod 600 "$rule"; chown root:root "$rule"; log_warn "Fixed perms on $rule"; }
    done

    usbguard list-devices >/dev/null 2>&1 && log_ok "IPC OK" || log_warn "IPC not responding"

    local logf="/var/log/usbguard-approval.log"
    [[ -f "$logf" ]] || touch "$logf"
    chmod 660 "$logf" 2>/dev/null || true
    chown root:usbadmins "$logf" 2>/dev/null || true

    return $val_errors
}

# ═══════════════════════════════════════════════════════════════
# STAGE 9: Summary
# ═══════════════════════════════════════════════════════════════
stage_summary() {
    log_header "Stage 9/9: Summary"
    echo ""
    echo -e "${COLOR_BOLD}════════════════════════════════════════════════════════════${COLOR_RESET}"
    if [[ $ERRORS -eq 0 ]]; then
        echo -e "${COLOR_GREEN}${COLOR_BOLD}  ✅ DEPLOYMENT COMPLETED SUCCESSFULLY!${COLOR_RESET}"
        echo -e "     Warnings: ${WARNINGS}  Errors: ${ERRORS}"
        echo ""
        echo -e "  ${COLOR_CYAN}CLI:${COLOR_RESET}   sudo /etc/usbguard/scripts/usb-approve.sh"
        echo -e "  ${COLOR_CYAN}Web:${COLOR_RESET}   systemctl start usbguard-web"
        echo -e "  ${COLOR_CYAN}URL:${COLOR_RESET}   http://127.0.0.1:5000"
        echo -e "  ${COLOR_CYAN}Uninstall:${COLOR_RESET} sudo ./deploy-uninstall.sh"
    else
        echo -e "${COLOR_RED}${COLOR_BOLD}  ❌ DEPLOYMENT HAD ${ERRORS} ERROR(S)${COLOR_RESET}"
        echo -e "     Check log: ${DEPLOY_LOG}"
    fi
    echo -e "${COLOR_BOLD}════════════════════════════════════════════════════════════${COLOR_RESET}"
}

# ═══════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════
main() {
    echo -e "${COLOR_BOLD}╔══════════════════════════════════════════════╗${COLOR_RESET}"
    echo -e "${COLOR_BOLD}║  USBGuard Approval Manager v2.3 (with Web)  ║${COLOR_RESET}"
    echo -e "${COLOR_BOLD}╚══════════════════════════════════════════════╝${COLOR_RESET}"
    echo "Log: $DEPLOY_LOG"
    echo ""

    stage_preflight      || exit 1
    stage_install_deps   || exit 1
    stage_directories_and_groups || exit 1
    stage_deploy_files   || exit 1
    stage_generate_policy || true
    stage_services       || exit 1
    stage_web_ui         || log_warn "Web UI setup had issues (CLI only)"
    stage_validation     || true
    stage_summary
}

main "$@"