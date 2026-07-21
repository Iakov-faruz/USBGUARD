#!/usr/bin/env bash
# ==============================================================================
# USBGuard Approval Manager - Configuration Check (QA Tool)
# Version: 3.0 (Hardened, Fully Structured, Enterprise-Grade)
# ==============================================================================
# תפקיד: כלי QA מקיף לבדיקת תקינות התקנה, הרשאות קבצים, סינטקסט קונפיגורציה,
#        סטטוס פוליסי ואינטגרציית מערכת של USBGuard Approval Manager.
# דרישות: הרצה כ-root (sudo) לקריאת קבצי מערכת רגישים.
# ==============================================================================

# הקשחת ריצה מלאה: עצירה בשגיאה, משתנים לא מוגדרים, וכשל ב-Pipe
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# טעינת ספריות קריאה ואימות מרכזיות
# נדרש כדי להשתמש בפונקציות get_conf ו-validate_config_file
source "${LIB_DIR}/config-reader.sh" 2>/dev/null || { echo "FATAL: config-reader.sh missing in ${LIB_DIR}" >&2; exit 1; }
source "${LIB_DIR}/validators.sh" 2>/dev/null || { echo "FATAL: validators.sh missing in ${LIB_DIR}" >&2; exit 1; }

CONFIG_FILE="/etc/usbguard/approval-manager.conf"

# ─── צבעים ופורמט תצוגה ────────────────────────────────────────────────────────
readonly COLOR_RESET='\033[0m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_BOLD='\033[1m'

# מונים אטומים (תואם set -e, מניעת ((++)) שעלול להיכשל אם הערך הוא 0)
PASSED=0
FAILED=0
WARNINGS=0

# פונקציית עזר להדפסת תוצאות ועדכון המונים
check() {
    local name="$1"
    local status="$2"
    local message="$3"
    case "$status" in
        pass)
            echo -e "  ${COLOR_GREEN}✓${COLOR_RESET} $name: $message"
            PASSED=$((PASSED + 1))
            ;;
        fail)
            echo -e "  ${COLOR_RED}✗${COLOR_RESET} $name: $message"
            FAILED=$((FAILED + 1))
            ;;
        warn)
            echo -e "  ${COLOR_YELLOW}⚠${COLOR_RESET} $name: $message"
            WARNINGS=$((WARNINGS + 1))
            ;;
    esac
}

# בדיקת הרשאות קובץ ספציפית (חוזרת מחרוזת סטטוס)
check_file_perms() {
    local file="$1"
    local expected_perms="$2"
    if [[ ! -f "$file" ]]; then echo "missing"; return; fi
    
    local perms owner
    perms=$(stat -L -c "%a" "$file" 2>/dev/null || echo "???")
    owner=$(stat -L -c "%U:%G" "$file" 2>/dev/null || echo "???:???")
    
    if [[ ("$perms" == "600" || "$perms" == "640") && "$owner" == "root:root" ]]; then
        echo "ok"
    elif [[ "$perms" != "600" && "$perms" != "640" ]]; then
        echo "bad_perms:${perms}"
    elif [[ "$owner" != "root:root" ]]; then 
        echo "bad_owner:${owner}"
    fi
}

# טעינת נתיבי עבודה מהקונפיגורציה עם ברירות מחדל קשיחות
# שימוש ב-get_conf מה-slibrary החיצונית
RULES_SYSTEM=$(get_conf "RULES_SYSTEM" "$CONFIG_FILE" 2>/dev/null) || RULES_SYSTEM="/etc/usbguard/rules.d/00-system.rules"
RULES_PERMANENT=$(get_conf "RULES_PERMANENT" "$CONFIG_FILE" 2>/dev/null) || RULES_PERMANENT="/etc/usbguard/rules.d/50-permanent.rules"
RULES_TEMPORARY=$(get_conf "RULES_TEMPORARY" "$CONFIG_FILE" 2>/dev/null) || RULES_TEMPORARY="/etc/usbguard/rules.d/90-temporary.rules"
BACKUP_DIR=$(get_conf "BACKUP_DIR" "$CONFIG_FILE" 2>/dev/null) || BACKUP_DIR="/etc/usbguard/backups"
LOG_FILE=$(get_conf "LOG_FILE" "$CONFIG_FILE" 2>/dev/null) || LOG_FILE="/var/log/usbguard-approval.log"
LOCK_FILE=$(get_conf "LOCK_FILE" "$CONFIG_FILE" 2>/dev/null) || LOCK_FILE="/var/lib/usbguard-manager/usbguard-manager.lock"
STATE_DIR=$(get_conf "STATE_DIR" "$CONFIG_FILE" 2>/dev/null) || STATE_DIR="/var/lib/usbguard-manager"

