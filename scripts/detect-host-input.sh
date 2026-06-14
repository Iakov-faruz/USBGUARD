#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# USBGuard Approval Manager - Host Input Device Detection
# Version: 1.1 (with HASH support) - מוסיף הערות מפורטות
# ═══════════════════════════════════════════════════════════════════════════════
# מטרת הסקריפט: 
#   לזהות את כל התקני הקלט (מקלדת/עכבר) המחוברים ישירות לשרת,
#   וליצור עבורם כללי "allow" ב-00-system.rules.
#
# למה זה קריטי?
#   בלי הסקריפט הזה, usbguard עלול לחסום את המקלדת/עכבר של השרת עצמו,
#   ולגרום לאובדן שליטה על המערכת. הסקריפט רץ אוטומטית במהלך ההתקנה
#   (שלב 5b ב-install.sh) ומוסיף את הכללים הדרושים.
#
# שיטות זיהוי:
#   1. sysfs – סורק את /sys/bus/usb/devices/ ומחפש ממשקי HID (03:01/03:02)
#   2. usbguard IPC – שואל את ה-daemon על התקנים קיימים ומקבל גם HASH
#
# HASH הוא מזהה ייחודי שמשתנה בין התקנים זהים (למשל שתי מקלדות זהות),
# ומוסיף שכבת אבטחה נוספת.
#
# הרצה:
#   sudo ./detect-host-input.sh [path-to-rules-file]
#   (ברירת מחדל: /etc/usbguard/rules.d/00-system.rules)
# ═══════════════════════════════════════════════════════════════════════════════

# ═══════════════════════════════════════════════════════════════════════════════
# הגדרות והגנות
# ═══════════════════════════════════════════════════════════════════════════════
# -e: שגיאה תעצור את הסקריפט
# -u: שימוש במשתנה לא מוגדר יגרום לשגיאה
# -o pipefail: אם פקודה ב-pipeline נכשלת, כל ה-pipeline נכשל
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════════
# קביעת קובץ היעד (לאן לכתוב את הכללים)
# ═══════════════════════════════════════════════════════════════════════════════
# אם הועבר פרמטר ראשון – השתמש בו, אחרת ברירת מחדל
TARGET="${1:-/etc/usbguard/rules.d/00-system.rules}"

# ═══════════════════════════════════════════════════════════════════════════════
# בדיקת הרשאות – חייב להיות root
# ═══════════════════════════════════════════════════════════════════════════════
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "ERROR: detect-host-input.sh must run as root" >&2
    exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════════
# יצירת ספריית היעד וקובץ בסיסי אם אינו קיים
# ═══════════════════════════════════════════════════════════════════════════════
mkdir -p "$(dirname "$TARGET")"
if [[ ! -f "$TARGET" ]]; then
    # קובץ ראשוני עם כללי USB controllers + מקום שמור להתקני קלט
    cat > "$TARGET" <<'EOF'
# USBGuard System Rules
# USB controllers (required for all systems)
allow id 1d6b:0001 with-interface 09:00:00
allow id 1d6b:0002 with-interface 09:00:00
allow id 1d6b:0003 with-interface 09:00:00

# Host keyboard/mouse devices (auto-detected by detect-host-input.sh)
# === HOST INPUT START ===
# === HOST INPUT END ===
EOF
fi

# ═══════════════════════════════════════════════════════════════════════════════
# מערך לאחסון הכללים שיתווספו
# ═══════════════════════════════════════════════════════════════════════════════
declare -A RULES=()

# ═══════════════════════════════════════════════════════════════════════════════
# פונקציה: הוספת כלל למערך RULES
# מקבלת: VID:PID, מחרוזת interface, ואופציונלי hash
# ═══════════════════════════════════════════════════════════════════════════════
add_rule() {
    local vid_pid="$1"
    local iface="$2"
    local hash="${3:-}"   # פרמטר שלישי אופציונלי – hash
    [[ -n "$vid_pid" && -n "$iface" ]] || return 0
    
    # בניית כלל מלא – אם יש hash, מוסיפים אותו בסוגריים עם "hash"
    if [[ -n "$hash" ]]; then
        local rule="allow id ${vid_pid} with-interface ${iface} hash \"${hash}\""
    else
        local rule="allow id ${vid_pid} with-interface ${iface}"
    fi
    
    # שמירה במערך עם מפתח ייחודי (כדי למנוע כפילויות)
    RULES["${vid_pid}|${iface}|${hash}"]="$rule"
}

