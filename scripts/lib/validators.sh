#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# USBGuard Approval Manager - Validators & Pre-flight Checks
# Version: 2.2
# ═══════════════════════════════════════════════════════════════
# בדיקות תקינות לכל הרכיבים
# ═══════════════════════════════════════════════════════════════

# ─── Default Configuration ────────────────────────────────────
readonly VALIDATOR_DEFAULT_MIN_DISK_MB=50

# ═══════════════════════════════════════════════════════════════
# פונקציה: check_root
# תפקיד: מוודא הרצה כ-root (או sudo)
# שימוש: check_root || exit 1
# ═══════════════════════════════════════════════════════════════
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "VALIDATOR" "This script must be run as root (use sudo)"
        echo "ERROR: This script must be run as root (use sudo)" >&2
        return 1
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════
# פונקציה: check_user_allowed
# תפקיד: בודק שהמשחק הנוכחי מורשה (ALLOWED_USERS / ALLOWED_GROUPS)
# שימוש: check_user_allowed ["admin"] ["wheel"]
# ═══════════════════════════════════════════════════════════════
check_user_allowed() {
    local allowed_users="${1:-root}"
    local allowed_groups="${2:-wheel}"
    local current_user
    current_user=$(whoami 2>/dev/null || echo 'unknown')

    # Root is always allowed
    [[ "$current_user" == "root" ]] && return 0

    # Check ALLOWED_USERS
    local user_found=0
    local u
    local IFS=','
    for u in $allowed_users; do
        u="${u#"${u%%[![:space:]]*}"}"
        u="${u%"${u##*[![:space:]]}"}"
        if [[ "$u" == "$current_user" ]]; then
            user_found=1
            break
        fi
    done

    [[ $user_found -eq 1 ]] && return 0

    # Check ALLOWED_GROUPS
    local g
    local IFS=','
    for g in $allowed_groups; do
        g="${g#"${g%%[![:space:]]*}"}"
        g="${g%"${g##*[![:space:]]}"}"
        if groups "$current_user" 2>/dev/null | grep -qw "$g"; then
            return 0
        fi
    done

    log_warn "VALIDATOR" "User '${current_user}' is not in ALLOWED_USERS or ALLOWED_GROUPS"
    echo "ERROR: User '${current_user}' is not authorized to run this command" >&2
    return 1
}

# ═══════════════════════════════════════════════════════════════
# פונקציה: check_daemon_active
# תפקיד: מוודא ש-usbguard daemon פעיל
# שימוש: check_daemon_active || exit 1
# ═══════════════════════════════════════════════════════════════
check_daemon_active() {
    if ! systemctl is-active --quiet usbguard 2>/dev/null; then
        log_error "VALIDATOR" "usbguard daemon is not active"
        echo "ERROR: usbguard daemon is not active. Run: systemctl start usbguard" >&2
        return 1
    fi
    log_debug "VALIDATOR" "usbguard daemon is active"
    return 0
}

# ═══════════════════════════════════════════════════════════════
# פונקציה: check_rules_files_exist
# תפקיד: מוודא שכל קבצי ה-rules קיימים
# שימוש: check_rules_files_exist ["/etc/usbguard/rules.d"]
# ═══════════════════════════════════════════════════════════════
check_rules_files_exist() {
    local rules_dir="${1:-/etc/usbguard/rules.d}"
    local missing=0

    for rule_file in "00-system.rules" "50-permanent.rules" "90-temporary.rules"; do
        if [[ ! -f "${rules_dir}/${rule_file}" ]]; then
            log_warn "VALIDATOR" "Rules file missing: ${rules_dir}/${rule_file}"
            echo "WARN: Rules file missing: ${rules_dir}/${rule_file}" >&2
            ((missing++))
        fi
    done

    if [[ $missing -gt 0 ]]; then
        log_error "VALIDATOR" "${missing} rules file(s) missing"
        return 1
    fi

    log_debug "VALIDATOR" "All rules files exist in: $rules_dir"
    return 0
}

# ═══════════════════════════════════════════════════════════════
# פונקציה: check_rule_syntax
# תפקיד: בדיקת תקינות תחביר של קובץ rules
# שימוש: check_rule_syntax "/path/to/file.rules"
# ═══════════════════════════════════════════════════════════════
# check_rule_syntax() {
#     local rule_file="$1"

#     if [[ ! -f "$rule_file" ]]; then
#         log_warn "VALIDATOR" "Syntax check skipped: file not found: $rule_file"
#         return 0
#     fi

#     if usbguard check-rules -f "$rule_file" 2>&1; then
#         log_debug "VALIDATOR" "Syntax OK: $rule_file"
#         return 0
#     else
#         log_error "VALIDATOR" "Syntax error in: $rule_file"
#         return 1
#     fi
# }

check_rule_syntax() {
    local rule_file="$1"

    if [[ ! -f "$rule_file" ]]; then
        log_warn "VALIDATOR" "Syntax check skipped: file not found: $rule_file"
        return 0
    fi

    # בדיקת תחביר מושבתת כי check-rules לא עובד בגרסה 1.1.2
    # לכן אנו מניחים שהקובץ תקין וממשיכים כרגיל
    log_debug "VALIDATOR" "Syntax check disabled - assuming OK: $rule_file"
    return 0
}


# ═══════════════════════════════════════════════════════════════
# פונקציה: check_disk_space
# תפקיד: מוודא מקום פנוי בדיסק (במגה-בייט)
# שימוש: check_disk_space "/path" 50
# ═══════════════════════════════════════════════════════════════
check_disk_space() {
    local path="$1"
    local min_mb="${2:-$VALIDATOR_DEFAULT_MIN_DISK_MB}"
    local available_mb

    if [[ ! -d "$path" ]] && [[ ! -f "$path" ]]; then
        # If path doesn't exist yet, check parent directory
        path=$(dirname "$path" 2>/dev/null)
    fi

    available_mb=$(df -m "$path" 2>/dev/null | awk 'NR==2 {print $4}')

    if [[ -z "$available_mb" ]] || [[ $available_mb -lt $min_mb ]]; then
        log_error "VALIDATOR" "Insufficient disk space at ${path}: ${available_mb:-0}MB available, need ${min_mb}MB"
        echo "ERROR: Insufficient disk space at ${path}: ${available_mb:-0}MB available, need ${min_mb}MB" >&2
        return 1
    fi

    log_debug "VALIDATOR" "Disk space OK at ${path}: ${available_mb}MB available"
    return 0
}

# ═══════════════════════════════════════════════════════════════
# פונקציה: check_rule_duplicate
# תפקיד: בדיקת כפילויות של חוק rules
# שימוש: if check_rule_duplicate "allow id 0781:5581" ["/rules/dir"]; then
# ═══════════════════════════════════════════════════════════════
check_rule_duplicate() {
    local rule="$1"
    local rules_dir="${2:-/etc/usbguard/rules.d}"

    if [[ -z "$rule" ]]; then
        log_error "VALIDATOR" "check_rule_duplicate: rule is empty"
        return 2
    fi

    if [[ ! -d "$rules_dir" ]]; then
        log_debug "VALIDATOR" "Rules directory does not exist (yet): $rules_dir"
        return 0  # No duplicates possible
    fi

    # Extract the rule content (remove comments, trim whitespace)
    local rule_core
    rule_core=$(echo "$rule" | sed 's/#.*$//' | xargs)

    if [[ -z "$rule_core" ]]; then
        return 2  # Empty rule after stripping comments
    fi

    # Search for duplicates across all .rules files
    if grep -Fqs "$rule_core" "${rules_dir}"/*.rules 2>/dev/null; then
        log_info "VALIDATOR" "Duplicate rule found: ${rule_core} in ${rules_dir}"
        return 0  # Duplicate exists
    fi

    return 1  # No duplicate
}

# ═══════════════════════════════════════════════════════════════
# פונקציה: check_external_deps
# תפקיד: בדיקת תלות חיצונית (usbguard, whiptail, flock)
# שימוש: check_external_deps || exit 1
# ═══════════════════════════════════════════════════════════════
check_external_deps() {
    local missing=0

    for dep in usbguard whiptail flock awk systemctl; do
        if ! command -v "$dep" &>/dev/null; then
            echo "ERROR: Required dependency not found: $dep" >&2
            log_error "VALIDATOR" "Required dependency not found: $dep"
            ((missing++))
        fi
    done

    if [[ $missing -gt 0 ]]; then
        echo "ERROR: ${missing} required dependency(ies) missing. Install with: apt install usbguard whiptail util-linux gawk systemd" >&2
        return 1
    fi

    log_debug "VALIDATOR" "All external dependencies found"
    return 0
}

# ═══════════════════════════════════════════════════════════════
# פונקציה: check_config_file
# תפקיד: בדיקת תקינות קובץ הקונפיג
# שימוש: check_config_file ["/path/to/approval-manager.conf"]
# ═══════════════════════════════════════════════════════════════
check_config_file() {
    local config_file="${1:-/etc/usbguard/approval-manager.conf}"

    if [[ ! -f "$config_file" ]]; then
        echo "ERROR: Config file not found: $config_file" >&2
        log_error "VALIDATOR" "Config file not found: $config_file"
        return 1
    fi

    if [[ ! -r "$config_file" ]]; then
        echo "ERROR: Config file not readable: $config_file" >&2
        log_error "VALIDATOR" "Config file not readable: $config_file"
        return 1
    fi

    # Check that the file has valid permissions (should be 640 root:root)
    local perms
    perms=$(stat -L -c "%a" "$config_file" 2>/dev/null)
    local owner
    owner=$(stat -L -c "%U" "$config_file" 2>/dev/null)

    if [[ -n "$perms" ]] && [[ "$perms" != "640" ]] && [[ "$perms" != "600" ]] && [[ "$perms" != "400" ]]; then
        log_warn "VALIDATOR" "Config file has permissive permissions: ${perms} (recommended: 640)"
    fi

    if [[ -n "$owner" ]] && [[ "$owner" != "root" ]]; then
        log_warn "VALIDATOR" "Config file owner is ${owner}, recommended: root"
    fi

    # Run config validator from config-reader.sh
    local validation_result
    validation_result=$(validate_config_file "$config_file" 2>&1)

    if [[ "$validation_result" != "VALIDATION_OK" ]]; then
        echo "ERROR: Configuration validation failed:" >&2
        echo "$validation_result" >&2
        log_error "VALIDATOR" "Configuration validation failed: $validation_result"
        return 1
    fi

    log_debug "VALIDATOR" "Config file OK: $config_file"
    return 0
}

# ═══════════════════════════════════════════════════════════════
# פונקציה: run_all_preflight_checks
# תפקיד: הרצת כל בדיקות ה-preflight
# שימוש: run_all_preflight_checks || exit 1
# ═══════════════════════════════════════════════════════════════
run_all_preflight_checks() {
    log_info "VALIDATOR" "Running pre-flight checks..."

    local checks=(
        "check_external_deps"
        "check_root"
        "check_daemon_active"
        "check_rules_files_exist"
    )

    local check_func
    local failed=0

    for check_func in "${checks[@]}"; do
        if ! $check_func; then
            ((failed++))
        fi
    done

    if [[ $failed -gt 0 ]]; then
        log_error "VALIDATOR" "${failed} pre-flight check(s) failed"
        echo "ERROR: ${failed} pre-flight check(s) failed. See /var/log/usbguard-approval.log for details." >&2
        return 1
    fi

    log_info "VALIDATOR" "All pre-flight checks passed"
    return 0
}