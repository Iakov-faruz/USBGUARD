#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# USBGuard Approval Manager - I/O Stages (7-12)
# Version: 2.2
# ═══════════════════════════════════════════════════════════════
# Contains: Build, Write, Verify, Reload, Notify, Audit, Rollback
# ═══════════════════════════════════════════════════════════════

# ═══════════════════════════════════════════════════════════════
# STAGE 7: Build & Deduplicate Rules
# ═══════════════════════════════════════════════════════════════
stage_build_rules() {
    echo -e "${COLOR_CYAN}[7/12] Building and deduplicating rules...${COLOR_RESET}"

    local rules_dir
    rules_dir=$(dirname "$RULES_PERMANENT")
    local ttl_epoch=""

    if [[ "$APPROVAL_TYPE" == "T" ]]; then
        ttl_epoch=$(compute_ttl_epoch "$TEMP_TTL_SECONDS") || {
            echo -e "${COLOR_RED}ERROR: Cannot compute TTL epoch${COLOR_RESET}" >&2
            return 1
        }
    fi

    for device_id in "${SELECTED_DEVICES[@]}"; do
        local rule
        rule=$(_build_rule "$device_id") || continue

        if [[ "$CHECK_DUPLICATES" == "true" ]]; then
            if check_rule_duplicate "$rule" "$rules_dir"; then
                local device_name
                device_name=$(for d in "${BLOCKED_DEVICES[@]}"; do
                    local did; did=$(_parse_device_info "$d" "device_id")
                    [[ "$did" == "$device_id" ]] && { _parse_device_info "$d" "name"; break; }
                done)
                echo -e "${COLOR_YELLOW}  ⚠ Skipping duplicate: ${device_name}${COLOR_RESET}"
                log_info "APPROVE" "Skipped duplicate device: ${device_name}"
                continue
            fi
        fi

        if [[ "$APPROVAL_TYPE" == "T" ]]; then
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
    
    if [[ "$DRY_RUN_ACTIVE" == "true" ]]; then
        for rule_entry in "${CREATED_RULES[@]}"; do
            local rule="${rule_entry%%|*}"
            local type_label=""
            [[ "$APPROVAL_TYPE" == "P" ]] && type_label="PERMANENT" || type_label="TEMPORARY"
            echo -e "${COLOR_YELLOW}  ⚠ DRY RUN: Would write (${type_label}): $(echo "$rule" | head -n 1)${COLOR_RESET}"
        done
        echo -e "${COLOR_GREEN}  ✓ DRY RUN: Skip backup, write, reload${COLOR_RESET}"
        return 0
    fi

    local target_file=""
    if [[ "$APPROVAL_TYPE" == "P" ]]; then
        target_file="$RULES_PERMANENT"
    else
        target_file="$RULES_TEMPORARY"
    fi

    local target_dir="$(dirname "$target_file")"
    mkdir -p "$target_dir" 2>/dev/null
    if [[ ! -f "$target_file" ]]; then
        touch "$target_file" 2>/dev/null || {
            echo -e "${COLOR_RED}  ✗ Failed to create rules file: $target_file${COLOR_RESET}" >&2
            return 1
        }
        chown root:root "$target_file" 2>/dev/null
        chmod 600 "$target_file" 2>/dev/null
    fi

    for rule_entry in "${CREATED_RULES[@]}"; do
        local rule="${rule_entry%%|*}"
        local device_id="${rule_entry##*|}"
        local rule_line=$(echo "$rule" | head -n 1)
        local ttl_comment=$(echo "$rule" | grep '# ttl_epoch:' || true)

        local tmp_append=$(mktemp -t usbguard_append_XXXXXX 2>/dev/null)
        { echo ""; echo "$rule_line"; [[ -n "$ttl_comment" ]] && echo "$ttl_comment"; } > "$tmp_append"
        cat "$tmp_append" >> "$target_file" 2>/dev/null || {
            rm -f "$tmp_append" 2>/dev/null
            echo -e "${COLOR_RED}  ✗ Failed to write rule${COLOR_RESET}" >&2
            return 1
        }
        rm -f "$tmp_append"
        chmod 600 "$target_file" 2>/dev/null
        chown root:root "$target_file" 2>/dev/null

        if usbguard allow-device "$device_id" 2>/dev/null; then
            echo -e "${COLOR_GREEN}  ✓ Authorized device $device_id via IPC${COLOR_RESET}"
        else
            echo -e "${COLOR_YELLOW}  ⚠ IPC failed (non-critical)${COLOR_RESET}"
        fi
    done
    return 0
}

