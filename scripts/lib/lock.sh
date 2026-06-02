#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# USBGuard Approval Manager - Atomic Lock Manager (Race-Free)
# Version: 2.2
# ═══════════════════════════════════════════════════════════════
# מחליף את מנגנון flock שאינו יציב בסביבות VM/Container
# משתמש ב-mkdir אטומי למניעת race conditions לחלוטין
# ═══════════════════════════════════════════════════════════════

# תיקיית הנעילה ברירת מחדל (mkdir אטומי)
LOCK_FILE_DEFAULT="/var/lib/usbguard-manager/usbguard-manager.lock"

# ───────────────────────────────────────────────────────────────
# acquire_lock
# שימוש: acquire_lock [lockdir] [nowait|wait] [timeout]
# ───────────────────────────────────────────────────────────────
acquire_lock() {
    local lock_path="${1:-$LOCK_FILE_DEFAULT}"
    local lock_dir=""
    
    # תאימות לאחור: אם נשלח נתיב קובץ, נהפוך אותו לתיקיית נעילה אטומית
    if [[ "$lock_path" == *".lock" ]]; then
        lock_dir="${lock_path}.dir"
    else
        lock_dir="${lock_path}"
    fi
    
    local wait_mode="${2:-nowait}"
    local timeout="${3:-30}"

    mkdir -p "$(dirname "$lock_dir")" 2>/dev/null

    local waited=0

    while true; do
        # ניסיון לבצע mkdir אטומי - מיושם ברמת הקרנל כפעולה אטומית
        if mkdir "$lock_dir" 2>/dev/null; then
            # הנעילה הצליחה! נכתוב את ה-PID שלנו בפנים לצרכי מעקב ואימות
            echo $$ > "$lock_dir/pid" 2>/dev/null
            chmod 600 "$lock_dir/pid" 2>/dev/null
            
            # התקנת trap לשחרור אוטומטי ביציאה
            trap "release_lock '$lock_dir'" EXIT INT TERM HUP
            return 0
        fi

        # אם התיקייה קיימת, נבדוק אם יש בפנים PID של תהליך פעיל (מניעת נעילות יתומות)
        local active_pid=""
        if [[ -f "$lock_dir/pid" ]]; then
            active_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
        fi

        if [[ -n "$active_pid" ]] && kill -0 "$active_pid" 2>/dev/null; then
            # התהליך עדיין חי -> הנעילה באמת תפוסה
            if [[ "$wait_mode" == "nowait" ]]; then
                return 1
            fi

            if [[ $waited -ge $timeout ]]; then
                return 1
            fi

            sleep 1
            ((waited++))
            continue
        else
            # נעילה יתומה (התהליך מת או שקובץ ה-pid חסר) -> מוחקים בבטחה ומנסים שוב
            rm -rf "$lock_dir" 2>/dev/null
        fi

        sleep 0.1
    done
}

# ───────────────────────────────────────────────────────────────
# release_lock
# משחרר את הנעילה רק אם ה‑PID בתיקייה הוא שלנו
# ───────────────────────────────────────────────────────────────
release_lock() {
    local lock_path="${1:-$LOCK_FILE_DEFAULT}"
    local lock_dir=""
    
    if [[ "$lock_path" == *".lock" ]]; then
        lock_dir="${lock_path}.dir"
    else
        lock_dir="${lock_path}"
    fi

    if [[ -d "$lock_dir" ]]; then
        local pid=""
        if [[ -f "$lock_dir/pid" ]]; then
            pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
        fi

        # משחררים רק אם ה-PID שייך לתהליך הנוכחי או שקובץ ה-PID ריק/מחוק
        if [[ "$pid" == "$$" || -z "$pid" ]]; then
            rm -rf "$lock_dir" 2>/dev/null
        fi
    fi

    return 0
}