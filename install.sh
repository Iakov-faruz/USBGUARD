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

# הקפאת שגיאות: אם פקודה נכשלת, המשתנה undefined, או pipe נכשל - תצא מיידית
set -euo pipefail

# ─── הגדרות כלליות (Configuration) ─────────────────────────────────────────────
# ספריית הסקריפט הנוכחי (המיקום שבו נמצא install.sh)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# מצב ברירת מחדל: התקנה. יכול להיות גם uninstall
MODE="install"
# dry-run = רק מדפיס מה היה עושה ללא ביצוע שינויים
DRY_RUN=false
# force = מדלג על שאלת האישור למשתמש
FORCE=false
# קובץ לוג לאחסון פלט ההתקנה
INSTALL_LOG="/var/log/usbguard-install.log"

# צבעים לפלט במסוף (להדפסה נוחה וברורה)
readonly COLOR_RESET='\033[0m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_BOLD='\033[1m'

# ─── קריאת ארגומנטים משורת הפקודה ─────────────────────────────────────────────
# פרסום פרמטרים כמו --dry-run, --force, --uninstall, --help
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run|-n) DRY_RUN=true; shift ;;
        --force|-f) FORCE=true; shift ;;
        --uninstall|-u) MODE="uninstall"; shift ;;
        --help|-h)
            echo "Usage: sudo $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --dry-run, -n   Show what would be done without making changes"
            echo "  --force, -f     Skip confirmation prompt"
            echo "  --uninstall, -u Remove all USBGuard Manager components"
            echo "  --help, -h      Show this help"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ─── פונקציות עזר ─────────────────────────────────────────────────────────────