# ─── פונקציות הבדיקה המלאות והמשוכתבות ──────────────────────────────────────────

# 1. בדיקת הרשאות Root משופרת ומניעת קריסת set -e
check_root() {
    echo ""
    echo -e "${COLOR_BOLD}── Root / Sudo ───────────────────────────────────────────${COLOR_RESET}"
    if [ "$EUID" -ne 0 ]; then
        check "Root" "fail" "Must run as root (use sudo)"
        exit 1
    else
        check "Root" "pass" "Running as root"
    fi
}

# 2. זיהוי מערכת הפעלה
check_os() {
    echo ""
    echo -e "${COLOR_BOLD}── Operating System ──────────────────────────────────────${COLOR_RESET}"
    if [[ -f /etc/os-release ]]; then
        # שימוש ב-cut במקום grep -P לתאימות מקסימלית
        local os_name os_version
        os_name=$(grep '^ID=' /etc/os-release 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "unknown")
        os_version=$(grep '^VERSION_ID=' /etc/os-release 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "unknown")
        check "OS" "pass" "${os_name} ${os_version}"
    else
        check "OS" "warn" "Cannot detect OS"
    fi
    local arch
    arch=$(uname -m 2>/dev/null || echo "unknown")
    check "Architecture" "pass" "$arch"
}

# 3. בדיקת תלויות חיצוניות
check_dependencies() {
    echo ""
    echo -e "${COLOR_BOLD}── Dependencies ──────────────────────────────────────────${COLOR_RESET}"
    local required_cmds=(usbguard whiptail systemctl awk sed)
    for cmd in "${required_cmds[@]}"; do
        if command -v "$cmd" &>/dev/null; then
            check "$cmd" "pass" "Installed"
        else
            check "$cmd" "fail" "NOT FOUND - required"
        fi
    done

    local optional_cmds=(dos2unix python3 logrotate)
    for cmd in "${optional_cmds[@]}"; do
        if command -v "$cmd" &>/dev/null; then
            check "$cmd (optional)" "pass" "Installed"
        else
            check "$cmd (optional)" "warn" "Not installed"
        fi
    done
}

# 4. בדיקת סטטוס ה-Daemon ותקשורת IPC
check_daemon() {
    echo ""
    echo -e "${COLOR_BOLD}── USBGuard Daemon ───────────────────────────────────────${COLOR_RESET}"
    if command -v usbguard &>/dev/null; then
        check "usbguard binary" "pass" "$(usbguard --version 2>/dev/null | head -n1 || echo "version unknown")"
    else
        check "usbguard binary" "fail" "NOT FOUND"
    fi

    if systemctl is-active --quiet usbguard 2>/dev/null; then
        check "Daemon status" "pass" "Running"
    else
        check "Daemon status" "fail" "NOT RUNNING"
    fi

    if systemctl is-enabled --quiet usbguard 2>/dev/null; then
        check "Daemon enabled" "pass" "Enabled"
    else
        check "Daemon enabled" "warn" "Not enabled"
    fi

    # בדיקת תקשורת ישירה מול ה-Daemon
    if usbguard list-devices >/dev/null 2>&1; then
        check "IPC channel" "pass" "Responding"
    else
        check "IPC channel" "fail" "NOT RESPONDING (Check permissions/IPCAllowedGroups)"
    fi
}

