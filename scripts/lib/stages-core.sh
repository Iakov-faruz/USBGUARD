#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# USBGuard Approval Manager - Core Stages (1-6)
# Version: 2.2
# ═══════════════════════════════════════════════════════════════
# Contains: Preflight, Lock, Discover, Multi-Select, Type, Backup
# ═══════════════════════════════════════════════════════════════

# ═══════════════════════════════════════════════════════════════
# STAGE 1: Pre-Flight Checks
# ═══════════════════════════════════════════════════════════════
stage_preflight() {
    echo -e "${COLOR_CYAN}[1/12] Pre-flight checks...${COLOR_RESET}"

    if ! check_root; then
        echo -e "${COLOR_RED}ERROR: Must run as root (use sudo)${COLOR_RESET}" >&2
        return 1
    fi

    if ! check_user_allowed "$ALLOWED_USERS" "$ALLOWED_GROUPS"; then
        echo -e "${COLOR_RED}ERROR: User not authorized${COLOR_RESET}" >&2
        return 1
    fi

    if ! check_daemon_active; then
        return 1
    fi

    if ! check_rules_files_exist "$(dirname "$RULES_PERMANENT")"; then
        echo -e "${COLOR_YELLOW}WARN: Some rules files missing - will create if needed${COLOR_RESET}"
    fi

    if ! check_clock_reasonable; then
        return 1
    fi

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
        return 1
    fi

    mapfile -t BLOCKED_DEVICES < <(echo "$blocked_output" | grep -E '^[0-9]+:' 2>/dev/null)

    if [[ ${#BLOCKED_DEVICES[@]} -eq 0 ]]; then
        echo -e "${COLOR_GREEN}  No blocked devices found.${COLOR_RESET}"
        return 1
    fi

    echo -e "${COLOR_GREEN}  Found ${#BLOCKED_DEVICES[@]} blocked device(s)${COLOR_RESET}"
    return 0
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

    SELECTED_DEVICES=()
    while IFS= read -r tag; do
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

    if [[ "$DRY_RUN_ACTIVE" == "true" ]]; then
        echo -e "${COLOR_YELLOW}  ⚠ DRY RUN: Backup would be created${COLOR_RESET}"
        return 0
    fi

    BACKUP_FILE=$(create_and_rotate "$BACKUP_DIR" "$(dirname "$RULES_PERMANENT")" "$BACKUP_KEEP") || {
        echo -e "${COLOR_RED}ERROR: Backup failed - aborting${COLOR_RESET}" >&2
        return 1
    }

    echo -e "${COLOR_GREEN}  ✓ Backup created: $(basename "$BACKUP_FILE")${COLOR_RESET}"
    return 0
}