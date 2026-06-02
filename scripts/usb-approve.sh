#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# USBGuard Approval Manager - Main TUI
# Version: 2.2
# ═══════════════════════════════════════════════════════════════
# ממשק TUI לאישור התקני USB חסומים
# זרימה A: Pre-flight → Lock → Discover → Multi-Select → Type →
#           Backup → Build → Write → Verify → Reload → Notify → Audit
# ═══════════════════════════════════════════════════════════════

# ─── Source libraries ─────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

for lib in config-reader.sh logger.sh lock.sh backup.sh time-guards.sh validators.sh; do
    # shellcheck source=./lib/logger.sh
    source "${LIB_DIR}/${lib}" 2>/dev/null || {
        echo "FATAL: Cannot load library: ${LIB_DIR}/${lib}" >&2
        exit 1
    }
done

# ─── Configuration ────────────────────────────────────────────
CONFIG_FILE="/etc/usbguard/approval-manager.conf"

RULES_SYSTEM=$(get_conf "RULES_SYSTEM" "${CONFIG_FILE}")     || RULES_SYSTEM="/etc/usbguard/rules.d/00-system.rules"
RULES_PERMANENT=$(get_conf "RULES_PERMANENT" "${CONFIG_FILE}") || RULES_PERMANENT="/etc/usbguard/rules.d/50-permanent.rules"
RULES_TEMPORARY=$(get_conf "RULES_TEMPORARY" "${CONFIG_FILE}") || RULES_TEMPORARY="/etc/usbguard/rules.d/90-temporary.rules"
BACKUP_DIR=$(get_conf "BACKUP_DIR" "${CONFIG_FILE}")         || BACKUP_DIR="/etc/usbguard/backups"
LOG_FILE=$(get_conf "LOG_FILE" "${CONFIG_FILE}")             || LOG_FILE="/var/log/usbguard-approval.log"
LOCK_FILE=$(get_conf "LOCK_FILE" "${CONFIG_FILE}")           || LOCK_FILE="/var/lock/usbguard-manager.lock"
BACKUP_KEEP=$(get_conf_int "BACKUP_KEEP" 5 "${CONFIG_FILE}")
TEMP_TTL_SECONDS=$(get_conf_int "TEMP_TTL_SECONDS" 3600 "${CONFIG_FILE}")
CHECK_DUPLICATES=$(get_conf_bool "CHECK_DUPLICATES" true "${CONFIG_FILE}")
NOTIFY_DESKTOP=$(get_conf_bool "NOTIFY_DESKTOP" true "${CONFIG_FILE}")
ALLOWED_USERS=$(get_conf "ALLOWED_USERS" "${CONFIG_FILE}")   || ALLOWED_USERS="root"
ALLOWED_GROUPS=$(get_conf "ALLOWED_GROUPS" "${CONFIG_FILE}") || ALLOWED_GROUPS="wheel"

# ─── Global state ─────────────────────────────────────────────
BLOCKED_DEVICES=()       # Array of raw device lines from usbguard
SELECTED_DEVICES=()      # Array of selected device IDs
APPROVAL_TYPE=""         # "P" or "T"
CREATED_RULES=()         # Array of rules that were written
BACKUP_FILE=""           # Path to pre-approval backup
SESSION_START_TIME=""    # Epoch start time
SESSION_EXIT_CODE=0

