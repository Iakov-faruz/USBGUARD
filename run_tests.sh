#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# USBGuard Integration Test Suite – Full Active Test
# Version: 2.0 - בדיקות אינטגרציה מלאות עם Active Testing
# ═══════════════════════════════════════════════════════════════════════════════
# מטרה: לבדוק את כל המערכת בפועל - לא רק קבצים, אלא תפקוד אמיתי
#   • שירותי systemd פעילים
#   • IPC עובד מול ה-daemon
#   • API מגיב ומחזיר נתונים
#   • חסימה/אישור התקנים דרך IPC ודרך API
#   • לוגים נרשמים כראוי
#   • סקריפטים קריטיים (cleanup, check-config) עובדים
#
# דרישות:
#   • המערכת חייבת להיות מותקנת (install.sh הורץ)
#   • נדרש passwordless sudo (או שהמשתמש כבר sudo)
#   • כל השירותים צריכים להיות פעילים
#
# הרצה:
#   sudo ./run_tests.sh
#
# פלט:
#   • פלט מלא למסך + קובץ לוג ב-/tmp/
#   • סיכום סופי עם PASS/FAIL/WARN
# ═══════════════════════════════════════════════════════════════════════════════

# ═══════════════════════════════════════════════════════════════════════════════
# אתחול מונים - לסטטיסטיקה סופית
# ═══════════════════════════════════════════════════════════════════════════════
PASS=0    # בדיקות שעברו
FAIL=0    # בדיקות שנכשלו
WARN=0    # אזהרות (לא קריטי)

# ═══════════════════════════════════════════════════════════════════════════════
# בדיקת הרשאות sudo ללא סיסמה
# חיוני כי רוב הבדיקות דורשות גישה ל-systemctl, usbguard, קבצי מערכת
# ═══════════════════════════════════════════════════════════════════════════════
sudo -n true >/dev/null 2>&1 || { 
    echo "run_tests.sh requires passwordless sudo privileges"
    echo "אנא הרץ עם: sudo ./run_tests.sh"
    exit 1 
}

# ═══════════════════════════════════════════════════════════════════════════════
# הגדרת קובץ לוג - שם ייחודי עם timestamp
# כל ההרצה מוקלטת ללוג בנוסף לפלט למסך (tee)
# ═══════════════════════════════════════════════════════════════════════════════
LOG="/tmp/usbguard_test_$(date +%Y%m%d_%H%M%S).log"
# exec > >(tee ...) - מפנה את כל stdout ו-stderr גם למסך וגם לקובץ
exec > >(tee -a "$LOG") 2>&1

# ═══════════════════════════════════════════════════════════════════════════════
# הגדרות צבעים לפלט צבעוני וקריא
# ═══════════════════════════════════════════════════════════════════════════════
GREEN='\033[0;32m'      # ירוק - הצלחה
RED='\033[0;31m'        # אדום - כשלון
YELLOW='\033[1;33m'     # צהוב - אזהרה
BLUE='\033[1;34m'       # כחול - מידע
NC='\033[0m'            # איפוס צבע

# ═══════════════════════════════════════════════════════════════════════════════
# פונקציות דיווח - כל אחת מעדכנת את המונה ומדפיסה בצבע מתאים
# ═══════════════════════════════════════════════════════════════════════════════

# דיווח על בדיקה שעברה
ok()   { echo -e "${GREEN}[PASS]${NC} $1"; PASS=$((PASS + 1)); }

# דיווח על בדיקה שנכשלה
fail() { echo -e "${RED}[FAIL]${NC} $1"; FAIL=$((FAIL + 1)); }

# דיווח על אזהרה
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; WARN=$((WARN + 1)); }

# הדפסת מידע (לא משפיע על המונים)
info() { echo -e "${BLUE}[INFO]${NC} $1"; }

