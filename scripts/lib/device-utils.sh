#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# USBGuard Approval Manager - Device Utilities
# Version: 2.2
# ═══════════════════════════════════════════════════════════════
# Contains: _parse_device_info, _build_rule
# ═══════════════════════════════════════════════════════════════

# ═══════════════════════════════════════════════════════════════
# פונקציה: _parse_device_info
# תפקיד: חילוץ מידע מהתקן (id, serial, name, port, hash)
# ═══════════════════════════════════════════════════════════════
_parse_device_info() {
    local device_line="$1"
    local field="$2"

    # Example line: "0: block id 0781:5581 serial 4C530001010412113934 name "SanDisk Ultra" hash abc123 parent-hub 1-2 via-port 1-2.3 ..."
    case "$field" in
        id)
            echo "$device_line" | grep -oP 'id \K[0-9a-fA-F]{4}:[0-9a-fA-F]{4}'
            ;;
        serial)
            echo "$device_line" | grep -oP 'serial "?\K[^"\s]+' || echo "no-serial"
            ;;
        name)
            echo "$device_line" | grep -oP 'name "?\K[^"]+(?="?)' | sed 's/"$//' || echo "Unknown Device"
            ;;
        hash)
            echo "$device_line" | grep -oP 'hash "?\K[^"\s]+' || echo ""
            ;;
        port)
            echo "$device_line" | grep -oP 'via-port "?\K[^"\s]+' || echo "N/A"
            ;;
        device_id)
            echo "$device_line" | grep -oP '^[0-9]+'
            ;;
    esac
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
    local vid_pid serial name hash_val interfaces
    vid_pid=$(_parse_device_info "$device_line" "id")
    serial=$(_parse_device_info "$device_line" "serial")
    name=$(_parse_device_info "$device_line" "name")
    hash_val=$(_parse_device_info "$device_line" "hash")
    # Extract interfaces - supports both single and multi-interface (brace) format
    interfaces=$(echo "$device_line" | grep -oP 'with-interface \{[^}]+\}' 2>/dev/null || echo "")
    [[ -z "$interfaces" ]] && interfaces=$(echo "$device_line" | grep -oP 'with-interface \K\S+' 2>/dev/null || echo "")

    # Validate minimum required field
    if [[ -z "$vid_pid" ]]; then
        log_error "APPROVE" "Cannot extract vendor:product ID for device ${device_id}"
        return 1
    fi

    # Build clean USBGuard rule – include hash for stronger device fingerprinting
    local rule="allow id ${vid_pid}"
    [[ "$serial" != "no-serial" && -n "$serial" ]] && rule+=" serial \"${serial}\""
    [[ -n "$name" && "$name" != "Unknown Device" ]] && rule+=" name \"${name}\""
    [[ -n "$hash_val" ]] && rule+=" hash \"${hash_val}\""
    [[ -n "$interfaces" ]] && rule+=" with-interface ${interfaces}"

    echo "$rule"
}