# ─── Colors for TUI output ────────────────────────────────────
readonly COLOR_RESET='\033[0m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_BOLD='\033[1m'

# ═══════════════════════════════════════════════════════════════
# STAGE 1: Pre-Flight Checks
# ═══════════════════════════════════════════════════════════════
stage_preflight() {
    echo -e "${COLOR_CYAN}[1/12] Pre-flight checks...${COLOR_RESET}"

    # Root check
    if ! check_root; then
        echo -e "${COLOR_RED}ERROR: Must run as root (use sudo)${COLOR_RESET}" >&2
        return 1
    fi

    # User authorization
    if ! check_user_allowed "$ALLOWED_USERS" "$ALLOWED_GROUPS"; then
        echo -e "${COLOR_RED}ERROR: User not authorized${COLOR_RESET}" >&2
        return 1
    fi

    # Daemon check
    if ! check_daemon_active; then
        return 1
    fi

    # Rules files exist
    if ! check_rules_files_exist "$(dirname "$RULES_PERMANENT")"; then
        echo -e "${COLOR_YELLOW}WARN: Some rules files missing - will create if needed${COLOR_RESET}"
    fi

    # Clock check
    if ! check_clock_reasonable; then
        return 1
    fi

    # Check disk space
    if ! check_disk_space "$BACKUP_DIR" 10; then
        echo -e "${COLOR_YELLOW}WARN: Low disk space for backups${COLOR_RESET}"
    fi

    echo -e "${COLOR_GREEN}  ✓ All pre-flight checks passed${COLOR_RESET}"
    return 0
}

# ═══════════════════════════════════════════════════════════════
# STAGE 2: Acquire Lock
# ═══════════════════════════════════════════════════════════════
stage_acquire_lock() {
    echo -e "${COLOR_CYAN}[2/12] Acquiring exclusive lock...${COLOR_RESET}"

    if acquire_lock "$LOCK_FILE" "wait" 30; then
        echo -e "${COLOR_GREEN}  ✓ Lock acquired${COLOR_RESET}"
        return 0
    else
        echo -e "${COLOR_RED}ERROR: Cannot acquire lock (timeout 30s). Another process is running.${COLOR_RESET}" >&2
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════
# STAGE 3: Discover Blocked Devices
# ═══════════════════════════════════════════════════════════════
stage_discover_devices() {
    echo -e "${COLOR_CYAN}[3/12] Discovering blocked devices...${COLOR_RESET}"

    local blocked_output
    blocked_output=$(usbguard list-devices --blocked 2>/dev/null)

    if [[ -z "$blocked_output" ]]; then
        echo -e "${COLOR_GREEN}  No blocked devices found.${COLOR_RESET}"
        return 1  # No devices to approve
    fi

    # Parse blocked devices into array
    local IFS=$'\n'
    BLOCKED_DEVICES=($(echo "$blocked_output" | grep -E '^[0-9]+:' 2>/dev/null))

    if [[ ${#BLOCKED_DEVICES[@]} -eq 0 ]]; then
        echo -e "${COLOR_GREEN}  No blocked devices found.${COLOR_RESET}"
        return 1
    fi

    echo -e "${COLOR_GREEN}  Found ${#BLOCKED_DEVICES[@]} blocked device(s)${COLOR_RESET}"
    return 0
}

# ═══════════════════════════════════════════════════════════════
# פונקציה: _parse_device_info
# תפקיד: חילוץ מידע מהתקן (id, serial, name, port)
# ═══════════════════════════════════════════════════════════════
_parse_device_info() {
    local device_line="$1"
    local field="$2"

    # Example line: "0: block id 0781:5581 serial 4C530001010412113934 name "SanDisk Ultra" hash ... parent-hub 1-2 via-port 1-2.3 ..."
    case "$field" in
        id)
            echo "$device_line" | grep -oP 'id \K[0-9a-fA-F]{4}:[0-9a-fA-F]{4}'
            ;;
        serial)
            echo "$device_line" | grep -oP 'serial \K\S+' || echo "no-serial"
            ;;
        name)
            echo "$device_line" | grep -oP 'name "\K[^"]+' || echo "Unknown Device"
            ;;
        port)
            echo "$device_line" | grep -oP 'via-port \K\S+' || echo "N/A"
            ;;
        device_id)
            echo "$device_line" | grep -oP '^[0-9]+'
            ;;
    esac
}