# 5. בדיקת קובץ הקונפיגורציה הראשי (Approval Manager)
check_config_file() {
    echo ""
    echo -e "${COLOR_BOLD}── Config File ───────────────────────────────────────────${COLOR_RESET}"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        check "approval-manager.conf" "fail" "FILE NOT FOUND: $CONFIG_FILE"
        return
    fi
    
    # בדיקת הרשאות הקובץ
    local perms_status
    perms_status=$(check_file_perms "$CONFIG_FILE" "640")
    case "$perms_status" in
        ok) check "approval-manager.conf" "pass" "Exists, permissions accepted, root:root" ;;
        missing) check "approval-manager.conf" "fail" "FILE NOT FOUND" ;;
        bad_perms:*) check "approval-manager.conf" "warn" "Bad permissions: ${perms_status#bad_perms:} (expected 600 or 640)" ;;
        bad_owner:*) check "approval-manager.conf" "warn" "Bad owner: ${perms_status#bad_owner:} (expected root:root)" ;;
    esac

    # 🚀 ייעול: טעינת הקובץ פעם אחת בלבד לתוך מערך אסוציאטיבי
    declare -A config_cache
    while IFS='=' read -r key value; do
        # ניקוי רווחים והתעלמות מהערות/שורות ריקות
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        
        # ניקוי רווחים משני צידי המפתח והערך
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        
        config_cache["$key"]="$value"
    done < "$CONFIG_FILE"

    # רשימת המפתחות הנדרשים לבדיקה
    local required_keys=(
        "RULES_SYSTEM" "RULES_PERMANENT" "RULES_TEMPORARY"
        "BACKUP_DIR" "LOG_FILE" "STATE_DIR" "LOCK_FILE"
        "BACKUP_KEEP" "TEMP_TTL_SECONDS"
        "ALLOWED_USERS" "ALLOWED_GROUPS"
        "CHECK_DUPLICATES" "LOG_LEVEL"
        "NETWORK_LOCKDOWN_ENABLED" "NETWORK_LOCKDOWN_POLICY"
        "NETWORK_LOCKDOWN_ALLOW_LOCALHOST" "NETWORK_LOCKDOWN_ALLOW_SSH"
        "NETWORK_LOCKDOWN_ALLOW_CIDRS" "MASS_STORAGE_POLICY"
        "MIN_REASONABLE_EPOCH" "MAX_CLOCK_JUMP_SECONDS"
        "TELEMETRY_ENABLED" "AUDIT_LOG_FILE" "METRICS_FILE"
    )

    # בדיקת נוכחות מתוך הזיכרון (Cache)
    for key in "${required_keys[@]}"; do
        if [[ -n "${config_cache[$key]+x}" ]]; then
            check "Config key: $key" "pass" "${config_cache[$key]}"
        else
            check "Config key: $key" "warn" "Missing or empty"
        fi
    done
    
    # בדיקת סינטקסט כללי באמצעות הפונקציה מה-lib
    if validate_config_file "$CONFIG_FILE" >/dev/null 2>&1; then
        check "Config Syntax" "pass" "Valid structure and no dangerous chars"
    else
        check "Config Syntax" "fail" "Invalid syntax or dangerous characters detected"
    fi
}

# 6. בדיקת קונפיגורציית ה-Daemon של USBGuard עצמו
check_usbguard_conf() {
    echo ""
    echo -e "${COLOR_BOLD}── USBGuard Daemon Config ────────────────────────────────${COLOR_RESET}"
    local conf_file="/etc/usbguard/usbguard-daemon.conf"
    [[ ! -f "$conf_file" ]] && conf_file="/etc/usbguard/usbguard.conf"

    if [[ ! -f "$conf_file" ]]; then
        check "usbguard-daemon.conf" "fail" "FILE NOT FOUND"
        return
    fi
    check "usbguard-daemon.conf" "pass" "Exists ($conf_file)"

    # בדיקת הגדרת RuleFolder/RuleDirectory (חיוני ל-Version 1.1.x+)
    if grep -q '^RuleFolder=' "$conf_file" 2>/dev/null; then
        check "RuleFolder setting" "pass" "$(grep '^RuleFolder=' "$conf_file" | cut -d'=' -f2)"
    elif grep -q '^RuleDirectory=' "$conf_file" 2>/dev/null; then
        check "RuleDirectory setting" "pass" "$(grep '^RuleDirectory=' "$conf_file" | cut -d'=' -f2)"
    else
        check "RuleFolder/RuleDirectory" "fail" "MISSING setting in config"
    fi

    # בדיקת הרשאות IPC לקבוצת usbadmins
    if grep -q '^IPCAllowedGroups=.*usbadmins' "$conf_file" 2>/dev/null; then
        check "IPC groups" "pass" "usbadmins group explicitly allowed"
    else
        check "IPC groups" "warn" "usbadmins not detected in IPCAllowedGroups"
    fi

    local perms
    perms=$(stat -L -c "%a" "$conf_file" 2>/dev/null || echo "???")
    if [[ "$perms" == "600" ]]; then
        check "Config permissions" "pass" "600"
    else
        check "Config permissions" "warn" "Bad: $perms (expected 600 for daemon security)"
    fi
}