# ═══════════════════════════════════════════════════════════════════════════════
# פונקציה: זיהוי התקני קלט דרך sysfs
# סורקת את /sys/bus/usb/devices/ ומחפשת ממשקי HID (class 03, subclass 01/02)
# ═══════════════════════════════════════════════════════════════════════════════
detect_sysfs() {
    local dev vid pid devname iface_dir class subclass protocol iface
    
    # nullglob: אם אין התאמה, התבנית תישאר ריקה ולא תתרחב ל-"*"
    shopt -s nullglob
    
    for dev in /sys/bus/usb/devices/*; do
        # נדרשים קבצי idVendor ו-idProduct – אחרת דלג
        [[ -f "$dev/idVendor" && -f "$dev/idProduct" ]] || continue
        
        # קריאת VID ו-PID (באותיות קטנות, ללא רווחים)
        vid=$(tr '[:upper:]' '[:lower:]' < "$dev/idVendor" 2>/dev/null | tr -d '[:space:]') || continue
        pid=$(tr '[:upper:]' '[:lower:]' < "$dev/idProduct" 2>/dev/null | tr -d '[:space:]') || continue
        
        # ודא שהם בפורמט תקין של 4 ספרות hex
        [[ "$vid" =~ ^[0-9a-f]{4}$ && "$pid" =~ ^[0-9a-f]{4}$ ]] || continue
        
        # קריאת שם ההתקן (product name) – אופציונלי, רק להדפסה
        devname=""
        [[ -f "$dev/product" ]] && devname=$(tr -d '[:space:]' < "$dev/product" 2>/dev/null || true)
        
        # בדיקת מחלקת ההתקן הראשי – אם 09 (USB hub/controller), דלג
        if [[ -f "$dev/bDeviceClass" ]]; then
            local devclass
            devclass=$(tr -d '[:space:]' < "$dev/bDeviceClass" 2>/dev/null || true)
            [[ "$devclass" == "09" ]] && continue
        fi
        
        # סריקת תיקיות הממשקים (format: X.Y)
        for iface_dir in "$dev"/*:*; do
            [[ -d "$iface_dir" ]] || continue
            [[ -f "$iface_dir/bInterfaceClass" && -f "$iface_dir/bInterfaceSubClass" && -f "$iface_dir/bInterfaceProtocol" ]] || continue
            
            # קריאת class, subclass, protocol (hex)
            class=$(tr '[:upper:]' '[:lower:]' < "$iface_dir/bInterfaceClass" 2>/dev/null | tr -d '[:space:]') || continue
            subclass=$(tr '[:upper:]' '[:lower:]' < "$iface_dir/bInterfaceSubClass" 2>/dev/null | tr -d '[:space:]') || continue
            protocol=$(tr '[:upper:]' '[:lower:]' < "$iface_dir/bInterfaceProtocol" 2>/dev/null | tr -d '[:space:]') || continue
            
            # HID: class 03, subclass 01 = מקלדת, 02 = עכבר
            if [[ "$class" == "03" && ("$subclass" == "01" || "$subclass" == "02") ]]; then
                iface="03:${subclass}:${protocol:-00}"
                # אין hash ב-sysfs – מוסיפים ללא hash
                add_rule "$vid:$pid" "$iface" ""
                echo "  Detected via sysfs: ${vid}:${pid} interface ${iface}${devname:+ (${devname})}" >&2
            fi
        done
    done
    
    shopt -u nullglob
}

# ═══════════════════════════════════════════════════════════════════════════════
# פונקציה: זיהוי התקני קלט דרך usbguard IPC
# שואלת את usbguard list-devices ומקבלת hash ייחודי (טביעת אצבע)
# ═══════════════════════════════════════════════════════════════════════════════
detect_usbguard() {
    local line id status rest iface hash
    
    # בדיקה שהפקודה usbguard קיימת
    command -v usbguard >/dev/null 2>&1 || return 0
    
    # מעבר על כל שורה של רשימת ההתקנים
    while IFS= read -r line; do
        # פורמט טיפוסי: "12: allow id 1234:5678 with-interface 03:01:00 ..."
        # לחלץ ID ומצב + rest
        [[ "$line" =~ ^[0-9]+:[[:space:]]+(allow|block)[[:space:]]+id[[:space:]]+([0-9a-fA-F]{4}:[0-9a-fA-F]{4})(.*)$ ]] || continue
        id="${BASH_REMATCH[2]}"
        rest="${BASH_REMATCH[3]}"
        
        # חילוץ hash: hash "xxxxx"
        hash=""
        if [[ "$rest" =~ hash\ \"([^\"]+)\" ]]; then
            hash="${BASH_REMATCH[1]}"
        fi
        
        # חילוץ כל ממשקי with-interface
        while IFS= read -r iface; do
            [[ -n "$iface" ]] || continue
            # התעניינות רק ב-HID (03:01, 03:02)
            if [[ "$iface" == 03:01:* || "$iface" == 03:02:* ]]; then
                if [[ -n "$hash" ]]; then
                    add_rule "$id" "$iface" "$hash"
                    echo "  Detected via usbguard: ${id} interface ${iface} hash \"${hash}\"" >&2
                else
                    add_rule "$id" "$iface" ""
                    echo "  Detected via usbguard: ${id} interface ${iface} (no hash)" >&2
                fi
            fi
        done < <(grep -oP 'with-interface \K\S+' <<< "$rest" || true)
        
    done < <(usbguard list-devices 2>/dev/null || true)
}

# ═══════════════════════════════════════════════════════════════════════════════
# פונקציה: בדיקה אם כלל כבר קיים בקובץ
# ═══════════════════════════════════════════════════════════════════════════════
rule_exists() {
    local rule="$1"
    grep -Fxq "$rule" "$TARGET" 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════════════════════
# פונקציה: הכנסת הכללים לקובץ 00-system.rules
# משמרת את סמני ה-HOST INPUT START/END ומחליפה את התוכן שביניהם
# ═══════════════════════════════════════════════════════════════════════════════
insert_rules() {
    local tmp inserted rule
    tmp=$(mktemp -t usbguard_host_input_XXXXXX)
    inserted=false
    
    # קריאת הקובץ הקיים ושמירת תוכן מחוץ לסעיף HOST INPUT
    local found_section=false
    local in_section=false
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        # זיהוי תחילת סעיף ההכנסה
        if [[ "$line" == "# === HOST INPUT START === "* ]]; then
            found_section=true
            in_section=true
            # מדפיסים את השורה עצמה (הכותרת)
            echo "$line" >> "$tmp"
            # נוסיף את הכללים החדשים אחרי הכותרת (עוד מעט)
            continue
        fi
        
        # זיהוי סוף סעיף
        if [[ "$line" == "# === HOST INPUT END === "* ]]; then
            # אם אנחנו בסוף, נדפיס את כל הכללים שצברנו (אם לא הוכנסו כבר)
            if [[ "$inserted" == "false" && ${#RULES[@]} -gt 0 ]]; then
                echo "" >> "$tmp"
                echo "# Host keyboard/mouse devices (auto-detected by detect-host-input.sh)" >> "$tmp"
                echo "# These are added automatically during installation — do not remove this line:" >> "$tmp"
                echo "# === HOST INPUT START ===" >> "$tmp"
                # הכנסת כללים ממוינים (ללא כפילויות)
                local sorted_rules=($(printf '%s\n' "${RULES[@]}" | sort -u))
                for rule in "${sorted_rules[@]}"; do
                    [[ -n "$rule" ]] || continue
                    printf '%s\n' "$rule" >> "$tmp"
                    echo "Added: $rule" >&2
                done
                echo "# === HOST INPUT END ===" >> "$tmp"
                inserted=true
            fi
            echo "$line" >> "$tmp"
            in_section=false
            continue
        fi
        
        # אם אנחנו בתוך הסעיף – לא מעתיקים את התוכן הישן (הוא יוחלף)
        if [[ "$in_section" == "true" ]]; then
            continue
        fi
        
        # העתקת שורות רגילות (מחוץ לסעיף)
        echo "$line" >> "$tmp"
    done < "$TARGET"
    
    # אם לא מצאנו בכלל סעיף HOST INPUT – נוסיף בסוף הקובץ
    if [[ "$found_section" == "false" ]]; then
        echo "" >> "$tmp"
        echo "# Host keyboard/mouse devices (auto-detected by detect-host-input.sh)" >> "$tmp"
        echo "# These are added automatically during installation — do not remove this line:" >> "$tmp"
        echo "# === HOST INPUT START ===" >> "$tmp"
        inserted=true
        
        # הוספת הכללים
        if [[ ${#RULES[@]} -gt 0 ]]; then
            local sorted_rules=($(printf '%s\n' "${RULES[@]}" | sort -u))
            for rule in "${sorted_rules[@]}"; do
                [[ -n "$rule" ]] || continue
                printf '%s\n' "$rule" >> "$tmp"
                echo "Added: $rule" >&2
            done
        fi
        
        echo "# === HOST INPUT END ===" >> "$tmp"
    fi
    
    # החלפת הקובץ הישן בחדש
    mv "$tmp" "$TARGET"
    chmod 600 "$TARGET"          # הרשאה: root קריאה/כתיבה בלבד
    chown root:root "$TARGET"
    
    echo "Host input allow rules ready in $TARGET" >&2
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN – הרצת הסקריפט
# ═══════════════════════════════════════════════════════════════════════════════
echo "Scanning for host input devices (keyboard/mouse)..." >&2
detect_sysfs         # זיהוי דרך sysfs (ללא hash)
detect_usbguard      # זיהוי דרך usbguard IPC (עם hash – עדיף)

if [[ ${#RULES[@]} -eq 0 ]]; then
    echo "No host keyboard/mouse USB HID interfaces detected" >&2
    exit 0
fi

echo "Found ${#RULES[@]} host input rule(s) to add" >&2
insert_rules
echo "Done. Host input allow rules ready in ${TARGET}" >&2