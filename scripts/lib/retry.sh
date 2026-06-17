#!/usr/bin/env bash
# ==============================================================================
# USBGuard Approval Manager - Retry Helper
# ==============================================================================
# רכיב חוסן קטן להרצת פקודות חיצוניות עם retry ו-exponential backoff.
# כל קריאה חיצונית קריטית שמשתמשת ברכיב זה מקבלת התנהגות דטרמיניסטית,
# ללא eval, ללא string command, ועם קודי יציאה שמורים במדויק.
# ==============================================================================

if [[ "${RETRY_LOADED:-0}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi
RETRY_LOADED=1

retry_command() {
    local max_attempts="$1"
    local base_delay_sec="$2"
    shift 2

    if [[ ! "$max_attempts" =~ ^[1-9][0-9]*$ ]]; then
        echo "retry_command: max_attempts must be positive integer" >&2
        return 2
    fi

    if [[ ! "$base_delay_sec" =~ ^[0-9]+$ ]]; then
        echo "retry_command: base_delay_sec must be non-negative integer" >&2
        return 2
    fi

    if [[ $# -eq 0 ]]; then
        echo "retry_command: missing command" >&2
        return 2
    fi

    local attempt=1
    local delay="$base_delay_sec"

    while [[ $attempt -le $max_attempts ]]; do
        if "$@"; then
            return 0
        fi

        local status=$?
        if [[ $attempt -ge $max_attempts ]]; then
            return "$status"
        fi

        if [[ $delay -gt 0 ]]; then
            sleep "$delay"
        fi

        delay=$((delay * 2))
        attempt=$((attempt + 1))
    done

    return 1
}