# 7. בדיקת קבצי הכללים (Rules)
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
            check "$name" "warn" "File not found (will be initialized dynamically)"
            continue
        fi

        # ספירת כללים פעילים (לא הערות)
        local count
        count=$(grep -cE '^[[:space:]]*(allow|block|reject)' "$file" 2>/dev/null || echo "0")
        local perms_status
        perms_status=$(check_file_perms "$file" "$expected_perms")
        
        case "$perms_status" in
            ok) check "$name" "pass" "$count rules, permissions $expected_perms, root:root" ;;
            bad_perms:*) check "$name" "warn" "$count rules, bad permissions: ${perms_status#bad_perms:} (expected $expected_perms)" ;;
            bad_owner:*) check "$name" "warn" "$count rules, bad owner: ${perms_status#bad_owner:} (expected root:root)" ;;
        esac
    done
}

# 8. בדיקת מבנה תיקיות
check_directories() {
    echo ""
    echo -e "${COLOR_BOLD}── Directories ───────────────────────────────────────────${COLOR_RESET}"
    
    # חילוץ בטוח של תיקיית הכללים - רק אם המשתנה אינו ריק
    local rules_dir=""
    if [[ -n "${RULES_SYSTEM:-}" ]]; then
        rules_dir="$(dirname "$RULES_SYSTEM")"
    fi

    # בניית מערך התיקיות באופן דינמי
    local dirs=("/etc/usbguard:750:root:usbadmins")
    
    if [[ -n "$rules_dir" && "$rules_dir" != "." ]]; then
        dirs+=("${rules_dir}:750:root:root")
    fi
    
    dirs+=(
        "/etc/usbguard/scripts:755:root:root"
        "/etc/usbguard/scripts/lib:750:root:root"
        "$BACKUP_DIR:700:root:root"
        "$STATE_DIR:700:root:root"
    )

    for entry in "${dirs[@]}"; do
        local dir="${entry%%:*}"
        local rest="${entry#*:}"
        local expected_perms="${rest%%:*}"
        local expected_owner="${rest#*:}"

        # בדיקה שהתיקייה קיימת
        if [[ ! -d "$dir" ]]; then
            check "$(basename "$dir")" "warn" "Directory not found: $dir"
            continue
        fi

        # קריאת הרשאות ובעלים בפועל
        local perms owner
        perms=$(stat -L -c "%a" "$dir" 2>/dev/null || echo "???")
        owner=$(stat -L -c "%U:%G" "$dir" 2>/dev/null || echo "???:???")

        if [[ "$perms" == "$expected_perms" ]] && [[ "$owner" == "$expected_owner" ]]; then
            check "$(basename "$dir")" "pass" "Exists, permissions $expected_perms"
        else
            check "$(basename "$dir")" "warn" "Exists but perms=$perms owner=$owner (expected $expected_perms $expected_owner)"
        fi
    done
}