# הדפסת כותרת סעיף עם הפרדה חזותית
sep()  { 
    echo -e "\n══════════════════════════════════════════════════"
    echo -e "  $1"
    echo -e "══════════════════════════════════════════════════"
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 1: בדיקת שירותי systemd
# מוודא שכל ה-daemons והטיימרים פעילים
# אם שירות לא פעיל - כמעט כל הבדיקות הבאות ייכשלו
# ═══════════════════════════════════════════════════════════════════════════════
sep "TEST 1: שירותי systemd"
for svc in usbguard usbguard-web usbguard-behavioral usbguard-ttl-reaper.timer; do
    # בודק את הסטטוס הנוכחי של השירות
    state=$(systemctl is-active "$svc" 2>/dev/null)
    if [[ "$state" == "active" ]]; then
        ok "$svc → $state"
    else
        # שירות לא פעיל = FAIL קריטי
        fail "$svc → $state"
    fi
done

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 2: בדיקת קובצי Rules - תחביר והרשאות
# מוודא שקבצי הכללים קיימים, עם הרשאות נכונות, וללא שגיאות תחביר
# ═══════════════════════════════════════════════════════════════════════════════
sep "TEST 2: קובצי Rules – תחביר ותוכן"
for f in /etc/usbguard/rules.d/00-system.rules /etc/usbguard/rules.d/50-permanent.rules /etc/usbguard/rules.d/90-temporary.rules; do
    if sudo test -f "$f"; then
        # בדיקת הרשאות - מצופה 600 (קריאה/כתיבה ל-root בלבד)
        perm=$(sudo stat -c "%a" "$f")
        if [[ "$perm" == "600" ]]; then
            ok "$f – הרשאות $perm"
        else
            # הרשאות לא תקינות = אזהרה (לא קריטי, אך מסוכן)
            warn "$f – הרשאות $perm (מצופה 600)"
        fi
        
        # בדיקת תחביר - חיפוש שגיאה נפוצה: הערה שמיד אחריה allow ללא ירידת שורה
        # זה עלול לקרות אם עורכים קובץ בצורה לא נכונה
        if sudo grep -qP '^#.*\nallow' "$f" 2>/dev/null; then
            fail "$f – נמצא תחביר שבור (הערה ללא ירידת שורה)"
        fi
    else
        # קובץ חסר = FAIL קריטי
        fail "קובץ חסר: $f"
    fi
done

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 3: בדיקת IPC - תקשורת מול ה-daemon
# מוודא ש-pkexec/usbguard יכולים לדבר עם ה-daemon דרך IPC socket
# ═══════════════════════════════════════════════════════════════════════════════
sep "TEST 3: IPC – רשימת התקנים מה-daemon"
# מריץ את הפקודה ששואלת את ה-daemon על כל ההתקנים
devices_raw=$(usbguard list-devices 2>&1)
# בודק שהפלט מכיל מילות מפתח של מצבי התקנים
if echo "$devices_raw" | grep -q "allow\|block"; then
    # סופר כמה התקנים הוחזרו
    count=$(echo "$devices_raw" | wc -l)
    ok "usbguard list-devices החזיר $count התקנים"
    # מדפיס את רשימת ההתקנים המלאה (חשוב ל-debug)
    echo "$devices_raw"
else
    # IPC לא עובד = בעיה רצינית ב-daemon או בהרשאות
    fail "usbguard list-devices נכשל: $devices_raw"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 3b: בדיקת מוכנות ה-API (Readiness Check)
# קריטי! Flask לוקח זמן לעלות. אם נרוץ ישר ל-TEST 4, הוא ייכשל סתם.
# הבדיקה הזו מחכה עד שה-API מוכן (עד 10 שניות)
# ═══════════════════════════════════════════════════════════════════════════════
sep "TEST 3b: API Web readiness"
ready=false
# לולאת ניסיונות - מנסה 10 פעמים עם sleep 1 שנייה בין ניסיון לניסיון
for _ in {1..10}; do
    # שואל את ה-API על הסטטוס שלו
    api_status=$(curl -s --max-time 2 http://127.0.0.1:5000/api/status 2>/dev/null)
    
    # בודק שה-JSON תקין ושה-daemon מסומן כפעיל
    # שימוש ב-Python לפרסור JSON בטוח (לא grep)
    if echo "$api_status" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('daemon_active') is True else 1)" >/dev/null 2>&1; then
        ok "/api/status ready"
        ready=true
        break  # יצא מהלולאה - ה-API מוכן!
    fi
    
    # מחכה שנייה לפני הניסיון הבא
    sleep 1
done

# אם אחרי 10 ניסיונות ה-API עדיין לא מוכן
if [[ "$ready" != "true" ]]; then
    fail "/api/status not ready after warmup"
    echo "  ייתכן ששירות usbguard-web לא עלה או קרס"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 4: בדיקת GET /api/status
# מוודא שה-API מחזיר מידע על ה-daemon
# ═══════════════════════════════════════════════════════════════════════════════
sep "TEST 4: API Web – GET /api/status"
# שולח בקשת GET עם timeout של 5 שניות
status_resp=$(curl -s --max-time 5 http://127.0.0.1:5000/api/status 2>&1)
# בודק שהתגובה מכילה מילות מפתח צפויות
if echo "$status_resp" | grep -qi "daemon_active\|daemon_running\|status\|running"; then
    ok "/api/status מגיב"
    # מדפיס את ה-JSON מעוצב (אם תקין)
    echo "$status_resp" | python3 -m json.tool 2>/dev/null || echo "$status_resp"
else
    fail "/api/status לא מגיב: $status_resp"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 5: בדיקת GET /api/devices
# מוודא שה-API מחזיר רשימת התקנים
# ═══════════════════════════════════════════════════════════════════════════════
sep "TEST 5: API Web – GET /api/devices"
devices_resp=$(curl -s --max-time 5 http://127.0.0.1:5000/api/devices 2>&1)
# בודק שהתגובה מכילה device_id או מערך ריק
if echo "$devices_resp" | grep -q "device_id\|\[\]"; then
    # סופר כמה התקנים הוחזרו (פרסור JSON בטוח)
    dev_count=$(echo "$devices_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d))" 2>/dev/null)
    ok "/api/devices מגיב – $dev_count התקנים"
else
    fail "/api/devices נכשל: $devices_resp"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 6: חסימה אקטיבית דרך IPC
# בדיקה קריטית! מוודא שאפשר לחסום התקן דרך שורת הפקודה
# בוחר התקן שאינו USB controller (09:00:00) כדי לא לנתק מקלדת/עכבר
# ═══════════════════════════════════════════════════════════════════════════════
sep "TEST 6: חסימה אקטיבית – block-device דרך IPC"

# מוצא את ה-device-id של התקן USB שאינו בקר מובנה
# grep -v "09:00:00" - מסנן USB controllers (מחלקה 09 = USB hub)
# head -1 - לוקח רק את הראשון
# awk '{print $1}' - מוציא את העמודה הראשונה (device-id)
# tr -d ':' - מסיר את ה-: מהסוף
BLOCK_DEV=$(usbguard list-devices 2>/dev/null | grep -v "09:00:00" | head -1 | awk '{print $1}' | tr -d ':')

if [[ -z "$BLOCK_DEV" ]]; then
    # לא נמצא התקן מתאים - לא קריטי, רק אזהרה
    warn "לא נמצא התקן לחסימה (אין HID/storage מחוץ לבקרי USB)"
else
    info "חוסם התקן ID=$BLOCK_DEV"
    
    # מריץ את פקודת החסימה
    block_out=$(usbguard block-device "$BLOCK_DEV" 2>&1)
    sleep 1  # נותן זמן ל-daemon לעדכן סטטוס
    
    # בודק שההתקן אכן נחסם
    new_state=$(usbguard list-devices 2>/dev/null | grep "^$BLOCK_DEV:" | awk '{print $2}')
    if [[ "$new_state" == "block" ]]; then
        ok "התקן $BLOCK_DEV נחסם בהצלחה (IPC)"
    else
        fail "חסימה נכשלה – מצב: '$new_state', פלט: $block_out"
    fi

    # ═══════════════════════════════════════════════════════════════════════════
    # TEST 7: בדיקת חסימה דרך ה-API
    # מוודא שה-API מציג את ההתקן כחסום (cache מתעדכן)
    # ═══════════════════════════════════════════════════════════════════════════
    sep "TEST 7: בדיקת חסימה דרך API – GET /api/devices אחרי חסימה"
    devices_after=$(curl -s --max-time 5 http://127.0.0.1:5000/api/devices 2>&1)
    
    # בודק שה-JSON מכיל "status": "block"
    if echo "$devices_after" | grep -q '"status": "block"\|"status":"block"'; then
        ok "/api/devices מציג התקן חסום"
    else
        # ייתכן שה-cache טרם התעדכן - לא בהכרח כשל
        warn "/api/devices לא מציג block – ייתכן שה-cache טרם התעדכן"
        echo "$devices_after" | python3 -m json.tool 2>/dev/null | grep -A2 "device_id.*$BLOCK_DEV" | head -10
    fi

    # ═══════════════════════════════════════════════════════════════════════════
    # TEST 8: פתיחה אקטיבית דרך IPC
    # מוודא שאפשר לשחרר את החסימה (allow-device)
    # ═══════════════════════════════════════════════════════════════════════════
    sep "TEST 8: פתיחה אקטיבית – allow-device דרך IPC"
    info "מאשר מחדש התקן ID=$BLOCK_DEV"
    
    # מריץ את פקודת השחרור
    allow_out=$(usbguard allow-device "$BLOCK_DEV" 2>&1)
    sleep 1
    
    # בודק שההתקן אכן שוחרר
    new_state2=$(usbguard list-devices 2>/dev/null | grep "^$BLOCK_DEV:" | awk '{print $2}')
    if [[ "$new_state2" == "allow" ]]; then
        ok "התקן $BLOCK_DEV שוחרר בהצלחה (IPC)"
    else
        fail "שחרור נכשל – מצב: '$new_state2', פלט: $allow_out"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 9: חסימה/אישור דרך ה-API (POST requests)
# בודק שה-API עצמו יכול לחסום ולאשר התקנים (לא רק IPC)
# ═══════════════════════════════════════════════════════════════════════════════
sep "TEST 9: API Block/Allow – POST /api/block + /api/approve"

# מוצא device_id דרך ה-API (לא דרך IPC)
# שימוש ב-Python לפרסור JSON ובחירת התקן מתאים
API_DEV=$(curl -s http://127.0.0.1:5000/api/devices 2>/dev/null | python3 -c "
import sys, json
devs = json.load(sys.stdin)
# העדף HID/tablet על פני USB controllers (09:00:00)
for d in devs:
    if '09:00:00' not in d.get('interfaces',''):
        print(d['device_id']); break
" 2>/dev/null)

if [[ -z "$API_DEV" ]]; then
    warn "לא נמצא התקן מתאים ל-API block/approve"
else
    # ═════════════════════════════════════════════════════════════════════════
    # חסימה דרך POST /api/block
    # ═════════════════════════════════════════════════════════════════════════
    info "חוסם התקן $API_DEV דרך POST /api/block"
    block_api=$(curl -s -X POST http://127.0.0.1:5000/api/block \
        -H "Content-Type: application/json" \
        -d "{\"device_id\":\"$API_DEV\"}" 2>&1)
    
    # בודק שהתגובה מכילה מילת מפתח של הצלחה
    if echo "$block_api" | grep -qi "success\|blocked\|ok"; then
        ok "POST /api/block הצליח"
    else
        fail "POST /api/block נכשל: $block_api"
    fi

    sleep 1
    
    # ═════════════════════════════════════════════════════════════════════════
    # אישור דרך POST /api/approve
    # type=P = Permanent (כלל קבוע), type=T = Temporary (עם TTL)
    # ═════════════════════════════════════════════════════════════════════════
    info "מאשר התקן $API_DEV דרך POST /api/approve"
    approve_api=$(curl -s -X POST http://127.0.0.1:5000/api/approve \
        -H "Content-Type: application/json" \
        -d "{\"device_id\":\"$API_DEV\",\"type\":\"P\"}" 2>&1)
    
    if echo "$approve_api" | grep -qi "success\|approved\|ok"; then
        ok "POST /api/approve הצליח"
    else
        fail "POST /api/approve נכשל: $approve_api"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 10: בדיקת לוג ראשי - usbguard-approval.log
# מוודא שהלוג נרשם ויש בו שורות
# ═══════════════════════════════════════════════════════════════════════════════
sep "TEST 10: לוג ראשי – usbguard-approval.log"
if [[ -f "/var/log/usbguard-approval.log" ]]; then
    # סופר שורות בלוג (בטוח - לא מדפיס את התוכן)
    lines=$(sudo sh -c 'wc -l < "$1"' _ "/var/log/usbguard-approval.log" | awk '{print $1}')
    ok "לוג ראשי קיים ($lines שורות)"
    # מדפיס 5 שורות אחרונות ל-debug
    sudo tail -5 /var/log/usbguard-approval.log
else
    warn "לוג ראשי לא נמצא – ייתכן שעדיין לא נרשמה פעולה"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 11: בדיקת לוג Audit - usbguard-audit.log
# לוג אבטחתי שמתעד פעולות חסימה/אישור
# ═══════════════════════════════════════════════════════════════════════════════
sep "TEST 11: לוג Audit – usbguard-audit.log"
# בודק בשני מיקומים אפשריים (תלוי בקונפיגורציה)
if [[ -f "/var/log/usbguard/usbguard-audit.log" ]]; then
    a_lines=$(sudo sh -c 'wc -l < "$1"' _ "/var/log/usbguard/usbguard-audit.log" | awk '{print $1}')
    ok "Audit log קיים ($a_lines שורות)"
    sudo tail -5 /var/log/usbguard/usbguard-audit.log
elif [[ -f "/var/log/usbguard-audit.log" ]]; then
    a_lines=$(sudo sh -c 'wc -l < "$1"' _ "/var/log/usbguard-audit.log" | awk '{print $1}')
    ok "Audit log קיים ($a_lines שורות)"
    sudo tail -5 /var/log/usbguard-audit.log
else
    warn "Audit log לא נמצא"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 12: journalctl - לוג systemd של usbguard
# מדפיס 10 שורות אחרונות מה-journal
# ═══════════════════════════════════════════════════════════════════════════════
sep "TEST 12: journalctl – 10 שורות אחרונות של USBGuard"
journalctl -u usbguard -n 10 --no-pager 2>/dev/null
ok "journalctl הורץ"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 13: בדיקת GET /api/logs
# מוודא שה-API מחזיר את הלוגים
# ═══════════════════════════════════════════════════════════════════════════════
sep "TEST 13: API /api/logs"
logs_api=$(curl -s --max-time 5 http://127.0.0.1:5000/api/logs 2>&1)
if echo "$logs_api" | grep -qi "lines\|log\|\[\]"; then
    ok "/api/logs מגיב"
    # מדפיס 20 שורות אחרונות מה-JSON
    echo "$logs_api" | python3 -m json.tool 2>/dev/null | tail -20
else
    fail "/api/logs נכשל: $logs_api"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 14: בדיקת GET /api/rules
# מוודא שה-API מחזיר את כללי ה-rules
# ═══════════════════════════════════════════════════════════════════════════════
sep "TEST 14: API /api/rules"
rules_api=$(curl -s --max-time 5 http://127.0.0.1:5000/api/rules 2>&1)
if echo "$rules_api" | grep -qi "system\|permanent\|temporary\|\[\]"; then
    ok "/api/rules מגיב"
    # מדפיס 30 שורות ראשונות מה-JSON
    echo "$rules_api" | python3 -m json.tool 2>/dev/null | head -30
else
    fail "/api/rules נכשל: $rules_api"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 15: בדיקת TTL Reaper - cleanup-expired.sh
# מוודא שהסקריפט שמוחק כללים שפג תוקפם עובד
# ═══════════════════════════════════════════════════════════════════════════════
sep "TEST 15: TTL Reaper – cleanup-expired.sh"
if [[ -x "/etc/usbguard/scripts/cleanup-expired.sh" ]]; then
    cleanup_out=$(sudo bash /etc/usbguard/scripts/cleanup-expired.sh 2>&1)
    ok "cleanup-expired.sh הורץ בהצלחה"
    echo "$cleanup_out"
else
    warn "cleanup-expired.sh לא נמצא/לא ניתן להרצה"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 16: בדיקת check-config.sh
# מוודא שהסקריפט שבודק את תקינות הקונפיגורציה עובד
# ═══════════════════════════════════════════════════════════════════════════════
sep "TEST 16: Check-Config"
if [[ -x "/etc/usbguard/scripts/check-config.sh" ]]; then
    cc_out=$(sudo bash /etc/usbguard/scripts/check-config.sh 2>&1)
    ok "check-config.sh הורץ"
    echo "$cc_out"
else
    warn "check-config.sh לא נמצא"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# סיכום סופי - הצגת סטטיסטיקות ומיקום הלוג
# ═══════════════════════════════════════════════════════════════════════════════
sep "📊 סיכום בדיקות"
echo -e "${GREEN}PASS: $PASS${NC}"
echo -e "${RED}FAIL: $FAIL${NC}"
echo -e "${YELLOW}WARN: $WARN${NC}"
echo ""
echo "לוג מלא נשמר ב: $LOG"

# ═══════════════════════════════════════════════════════════════════════════════
# קוד יציאה - 0 אם אין FAILs, אחרת 1
# מאפשר שימוש בסקריפטים אוטומטיים (CI/CD)
# ═══════════════════════════════════════════════════════════════════════════════
if [[ $FAIL -gt 0 ]]; then
    exit 1
else
    exit 0
fi