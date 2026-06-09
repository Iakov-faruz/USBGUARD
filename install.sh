#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# USBGuard Approval Manager - Full Installation Script
# Version: 3.0 (Unified - replaces start.sh)
# ═══════════════════════════════════════════════════════════════════════════════
# התקנה אוטומטית מלאה של כל רכיבי המערכת:
#   • USBGuard daemon & rules structure
#   • Approval Manager (scripts, lib, config)
#   • Web Interface (Flask API + frontend)
#   • BadUSB Behavioral Monitor
#   • Systemd services & timers
#   • Logrotate configuration
#   • Sudoers authorization
#
# הרצה:
#   sudo ./install.sh
#   sudo ./install.sh --dry-run   (הצגת פעולות ללא ביצוע)
#   sudo ./install.sh --force     (התקנה ללא אישור)
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ─── Configuration ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=false
FORCE=false
INSTALL_LOG="/var/log/usbguard-install.log"

# צבעים לפלט
readonly COLOR_RESET='\033[0m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_BOLD='\033[1m'

# ─── Argument Parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run|-n) DRY_RUN=true; shift ;;
        --force|-f) FORCE=true; shift ;;
        --help|-h)
            echo "Usage: sudo $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --dry-run, -n   Show what would be done without making changes"
            echo "  --force, -f     Skip confirmation prompt"
            echo "  --help, -h      Show this help"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ─── Helper Functions ─────────────────────────────────────────────────────────
log_info()    { echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET} $*"; }
log_ok()      { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET} $*"; }
log_warn()    { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"; }
log_error()   { echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*"; }
log_section() { echo -e "\n${COLOR_BOLD}═══════════════════════════════════════════════════${COLOR_RESET}"; echo -e "${COLOR_BOLD}  $*${COLOR_RESET}"; echo -e "${COLOR_BOLD}═══════════════════════════════════════════════════${COLOR_RESET}"; }

run_cmd() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${COLOR_YELLOW}  [DRY-RUN] Would execute:${COLOR_RESET} $*"
        return 0
    fi
    "$@" 2>&1 | tee -a "$INSTALL_LOG" || {
        local rc=$?
        log_error "Command failed (rc=$rc): $*"
        return $rc
    }
}

verify_file() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        log_error "Required file not found: $path"
        log_error "Make sure you are running install.sh from the project root directory."
        return 1
    fi
    return 0
}

# ─── Pre-flight Checks ────────────────────────────────────────────────────────
preflight_checks() {
    log_section "Pre-flight Checks"
    
    # Root check
    if [[ $EUID -ne 0 ]]; then
        log_error "Must run as root (use sudo)"
        exit 1
    fi
    log_ok "Running as root"
    
    # System detection
    if [[ ! -f /etc/os-release ]]; then
        log_warn "Cannot detect OS. Assuming Debian-based."
    else
        source /etc/os-release
        log_info "Detected OS: ${NAME} ${VERSION_ID}"
    fi
    
    # Verify project structure
    local required_dirs=(
        "$SCRIPT_DIR/scripts"
        "$SCRIPT_DIR/scripts/lib"
        "$SCRIPT_DIR/conf"
        "$SCRIPT_DIR/rules.d"
        "$SCRIPT_DIR/systemd"
        "$SCRIPT_DIR/web"
        "$SCRIPT_DIR/web/static"
        "$SCRIPT_DIR/web/templates"
    )
    
    for dir in "${required_dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            log_warn "Missing directory: $dir (some features may be unavailable)"
        fi
    done
    
    # Verify key files
    local required_files=(
        "$SCRIPT_DIR/conf/approval-manager.conf"
        "$SCRIPT_DIR/rules.d/00-system.rules"
        "$SCRIPT_DIR/rules.d/50-permanent.rules"
        "$SCRIPT_DIR/rules.d/90-temporary.rules"
        "$SCRIPT_DIR/scripts/usb-approve.sh"
        "$SCRIPT_DIR/scripts/cleanup-expired.sh"
        "$SCRIPT_DIR/scripts/backup-rules.sh"
        "$SCRIPT_DIR/scripts/import-rules.sh"
        "$SCRIPT_DIR/scripts/export-rules.sh"
        "$SCRIPT_DIR/web/app.py"
        "$SCRIPT_DIR/web/start-web.sh"
        "$SCRIPT_DIR/systemd/usbguard-ttl-reaper.service"
        "$SCRIPT_DIR/systemd/usbguard-ttl-reaper.timer"
        "$SCRIPT_DIR/systemd/usbguard-web.service"
    )
    
    local missing=0
    for file in "${required_files[@]}"; do
        if ! verify_file "$file"; then
            ((missing++))
        fi
    done
    
    if [[ $missing -gt 0 ]]; then
        log_error "${missing} required file(s) missing. Aborting."
        exit 1
    fi
    log_ok "All required files present"
    
    # Check disk space
    local min_space=50  # MB
    local available
    available=$(df -m / 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ -n "$available" ]] && (( available < min_space )); then
        log_error "Insufficient disk space: ${available}MB (need ${min_space}MB)"
        exit 1
    fi
    log_ok "Disk space: ${available}MB available"
    
    # Confirmation prompt
    if [[ "$FORCE" != "true" ]] && [[ "$DRY_RUN" != "true" ]]; then
        echo ""
        echo -e "${COLOR_YELLOW}This will install USBGuard Approval Manager system-wide.${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}Continue? [y/N]${COLOR_RESET}"
        read -r confirm
        if [[ ! "$confirm" =~ ^[yY]$ ]]; then
            echo "Installation cancelled."
            exit 0
        fi
    fi
    
    return 0
}

