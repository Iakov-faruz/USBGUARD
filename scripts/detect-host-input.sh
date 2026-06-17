#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# USBGuard Approval Manager - Host Input Device Detection
# Version: 1.2 (Hardened, Zero-PCRE, Production-Ready)
# ═══════════════════════════════════════════════════════════════════════════════
# מטרת הסקריפט:
#   לזהות את כל התקני הקלט (מקלדת/עכבר) המחוברים ישירות לשרת הפיזי,
#   וליצור עבורם כללי "allow" דינמיים בתוך קובץ הכללים של USBGuard.
#
# למה זה קריטי?
#   בלי הסקריפט הזה, USBGuard עלול לחסום את המקלדת/עכבר הפיזיים של השרת עצמו
#   מיד עם הפעלת השירות, מה שיגרום ל-Lockout (אובדן שליטה פיזית על השרת).
#
# תכונות מתקדמות בגרסה זו (Hardening):
#   1. Zero-Subprocess ב-sysfs: קריאת קבצים ישירות לזיכרון ללא tr/sed/awk.
#   2. Zero-PCRE ב-USBGuard: חילוץ ממשקים באמצעות לולאות Regex פנימיות של Bash בלבד (ללא grep -oP).
#   3. חסינות CRLF/רווחים: ניקוי אקטיבי של תווי \r ורווחים זנביים למניעת שבירת מבנה הקובץ.
# ═══════════════════════════════════════════════════════════════════════════════

# הגנות Shell מחמירות:
# -e: עצירת הסקריפט מיד בכל שגיאה.
# -u: התייחסות למשתנה לא מוגדר כשגיאה קריטית.
# -o pipefail: החזרת קוד שגיאה אם פקודה ב-Pipeline נכשלת.
set -euo pipefail

# קביעת קובץ היעד (פרמטר ראשון או ברירת מחדל של המערכת)
TARGET="${1:-/etc/usbguard/rules.d/00-system.rules}"

# וידאו שהסקריפט רץ כ-root (חובה לצורך גישה ל-sysfs וכתיבה לכללי USBGuard)
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "ERROR: detect-host-input.sh must run as root" >&2
    exit 1
fi

# יצירת תיקיית היעד וקובץ בסיסי ריק עם בקרים (Controllers) חיוניים אם אינו קיים
mkdir -p "$(dirname "$TARGET")"
if [[ ! -f "$TARGET" ]]; then
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

# מערך אסוציאטיבי גלובלי לאחסון החוקים (מונע כפילויות באופן טבעי ע"י מפתחות ייחודיים)
declare -A RULES=()
TMP_FILE=""

# פונקציית ניקוי קבצים זמניים במקרה של קריסה או סיום מוצלח
_cleanup_host_input_temp() {
    [[ -n "$TMP_FILE" && -f "$TMP_FILE" ]] && rm -f "$TMP_FILE" 2>/dev/null
    return 0
}
# רישום ה-Trap לתפיסת אירועי יציאה (EXIT)
trap '_cleanup_host_input_temp' EXIT

# ═══════════════════════════════════════════════════════════════════════════════
# פונקציה: הוספת כלל למערך RULES
# ═══════════════════════════════════════════════════════════════════════════════
add_rule() {
    local vid_pid="$1" iface="$2" hash="${3:-}"
    [[ -n "$vid_pid" && -n "$iface" ]] || return 0
    
    local rule
    # אם קיים Hash (מ-USBGuard IPC), נרכיב כלל חזק ומאובטח שנועל את החומרה הספציפית
    if [[ -n "$hash" ]]; then
        rule="allow id ${vid_pid} with-interface ${iface} hash \"${hash}\""
    else
        # אם אין Hash (מסריקת sysfs בלבד), נסתפק ב-VID:PID ובממשק הקלט
        rule="allow id ${vid_pid} with-interface ${iface}"
    fi
    
    # שימוש במחרוזת ייחודית כמפתח כדי למנוע מצב שחוק זהה יירשם פעמיים
    RULES["${vid_pid}|${iface}|${hash}"]="$rule"
}