# פונקציות לוגיות בצבעים – מקלות על קריאת הפלט
log_info()    { echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET} $*"; }
log_ok()      { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET} $*"; }
log_warn()    { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"; }
log_error()   { echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*"; }
log_section() { echo -e "\n${COLOR_BOLD}═══════════════════════════════════════════════════${COLOR_RESET}"; echo -e "${COLOR_BOLD}  $*${COLOR_RESET}"; echo -e "${COLOR_BOLD}═══════════════════════════════════════════════════${COLOR_RESET}"; }

# הרצת פקודה תוך רישום ללוג, ותמיכה במצב dry-run (רק הדפסה)
# מקבלת: כל פקודה עם הפרמטרים שלה
run_cmd() {
    if [[ "$DRY_RUN" == "true" ]]; then
        # במצב יבש: רק מראים מה היה מורץ, לא מבצעים באמת
        echo -e "${COLOR_YELLOW}  [DRY-RUN] Would execute:${COLOR_RESET} $*"
        return 0
    fi
    # ביצוע הפקודה, הפלט מוצג למסך וגם נשמר בלוג ההתקנה
    "$@" 2>&1 | tee -a "$INSTALL_LOG"
    local rc=${PIPESTATUS[0]}   # קוד יציאה של הפקודה עצמה (לא של tee)
    if [[ $rc -ne 0 ]]; then
        log_error "Command failed (rc=$rc): $*"
        return "$rc"
    fi
    return 0
}

# בדיקה שקובץ מסוים קיים – אם לא, מדפיס שגיאה ומחזיר 1 (נעשה שימוש בבדיקות טיסה)
verify_file() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        log_error "Required file not found: $path"
        log_error "Make sure you are running install.sh from the project root directory."
        return 1
    fi
    return 0
}

# ─── שלב מקדים: בדיקות טיסה (Pre-flight Checks) ──────────────────────────────
# מטרה: לוודא שהסביבה מתאימה להתקנה לפני שמתחילים לשנות דברים.
preflight_checks() {
    log_section "Pre-flight Checks"

    # 1. הרשאות root – חובה להיות root (או sudo)
    if [[ $EUID -ne 0 ]]; then
        log_error "Must run as root (use sudo)"
        exit 1
    fi
    log_ok "Running as root"

    # 2. זיהוי מערכת הפעלה (אופציונלי, רק לצורך מידע)
    if [[ ! -f /etc/os-release ]]; then
        log_warn "Cannot detect OS. Assuming Debian-based."
    else
        source /etc/os-release
        log_info "Detected OS: ${NAME} ${VERSION_ID}"
    fi

    # 3. בדיקת מבנה התיקיות הנדרש בפרויקט (אזהרה בלבד אם חסרות)
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

    # 4. בדיקת קבצים קריטיים – בלעדיהם ההתקנה לא יכולה להמשיך
    local required_files=(
        "$SCRIPT_DIR/conf/approval-manager.conf"
        "$SCRIPT_DIR/rules.d/00-system.rules"
        "$SCRIPT_DIR/rules.d/50-permanent.rules"
        "$SCRIPT_DIR/rules.d/90-temporary.rules"
        "$SCRIPT_DIR/scripts/usb-approve.sh"
        "$SCRIPT_DIR/scripts/detect-host-input.sh"      # חשוב: זיהוי מקלדת/עכבר מקומיים
        "$SCRIPT_DIR/scripts/cleanup-expired.sh"
        "$SCRIPT_DIR/scripts/healthcheck.sh"
        "$SCRIPT_DIR/scripts/badusb-monitor.py"
        "$SCRIPT_DIR/scripts/backup-rules.sh"
        "$SCRIPT_DIR/scripts/import-rules.sh"
        "$SCRIPT_DIR/scripts/export-rules.sh"
        "$SCRIPT_DIR/scripts/network-lockdown.sh"
        "$SCRIPT_DIR/web/app.py"
        "$SCRIPT_DIR/web/start-web.sh"
        "$SCRIPT_DIR/systemd/usbguard-ttl-reaper.service"
        "$SCRIPT_DIR/systemd/usbguard-ttl-reaper.timer"
        "$SCRIPT_DIR/systemd/usbguard-web.service"
        "$SCRIPT_DIR/systemd/usbguard-network-lockdown.service"
    )
    local missing=0
    for file in "${required_files[@]}"; do
        if ! verify_file "$file"; then
            missing=$((missing + 1))
        fi
    done
    if [[ $missing -gt 0 ]]; then
        log_error "${missing} required file(s) missing. Aborting."
        exit 1
    fi
    log_ok "All required files present"

    # 5. בדיקת שטח דיסק מינימלי (50MB לפחות בספריית השורש)
    local min_space=50  # MB
    local available
    available=$(df -m / 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ -n "$available" ]] && (( available < min_space )); then
        log_error "Insufficient disk space: ${available}MB (need ${min_space}MB)"
        exit 1
    fi
    log_ok "Disk space: ${available}MB available"

    # 6. בקשת אישור מהמשתמש (אם לא דילגנו עם --force)
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

# ─── שלב 1: התקנת חבילות מערכת ─────────────────────────────────────────────────
# מתקין את כל החבילות הנדרשות: usbguard, python, flask, כלי עזר וכו'.
install_system_packages() {
    log_section "Step 1/8: Installing System Packages"

    # רשימת החבילות הדרושות (עבור Debian/Ubuntu)
    local packages=(
        usbguard          # הדמון הראשי
        whiptail          # ל-TUI של אישור USB
        curl
        gawk
        util-linux
        tar
        gzip
        systemd
        python3
        python3-venv
        python3-pip
        python3-evdev     # לקריאת אירועי מקלדת/עכבר
        python3-flask     # ממשק האינטרנט
        dos2unix          # להמרת סיומות שורות
        nftables          # kernel firewall enforcement
        ntpdate           # סנכרון זמן
    )

    local installed_pkgs=()
    local missing_pkgs=()
    local upgradable_pkgs=()

    # סריקה לאילו חבילות כבר מותקנות
    log_info "Scanning package status..."
    for pkg in "${packages[@]}"; do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q " installed$"; then
            installed_pkgs+=("$pkg")
        else
            missing_pkgs+=("$pkg")
        fi
    done

    # בדיקת עדכונים זמינים (רשימת חבילות שניתן לשדרג)
    if command -v apt-get &>/dev/null; then
        apt-get update -qq 2>/dev/null
        upgradable_pkgs=($(apt list --upgradable 2>/dev/null | grep -oP '^[^/]+' | grep -xF -f <(printf "%s\n" "${packages[@]}") || true))
    fi

    # הצגת סיכום למשתמש
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

    # התקנת החבילות החסרות
    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        log_info "Installing ${#missing_pkgs[@]} missing package(s)..."
        run_cmd apt-get install -y "${missing_pkgs[@]}"
        log_ok "System packages installed"
    else
        log_ok "All system packages already installed"
    fi

    # שדרוג חבילות מיושנות (אופציונלי)
    if [[ ${#upgradable_pkgs[@]} -gt 0 ]]; then
        log_info "Upgrading ${#upgradable_pkgs[@]} package(s)..."
        run_cmd apt-get install -y "${upgradable_pkgs[@]}" --only-upgrade
        log_ok "Packages upgraded"
    fi

    # התקנת python3-usbguard (ספרייה לתקשורת עם usbguard) – דרך apt או pip כגיבוי
    log_info "Installing python3-usbguard..."
    if apt-get install -y python3-usbguard 2>/dev/null; then
        log_ok "python3-usbguard installed via apt"
    else
        log_warn "python3-usbguard not in apt repos, trying pip..."
        if pip3 install --break-system-packages usbguard 2>/dev/null; then
            log_ok "python3-usbguard installed via pip"
        else
            log_warn "Could not install python3-usbguard. The web interface will fall back to subprocess."
        fi
    fi

    # התקנת Flask-Limiter (להגבלת קצב בקשות ב-web)
    log_info "Installing Python web dependencies..."
    pip3 install --break-system-packages flask-limiter 2>/dev/null || log_warn "flask-limiter not installed (rate limiting disabled)"

    # סנכרון שעון (עוזר לתזמונים של TTL)
    ntpdate ntp.ubuntu.com 2>/dev/null || log_warn "Time sync skipped (NTP unavailable)"

    return 0
}

# ─── שלב 2: יצירת קבוצת usbadmins והוספת המשתמש הנוכחי ─────────────────────────
# קבוצה זו תקבל הרשאות לנהל את USBGuard ללא סיסמה (sudoers)
setup_groups() {
    log_section "Step 2/8: Creating Groups & Users"

    # יצירת הקבוצה אם אינה קיימת
    run_cmd groupadd -f usbadmins

    # המשתמש שהפעיל את ה-sudo (SUDO_USER) – נוסיף אותו לקבוצה
    local real_user="${SUDO_USER:-root}"
    if [[ "$real_user" != "root" ]]; then
        run_cmd usermod -aG usbadmins "$real_user"
        log_ok "Added user '${real_user}' to 'usbadmins' group"
        log_warn "You may need to log out and back in for group changes to take effect."
    fi

    log_ok "Group 'usbadmins' is ready"
    return 0
}

# ─── שלב 3: יצירת מבנה התיקיות הדרוש תחת /etc, /var ──────────────────────────
setup_directories() {
    log_section "Step 3/8: Creating Directory Structure"

    local dirs=(
        "/etc/usbguard/rules.d"            # קבצי כללי USBGuard
        "/etc/usbguard/scripts/lib"        # ספריות עזר לסקריפטים
        "/etc/usbguard/backups"            # גיבויים של כללים
        "/etc/usbguard/web/static"         # קבצי CSS, JS, images
        "/etc/usbguard/web/templates"      # תבניות HTML (Jinja2)
        "/var/lib/usbguard-manager"        # נתונים מתמשכים (למשל TTL)
        "/var/lock"                        # קבצי נעילה (lock files)
        "/var/log/usbguard"                # לוגים של הדמון
        "/var/run"                         # קבצי PID
    )

    for dir in "${dirs[@]}"; do
        run_cmd mkdir -p "$dir"
    done

    log_ok "Directory structure created"
    return 0
}

# ─── שלב 4: כתיבת קובץ התצורה של USBGuard daemon ─────────────────────────────
# קובץ זה שולט בהתנהגות הדמון: תיקיית כללים, מדיניות חסימה, IPC ועוד.
configure_usbguard() {
    log_section "Step 4/8: Configuring USBGuard Daemon"

    local daemon_conf="/etc/usbguard/usbguard-daemon.conf"

    run_cmd tee "$daemon_conf" > /dev/null << 'EOF'
# תיקיית הכללים הראשית (מפוצלת לקבצים נפרדים)
RuleFolder=/etc/usbguard/rules.d
# ברירת מחדל: לחסום כל מה שלא מוגדר במפורש
ImplicitPolicyTarget=block
# כיצד לטפל בהתקנים שכבר מחוברים בהפעלת הדמון
PresentDevicePolicy=apply-policy
# כיצד לטפל בהתקנים שמוכנסים לאחר שהדמון רץ
InsertedDevicePolicy=apply-policy
# לשחזר מצב של בקרי USB לאחר אתחול
RestoreControllerDeviceState=true
# שימוש ב-uevent לגילוי חיבור/ניתוק התקנים
DeviceManagerBackend=uevent
# משתמשים וקבוצות שיכולים לדבר עם הדמון דרך IPC
IPCAllowedUsers=root
IPCAllowedGroups=usbadmins
# תיעוד ביקורת (audit) לקובץ
AuditBackend=FileAudit
AuditFilePath=/var/log/usbguard/usbguard-audit.log
# אין להסתיר מידע רגיש (כמו serial numbers) – שימושי לאישור מדויק
HidePII=false
EOF

    run_cmd chmod 600 "$daemon_conf"
    run_cmd chown root:root "$daemon_conf"
    run_cmd mkdir -p "/etc/usbguard/IPCAccessControl.d"
    run_cmd tee "/etc/usbguard/IPCAccessControl.d/root" > /dev/null << 'EOF'
Devices=modify,list,listen
Policy=modify,list
Exceptions=listen
Parameters=modify,list,listen
EOF
    run_cmd tee "/etc/usbguard/IPCAccessControl.d/:usbadmins" > /dev/null << 'EOF'
Devices=modify,list,listen
Policy=list
Exceptions=listen
Parameters=list,listen
EOF
    run_cmd chmod 600 "/etc/usbguard/IPCAccessControl.d/root" "/etc/usbguard/IPCAccessControl.d/:usbadmins"
    run_cmd chown root:root "/etc/usbguard/IPCAccessControl.d/root" "/etc/usbguard/IPCAccessControl.d/:usbadmins"

    log_ok "USBGuard daemon configured"
    return 0
}

# ─── שלב 5: העתקת קבצי ההגדרה, הסקריפטים וספריות ה-web ────────────────────────
deploy_files() {
    log_section "Step 5/8: Deploying Configuration & Scripts"

    # 5.1 קובץ התצורה הראשי של Approval Manager
    log_info "Deploying configuration files..."
    run_cmd cp "$SCRIPT_DIR/conf/approval-manager.conf" "/etc/usbguard/"
    run_cmd chmod 600 "/etc/usbguard/approval-manager.conf"
    run_cmd chown root:root "/etc/usbguard/approval-manager.conf"

    # 5.2 קבצי הכללים (rules) – שלושה קבצים: מערכת, קבועים, זמניים
    log_info "Deploying rules files..."
    for rule in 00-system.rules 50-permanent.rules 90-temporary.rules; do
        run_cmd cp "$SCRIPT_DIR/rules.d/$rule" "/etc/usbguard/rules.d/"
        run_cmd chmod 600 "/etc/usbguard/rules.d/$rule"
        run_cmd chown root:root "/etc/usbguard/rules.d/$rule"
    done
    # הרשאות לתיקיית הכללים: root ו-usbadmins יכולים לקרוא/לכתוב
    run_cmd chmod 750 "/etc/usbguard/rules.d"
    run_cmd chown root:usbadmins "/etc/usbguard/rules.d"

    # 5.3 סקריפטים ראשיים (כולל detect-host-input.sh)
    log_info "Deploying main scripts..."
    local main_scripts=(
        healthcheck.sh          # בדיקת מוכנות ל-systemd
        usb-approve.sh          # ממשק ה-TUI לאישור התקנים
        detect-host-input.sh    # זיהוי מקלדת/עכבר מקומיים ויצירת כללים
        cleanup-expired.sh      # ניקוי כללים שפג תוקפם (TTL)
        backup-rules.sh         # גיבוי כללים
        restore-rules.sh        # שחזור כללים מגיבוי
        import-rules.sh         # יבוא כללים מקובץ חיצוני
        export-rules.sh         # ייצוא כללים לקובץ
        network-lockdown.sh     # nftables lockdown enforcement
        badusb-monitor.py       # ניטור התנהגותי להתקפות BadUSB
        usbguard-status.sh      # הצגת סטטוס התקנים מחוברים
        check-config.sh         # בדיקת תקינות תצורה
    )

    for script in "${main_scripts[@]}"; do
        local src="$SCRIPT_DIR/scripts/$script"
        if [[ -f "$src" ]]; then
            run_cmd cp "$src" "/etc/usbguard/scripts/"
            run_cmd chmod 755 "/etc/usbguard/scripts/$script"
        else
            log_warn "Script not found, skipping: $script"
        fi
    done

    # 5.4 ספריות עזר (lib) – קבצי bash שניתנים ל-sourcing
    log_info "Deploying library scripts..."
    local lib_files=(
        config-reader.sh    # קריאת קובץ התצורה
        logger.sh           # פונקציות לוג מאוחדות
        lock.sh             # מנגנון נעילה למניעת ריצות מקבילות
        backup.sh           # פונקציות גיבוי
        time-guards.sh      # פונקציות לטיפול ב-TTL (זמן חיים)
        validators.sh       # אימות פרמטרים
        stages-core.sh      # לוגיקת אישור רב-שלבי
        stages-io.sh        # קלט/פלט לשלבי האישור
        device-utils.sh     # כלים לעבודה עם מזהי התקנים
        retry.sh            # retry with exponential backoff
        telemetry.sh        # audit JSONL and metrics
        rules-validator.sh  # USBGuard rule schema validation
        network-lockdown.sh # nftables helper
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

    # בעלות על כל הסקריפטים – root בלבד (למניעת שינויים לא מורשים)
    run_cmd chown -R root:root "/etc/usbguard/scripts"

    # 5.5 ממשק ה-web (Flask)
    log_info "Deploying web application..."
    run_cmd cp "$SCRIPT_DIR/web/app.py" "/etc/usbguard/web/"
    run_cmd cp "$SCRIPT_DIR/web/start-web.sh" "/etc/usbguard/web/"
    run_cmd chmod 755 "/etc/usbguard/web/start-web.sh"
    run_cmd chmod 644 "/etc/usbguard/web/app.py"

    # העתקת קבצי סטטיים (CSS, JS) ותבניות HTML
    if [[ -d "$SCRIPT_DIR/web/static" ]]; then
        run_cmd cp -R "$SCRIPT_DIR/web/static/." "/etc/usbguard/web/static/"
    fi
    if [[ -d "$SCRIPT_DIR/web/templates" ]]; then
        run_cmd cp -R "$SCRIPT_DIR/web/templates/." "/etc/usbguard/web/templates/"
    fi

    # בעלות על קבצי ה-web: root עם קבוצת usbadmins (לקבוצה יש קריאה)
    run_cmd chown -R root:usbadmins "/etc/usbguard/web"

    log_ok "All configuration and scripts deployed"
    return 0
}

# ─── שלב 5ב: זיהוי התקני קלט מקומיים (מקלדת/עכבר) ─────────────────────────────
# מטרתו: למנוע מצב שבו המערכת חוסמת את המקלדת/עכבר של השרת עצמו.
# הסקריפט detect-host-input.sh יוצר כללים ב-00-system.rules המתירים אותם.
detect_host_input_rules() {
    log_section "Step 5b/8: Detecting Host Keyboard/Mouse"

    if [[ -x "/etc/usbguard/scripts/detect-host-input.sh" ]]; then
        run_cmd /etc/usbguard/scripts/detect-host-input.sh /etc/usbguard/rules.d/00-system.rules || \
            log_warn "Could not detect host keyboard/mouse rules"
    else
        log_warn "detect-host-input.sh not deployed"
    fi

    return 0
}

# ─── שלב 6: התקנת שירותי systemd והפעלתם ──────────────────────────────────────
install_services() {
    log_section "Step 6/8: Installing Systemd Services"

    # רשימת קבצי ה-unit (שירותים וטיימרים)
    local services=(
        "usbguard-ttl-reaper.service"   # שירות לניקוי כללים שפג תוקפם
        "usbguard-ttl-reaper.timer"     # טיימר שמפעיל את השירות מדי יום
        "usbguard-web.service"          # שירות ה-Flask web interface
        "usbguard-behavioral.service"   # ניטור התנהגותי (BadUSB)
        "usbguard-network-lockdown.service"
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

    # טעינת קבצי systemd מחדש
    run_cmd systemctl daemon-reload
    log_ok "Systemd daemon reloaded"

    # הפעלה אוטומטית (enable) והפעלה מיידית (start) של כל השירותים
    log_info "Enabling and starting services..."

    # שירות usbguard הראשי
    run_cmd systemctl enable --now usbguard || log_warn "Could not enable usbguard (already running?)"
    run_cmd systemctl restart usbguard || log_warn "Could not restart usbguard"
    sleep 2   # לתת לדמון להתבסס

    # שירות lockdown רשתי
    run_cmd systemctl enable --now usbguard-network-lockdown.service || log_warn "Could not enable/start network lockdown"

    # טיימר ה-TTL reaper
    run_cmd systemctl enable --now usbguard-ttl-reaper.timer || log_warn "Could not enable TTL reaper timer"
    run_cmd systemctl restart usbguard-ttl-reaper.service || true
    run_cmd systemctl restart usbguard-ttl-reaper.timer || true

    # שירות ה-web
    run_cmd systemctl enable --now usbguard-web.service || log_warn "Could not enable/start web service"
    run_cmd systemctl restart usbguard-web.service || log_warn "Could not restart web service"

    # שירות behavioral (אם קיים)
    if [[ -f "/etc/systemd/system/usbguard-behavioral.service" ]]; then
        run_cmd systemctl enable --now usbguard-behavioral.service || log_warn "Could not enable/start behavioral monitor"
        run_cmd systemctl restart usbguard-behavioral.service || log_warn "Could not restart behavioral monitor"
    fi

    log_ok "Services configured"
    return 0
}

# ─── שלב 7: הגדרת logrotate (סיבוב לוגים) והרשאות sudoers ─────────────────────
configure_security() {
    log_section "Step 7/8: Configuring Logrotate & Sudoers"

    # 7.1 Logrotate: ניהול אוטומטי של קבצי הלוג (גודל, דחיסה, מחיקה)
    if [[ -f "$SCRIPT_DIR/logrotate/usbguard-approval" ]]; then
        run_cmd cp "$SCRIPT_DIR/logrotate/usbguard-approval" "/etc/logrotate.d/"
        run_cmd chmod 644 "/etc/logrotate.d/usbguard-approval"
        log_ok "Logrotate configuration installed"
    else
        # יצירת קובץ logrotate ברירת מחדל אם לא סופק
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

    # 7.2 Sudoers: מתן הרשאה לקבוצת usbadmins להריץ סקריפטים מסוימים ללא סיסמה
    local sudoers_file="/etc/sudoers.d/usbguard-approval"
    local mass_storage_alias=""
    local mass_storage_alias_line=""
    if [[ -f "/etc/usbguard/scripts/usb-mass-storage-handler.sh" ]]; then
        mass_storage_alias=" USBGUARD_MASS_STORAGE"
        mass_storage_alias_line="Cmnd_Alias USBGUARD_MASS_STORAGE=/etc/usbguard/scripts/usb-mass-storage-handler.sh
"
    fi

    run_cmd tee "$sudoers_file" > /dev/null << EOF
# USBGuard Approval Manager - Sudoers Authorization
# Allows members of usbadmins group to run approval scripts without password
Cmnd_Alias USBGUARD_APPROVE=/etc/usbguard/scripts/usb-approve.sh
Cmnd_Alias USBGUARD_BACKUP=/etc/usbguard/scripts/backup-rules.sh
Cmnd_Alias USBGUARD_RESTORE=/etc/usbguard/scripts/restore-rules.sh
Cmnd_Alias USBGUARD_IMPORT=/etc/usbguard/scripts/import-rules.sh
Cmnd_Alias USBGUARD_EXPORT=/etc/usbguard/scripts/export-rules.sh
Cmnd_Alias USBGUARD_HEALTHCHECK=/etc/usbguard/scripts/healthcheck.sh
Cmnd_Alias USBGUARD_NETWORK=/etc/usbguard/scripts/network-lockdown.sh
${mass_storage_alias_line}
%usbadmins ALL=(root) NOPASSWD: USBGUARD_APPROVE, USBGUARD_BACKUP, USBGUARD_RESTORE, USBGUARD_IMPORT, USBGUARD_EXPORT, USBGUARD_HEALTHCHECK, USBGUARD_NETWORK${mass_storage_alias}
EOF

    run_cmd chmod 440 "$sudoers_file"
    run_cmd chown root:root "$sudoers_file"

    # בדיקת תקינות תחביר sudoers (visudo -c)
    if visudo -c 2>&1 | grep -q "parsed OK"; then
        log_ok "Sudoers configuration valid"
    else
        log_error "Sudoers syntax error! Check: visudo -c"
        log_error "Removing invalid sudoers file..."
        run_cmd rm -f "$sudoers_file"
        return 1
    fi

    # 7.3 יצירת קבצי לוג ריקים עם הרשאות מתאימות
    run_cmd touch "/var/log/usbguard-approval.log"
    run_cmd touch "/var/log/usbguard-approval-audit.jsonl"
    run_cmd touch "/var/log/usbguard-approval.prom"
    run_cmd touch "/var/log/usbguard-badusb.log"
    run_cmd touch "/var/log/usbguard-web.log"
    run_cmd chmod 640 "/var/log/usbguard-approval.log"
    run_cmd chmod 600 "/var/log/usbguard-approval-audit.jsonl"
    run_cmd chmod 600 "/var/log/usbguard-approval.prom"
    run_cmd chmod 600 "/var/log/usbguard-badusb.log"
    run_cmd chmod 600 "/var/log/usbguard-web.log"
    run_cmd chown root:usbadmins /var/log/usbguard-approval.log
    run_cmd chown root:root /var/log/usbguard-approval-audit.jsonl /var/log/usbguard-approval.prom /var/log/usbguard-badusb.log /var/log/usbguard-web.log

    log_ok "Security configuration complete"
    return 0
}

# ─── שלב 8: אימות סופי (final verification) ───────────────────────────────────
# בודק שהדמון רץ, טיימרים פעילים, קבצי הכללים קיימים ותקשורת IPC עובדת.
final_verification() {
    log_section "Step 8/8: Final Verification"

    local failed=0

    # 8.1 בדיקה ש-usbguard daemon פעיל
    log_info "Checking USBGuard daemon..."
    if systemctl is-active --quiet usbguard 2>/dev/null; then
        log_ok "USBGuard daemon is running"
    else
        log_error "USBGuard daemon is NOT running"
        failed=$((failed + 1))
    fi

    # 8.2 בדיקה שה-TTL reaper timer פעיל (אפשרי שיהיה disabled, זה רק אזהרה)
    log_info "Checking TTL reaper timer..."
    if systemctl is-active --quiet usbguard-ttl-reaper.timer 2>/dev/null; then
        log_ok "TTL reaper timer is active"
    else
        log_warn "TTL reaper timer is NOT active"
        log_warn "  Run: sudo systemctl enable --now usbguard-ttl-reaper.timer"
    fi

    # 8.3 בדיקת קיומם והרשאות של קבצי הכללים
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
            failed=$((failed + 1))
        fi
    done

    # 8.4 בדיקת תקשורת IPC מול הדמון (רשימת התקנים)
    log_info "Testing USBGuard IPC communication..."
    if usbguard list-devices 2>/dev/null | head -n 5 > /dev/null 2>&1; then
        log_ok "USBGuard IPC communication OK"
    else
        log_warn "USBGuard IPC test failed (may need restart)"
    fi

    # סיכום סופי
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
# הסרה מלאה (uninstall) – הפוכה להתקנה
# ═══════════════════════════════════════════════════════════════════════════════
uninstall_usbguard() {
    log_section "Full Uninstall - USBGuard Manager"

    # בקשת אישור מפורשת (נדרשת תשובה "yes")
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
        echo "Uninstall cancelled."
        exit 0
    fi
    echo ""

    # שלב 1: עצירה והשבתת כל השירותים
    log_section "Step 1/8: Stopping and disabling services"
    local all_services=(
        "usbguard"
        "usbguard-web.service"
        "usbguard-behavioral.service"
        "usbguard-network-lockdown.service"
        "usbguard-ttl-reaper.timer"
        "usbguard-ttl-reaper.service"
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

    # שלב 2: הסרת קבצי systemd (service, timer) וקישורים סימבוליים
    log_section "Step 2/8: Removing systemd service files and symlinks"
    local service_files=(
        "/etc/systemd/system/usbguard-ttl-reaper.service"
        "/etc/systemd/system/usbguard-ttl-reaper.timer"
        "/etc/systemd/system/usbguard-web.service"
        "/etc/systemd/system/usbguard-behavioral.service"
        "/etc/systemd/system/usbguard-network-lockdown.service"
        "/lib/systemd/system/usbguard.service"
        "/etc/systemd/system/usbguard.service"
    )
    for svc_file in "${service_files[@]}"; do
        if [[ -f "$svc_file" ]]; then
            rm -f "$svc_file"
            log_ok "Removed: $svc_file"
        fi
    done
    local symlinks=(
        "/etc/systemd/system/multi-user.target.wants/usbguard.service"
        "/etc/systemd/system/multi-user.target.wants/usbguard-ttl-reaper.service"
        "/etc/systemd/system/multi-user.target.wants/usbguard-web.service"
        "/etc/systemd/system/multi-user.target.wants/usbguard-behavioral.service"
        "/etc/systemd/system/multi-user.target.wants/usbguard-network-lockdown.service"
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

    # שלב 3: הסרת קבצי בינארי וספריות של usbguard
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

    # שלב 4: הסרת חבילות (apt ו-pip)
    log_section "Step 4/8: Removing packages"
    if command -v dpkg &>/dev/null; then
        for pkg in usbguard python3-usbguard python3-evdev python3-flask dos2unix nftables ntpdate; do
            if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q " installed$"; then
                apt-get remove -y "$pkg" 2>/dev/null || true
                apt-get purge -y "$pkg" 2>/dev/null || true
                log_ok "Removed package: $pkg"
            fi
        done
    fi
    if command -v pip3 &>/dev/null; then
        for pip_pkg in usbguard flask flask-limiter; do
            if pip3 list 2>/dev/null | grep -qi "^$pip_pkg "; then
                pip3 uninstall -y "$pip_pkg" 2>/dev/null || true
                log_ok "Removed pip package: $pip_pkg"
            fi
        done
    fi
    log_ok "Packages removed"

    # שלב 5: הסרת קבצי sudoers ו-logrotate
    log_section "Step 5/8: Removing sudoers and logrotate configuration"
    if [[ -f "/etc/sudoers.d/usbguard-approval" ]]; then
        rm -f /etc/sudoers.d/usbguard-approval
        log_ok "Removed: /etc/sudoers.d/usbguard-approval"
    fi
    if [[ -f "/etc/logrotate.d/usbguard-approval" ]]; then
        rm -f /etc/logrotate.d/usbguard-approval
        log_ok "Removed: /etc/logrotate.d/usbguard-approval"
    fi

    # שלב 6: מחיקת כל הקבצים והתיקיות של USBGuard Manager
    log_section "Step 6/8: Removing USBGuard Manager files and directories"
    local remove_paths=(
        "/etc/usbguard"
        "/etc/udev/rules.d/99-usbguard-mass-storage.rules"
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

    # שלב 7: הסרת קבוצת usbadmins (אחרי שהורדנו את כל המשתמשים ממנה)
    log_section "Step 7/8: Removing usbadmins group"

    if getent group usbadmins >/dev/null 2>&1; then
        local members
        members=$(getent group usbadmins | cut -d: -f4)

        # פיצול רשימת המשתמשים ללא שימוש ב־tr או Subprocess מיותר
        IFS=',' read -r -a users <<< "$members"

        for user in "${users[@]}"; do
            [[ -n "$user" ]] || continue
            gpasswd -d "$user" usbadmins 2>/dev/null || true
            log_info "Removed user '$user' from usbadmins group"
        done

        # ניסיון להסיר את הקבוצה עצמה
        if groupdel usbadmins 2>/dev/null; then
            log_ok "Group 'usbadmins' removed"
        else
            log_warn "Could not remove usbadmins group (may have other members)"
        fi
    else
        log_info "Group 'usbadmins' not found, skipping"
    fi

    # שלב 8: טעינת systemd מחדש וסיום
    log_section "Step 8/8: Final cleanup"
    systemctl daemon-reload 2>/dev/null || true
    log_ok "Systemd daemon reloaded"

    echo ""
    echo -e "${COLOR_BOLD}═══════════════════════════════════════════════════${COLOR_RESET}"
    echo -e "${COLOR_GREEN}${COLOR_BOLD}  ✅ Uninstall completed successfully!${COLOR_RESET}"
    echo -e "${COLOR_BOLD}  USBGuard Manager has been fully removed.${COLOR_RESET}"
    echo -e "${COLOR_BOLD}═══════════════════════════════════════════════════${COLOR_RESET}"
    echo ""

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN – נקודת כניסה ראשית
# ═══════════════════════════════════════════════════════════════════════════════
main() {
    # אם המצב הוא uninstall – מפעילים את פונקציית ההסרה ויוצאים
    if [[ "$MODE" == "uninstall" ]]; then
        uninstall_usbguard
        exit $?
    fi

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

    # הרצת כל השלבים בסדר הנכון
    preflight_checks || exit 1                     # בדיקות מקדימות
    install_system_packages || log_warn "Package installation had issues (continuing)"
    setup_groups || exit 1                         # יצירת קבוצה ומשתמש
    setup_directories || exit 1                    # מבנה תיקיות
    configure_usbguard || exit 1                   # תצורת הדמון
    deploy_files || exit 1                         # העתקת קבצים
    detect_host_input_rules || exit 1              # ✅ זיהוי מקלדת/עכבר (חיוני)
    install_services || exit 1                     # התקנת שירותי systemd
    configure_security || log_warn "Security configuration had issues (continuing)"

    # דילוג על אימות סופי במצב dry-run
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

# קריאה לפונקציה main עם כל הפרמטרים שהתקבלו
main "$@"