# ─── Step 1: Install System Packages ──────────────────────────────────────────
install_system_packages() {
    log_section "Step 1/8: Installing System Packages"
    
    # ── Pre-check: Scan existing packages ─────────────────────────
    local packages=(
        usbguard
        whiptail
        gawk
        util-linux
        tar
        gzip
        systemd
        python3
        python3-pip
        python3-evdev
        python3-flask
        dos2unix
        ntpdate
    )
    
    local installed_pkgs=()
    local missing_pkgs=()
    local upgradable_pkgs=()
    
    log_info "Scanning package status..."
    for pkg in "${packages[@]}"; do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q " installed$"; then
            installed_pkgs+=("$pkg")
        else
            missing_pkgs+=("$pkg")
        fi
    done
    
    # Check for upgradable packages
    if command -v apt-get &>/dev/null; then
        apt-get update -qq 2>/dev/null
        upgradable_pkgs=($(apt list --upgradable 2>/dev/null | grep -oP '^[^/]+' | grep -xF -f <(printf "%s\n" "${packages[@]}") || true))
    fi
    
    # ── Summary report ────────────────────────────────────────────
    echo ""
    log_info "Package status summary:"
    echo -e "  ${COLOR_GREEN}✓ Already installed: ${#installed_pkgs[@]}/${#packages[@]}${COLOR_RESET}"
    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        echo -e "  ${COLOR_YELLOW}▸ Will install: ${missing_pkgs[*]}${COLOR_RESET}"
    fi
    if [[ ${#upgradable_pkgs[@]} -gt 0 ]]; then
        echo -e "  ${COLOR_CYAN}▸ Upgradable: ${upgradable_pkgs[*]}${COLOR_RESET}"
    fi
    echo ""
    
    # ── Install missing packages ──────────────────────────────────
    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        log_info "Installing ${#missing_pkgs[@]} missing package(s)..."
        run_cmd apt-get install -y "${missing_pkgs[@]}"
        log_ok "System packages installed"
    else
        log_ok "All system packages already installed"
    fi
    
    # ── Upgrade outdated packages ─────────────────────────────────
    if [[ ${#upgradable_pkgs[@]} -gt 0 ]]; then
        log_info "Upgrading ${#upgradable_pkgs[@]} package(s)..."
        run_cmd apt-get install -y "${upgradable_pkgs[@]}" --only-upgrade
        log_ok "Packages upgraded"
    fi
    
    # Install python3-usbguard (may not be in all repos, try pip as fallback)
    log_info "Installing python3-usbguard..."
    if apt-get install -y python3-usbguard 2>/dev/null; then
        log_ok "python3-usbguard installed via apt"
    else
        log_warn "python3-usbguard not in apt repos, trying pip..."
        if pip3 install usbguard 2>/dev/null; then
            log_ok "python3-usbguard installed via pip"
        else
            log_warn "Could not install python3-usbguard. The web interface will fall back to subprocess."
        fi
    fi
    
    # Install Flask-Limiter
    log_info "Installing Python web dependencies..."
    pip3 install flask-limiter 2>/dev/null || log_warn "flask-limiter not installed (rate limiting disabled)"
    
    # Try to sync time
    ntpdate ntp.ubuntu.com 2>/dev/null || log_warn "Time sync skipped (NTP unavailable)"
    
    return 0
}

# ─── Step 2: Create Group & User Structure ────────────────────────────────────
setup_groups() {
    log_section "Step 2/8: Creating Groups & Users"
    
    run_cmd groupadd -f usbadmins
    
    # Get the original user (the one who invoked sudo)
    local real_user="${SUDO_USER:-root}"
    if [[ "$real_user" != "root" ]]; then
        run_cmd usermod -aG usbadmins "$real_user"
        log_ok "Added user '${real_user}' to 'usbadmins' group"
        log_warn "You may need to log out and back in for group changes to take effect."
    fi
    
    log_ok "Group 'usbadmins' is ready"
    return 0
}

# ─── Step 3: Create Directory Structure ───────────────────────────────────────
setup_directories() {
    log_section "Step 3/8: Creating Directory Structure"
    
    local dirs=(
        "/etc/usbguard/rules.d"
        "/etc/usbguard/scripts/lib"
        "/etc/usbguard/backups"
        "/etc/usbguard/web/static"
        "/etc/usbguard/web/templates"
        "/var/lib/usbguard-manager"
        "/var/lock"
        "/var/log/usbguard"
        "/var/run"
    )
    
    for dir in "${dirs[@]}"; do
        run_cmd mkdir -p "$dir"
    done
    
    log_ok "Directory structure created"
    return 0
}

# ─── Step 4: Configure USBGuard Daemon ────────────────────────────────────────
configure_usbguard() {
    log_section "Step 4/8: Configuring USBGuard Daemon"
    
    local daemon_conf="/etc/usbguard/usbguard-daemon.conf"
    
    run_cmd tee "$daemon_conf" > /dev/null << 'EOF'
RuleFolder=/etc/usbguard/rules.d
ImplicitPolicyTarget=block
PresentDevicePolicy=apply-policy
InsertedDevicePolicy=apply-policy
RestoreControllerDeviceState=true
DeviceManagerBackend=uevent
IPCAllowedUsers=root
IPCAllowedGroups=usbadmins
AuditBackend=FileAudit
AuditFilePath=/var/log/usbguard/usbguard-audit.log
HidePII=false
EOF
    
    run_cmd chmod 600 "$daemon_conf"
    run_cmd chown root:root "$daemon_conf"
    
    log_ok "USBGuard daemon configured"
    return 0
}

# ─── Step 5: Deploy Scripts & Configuration Files ─────────────────────────────
deploy_files() {
    log_section "Step 5/8: Deploying Configuration & Scripts"
    
    # ── Configuration ─────────────────────────────────────────────
    log_info "Deploying configuration files..."
    run_cmd cp "$SCRIPT_DIR/conf/approval-manager.conf" "/etc/usbguard/"
    run_cmd chmod 600 "/etc/usbguard/approval-manager.conf"
    run_cmd chown root:root "/etc/usbguard/approval-manager.conf"
    
    # ── Rules files ───────────────────────────────────────────────
    log_info "Deploying rules files..."
    for rule in 00-system.rules 50-permanent.rules 90-temporary.rules; do
        run_cmd cp "$SCRIPT_DIR/rules.d/$rule" "/etc/usbguard/rules.d/"
        run_cmd chmod 600 "/etc/usbguard/rules.d/$rule"
        run_cmd chown root:root "/etc/usbguard/rules.d/$rule"
    done
    
    # ── Main scripts ──────────────────────────────────────────────
    log_info "Deploying main scripts..."
    local main_scripts=(
        usb-approve.sh
        cleanup-expired.sh
        backup-rules.sh
        restore-rules.sh
        import-rules.sh
        export-rules.sh
        badusb-monitor.py
        usbguard-status.sh
        check-config.sh
    )
    
    for script in "${main_scripts[@]}"; do
        local src="$SCRIPT_DIR/scripts/$script"
        if [[ -f "$src" ]]; then
            run_cmd cp "$src" "/etc/usbguard/scripts/"
            # Set executable permission for scripts, standard for .py as well
            run_cmd chmod 755 "/etc/usbguard/scripts/$script"
        else
            log_warn "Script not found, skipping: $script"
        fi
    done
    
    # ── Library scripts ───────────────────────────────────────────
    log_info "Deploying library scripts..."
    local lib_files=(
        config-reader.sh
        logger.sh
        lock.sh
        backup.sh
        time-guards.sh
        validators.sh
    )
    
    for lib in "${lib_files[@]}"; do
        local src="$SCRIPT_DIR/scripts/lib/$lib"
        if [[ -f "$src" ]]; then
            run_cmd cp "$src" "/etc/usbguard/scripts/lib/"
            run_cmd chmod 640 "/etc/usbguard/scripts/lib/$lib"
        else
            log_warn "Library not found, skipping: $lib"
        fi
    done
    
    # Set ownership for all scripts
    run_cmd chown -R root:root "/etc/usbguard/scripts"
    
    # ── Web application ───────────────────────────────────────────
    log_info "Deploying web application..."
    run_cmd cp "$SCRIPT_DIR/web/app.py" "/etc/usbguard/web/"
    run_cmd cp "$SCRIPT_DIR/web/start-web.sh" "/etc/usbguard/web/"
    run_cmd chmod 755 "/etc/usbguard/web/start-web.sh"
    run_cmd chmod 644 "/etc/usbguard/web/app.py"
    
    # Copy static files
    if [[ -d "$SCRIPT_DIR/web/static" ]]; then
        run_cmd cp -r "$SCRIPT_DIR/web/static/"* "/etc/usbguard/web/static/"
    fi
    if [[ -d "$SCRIPT_DIR/web/templates" ]]; then
        run_cmd cp -r "$SCRIPT_DIR/web/templates/"* "/etc/usbguard/web/templates/"
    fi
    
    run_cmd chown -R root:usbadmins "/etc/usbguard/web"
    
    log_ok "All configuration and scripts deployed"
    return 0
}

# ─── Step 6: Install Systemd Services ────────────────────────────────────────
install_services() {
    log_section "Step 6/8: Installing Systemd Services"
    
    local services=(
        "usbguard-ttl-reaper.service"
        "usbguard-ttl-reaper.timer"
        "usbguard-web.service"
        "usbguard-behavioral.service"
    )
    
    for service in "${services[@]}"; do
        local src="$SCRIPT_DIR/systemd/$service"
        if [[ -f "$src" ]]; then
            run_cmd cp "$src" "/etc/systemd/system/"
            run_cmd chmod 644 "/etc/systemd/system/$service"
            log_ok "Installed: $service"
        else
            log_warn "Service file not found: $service"
        fi
    done
    
    run_cmd systemctl daemon-reload
    log_ok "Systemd daemon reloaded"
    
    # Enable and start services
    log_info "Enabling and starting services..."
    
    run_cmd systemctl enable --now usbguard || log_warn "Could not enable usbguard (already running?)"
    sleep 2
    
    run_cmd systemctl enable --now usbguard-ttl-reaper.timer || log_warn "Could not enable TTL reaper timer"
    run_cmd systemctl enable usbguard-web.service || log_warn "Could not enable web service"
    
    # Enable behavioral service if the file exists
    if [[ -f "/etc/systemd/system/usbguard-behavioral.service" ]]; then
        run_cmd systemctl enable usbguard-behavioral.service || log_warn "Could not enable behavioral monitor"
    fi
    
    log_ok "Services configured"
    return 0
}

# ─── Step 7: Configure Logrotate & Sudoers ────────────────────────────────────
configure_security() {
    log_section "Step 7/8: Configuring Logrotate & Sudoers"
    
    # ── Logrotate ─────────────────────────────────────────────────
    if [[ -f "$SCRIPT_DIR/logrotate/usbguard-approval" ]]; then
        run_cmd cp "$SCRIPT_DIR/logrotate/usbguard-approval" "/etc/logrotate.d/"
        run_cmd chmod 644 "/etc/logrotate.d/usbguard-approval"
        log_ok "Logrotate configuration installed"
    else
        # Create default logrotate config
        run_cmd tee "/etc/logrotate.d/usbguard-approval" > /dev/null << 'EOF'
/var/log/usbguard-*.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 660 root usbadmins
    sharedscripts
    postrotate
        /bin/systemctl reload usbguard-web.service 2>/dev/null || true
    endscript
}
EOF
        log_ok "Default logrotate configuration created"
    fi
    
    # ── Sudoers ───────────────────────────────────────────────────
    local sudoers_file="/etc/sudoers.d/usbguard-approval"
    run_cmd tee "$sudoers_file" > /dev/null << 'EOF'
# USBGuard Approval Manager - Sudoers Authorization
# Allows members of usbadmins group to run approval scripts without password
Cmnd_Alias USBGUARD_APPROVE=/etc/usbguard/scripts/usb-approve.sh
Cmnd_Alias USBGUARD_BACKUP=/etc/usbguard/scripts/backup-rules.sh
Cmnd_Alias USBGUARD_RESTORE=/etc/usbguard/scripts/restore-rules.sh
Cmnd_Alias USBGUARD_IMPORT=/etc/usbguard/scripts/import-rules.sh
Cmnd_Alias USBGUARD_EXPORT=/etc/usbguard/scripts/export-rules.sh

%usbadmins ALL=(root) NOPASSWD: USBGUARD_APPROVE, USBGUARD_BACKUP, USBGUARD_RESTORE, USBGUARD_IMPORT, USBGUARD_EXPORT
EOF
    
    run_cmd chmod 440 "$sudoers_file"
    run_cmd chown root:root "$sudoers_file"
    
    # Validate sudoers syntax
    if visudo -c 2>&1 | grep -q "parsed OK"; then
        log_ok "Sudoers configuration valid"
    else
        log_error "Sudoers syntax error! Check: visudo -c"
        log_error "Removing invalid sudoers file..."
        run_cmd rm -f "$sudoers_file"
        return 1
    fi
    
    # ── Log files ─────────────────────────────────────────────────
    run_cmd touch "/var/log/usbguard-approval.log"
    run_cmd touch "/var/log/usbguard-badusb.log"
    run_cmd touch "/var/log/usbguard-web.log"
    run_cmd chmod 660 "/var/log/usbguard-approval.log"
    run_cmd chmod 660 "/var/log/usbguard-badusb.log"
    run_cmd chmod 660 "/var/log/usbguard-web.log"
    run_cmd chown root:usbadmins /var/log/usbguard-approval.log /var/log/usbguard-badusb.log /var/log/usbguard-web.log
    
    log_ok "Security configuration complete"
    return 0
}

# ─── Step 8: Final Verification ───────────────────────────────────────────────
final_verification() {
    log_section "Step 8/8: Final Verification"
    
    local failed=0
    
    # Check USBGuard daemon
    log_info "Checking USBGuard daemon..."
    if systemctl is-active --quiet usbguard 2>/dev/null; then
        log_ok "USBGuard daemon is running"
    else
        log_error "USBGuard daemon is NOT running"
        ((failed++))
    fi
    
    # Check TTL reaper timer
    log_info "Checking TTL reaper timer..."
    if systemctl is-active --quiet usbguard-ttl-reaper.timer 2>/dev/null; then
        log_ok "TTL reaper timer is active"
    else
        log_warn "TTL reaper timer is NOT active"
        log_warn "  Run: sudo systemctl enable --now usbguard-ttl-reaper.timer"
    fi
    
    # Check rules files
    log_info "Checking rules files..."
    for rule in 00-system.rules 50-permanent.rules 90-temporary.rules; do
        local path="/etc/usbguard/rules.d/$rule"
        if [[ -f "$path" ]]; then
            local perms
            perms=$(stat -c "%a" "$path" 2>/dev/null)
            if [[ "$perms" == "600" ]]; then
                log_ok "$rule (permissions: $perms)"
            else
                log_warn "$rule has permissions $perms (expected 600)"
            fi
        else
            log_error "$rule not found"
            ((failed++))
        fi
    done
    
    # Test usbguard IPC
    log_info "Testing USBGuard IPC communication..."
    if usbguard list-devices 2>/dev/null | head -n 5 > /dev/null 2>&1; then
        log_ok "USBGuard IPC communication OK"
    else
        log_warn "USBGuard IPC test failed (may need restart)"
    fi
    
    # Summary
    echo ""
    echo -e "${COLOR_BOLD}═══════════════════════════════════════════════════${COLOR_RESET}"
    if [[ $failed -eq 0 ]]; then
        echo -e "${COLOR_GREEN}${COLOR_BOLD}  ✅ Installation completed successfully!${COLOR_RESET}"
    else
        echo -e "${COLOR_YELLOW}${COLOR_BOLD}  ⚠️  Installation completed with ${failed} issue(s)${COLOR_RESET}"
    fi
    echo -e "${COLOR_BOLD}═══════════════════════════════════════════════════${COLOR_RESET}"
    echo ""
    echo -e "  ${COLOR_CYAN}Web Interface:${COLOR_RESET}  http://127.0.0.1:5000"
    echo -e "  ${COLOR_CYAN}TUI Approval:${COLOR_RESET}  sudo /etc/usbguard/scripts/usb-approve.sh"
    echo -e "  ${COLOR_CYAN}Logs:${COLOR_RESET}          /var/log/usbguard-*.log"
    echo -e "  ${COLOR_CYAN}Rules dir:${COLOR_RESET}     /etc/usbguard/rules.d/"
    echo -e "  ${COLOR_CYAN}Config:${COLOR_RESET}        /etc/usbguard/approval-manager.conf"
    echo ""
    
    if [[ $failed -gt 0 ]]; then
        echo -e "  ${COLOR_YELLOW}Some checks failed. Review the messages above and correct manually.${COLOR_RESET}"
        echo -e "  ${COLOR_YELLOW}Common fixes:${COLOR_RESET}"
        echo -e "  • sudo systemctl restart usbguard"
        echo -e "  • sudo systemctl start usbguard-web.service"
        echo -e "  • sudo systemctl start usbguard-behavioral.service"
        echo ""
    fi
    
    return $failed
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════
main() {
    local start_time
    start_time=$(date +%s)
    
    echo ""
    echo -e "${COLOR_BOLD}╔══════════════════════════════════════════════════════════════╗${COLOR_RESET}"
    echo -e "${COLOR_BOLD}║       USBGuard Approval Manager v3.0 - Installation       ║${COLOR_RESET}"
    echo -e "${COLOR_BOLD}╚══════════════════════════════════════════════════════════════╝${COLOR_RESET}"
    echo ""
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${COLOR_YELLOW}  --- DRY RUN MODE ---${COLOR_RESET}"
        echo ""
    fi
    
    # Run all stages
    preflight_checks || exit 1
    install_system_packages || log_warn "Package installation had issues (continuing)"
    setup_groups || exit 1
    setup_directories || exit 1
    configure_usbguard || exit 1
    deploy_files || exit 1
    install_services || exit 1
    configure_security || log_warn "Security configuration had issues (continuing)"
    
    # Skip final verification in dry-run mode
    if [[ "$DRY_RUN" != "true" ]]; then
        final_verification || true
    else
        echo ""
        echo -e "${COLOR_YELLOW}${COLOR_BOLD}  Dry run completed. No changes were made.${COLOR_RESET}"
        echo ""
    fi
    
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    echo -e "  ${COLOR_CYAN}Installation duration: ${duration}s${COLOR_RESET}"
    echo ""
    
    return 0
}

main "$@"