# ═══════════════════════════════════════════════════════════════════════════════
# פונקציה: סריקת מערכת הקבצים הווירטואלית של הליבה (sysfs)
# ═══════════════════════════════════════════════════════════════════════════════
detect_sysfs() {
    local dev vid pid devname iface_dir class subclass protocol iface
    shopt -s nullglob # מונע מהלולאה לרוץ על כוכבית ריקה (*) אם אין התקנים
    
    for dev in /sys/bus/usb/devices/*; do
        [[ -f "$dev/idVendor" && -f "$dev/idProduct" ]] || continue
        
        # [Zero-Subprocess] קריאת קבצים מובנית של Bash (מהיר ומאובטח)
        # המרת אותיות לקטנות (,,) וניקוי כל סוגי הרווחים והטאבים (//[[:space:]]/)
        vid=$(<"$dev/idVendor"); vid="${vid,,}"; vid="${vid//[[:space:]]/}"
        pid=$(<"$dev/idProduct"); pid="${pid,,}"; pid="${pid//[[:space:]]/}"
        
        # אימות פורמט הקלט (חייב להיות בדיוק 4 ספרות הקסדצימליות)
        [[ "$vid" =~ ^[0-9a-f]{4}$ && "$pid" =~ ^[0-9a-f]{4}$ ]] || continue
        
        devname=""
        [[ -f "$dev/product" ]] && devname=$(<"$dev/product"); devname="${devname//[[:space:]]/}"
        
        # בדיקה: אם מחלקת ההתקן היא 09 (USB Hub), נדלג (מטופל מראש בסטטיים)
        if [[ -f "$dev/bDeviceClass" ]]; then
            local devclass
            devclass=$(<"$dev/bDeviceClass"); devclass="${devclass//[[:space:]]/}"
            [[ "$devclass" == "09" ]] && continue
        fi
        
        # מעבר על כל הממשקים של התקן ה-USB הנוכחי
        for iface_dir in "$dev"/*:*; do
            [[ -d "$iface_dir" ]] || continue
            [[ -f "$iface_dir/bInterfaceClass" && -f "$iface_dir/bInterfaceSubClass" && -f "$iface_dir/bInterfaceProtocol" ]] || continue
            
            class=$(<"$iface_dir/bInterfaceClass"); class="${class,,}"; class="${class//[[:space:]]/}"
            subclass=$(<"$iface_dir/bInterfaceSubClass"); subclass="${subclass,,}"; subclass="${subclass//[[:space:]]/}"
            protocol=$(<"$iface_dir/bInterfaceProtocol"); protocol="${protocol,,}"; protocol="${protocol//[[:space:]]/}"
            
            # זיהוי HID (Class 03): Subclass 01 = מקלדת, Subclass 02 = עכבר
            if [[ "$class" == "03" && ("$subclass" == "01" || "$subclass" == "02") ]]; then
                iface="03:${subclass}:${protocol:-00}"
                add_rule "$vid:$pid" "$iface" ""
                echo "  Detected via sysfs: ${vid}:${pid} interface ${iface}${devname:+ (${devname})}" >&2
            fi
        done
    done
    shopt -u nullglob
}

# ═══════════════════════════════════════════════════════════════════════════════
# פונקציה: תשאול ה-Daemon של USBGuard באמצעות ה-IPC שלו (קבלת ה-Hash החיוני)
# ═══════════════════════════════════════════════════════════════════════════════
detect_usbguard() {
    # אם פקודת ה-CLI של usbguard לא קיימת, נצא בשקט ללא שגיאה
    command -v usbguard >/dev/null 2>&1 || return 0
    
    while IFS= read -r line; do
        # ניתוח מבנה השורה של usbguard: "מזהה: סטטוס id VID:PID שאר_הנתונים"
        [[ "$line" =~ ^[0-9]+:[[:space:]]+(allow|block)[[:space:]]+id[[:space:]]+([0-9a-fA-F]{4}:[0-9a-fA-F]{4})(.*)$ ]] || continue
        local id="${BASH_REMATCH[2]}" rest="${BASH_REMATCH[3]}"
        
        # חילוץ ה-Hash המאובטח מתוך סוגריים, אם קיים
        local hash=""
        if [[ "$rest" =~ hash[[:space:]]+\"([^\"]+)\" ]]; then
            hash="${BASH_REMATCH[1]}"
        fi
        
        # [Zero-PCRE] חילוץ ממשקי with-interface בלולאת Regex פנימית טהורה של Bash.
        # מחליף לחלוטין את התלות ב-grep -oP השביר ולא פורטבילי.
        local temp_rest="$rest"
        while [[ "$temp_rest" =~ with-interface[[:space:]]+([^[:space:]]+) ]]; do
            local iface="${BASH_REMATCH[1]}"
            # קיצוץ המחרוזת שנותרה כדי להתקדם לממשק הבא בשורה (אם מדובר במכשיר משולב)
            temp_rest="${temp_rest#*"$iface"}"
            
            # סינון: רק ממשקי HID מסוג מקלדת (03:01) או עכבר (03:02)
            if [[ "$iface" == 03:01:* || "$iface" == 03:02:* ]]; then
                if [[ -n "$hash" ]]; then
                    add_rule "$id" "$iface" "$hash"
                    echo "  Detected via usbguard: ${id} interface ${iface} hash \"${hash}\"" >&2
                else
                    add_rule "$id" "$iface" ""
                    echo "  Detected via usbguard: ${id} interface ${iface} (no hash)" >&2
                fi
            fi
        done
    done < <(usbguard list-devices 2>/dev/null || true)
}

# ═══════════════════════════════════════════════════════════════════════════════
# פונקציה: הזרקה מנוהלת ומאובטחת של החוקים לקובץ 00-system.rules
# ═══════════════════════════════════════════════════════════════════════════════
insert_rules() {
    # יצירת קובץ זמני מאובטח ב-tmp
    TMP_FILE=$(mktemp -t usbguard_host_input_XXXXXX) || {
        echo "ERROR: Cannot create temporary file" >&2
        exit 1
    }
    
    local found_section=false in_section=false inserted=false
    local line clean_line
    
    # קריאת קובץ החוקים הקיים שורה אחר שורה
    while IFS= read -r line || [[ -n "$line" ]]; do
        # חסינות לקבצי Windows (CRLF): הסרת תווי \r סמויים ורווחים מיותרים בסוף השורה
        clean_line="${line%$'\r'}"
        clean_line="${clean_line%"${clean_line##*[![:space:]]}"}"
        
        # זיהוי תחילת סעיף הזרקת התקני הקלט
        if [[ "$clean_line" == "# === HOST INPUT START ===" ]]; then
            found_section=true
            in_section=true
            echo "$line" >> "$TMP_FILE"
            continue
        fi
        
        # זיהוי סוף הסעיף - כאן תתבצע הזרקת כל החוקים החדשים שזיהינו
        if [[ "$clean_line" == "# === HOST INPUT END ===" ]]; then
            if [[ "$inserted" == "false" && ${#RULES[@]} -gt 0 ]]; then
                echo "" >> "$TMP_FILE"
                echo "# Host keyboard/mouse devices (auto-detected by detect-host-input.sh)" >> "$TMP_FILE"
                echo "# These are added automatically during installation — do not remove this line:" >> "$TMP_FILE"
                echo "# === HOST INPUT START ===" >> "$TMP_FILE"
                
                # שימוש ב-mapfile ו-sort -u בצורה בטוחה (תואם set -euo pipefail)
                local sorted_rules=()
                mapfile -t sorted_rules < <(printf '%s\n' "${RULES[@]}" | sort -u)
                for rule in "${sorted_rules[@]}"; do
                    [[ -n "$rule" ]] || continue
                    printf '%s\n' "$rule" >> "$TMP_FILE"
                    echo "Added: $rule" >&2
                done
                echo "# === HOST INPUT END ===" >> "$TMP_FILE"
                inserted=true
            fi
            echo "$line" >> "$TMP_FILE"
            in_section=false
            continue
        fi
        
        # אם אנחנו כרגע בתוך בלוק ה-HOST INPUT הישן, נדלג (מבצע דריסה/עדכון של הבלוק)
        [[ "$in_section" == "true" ]] && continue
        
        # העתקת שורות רגילות שנמצאות מחוץ לבלוק ההזרקה
        echo "$line" >> "$TMP_FILE"
    done < "$TARGET"
    
    # מקרה קצה: אם הבלוק המיועד לא נמצא בכלל בקובץ, נרפד ונוסיף אותו בסוף הקובץ
    if [[ "$found_section" == "false" ]]; then
        echo "" >> "$TMP_FILE"
        echo "# Host keyboard/mouse devices (auto-detected by detect-host-input.sh)" >> "$TMP_FILE"
        echo "# These are added automatically during installation — do not remove this line:" >> "$TMP_FILE"
        echo "# === HOST INPUT START ===" >> "$TMP_FILE"
        inserted=true
        
        if [[ ${#RULES[@]} -gt 0 ]]; then
            local sorted_rules=()
            mapfile -t sorted_rules < <(printf '%s\n' "${RULES[@]}" | sort -u)
            for rule in "${sorted_rules[@]}"; do
                [[ -n "$rule" ]] || continue
                printf '%s\n' "$rule" >> "$TMP_FILE"
                echo "Added: $rule" >&2
            done
        fi
        echo "# === HOST INPUT END ===" >> "$TMP_FILE"
    fi
    
    # החלפה אטומית של קובץ המקור בקובץ החדש והמעודכן
    mv "$TMP_FILE" "$TARGET"
    TMP_FILE="" # איפוס המשתנה מונע מה-Trap (באירוע EXIT) למחוק את הקובץ האמיתי שהרגע יצרנו
    
    # הקשחת הרשאות קובץ החוקים (קריאה וכתיבה ל-root בלבד)
    chmod 600 "$TARGET"
    chown root:root "$TARGET"
    echo "Host input allow rules ready in $TARGET" >&2
}

# ═══════════════════════════════════════════════════════════════════════════════
# גוף ההרצה הראשי (MAIN)
# ═══════════════════════════════════════════════════════════════════════════════
echo "Scanning for host input devices (keyboard/mouse)..." >&2
detect_sysfs       # סבב א': זיהוי חומרתי ישיר דרך הקרנל
detect_usbguard    # סבב ב': העשרת החוקים ב-Hash דרך ה-Daemon של USBGuard

# אם לא נמצאו התקני HID פיזיים, נעצור ללא שינוי הקובץ
if [[ ${#RULES[@]} -eq 0 ]]; then
    echo "No host keyboard/mouse USB HID interfaces detected" >&2
    exit 0
fi

echo "Found ${#RULES[@]} host input rule(s) to add" >&2
insert_rules
echo "Done. Host input allow rules ready in ${TARGET}" >&2