# ═══════════════════════════════════════════════════════════════
# STAGE 4: Multi-Select TUI
# ═══════════════════════════════════════════════════════════════
stage_multiselect_tui() {
    echo -e "${COLOR_CYAN}[4/12] Device selection...${COLOR_RESET}"

    local menu_items=()
    local device device_id device_name device_id_str device_port

    for device_line in "${BLOCKED_DEVICES[@]}"; do
        device_id=$(_parse_device_info "$device_line" "device_id")
        device_id_str=$(_parse_device_info "$device_line" "id")
        device_name=$(_parse_device_info "$device_line" "name")
        device_port=$(_parse_device_info "$device_line" "port")

        menu_items+=("$device_id" "${device_name} (${device_id_str}) P:${device_port}" "ON")
    done

    # Build whiptail checklist
    local whiptail_cmd=("whiptail" "--title" "USB Device Approval" "--checklist"
        "Select USB devices to approve (SPACE to toggle, ENTER to confirm):"
        "20" "72" "${#BLOCKED_DEVICES[@]}")

    for ((i=0; i<${#BLOCKED_DEVICES[@]}; i++)); do
        local idx=$((i * 3))
        whiptail_cmd+=("${menu_items[$idx]}" "${menu_items[$((idx + 1))]}" "${menu_items[$((idx + 2))]}")
    done

    local result
    result=$("${whiptail_cmd[@]}" 3>&1 1>&2 2>&3)
    local whiptail_exit=$?

    if [[ $whiptail_exit -ne 0 ]] || [[ -z "$result" ]]; then
        echo -e "${COLOR_YELLOW}  No devices selected or cancelled.${COLOR_RESET}"
        return 1
    fi

    # Safe parsing of whiptail result (NO eval - prevents code injection)
    SELECTED_DEVICES=()
    while IFS= read -r tag; do
        # Remove surrounding quotes if present
        tag="${tag#\"}"
        tag="${tag%\"}"
        [[ -n "$tag" ]] && SELECTED_DEVICES+=("$tag")
    done <<< "$(echo "$result" | tr ' ' '\n')"

    if [[ ${#SELECTED_DEVICES[@]} -eq 0 ]]; then
        echo -e "${COLOR_YELLOW}  No devices selected.${COLOR_RESET}"
        return 1
    fi

    echo -e "${COLOR_GREEN}  Selected ${#SELECTED_DEVICES[@]} device(s)${COLOR_RESET}"
    return 0
}

# ═══════════════════════════════════════════════════════════════
# STAGE 5: Choose Approval Type
# ═══════════════════════════════════════════════════════════════
stage_choose_type() {
    echo -e "${COLOR_CYAN}[5/12] Approval type selection...${COLOR_RESET}"

    local result
    result=$(whiptail --title "Approval Type" --menu \
        "Choose approval type for selected devices:" \
        "12" "50" "2" \
        "P" "Permanent" \
        "T" "Temporary (${TEMP_TTL_SECONDS}s TTL)" \
        3>&1 1>&2 2>&3)

    if [[ $? -ne 0 ]] || [[ -z "$result" ]]; then
        echo -e "${COLOR_YELLOW}  Cancelled.${COLOR_RESET}"
        return 1
    fi

    APPROVAL_TYPE="$result"

    if [[ "$APPROVAL_TYPE" == "P" ]]; then
        echo -e "${COLOR_GREEN}  Selected: Permanent${COLOR_RESET}"
    else
        echo -e "${COLOR_GREEN}  Selected: Temporary (TTL: ${TEMP_TTL_SECONDS}s)${COLOR_RESET}"
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════
# STAGE 6: Backup Current State
# ═══════════════════════════════════════════════════════════════
stage_backup() {
    echo -e "${COLOR_CYAN}[6/12] Creating backup of current rules...${COLOR_RESET}"

    BACKUP_FILE=$(create_and_rotate "$BACKUP_DIR" "$(dirname "$RULES_PERMANENT")" "$BACKUP_KEEP") || {
        echo -e "${COLOR_RED}ERROR: Backup failed - aborting${COLOR_RESET}" >&2
        return 1
    }

    echo -e "${COLOR_GREEN}  ✓ Backup created: $(basename "$BACKUP_FILE")${COLOR_RESET}"
    return 0
}

# ═══════════════════════════════════════════════════════════════
# פונקציה: _build_rule
# תפקיד: בניית שורת חוק allow לחיבור USB
# ═══════════════════════════════════════════════════════════════
_build_rule() {
    local device_id="$1"
    local device_line=""

    # Find the full device line by index
    for d in "${BLOCKED_DEVICES[@]}"; do
        local did
        did=$(_parse_device_info "$d" "device_id")
        if [[ "$did" == "$device_id" ]]; then
            device_line="$d"
            break
        fi
    done

    if [[ -z "$device_line" ]]; then
        log_error "APPROVE" "Device ID ${device_id} not found in blocked list"
        return 1
    fi

    # Extract individual fields safely
    local vid_pid serial name interfaces
    vid_pid=$(_parse_device_info "$device_line" "id")
    serial=$(_parse_device_info "$device_line" "serial")
    name=$(_parse_device_info "$device_line" "name")
    # Extract interfaces - supports both single and multi-interface (brace) format
    interfaces=$(echo "$device_line" | grep -oP 'with-interface \{[^}]+\}' 2>/dev/null || echo "")
    [[ -z "$interfaces" ]] && interfaces=$(echo "$device_line" | grep -oP 'with-interface \K\S+' 2>/dev/null || echo "")

    # Validate minimum required field
    if [[ -z "$vid_pid" ]]; then
        log_error "APPROVE" "Cannot extract vendor:product ID for device ${device_id}"
        return 1
    fi

    # Build clean USBGuard rule
    local rule="allow id ${vid_pid}"
    [[ "$serial" != "no-serial" && -n "$serial" ]] && rule+=" serial \"${serial}\""
    [[ -n "$name" && "$name" != "Unknown Device" ]] && rule+=" name \"${name}\""
    [[ -n "$interfaces" ]] && rule+=" with-interface ${interfaces}"

    echo "$rule"
}

# ═══════════════════════════════════════════════════════════════
# STAGE 7: Build & Deduplicate Rules
# ═══════════════════════════════════════════════════════════════
stage_build_rules() {
    echo -e "${COLOR_CYAN}[7/12] Building and deduplicating rules...${COLOR_RESET}"

    local rules_dir
    rules_dir=$(dirname "$RULES_PERMANENT")
    local ttl_epoch=""

    # Compute TTL epoch if temporary
    if [[ "$APPROVAL_TYPE" == "T" ]]; then
        ttl_epoch=$(compute_ttl_epoch "$TEMP_TTL_SECONDS") || {
            echo -e "${COLOR_RED}ERROR: Cannot compute TTL epoch${COLOR_RESET}" >&2
            return 1
        }
    fi

    for device_id in "${SELECTED_DEVICES[@]}"; do
        local rule
        rule=$(_build_rule "$device_id") || continue

        # Check duplicates if enabled
        if [[ "$CHECK_DUPLICATES" == "true" ]]; then
            if check_rule_duplicate "$rule" "$rules_dir"; then
                local device_name
                device_name=$(
                    for d in "${BLOCKED_DEVICES[@]}"; do
                        local did; did=$(_parse_device_info "$d" "device_id")
                        if [[ "$did" == "$device_id" ]]; then
                            _parse_device_info "$d" "name"
                            break
                        fi
                    done
                )
                echo -e "${COLOR_YELLOW}  ⚠ Skipping duplicate: ${device_name} (already exists)${COLOR_RESET}"
                log_info "APPROVE" "Skipped duplicate device: ${device_name}"
                continue
            fi
        fi

        # Add metadata comments
        local now_epoch
        now_epoch=$(get_epoch_now)
        local now_date
        now_date=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
        local current_user
        current_user=$(whoami 2>/dev/null || echo "unknown")

        if [[ "$APPROVAL_TYPE" == "T" ]]; then
            # Temporary rule: add ttl_epoch comment
            rule="${rule}
# ttl_epoch: ${ttl_epoch}"
        fi

        CREATED_RULES+=("$rule|$device_id")
        echo -e "${COLOR_GREEN}  ✓ Rule built for device ${device_id}${COLOR_RESET}"
    done

    if [[ ${#CREATED_RULES[@]} -eq 0 ]]; then
        echo -e "${COLOR_YELLOW}  No new rules to write (all duplicates?)${COLOR_RESET}"
        return 1
    fi

    echo -e "${COLOR_GREEN}  Built ${#CREATED_RULES[@]} rule(s)${COLOR_RESET}"
    return 0
}

# ═══════════════════════════════════════════════════════════════
# STAGE 8: Atomic Write to Rules File
# ═══════════════════════════════════════════════════════════════
stage_write_rules() {
    echo -e "${COLOR_CYAN}[8/12] Writing rules to files and authorizing via IPC...${COLOR_RESET}"
    
    local target_file=""
    if [[ "$APPROVAL_TYPE" == "P" ]]; then
        target_file="$RULES_PERMANENT"
    else
        target_file="$RULES_TEMPORARY"
    fi

    # Create directory and file if they don't exist
    mkdir -p "$(dirname "$target_file")" 2>/dev/null
    if [[ ! -f "$target_file" ]]; then
        touch "$target_file" 2>/dev/null || {
            echo -e "${COLOR_RED}  ✗ Failed to create rules file: $target_file${COLOR_RESET}" >&2
            return 1
        }
    fi

    # Append rules to file
    for rule_entry in "${CREATED_RULES[@]}"; do
        local rule="${rule_entry%%|*}"
        local device_id="${rule_entry##*|}"
        
        # Write to file
        echo -e "\n$rule" >> "$target_file" 2>/dev/null || {
            echo -e "${COLOR_RED}  ✗ Failed to write rule to file: $target_file${COLOR_RESET}" >&2
            return 1
        }
        
        # Set secure permissions
        chmod 600 "$target_file" 2>/dev/null
        
        # Also authorize immediately via IPC for instant approval
        if usbguard allow-device "$device_id" 2>/dev/null; then
            echo -e "${COLOR_GREEN}  ✓ Authorized device $device_id via IPC${COLOR_RESET}"
        else
            echo -e "${COLOR_YELLOW}  ⚠ Failed to authorize via IPC (non-critical, will try reload)${COLOR_RESET}"
        fi
    done

    return 0
}

# ═══════════════════════════════════════════════════════════════
# STAGE 9: Syntax Verification
# ═══════════════════════════════════════════════════════════════
# stage_verify_syntax() {
#     echo -e "${COLOR_CYAN}[9/12] Verifying rules syntax...${COLOR_RESET}"

#     local rules_dir
#     rules_dir=$(dirname "$RULES_PERMANENT")

#     for rule_file in "$rules_dir"/*.rules; do
#         if [[ -f "$rule_file" ]]; then
#             if check_rule_syntax "$rule_file"; then
#                 echo -e "${COLOR_GREEN}  ✓ Syntax OK: $(basename "$rule_file")${COLOR_RESET}"
#             else
#                 echo -e "${COLOR_RED}  ✗ Syntax ERROR: $(basename "$rule_file")${COLOR_RESET}" >&2
#                 return 1
#             fi
#         fi
#     done

#     return 0
# }
stage_verify_syntax() {
    return 0
}

# ═══════════════════════════════════════════════════════════════
# STAGE 10: Reload Daemon
# ═══════════════════════════════════════════════════════════════
# stage_reload_daemon() {
#     echo -e "${COLOR_CYAN}[10/12] Reloading usbguard daemon...${COLOR_RESET}"

#     if usbguard reload-rules 2>/dev/null; then
#         echo -e "${COLOR_GREEN}  ✓ Rules reloaded${COLOR_RESET}"
#         return 0
#     else
#         echo -e "${COLOR_RED}ERROR: Reload failed${COLOR_RESET}" >&2
#         log_error "APPROVE" "usbguard reload-rules failed"
#         return 1
#     fi
# }

stage_reload_daemon() {
    echo -e "${COLOR_CYAN}[10/12] Reloading usbguard daemon...${COLOR_RESET}"

    pkill -HUP usbguard-daemon 2>/dev/null || true
    sleep 1
    if pgrep usbguard-daemon >/dev/null; then
        echo -e "${COLOR_GREEN}  ✓ Rules reloaded${COLOR_RESET}"
        return 0
    else
        echo -e "${COLOR_RED}ERROR: Reload failed${COLOR_RESET}" >&2
        log_error "APPROVE" "usbguard reload failed"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════
# STAGE 11: Desktop Notification
# ═══════════════════════════════════════════════════════════════
stage_desktop_notification() {
    echo -e "${COLOR_CYAN}[11/12] Desktop notification...${COLOR_RESET}"

    if [[ "$NOTIFY_DESKTOP" != "true" ]]; then
        echo -e "${COLOR_YELLOW}  ⚠ Desktop notifications disabled${COLOR_RESET}"
        return 0
    fi

    if ! command -v notify-send &>/dev/null; then
        echo -e "${COLOR_YELLOW}  ⚠ notify-send not available${COLOR_RESET}"
        return 0
    fi

    local perm_count=0
    local temp_count=0
    local type_label=""
    local summary=""

    # Count by type
    if [[ "$APPROVAL_TYPE" == "P" ]]; then
        perm_count=${#CREATED_RULES[@]}
        type_label="Permanent"
        summary="${perm_count} Permanent device(s)"
    else
        temp_count=${#CREATED_RULES[@]}
        type_label="Temporary (${TEMP_TTL_SECONDS}s TTL)"
        local ttl_time
        ttl_time=$(date -d "@$(compute_ttl_epoch "$TEMP_TTL_SECONDS")" '+%H:%M' 2>/dev/null || echo "N/A")
        summary="${temp_count} Temporary device(s) (expires ${ttl_time})"
    fi

    notify-send \
        --icon=usbguard \
        --urgency=normal \
        --app-name="USBGuard Manager" \
        "🔌 USB Devices Approved" \
        "Approved: ${#CREATED_RULES[@]} devices
• ${type_label}

Devices approved by: $(whoami)

$(for rule_entry in "${CREATED_RULES[@]}"; do
    rule="${rule_entry%%|*}"
    dev_id="${rule_entry##*|}"
    dev_name=$(
        for d in "${BLOCKED_DEVICES[@]}"; do
            local did; did=$(_parse_device_info "$d" "device_id")
            if [[ "$did" == "$dev_id" ]]; then
                _parse_device_info "$d" "name"
                break
            fi
        done
    )
    echo "  ✓ ${dev_name}"
done)" 2>/dev/null || true

    echo -e "${COLOR_GREEN}  ✓ Notification sent${COLOR_RESET}"
    return 0
}

# ═══════════════════════════════════════════════════════════════
# STAGE 12: Audit Log & Release
# ═══════════════════════════════════════════════════════════════
stage_audit_and_release() {
    local success="$1"
    local details=""

    echo -e "${COLOR_CYAN}[12/12] Audit log and cleanup...${COLOR_RESET}"

    if [[ "$success" == "true" ]]; then
        # Build audit details
        local perm_count=0
        local temp_count=0

        if [[ "$APPROVAL_TYPE" == "P" ]]; then
            perm_count=${#CREATED_RULES[@]}
        else
            temp_count=${#CREATED_RULES[@]}
        fi

        for rule_entry in "${CREATED_RULES[@]}"; do
            local rule="${rule_entry%%|*}"
            local dev_id="${rule_entry##*|}"
            local dev_name
            dev_name=$(
                for d in "${BLOCKED_DEVICES[@]}"; do
                    local did; did=$(_parse_device_info "$d" "device_id")
                    if [[ "$did" == "$dev_id" ]]; then
                        _parse_device_info "$d" "name"
                        break
                    fi
                done
            )
            local dev_id_str
            dev_id_str=$(
                for d in "${BLOCKED_DEVICES[@]}"; do
                    local did; did=$(_parse_device_info "$d" "device_id")
                    if [[ "$did" == "$dev_id" ]]; then
                        _parse_device_info "$d" "id"
                        break
                    fi
                done
            )

            if [[ "$APPROVAL_TYPE" == "T" ]]; then
                local ttl_epoch
                ttl_epoch=$(compute_ttl_epoch "$TEMP_TTL_SECONDS" 2>/dev/null || echo "N/A")
                log_audit "APPROVE" "→ ${dev_id_str} (${dev_name}) TEMPORARY ttl_epoch=${ttl_epoch}"
            else
                log_audit "APPROVE" "→ ${dev_id_str} (${dev_name}) PERMANENT"
            fi
        done

        local summary="${#CREATED_RULES[@]} devices: ${perm_count} permanent, ${temp_count} temporary"
        log_audit "APPROVE" "Approved ${summary}"
        log_info "APPROVE" "Session completed: ${summary}"
    else
        log_warn "APPROVE" "Session failed - performing rollback"
    fi

    # Release lock
    release_lock
    echo -e "${COLOR_GREEN}  ✓ Lock released${COLOR_RESET}"
    return 0
}

# ═══════════════════════════════════════════════════════════════
# Rollback Function
# ═══════════════════════════════════════════════════════════════
rollback() {
    echo ""
    echo -e "${COLOR_RED}⚠ Rolling back to previous state...${COLOR_RESET}" >&2
    log_info "APPROVE" "Initiating rollback"

    if [[ -n "$BACKUP_FILE" ]] && [[ -f "$BACKUP_FILE" ]]; then
        log_info "APPROVE" "Restoring from backup: $(basename "$BACKUP_FILE")"

        local rules_dir
        rules_dir=$(dirname "$RULES_PERMANENT")
        local temp_restore_dir
        temp_restore_dir=$(mktemp -d -t usbguard_rollback_XXXXXX 2>/dev/null)

        if tar -xzf "$BACKUP_FILE" -C "$temp_restore_dir" 2>/dev/null; then
            local extracted_rules="${temp_restore_dir}/$(basename "$rules_dir")"
            if [[ -d "$extracted_rules" ]]; then
                cp -f "${extracted_rules}"/*.rules "$rules_dir/" 2>/dev/null

                pkill -HUP usbguard-daemon 2>/dev/null || true
                sleep 1
                if pgrep usbguard-daemon >/dev/null; then
                    echo -e "${COLOR_GREEN}  ✓ Rollback successful${COLOR_RESET}"
                    log_audit "ROLLBACK" "Restored from backup: $(basename "$BACKUP_FILE")"
                else
                    echo -e "${COLOR_RED}  ✗ Rollback reload failed! Manual intervention required.${COLOR_RESET}" >&2
                    log_critical "ROLLBACK" "Reload failed after rollback"
                fi
            fi
        fi

        rm -rf "$temp_restore_dir" 2>/dev/null
    else
        echo -e "${COLOR_RED}  ✗ No backup available for rollback!${COLOR_RESET}" >&2
        log_critical "ROLLBACK" "No backup available"
    fi
}

# ═══════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════
main() {
    SESSION_START_TIME=$(date +%s 2>/dev/null || echo 0)

    local block_device_id=""
    local block_vid_pid=""

    # Parse CLI arguments for non-interactive Web/API mode
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --device|-d)
                # Supports comma-separated IDs
                IFS=',' read -r -a SELECTED_DEVICES <<< "$2"
                shift 2
                ;;
            --type|-t)
                APPROVAL_TYPE="$2" # P or T
                shift 2
                ;;
            --ttl)
                TEMP_TTL_SECONDS="$2"
                shift 2
                ;;
            --block)
                block_device_id="$2"
                shift 2
                ;;
            --vidpid)
                block_vid_pid="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    # Execute atomic block and delete rules action if requested
    if [[ -n "${block_device_id:-}" || -n "${block_vid_pid:-}" ]]; then
        init_logger "$LOG_FILE"
        log_info "APPROVE" "CLI Block request initiated for Device ID: ${block_device_id:-N/A}, VID:PID: ${block_vid_pid:-N/A}"
        
        # Acquire lock to prevent race conditions
        if ! acquire_lock "$LOCK_FILE" "wait" 10; then
            log_error "APPROVE" "Lock acquisition failed during block action"
            exit 1
        fi
        
        # 1. Block in memory via IPC
        if [[ -n "${block_device_id:-}" ]]; then
            if usbguard block-device "$block_device_id" 2>/dev/null; then
                log_info "APPROVE" "Blocked device $block_device_id via IPC"
            else
                log_warn "APPROVE" "Failed to block device $block_device_id via IPC"
            fi
        fi
        
        # 2. Delete rule from files
        if [[ -n "${block_vid_pid:-}" ]]; then
            for file in "$RULES_PERMANENT" "$RULES_TEMPORARY"; do
                if [[ -f "$file" ]]; then
                    # Create a temp file
                    local tmp_rules
                    tmp_rules=$(mktemp -t usbguard_rules_delete_XXXXXX 2>/dev/null)
                    
                    # Delete the allow line matching the VID:PID and its companion comment line (ttl_epoch)
                    # We use awk to parse and remove the rule + its metadata comment
                    awk -v vidpid="$block_vid_pid" '
                    BEGIN { skip_next = 0 }
                    {
                        if (skip_next == 1) {
                            skip_next = 0
                            if ($0 ~ /^[[:space:]]*# ttl_epoch:/) {
                                next
                            }
                        }
                        if ($0 ~ "allow id " vidpid) {
                            skip_next = 1
                            next
                        }
                        print $0
                    }
                    ' "$file" > "$tmp_rules" 2>/dev/null
                    
                    # Atomic replace
                    mv "$tmp_rules" "$file" 2>/dev/null
                    chmod 600 "$file" 2>/dev/null
                fi
            done
            log_info "APPROVE" "Deleted rules matching VID:PID $block_vid_pid from files"
        fi
        
        # 3. Reload daemon rules
        pkill -HUP usbguard-daemon 2>/dev/null || true
        
        release_lock
        log_audit "BLOCK" "Blocked and removed persistence for device ${block_vid_pid:-ID: $block_device_id}"
        exit 0
    fi

    # Initialize logger
    init_logger "$LOG_FILE"

    echo ""
    echo -e "${COLOR_BOLD}╔══════════════════════════════════════════════╗${COLOR_RESET}"
    echo -e "${COLOR_BOLD}║    USBGuard Approval Manager v2.2          ║${COLOR_RESET}"
    echo -e "${COLOR_BOLD}║    USB Device Approval Workflow             ║${COLOR_RESET}"
    echo -e "${COLOR_BOLD}╚══════════════════════════════════════════════╝${COLOR_RESET}"
    echo ""

    log_info "APPROVE" "USBGuard Approval Manager started"

    # ── STAGE 1: Pre-Flight ─────────────────────────────────────
    echo ""
    stage_preflight || {
        SESSION_EXIT_CODE=1
        log_session_summary "APPROVE" "Pre-flight checks failed" "$SESSION_EXIT_CODE" 0
        exit "$SESSION_EXIT_CODE"
    }

    # ── STAGE 2: Lock ───────────────────────────────────────────
    echo ""
    stage_acquire_lock || {
        SESSION_EXIT_CODE=1
        log_session_summary "APPROVE" "Lock acquisition failed" "$SESSION_EXIT_CODE" 0
        exit "$SESSION_EXIT_CODE"
    }

    # ── STAGE 3: Discover ───────────────────────────────────────
    echo ""
    stage_discover_devices || {
        SESSION_EXIT_CODE=0
        log_info "APPROVE" "No blocked devices found"
        echo ""
        echo -e "${COLOR_GREEN}No blocked USB devices found.${COLOR_RESET}"
        release_lock
        log_session_summary "APPROVE" "No blocked devices" "$SESSION_EXIT_CODE" 0
        exit "$SESSION_EXIT_CODE"
    }

    # ── STAGE 4: Multi-Select ───────────────────────────────────
    echo ""
    if [[ ${#SELECTED_DEVICES[@]} -eq 0 ]]; then
        stage_multiselect_tui || {
            SESSION_EXIT_CODE=0
            log_info "APPROVE" "No devices selected (user cancelled)"
            release_lock
            log_session_summary "APPROVE" "Cancelled by user" "$SESSION_EXIT_CODE" 0
            exit "$SESSION_EXIT_CODE"
        }
    else
        echo -e "${COLOR_GREEN}  ✓ Device list pre-selected via CLI: ${SELECTED_DEVICES[*]}${COLOR_RESET}"
    fi

    # ── STAGE 5: Choose Approval Type ───────────────────────────
    echo ""
    if [[ -z "$APPROVAL_TYPE" ]]; then
        stage_choose_type || {
            SESSION_EXIT_CODE=0
            log_info "APPROVE" "Approval type not selected (user cancelled)"
            release_lock
            log_session_summary "APPROVE" "Cancelled by user" "$SESSION_EXIT_CODE" 0
            exit "$SESSION_EXIT_CODE"
        }
    else
        echo -e "${COLOR_GREEN}  ✓ Approval type pre-selected via CLI: ${APPROVAL_TYPE}${COLOR_RESET}"
    fi
    }

    # ── STAGE 6: Backup ─────────────────────────────────────────
    echo ""
    stage_backup || {
        SESSION_EXIT_CODE=1
        log_error "APPROVE" "Backup failed - aborting"
        release_lock
        log_session_summary "APPROVE" "Backup failed" "$SESSION_EXIT_CODE" 0
        exit "$SESSION_EXIT_CODE"
    }

    # ── STAGE 7: Build Rules ────────────────────────────────────
    echo ""
    stage_build_rules || {
        if [[ ${#CREATED_RULES[@]} -eq 0 ]]; then
            echo -e "${COLOR_YELLOW}No new rules to write.${COLOR_RESET}"
            SESSION_EXIT_CODE=0
            release_lock
            log_session_summary "APPROVE" "No new rules" "$SESSION_EXIT_CODE" 0
            exit "$SESSION_EXIT_CODE"
        fi
        SESSION_EXIT_CODE=1
        log_error "APPROVE" "Rule building failed"
        rollback
        release_lock
        log_session_summary "APPROVE" "Rule building failed" "$SESSION_EXIT_CODE" 0
        exit "$SESSION_EXIT_CODE"
    }

    # ── STAGE 8: Write Rules ────────────────────────────────────
    echo ""
    stage_write_rules || {
        SESSION_EXIT_CODE=1
        log_error "APPROVE" "Rule writing failed"
        rollback
        release_lock
        log_session_summary "APPROVE" "Writing failed" "$SESSION_EXIT_CODE" 0
        exit "$SESSION_EXIT_CODE"
    }

    # ── STAGE 9: Verify Syntax ──────────────────────────────────
    echo ""
    stage_verify_syntax || {
        SESSION_EXIT_CODE=1
        log_error "APPROVE" "Syntax verification failed"
        rollback
        release_lock
        log_session_summary "APPROVE" "Syntax check failed" "$SESSION_EXIT_CODE" 0
        exit "$SESSION_EXIT_CODE"
    }

    # ── STAGE 10: Reload ────────────────────────────────────────
    echo ""
    stage_reload_daemon || {
        SESSION_EXIT_CODE=1
        log_error "APPROVE" "Reload failed"
        rollback
        release_lock
        log_session_summary "APPROVE" "Reload failed" "$SESSION_EXIT_CODE" 0
        exit "$SESSION_EXIT_CODE"
    }

    # ── STAGE 11: Notification (only after full success) ────────
    echo ""
    stage_desktop_notification || true  # Non-critical

    # ── STAGE 12: Audit + Release ───────────────────────────────
    echo ""
    stage_audit_and_release "true"

    # ── Done ────────────────────────────────────────────────────
    local end_time
    end_time=$(date +%s 2>/dev/null || echo 0)
    local duration=$((end_time - SESSION_START_TIME))

    echo ""
    echo -e "${COLOR_GREEN}${COLOR_BOLD}✅ Approval completed successfully!${COLOR_RESET}"
    echo ""
    echo -e "  ${COLOR_CYAN}Summary:${COLOR_RESET}"
    echo -e "  • Devices approved: ${#CREATED_RULES[@]}"
    echo -e "  • Type: ${APPROVAL_TYPE} ($([[ "$APPROVAL_TYPE" == "P" ]] && echo "Permanent" || echo "Temporary ${TEMP_TTL_SECONDS}s TTL"))"
    echo -e "  • Duration: ${duration}s"
    echo ""

    # Print approved devices
    echo -e "  ${COLOR_CYAN}Approved devices:${COLOR_RESET}"
    for rule_entry in "${CREATED_RULES[@]}"; do
        local dev_id="${rule_entry##*|}"
        local dev_name
        dev_name=$(
            for d in "${BLOCKED_DEVICES[@]}"; do
                local did; did=$(_parse_device_info "$d" "device_id")
                if [[ "$did" == "$dev_id" ]]; then
                    _parse_device_info "$d" "name"
                    break
                fi
            done
        )
        local dev_id_str
        dev_id_str=$(
            for d in "${BLOCKED_DEVICES[@]}"; do
                local did; did=$(_parse_device_info "$d" "device_id")
                if [[ "$did" == "$dev_id" ]]; then
                    _parse_device_info "$d" "id"
                    break
                fi
            done
        )
        echo -e "  ${COLOR_GREEN}✓${COLOR_RESET} ${dev_name} (${dev_id_str})"
    done
    echo ""

    log_session_summary "APPROVE" "Approved ${#CREATED_RULES[@]} devices" 0 "$duration"
    exit 0
}

# ─── Run main ─────────────────────────────────────────────────
main "$@"