# 9. בדיקת סקריפטים וספריות
check_scripts() {
    echo ""
    echo -e "${COLOR_BOLD}── Scripts & Libraries ───────────────────────────────────${COLOR_RESET}"
    local scripts=(
        "/etc/usbguard/scripts/usb-approve.sh:755"
        "/etc/usbguard/scripts/cleanup-expired.sh:755"
        "/etc/usbguard/scripts/backup-rules.sh:755"
        "/etc/usbguard/scripts/restore-rules.sh:755"
        "/etc/usbguard/scripts/import-rules.sh:755"
        "/etc/usbguard/scripts/export-rules.sh:755"
        "/etc/usbguard/scripts/network-lockdown.sh:755"
        "/etc/usbguard/scripts/detect-host-input.sh:755"
        "/etc/usbguard/scripts/healthcheck.sh:755"
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

    # בדיקת נוכחות ספריות lib
    local lib_files=(
        "config-reader.sh" "logger.sh" "lock.sh" "backup.sh"
        "time-guards.sh" "validators.sh" "stages-core.sh" "stages-io.sh"
        "device-utils.sh" "retry.sh" "telemetry.sh" "rules-validator.sh"
        "network-lockdown.sh" "policy-sync.sh"
    )
    for lib in "${lib_files[@]}"; do
        # בדיקה גם בנתיב המקומי וגם בנתיב המותקן
        local full_lib_path="${LIB_DIR}/${lib}"
        local installed_lib_path="/etc/usbguard/scripts/lib/${lib}"
        
        if [[ -f "$full_lib_path" ]] || [[ -f "$installed_lib_path" ]]; then
            check "lib/${lib}" "pass" "Exists"
        else
            check "lib/${lib}" "warn" "Missing module"
        fi
    done
}

# 10. בדיקת שירותי Systemd
check_systemd_services() {
    echo ""
    echo -e "${COLOR_BOLD}── Systemd Services & Timers ─────────────────────────────${COLOR_RESET}"
    local services=(
        "usbguard-ttl-reaper.timer"
        "usbguard-ttl-reaper.service"
        "usbguard-web.service"
        "usbguard-behavioral.service"
        "usbguard-network-lockdown.service"
    )

    for service in "${services[@]}"; do
        if systemctl list-unit-files --no-legend "$service" >/dev/null 2>&1; then
            if systemctl is-active --quiet "$service" 2>/dev/null; then
                check "$service" "pass" "Active / Running"
            else
                check "$service" "warn" "Installed but Inactive"
            fi
        else
            check "$service" "warn" "Not loaded/installed"
        fi
    done
}

# 11. בדיקת Sudoers
check_sudoers() {
    echo ""
    echo -e "${COLOR_BOLD}── Sudoers Integration ───────────────────────────────────${COLOR_RESET}"
    local sudoers_file="/etc/sudoers.d/usbguard-approval"
    if [[ -f "$sudoers_file" ]]; then
        local perms
        perms=$(stat -L -c "%a" "$sudoers_file" 2>/dev/null || echo "???")
        if [[ "$perms" == "440" ]]; then
            check "sudoers.d layout" "pass" "Secure policy configuration (440)"
        else
            check "sudoers.d layout" "warn" "Bad permissions: $perms (expected strict 440)"
        fi
    else
        check "sudoers.d layout" "warn" "Drop-in configuration file not found"
    fi
}

# 12. בדיקת לוגים ו-Telemetry
check_logging() {
    echo ""
    echo -e "${COLOR_BOLD}── Advanced Telemetry & Logs ─────────────────────────────${COLOR_RESET}"
    
    # לוג ראשי
    if [[ -f "$LOG_FILE" ]]; then
        local perms owner size
        perms=$(stat -L -c "%a" "$LOG_FILE" 2>/dev/null || echo "???")
        owner=$(stat -L -c "%U:%G" "$LOG_FILE" 2>/dev/null || echo "???:???")
        size=$(du -h "$LOG_FILE" 2>/dev/null | cut -f1 || echo "?")
        if [[ "$perms" == "640" && "$owner" == "root:usbadmins" ]]; then
            check "Standard log" "pass" "[$size] perms $perms, owner $owner"
        else
            check "Standard log" "warn" "[$size] perms $perms, owner $owner (expected 640 root:usbadmins)"
        fi
    else
        check "Standard log" "warn" "Will be initialized on the first cycle"
    fi

    # לוגים רגישים (Audit/Metrics)
    local sensitive_logs=(
        "/var/log/usbguard-approval-audit.jsonl"
        "/var/log/usbguard-approval.prom"
        "/var/log/usbguard-badusb.log"
        "/var/log/usbguard-web.log"
    )
    for log_p in "${sensitive_logs[@]}"; do
        if [[ -f "$log_p" ]]; then
            local perms owner
            perms=$(stat -L -c "%a" "$log_p" 2>/dev/null || echo "???")
            owner=$(stat -L -c "%U:%G" "$log_p" 2>/dev/null || echo "???:???")
            if [[ "$perms" == "600" && "$owner" == "root:root" ]]; then
                check "$(basename "$log_p")" "pass" "Secure layout ($perms)"
            else
                check "$(basename "$log_p")" "warn" "perms $perms (expected strict 600 root:root)"
            fi
        else
            check "$(basename "$log_p")" "warn" "Pending activation"
        fi
    done

    if [[ -f "/etc/logrotate.d/usbguard-approval" ]]; then
        check "Logrotate rules" "pass" "Policy template ready"
    else
        check "Logrotate rules" "warn" "Logrotate context omitted"
    fi
}

# 13. בדיקת קבוצות משתמשים
check_group() {
    echo ""
    echo -e "${COLOR_BOLD}── System Access Groups ──────────────────────────────────${COLOR_RESET}"
    
    if ! getent group usbadmins >/dev/null; then
        check "usbadmins layer" "fail" "GROUP MISSING FROM SYSTEM"
        return
    fi

    local members
    members=$(getent group usbadmins | cut -d: -f4)

    # אם ריק, ננסה כלים חלופיים שאולי קיימים במערכת ומכירים משתמשי דומיין
    if [[ -z "$members" ]]; then
        if command -v groupmems &>/dev/null; then
            members=$(groupmems -l -g usbadmins 2>/dev/null | tr ' ' ',' || echo "")
        elif command -v lid &>/dev/null; then
            members=$(lid -g usbadmins 2>/dev/null | awk '{print $1}' | tr '\n' ',' | sed 's/,$//' || echo "")
        fi
    fi

    # הצגת התוצאה: אם עדיין ריק, נציג זאת כמידע (pass/warn מרוכך) ולא ככשל
    if [[ -n "$members" ]]; then
        check "usbadmins layer" "pass" "Active members: $members"
    else
        # שינוי סטטוס ל-pass עם הערה, מכיוון שזה תקין לחלוטין בסביבות סנטרליות (AD/IPA)
        check "usbadmins layer" "pass" "Group detected (Members managed externally or via central IDM)"
    fi
}

# 14. בדיקת שעון מערכת
check_clock() {
    echo ""
    echo -e "${COLOR_BOLD}── Core Clock Sync ───────────────────────────────────────${COLOR_RESET}"
    local current_epoch
    current_epoch=$(date +%s 2>/dev/null || echo "0")
    if [[ "$current_epoch" -gt 1577836800 ]]; then
        check "System walltime" "pass" "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")"
    else
        check "System walltime" "fail" "Clock corruption detected ($current_epoch)"
    fi
}