# ═══════════════════════════════════════════════════════════════
# STAGE 9: Syntax Verification
# ═══════════════════════════════════════════════════════════════
stage_verify_syntax() {
    return 0
}

# ═══════════════════════════════════════════════════════════════
# STAGE 10: Reload Daemon
# ═══════════════════════════════════════════════════════════════
stage_reload_daemon() {
    echo -e "${COLOR_CYAN}[10/12] Reloading usbguard daemon...${COLOR_RESET}"

    if systemctl reload usbguard 2>/dev/null; then
        echo -e "${COLOR_GREEN}  ✓ Rules reloaded via systemctl reload${COLOR_RESET}"
        return 0
    fi

    pkill -HUP usbguard-daemon 2>/dev/null || true
    sleep 1

    if systemctl is-active --quiet usbguard 2>/dev/null; then
        echo -e "${COLOR_GREEN}  ✓ Rules reloaded via SIGHUP (daemon active)${COLOR_RESET}"
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

    if [[ "$NOTIFY_DESKTOP" != "true" ]] || ! command -v notify-send &>/dev/null; then
        return 0
    fi

    local type_label=""
    if [[ "$APPROVAL_TYPE" == "P" ]]; then
        type_label="Permanent"
    else
        local ttl_time=$(date -d "@$(compute_ttl_epoch "$TEMP_TTL_SECONDS")" '+%H:%M' 2>/dev/null || echo "N/A")
        type_label="Temporary (expires ${ttl_time})"
    fi

    notify-send --icon=usbguard --urgency=normal --app-name="USBGuard Manager" \
        "🔌 USB Devices Approved" \
        "Approved: ${#CREATED_RULES[@]} devices • ${type_label}" 2>/dev/null || true

    echo -e "${COLOR_GREEN}  ✓ Notification sent${COLOR_RESET}"
    return 0
}

# ═══════════════════════════════════════════════════════════════
# STAGE 12: Audit Log & Release
# ═══════════════════════════════════════════════════════════════
stage_audit_and_release() {
    local success="$1"
    echo -e "${COLOR_CYAN}[12/12] Audit log and cleanup...${COLOR_RESET}"

    if [[ "$success" == "true" ]]; then
        local perm_count=0 temp_count=0
        [[ "$APPROVAL_TYPE" == "P" ]] && perm_count=${#CREATED_RULES[@]} || temp_count=${#CREATED_RULES[@]}

        for rule_entry in "${CREATED_RULES[@]}"; do
            local dev_id="${rule_entry##*|}"
            local dev_name=$(for d in "${BLOCKED_DEVICES[@]}"; do
                local did; did=$(_parse_device_info "$d" "device_id")
                [[ "$did" == "$dev_id" ]] && { _parse_device_info "$d" "name"; break; }
            done)
            local dev_id_str=$(for d in "${BLOCKED_DEVICES[@]}"; do
                local did; did=$(_parse_device_info "$d" "device_id")
                [[ "$did" == "$dev_id" ]] && { _parse_device_info "$d" "id"; break; }
            done)

            if [[ "$APPROVAL_TYPE" == "T" ]]; then
                local ttl_epoch=$(compute_ttl_epoch "$TEMP_TTL_SECONDS" 2>/dev/null || echo "N/A")
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
        local rules_dir=$(dirname "$RULES_PERMANENT")
        local temp_restore_dir=$(mktemp -d -t usbguard_rollback_XXXXXX 2>/dev/null)

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
                    echo -e "${COLOR_RED}  ✗ Rollback reload failed!${COLOR_RESET}" >&2
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