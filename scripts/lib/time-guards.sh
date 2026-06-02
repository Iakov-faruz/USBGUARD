#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# USBGuard Approval Manager - Time Guards
# Version: 2.2
# ═══════════════════════════════════════════════════════════════
# זיהוי קפיצות זמן חריגות (backward jumps, unreasonable epochs)
# מונע הרס state במקרה של קפיצת שעון
# ═══════════════════════════════════════════════════════════════

# ─── Default Paths ────────────────────────────────────────────
readonly TIME_GUARDS_STATE_FILE="/var/lib/usbguard-manager/last_run_epoch"
readonly TIME_GUARDS_DEFAULT_MIN_EPOCH=1577836800   # 2020-01-01
readonly TIME_GUARDS_DEFAULT_MAX_JUMP=3600          # 1 hour

# ═══════════════════════════════════════════════════════════════
# פונקציה: get_epoch_now
# תפקיד: מחזיר epoch נוכחי (בטוח)
# שימוש: epoch=$(get_epoch_now)
# ═══════════════════════════════════════════════════════════════
get_epoch_now() {
    date +%s 2>/dev/null || {
        log_error "TIMEGUARD" "Cannot get current epoch time"
        return 1
    }
}

# ═══════════════════════════════════════════════════════════════
# פונקציה: check_clock_reasonable
# תפקיד: מוודא שהשעון הגיוני (אחרי MIN_REASONABLE_EPOCH)
# שימוש: check_clock_reasonable [min_epoch]
# ═══════════════════════════════════════════════════════════════
check_clock_reasonable() {
    local min_epoch="${1:-$TIME_GUARDS_DEFAULT_MIN_EPOCH}"
    local now

    now=$(get_epoch_now) || return 1

    if [[ $now -lt $min_epoch ]]; then
        log_error "TIMEGUARD" "System clock is unreasonable: epoch=${now} (min=${min_epoch})"
        echo "ERROR: System clock is before year 2020 (epoch=${now}). Check NTP/CMOS battery." >&2
        return 1
    fi

    log_debug "TIMEGUARD" "Clock is reasonable: epoch=${now}"
    return 0
}

# ═══════════════════════════════════════════════════════════════
# פונקציה: read_last_run_epoch
# תפקיד: קריאת ה-epoch האחרון מקובץ state
# שימוש: last_run=$(read_last_run_epoch)
# ═══════════════════════════════════════════════════════════════
read_last_run_epoch() {
    local state_file="${1:-$TIME_GUARDS_STATE_FILE}"
    local value

    if [[ ! -f "$state_file" ]]; then
        log_debug "TIMEGUARD" "State file not found (first run): $state_file"
        return 1
    fi

    value=$(cat "$state_file" 2>/dev/null)

    # Validate: must be a positive integer
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        log_warn "TIMEGUARD" "Invalid state file content: ${value} (expected epoch integer)"
        return 1
    fi

    echo "$value"
    return 0
}

# ═══════════════════════════════════════════════════════════════
# פונקציה: write_last_run_epoch
# תפקיד: כתיבת epoch נוכחי לקובץ state (אטומי)
# שימוש: write_last_run_epoch [epoch] [state_file]
# ═══════════════════════════════════════════════════════════════
write_last_run_epoch() {
    local epoch="${1:-$(get_epoch_now)}"
    local state_file="${2:-$TIME_GUARDS_STATE_FILE}"
    local state_dir
    local temp_file

    state_dir=$(dirname "$state_file" 2>/dev/null)

    # Ensure state directory exists
    if [[ ! -d "$state_dir" ]]; then
        mkdir -p "$state_dir" 2>/dev/null || {
            log_error "TIMEGUARD" "Cannot create state directory: $state_dir"
            return 1
        }
    fi

    # Atomic write via temp file + mv
    temp_file=$(mktemp -t usbguard_last_run_XXXXXX 2>/dev/null) || {
        log_error "TIMEGUARD" "Cannot create temp file for state"
        return 1
    }

    echo "$epoch" > "$temp_file" 2>/dev/null || {
        rm -f "$temp_file" 2>/dev/null
        log_error "TIMEGUARD" "Cannot write to temp state file"
        return 1
    }

    if ! mv "$temp_file" "$state_file" 2>/dev/null; then
        rm -f "$temp_file" 2>/dev/null
        log_error "TIMEGUARD" "Cannot move temp state to: $state_file"
        return 1
    fi

    chmod 600 "$state_file" 2>/dev/null

    log_debug "TIMEGUARD" "State updated: epoch=${epoch}"
    return 0
}

# ═══════════════════════════════════════════════════════════════
# פונקציה: detect_clock_jump_backward
# תפקיד: זיהוי קפיצת שעון אחורה
# שימוש: detect_clock_jump_backward [max_jump_sec] [state_file]
# ═══════════════════════════════════════════════════════════════
detect_clock_jump_backward() {
    local max_jump="${1:-$TIME_GUARDS_DEFAULT_MAX_JUMP}"
    local state_file="${2:-$TIME_GUARDS_STATE_FILE}"
    local last_run now diff

    # Try to read last run epoch
    last_run=$(read_last_run_epoch "$state_file") || {
        # No previous state - this is acceptable (first run)
        log_debug "TIMEGUARD" "No previous state found (first run or state reset)"
        return 0
    }

    now=$(get_epoch_now) || return 1

    # Calculate difference
    diff=$((last_run - now))

    # If no backward jump (or very small)
    if [[ $diff -le 0 ]]; then
        log_debug "TIMEGUARD" "No backward jump detected (diff=${diff}s)"
        return 0
    fi

    # If backward jump exceeds threshold
    if [[ $diff -gt $max_jump ]]; then
        log_warn "TIMEGUARD" "Clock jumped backward by ${diff}s (max allowed: ${max_jump}s). Skipping to prevent state corruption."
        echo "WARN: System clock jumped backward by ${diff}s. Verify NTP synchronization." >&2
        return 1
    fi

    # Small backward jump within tolerance
    log_warn "TIMEGUARD" "Small backward clock jump: ${diff}s (within tolerance: ${max_jump}s)"
    return 0
}

# ═══════════════════════════════════════════════════════════════
# פונקציה: update_time_guard_state
# תפקיד: עדכון state + Time Guards (שימוש נוח)
# שימוש: update_time_guard_state [max_jump] [state_file]
# ═══════════════════════════════════════════════════════════════
update_time_guard_state() {
    local max_jump="${1:-$TIME_GUARDS_DEFAULT_MAX_JUMP}"
    local state_file="${2:-$TIME_GUARDS_STATE_FILE}"

    # 1. Check clock is reasonable
    check_clock_reasonable || return 1

    # 2. Detect backward jumps
    detect_clock_jump_backward "$max_jump" "$state_file" || {
        log_warn "TIMEGUARD" "Backward jump detected - not updating state file"
        return 1
    }

    # 3. Update state with current epoch
    write_last_run_epoch "$(get_epoch_now)" "$state_file" || return 1

    return 0
}

# ═══════════════════════════════════════════════════════════════
# פונקציה: compute_ttl_epoch
# תפקיד: חישוב epoch תפוגה ל-TTL
# שימוש: ttl_epoch=$(compute_ttl_epoch 3600)
# ═══════════════════════════════════════════════════════════════
compute_ttl_epoch() {
    local ttl_seconds="${1:-3600}"
    local now

    now=$(get_epoch_now) || return 1
    echo $((now + ttl_seconds))
    return 0
}

# ═══════════════════════════════════════════════════════════════
# פונקציה: is_ttl_expired
# תפקיד: בדיקה האם TTL פג (epoch <= now)
# שימוש: if is_ttl_expired 1748357523; then echo "expired"; fi
# ═══════════════════════════════════════════════════════════════
is_ttl_expired() {
    local ttl_epoch="$1"
    local now

    if [[ -z "$ttl_epoch" ]]; then
        log_error "TIMEGUARD" "is_ttl_expired: ttl_epoch is empty"
        return 2
    fi

    if [[ ! "$ttl_epoch" =~ ^[0-9]+$ ]]; then
        log_error "TIMEGUARD" "is_ttl_expired: invalid ttl_epoch: $ttl_epoch"
        return 2
    fi

    now=$(get_epoch_now) || return 1

    if [[ $ttl_epoch -le $now ]]; then
        return 0  # Expired
    fi

    return 1  # Still valid
}

# ═══════════════════════════════════════════════════════════════
# פונקציה: format_ttl_remaining
# תפקיד: חישוב זמן נותר ב-TTL בפורמט קריא
# שימוש: remaining=$(format_ttl_remaining 1748357523)
# ═══════════════════════════════════════════════════════════════
format_ttl_remaining() {
    local ttl_epoch="$1"
    local now diff hours minutes

    if [[ -z "$ttl_epoch" ]]; then
        echo "N/A"
        return 1
    fi

    if [[ ! "$ttl_epoch" =~ ^[0-9]+$ ]]; then
        echo "N/A"
        return 1
    fi

    now=$(get_epoch_now) || {
        echo "N/A"
        return 1
    }

    diff=$((ttl_epoch - now))

    if [[ $diff -le 0 ]]; then
        echo "Expired"
        return 0
    fi

    if [[ $diff -ge 3600 ]]; then
        hours=$((diff / 3600))
        minutes=$(((diff % 3600) / 60))
        echo "${hours}h ${minutes}m"
    elif [[ $diff -ge 60 ]]; then
        minutes=$((diff / 60))
        echo "${minutes}m"
    else
        echo "${diff}s"
    fi

    return 0
}