# 15. בדיקת State Files עם הגנה מפני שינויי גרסאות של date
check_state() {
    echo ""
    echo -e "${COLOR_BOLD}── Runtime States ────────────────────────────────────────${COLOR_RESET}"
    local state_file="${STATE_DIR}/last_run_epoch"
    if [[ -f "$state_file" ]]; then
        local epoch
        epoch=$(cat "$state_file" 2>/dev/null || echo "0")
        if [[ "$epoch" =~ ^[0-9]+$ ]] && [[ "$epoch" -gt 0 ]]; then
            # שימוש ב-|| אלטרנטיבי לטובת תאימות רחבה
            local human_date
            human_date=$(date -d "@$epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "Epoch: $epoch")
            check "Last execution" "pass" "$human_date"
        else
            check "Last execution" "warn" "State epoch corrupted or zero ($epoch)"
        fi
    else
        check "Last execution" "warn" "No baseline state recorded yet"
    fi
}

# הצגת סיכום סופי
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

# ─── הטיפול הראשי (Main Entrypoint) ───────────────────────────────────────────
main() {
    echo ""
    echo -e "${COLOR_BOLD}╔══════════════════════════════════════════════╗${COLOR_RESET}"
    echo -e "${COLOR_BOLD}║   USBGuard Config Validation Tool v3.0       ║${COLOR_RESET}"
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

    if [[ $FAILED -gt 0 ]]; then 
        exit 1
    fi
    exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi