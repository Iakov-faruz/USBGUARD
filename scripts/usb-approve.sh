#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# USBGuard Approval Manager - Main TUI
# Version: 2.2
# ═══════════════════════════════════════════════════════════════
# ממשק TUI לאישור התקני USB חסומים
# הערה: ה-stages מפוצלים ל: lib/stages-core.sh, lib/stages-io.sh, lib/device-utils.sh
# ═══════════════════════════════════════════════════════════════

# ─── Source libraries ─────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

for lib in config-reader.sh logger.sh lock.sh backup.sh time-guards.sh validators.sh \
           device-utils.sh stages-core.sh stages-io.sh; do
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
DRY_RUN_ACTIVE=false

# ─── Colors for TUI output ────────────────────────────────────
readonly COLOR_RESET='\033[0m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_BOLD='\033[1m'

# ═══════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════
main() {
    SESSION_START_TIME=$(date +%s 2>/dev/null || echo 0)

    local block_device_id=""
    local block_vid_pid=""

    # Parse CLI arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --list-rules)
                echo "{"
                for cat in system permanent temporary; do
                    local filepath=""
                    case "$cat" in
                        system) filepath="$RULES_SYSTEM" ;;
                        permanent) filepath="$RULES_PERMANENT" ;;
                        temporary) filepath="$RULES_TEMPORARY" ;;
                    esac
                    echo "  \"$cat\": ["
                    if [[ -f "$filepath" ]]; then
                        local first=true
                        while IFS= read -r line || [[ -n "$line" ]]; do
                            line=$(echo "$line" | xargs)
                            [[ -z "$line" ]] && continue
                            local escaped_line=$(echo "$line" | sed 's/"/\\"/g')
                            [[ "$first" == "true" ]] && first=false || echo ","
                            echo -n "    \"$escaped_line\""
                        done < "$filepath"
                        echo ""
                    fi
                    echo -n "  ]"
                    [[ "$cat" != "temporary" ]] && echo "," || echo ""
                done
                echo "}"
                exit 0
                ;;
            --device|-d)
                IFS=',' read -r -a SELECTED_DEVICES <<< "$2"; shift 2 ;;
            --type|-t)
                APPROVAL_TYPE="$2"; shift 2 ;;
            --ttl)
                TEMP_TTL_SECONDS="$2"; shift 2 ;;
            --dry-run|-n)
                DRY_RUN_ACTIVE=true; shift ;;
            --block)
                block_device_id="$2"; shift 2 ;;
            --vidpid)
                block_vid_pid="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    # Block action
    if [[ -n "${block_device_id:-}" || -n "${block_vid_pid:-}" ]]; then
        init_logger "$LOG_FILE"
        log_info "APPROVE" "CLI Block request: Device ID=${block_device_id:-N/A}, VID:PID=${block_vid_pid:-N/A}"
        acquire_lock "$LOCK_FILE" "wait" 10 || { log_error "APPROVE" "Lock failed"; exit 1; }

        [[ -n "${block_device_id:-}" ]] && usbguard block-device "$block_device_id" 2>/dev/null && \
            log_info "APPROVE" "Blocked device $block_device_id via IPC"

        if [[ -n "${block_vid_pid:-}" ]]; then
            for file in "$RULES_PERMANENT" "$RULES_TEMPORARY"; do
                [[ -f "$file" ]] || continue
                local tmp_rules=$(mktemp -t usbguard_rules_delete_XXXXXX 2>/dev/null)
                awk -v vidpid="$block_vid_pid" '
                BEGIN { skip_next = 0 }
                { if (skip_next == 1) { skip_next = 0; if ($0 ~ /^[[:space:]]*# ttl_epoch:/) next }
                  if ($0 ~ "allow id " vidpid) { skip_next = 1; next } print $0 }
                ' "$file" > "$tmp_rules" 2>/dev/null
                mv "$tmp_rules" "$file" 2>/dev/null; chmod 600 "$file" 2>/dev/null
            done
            log_info "APPROVE" "Deleted rules matching VID:PID $block_vid_pid"
        fi

        pkill -HUP usbguard-daemon 2>/dev/null || true
        release_lock
        log_audit "BLOCK" "Blocked device ${block_vid_pid:-ID: $block_device_id}"
        exit 0
    fi

    # ── Normal approval flow ─────────────────────────────────
    init_logger "$LOG_FILE"

    echo ""
    echo -e "${COLOR_BOLD}╔══════════════════════════════════════════════╗${COLOR_RESET}"
    echo -e "${COLOR_BOLD}║    USBGuard Approval Manager v2.2          ║${COLOR_RESET}"
    echo -e "${COLOR_BOLD}╚══════════════════════════════════════════════╝${COLOR_RESET}"
    echo ""
    log_info "APPROVE" "USBGuard Approval Manager started"

    [[ "$DRY_RUN_ACTIVE" == "true" ]] && echo -e "${COLOR_YELLOW}  DRY RUN MODE${COLOR_RESET}" && echo ""

    # Stages 1-5
    echo ""; stage_preflight || { SESSION_EXIT_CODE=1; log_session_summary "APPROVE" "Pre-flight failed" "$SESSION_EXIT_CODE" 0; exit "$SESSION_EXIT_CODE"; }
    echo ""; stage_acquire_lock || { SESSION_EXIT_CODE=1; log_session_summary "APPROVE" "Lock failed" "$SESSION_EXIT_CODE" 0; exit "$SESSION_EXIT_CODE"; }
    echo ""; stage_discover_devices || { SESSION_EXIT_CODE=0; release_lock; log_session_summary "APPROVE" "No devices" "$SESSION_EXIT_CODE" 0; exit "$SESSION_EXIT_CODE"; }
    
    echo ""
    if [[ ${#SELECTED_DEVICES[@]} -eq 0 ]]; then
        stage_multiselect_tui || { SESSION_EXIT_CODE=0; release_lock; log_session_summary "APPROVE" "Cancelled" "$SESSION_EXIT_CODE" 0; exit "$SESSION_EXIT_CODE"; }
    else
        echo -e "${COLOR_GREEN}  ✓ Device list pre-selected via CLI${COLOR_RESET}"
    fi

    echo ""
    if [[ -z "$APPROVAL_TYPE" ]]; then
        stage_choose_type || { SESSION_EXIT_CODE=0; release_lock; log_session_summary "APPROVE" "Cancelled" "$SESSION_EXIT_CODE" 0; exit "$SESSION_EXIT_CODE"; }
    else
        echo -e "${COLOR_GREEN}  ✓ Approval type pre-selected: ${APPROVAL_TYPE}${COLOR_RESET}"
    fi

    # Stage 6-7
    echo ""; stage_backup || { SESSION_EXIT_CODE=1; log_error "APPROVE" "Backup failed"; release_lock; log_session_summary "APPROVE" "Backup failed" "$SESSION_EXIT_CODE" 0; exit "$SESSION_EXIT_CODE"; }
    echo ""; stage_build_rules || {
        if [[ ${#CREATED_RULES[@]} -eq 0 ]]; then
            SESSION_EXIT_CODE=0; release_lock; log_session_summary "APPROVE" "No new rules" "$SESSION_EXIT_CODE" 0; exit "$SESSION_EXIT_CODE"
        fi
        SESSION_EXIT_CODE=1; rollback; release_lock; log_session_summary "APPROVE" "Build failed" "$SESSION_EXIT_CODE" 0; exit "$SESSION_EXIT_CODE"
    }

    # Dry-run shortcut
    if [[ "$DRY_RUN_ACTIVE" == "true" ]]; then
        echo ""
        echo -e "${COLOR_YELLOW}╔══════════════════════════════════════════════╗${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}║  DRY RUN - No changes were made             ║${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}╚══════════════════════════════════════════════╝${COLOR_RESET}"
        echo ""
        stage_audit_and_release "true"
        exit 0
    fi

    # Stages 8-12
    echo ""; stage_write_rules || { SESSION_EXIT_CODE=1; rollback; release_lock; log_session_summary "APPROVE" "Write failed" "$SESSION_EXIT_CODE" 0; exit "$SESSION_EXIT_CODE"; }
    echo ""; stage_verify_syntax || { SESSION_EXIT_CODE=1; rollback; release_lock; log_session_summary "APPROVE" "Syntax failed" "$SESSION_EXIT_CODE" 0; exit "$SESSION_EXIT_CODE"; }
    echo ""; stage_reload_daemon || { SESSION_EXIT_CODE=1; rollback; release_lock; log_session_summary "APPROVE" "Reload failed" "$SESSION_EXIT_CODE" 0; exit "$SESSION_EXIT_CODE"; }
    echo ""; stage_desktop_notification || true
    echo ""; stage_audit_and_release "true"

    # Summary
    local end_time=$(date +%s 2>/dev/null || echo 0)
    local duration=$((end_time - SESSION_START_TIME))

    echo ""
    echo -e "${COLOR_GREEN}${COLOR_BOLD}✅ Approval completed successfully!${COLOR_RESET}"
    echo ""
    echo -e "  ${COLOR_CYAN}Summary:${COLOR_RESET}"
    echo -e "  • Devices approved: ${#CREATED_RULES[@]}"
    echo -e "  • Type: ${APPROVAL_TYPE} ($([[ "$APPROVAL_TYPE" == "P" ]] && echo "Permanent" || echo "Temporary ${TEMP_TTL_SECONDS}s TTL"))"
    echo -e "  • Duration: ${duration}s"
    echo ""
    echo -e "  ${COLOR_CYAN}Approved devices:${COLOR_RESET}"
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
        echo -e "  ${COLOR_GREEN}✓${COLOR_RESET} ${dev_name} (${dev_id_str})"
    done
    echo ""

    log_session_summary "APPROVE" "Approved ${#CREATED_RULES[@]} devices" 0 "$duration"
    exit 0
}

# ─── Run main ─────────────────────────────────────────────────
main "$@"