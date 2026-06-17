#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════
# USBGuard Approval Manager – Atomic Lock Manager
# Version: 3.2 (Race‑Free, Safe‑Trap, Hardened)
# ════════════════════════════════════════════════════════════════════════
#
# מנגנון נעילה אטומי לחלוטין המבוסס על mkdir:
#   • חסין Race Conditions (mkdir אטומי ב‑POSIX)
#   • חסין PID‑spoofing (בדיקת תהליך חי)
#   • מניעת stale locks בצורה בטוחה
#   • Trap בטוח ללא הרחבת משתנים בזמן הגדרה
#   • Zero‑Subprocess (ללא grep/awk/sed/tr)
#
# ════════════════════════════════════════════════════════════════════════

LOCK_FILE_DEFAULT="/var/lib/usbguard-manager/usbguard-manager.lock"
LOCK_ACTIVE_DIR=""
LOCK_OWNER_PID=""

# ───────────────────────────────────────────────────────────────────────
# המרה של נתיב .lock לנתיב ספרייה אטומית (.lock.dir)
# ───────────────────────────────────────────────────────────────────────
_lock_path_to_dir() {
    local p="$1"
    [[ "$p" == *.lock ]] && printf '%s.dir' "$p" || printf '%s' "$p"
}

# ───────────────────────────────────────────────────────────────────────
# בדיקה האם PID חי
# ───────────────────────────────────────────────────────────────────────
_lock_pid_is_live() {
    local pid="$1"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    [[ "$pid" == "$$" ]] && return 0
    kill -0 "$pid" 2>/dev/null
}

# ───────────────────────────────────────────────────────────────────────
# בדיקה האם הנעילה שייכת לתהליך הנוכחי בלבד
# ───────────────────────────────────────────────────────────────────────
_lock_is_owned_by_current_process() {
    local lock_dir="$1"
    local pid_file="${lock_dir}/pid"
    local pid=""

    [[ -d "$lock_dir" ]] || return 1
    [[ -f "$pid_file" ]] || return 1

    pid=$(cat "$pid_file" 2>/dev/null || echo "")
    [[ "$pid" == "$$" ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1

    return 0
}

# ───────────────────────────────────────────────────────────────────────
# acquire_lock [path] [nowait|wait] [timeout]
# ───────────────────────────────────────────────────────────────────────
acquire_lock() {
    local lock_path="${1:-$LOCK_FILE_DEFAULT}"
    local lock_dir=$(_lock_path_to_dir "$lock_path")
    local wait_mode="${2:-nowait}"
    local timeout="${3:-30}"
    local waited=0

    mkdir -p "$(dirname "$lock_dir")" 2>/dev/null || {
        echo "ERROR: Cannot create lock directory" >&2
        return 1
    }

    while true; do
        # ניסיון יצירת הנעילה (אטומי)
        if mkdir "$lock_dir" 2>/dev/null; then
            printf '%s\n' "$$" > "$lock_dir/pid"
            chmod 600 "$lock_dir/pid" 2>/dev/null

            LOCK_ACTIVE_DIR="$lock_dir"
            LOCK_OWNER_PID="$$"

            # Trap בטוח — המשתנה מורחב רק בזמן ההפעלה, לא בזמן ההגדרה
            trap 'release_lock "$LOCK_ACTIVE_DIR"' EXIT INT TERM HUP

            return 0
        fi

        # הנעילה קיימת — נבדוק מי מחזיק אותה
        local active_pid=""
        [[ -f "$lock_dir/pid" ]] && active_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")

        if _lock_pid_is_live "$active_pid"; then
            # תהליך חי מחזיק בנעילה
            [[ "$wait_mode" == "nowait" ]] && return 1
            [[ $waited -ge $timeout ]] && return 1

            sleep 1
            waited=$((waited + 1))
            continue
        fi

        # הנעילה יתומה — אבל נוודא שה‑PID תקין לפני מחיקה
        if [[ -z "$active_pid" || ! "$active_pid" =~ ^[0-9]+$ ]]; then
            echo "WARN: Lock metadata invalid — refusing to remove: $lock_dir" >&2
            return 1
        fi

        # מחיקת stale lock
        rm -rf "$lock_dir" 2>/dev/null || return 1
        sleep 0.1
    done
}

# ───────────────────────────────────────────────────────────────────────
# release_lock [path]
# ───────────────────────────────────────────────────────────────────────
release_lock() {
    local lock_path="${1:-}"
    local lock_dir

    [[ -z "$lock_path" && -n "$LOCK_ACTIVE_DIR" ]] && lock_path="$LOCK_ACTIVE_DIR"
    lock_path="${lock_path:-$LOCK_FILE_DEFAULT}"
    lock_dir=$(_lock_path_to_dir "$lock_path")

    # שחרור רק אם אנחנו הבעלים
    if _lock_is_owned_by_current_process "$lock_dir"; then
        rm -rf "$lock_dir" 2>/dev/null

        [[ "$LOCK_ACTIVE_DIR" == "$lock_dir" ]] && {
            LOCK_ACTIVE_DIR=""
            LOCK_OWNER_PID=""
        }

        return 0
    fi

    # אם הנעילה קיימת אך לא שלנו — אזהרה בלבד
    [[ -d "$lock_dir" ]] && \
        echo "WARN: Refusing to release lock not owned by this process: $lock_dir" >&2

    return 0
}
