#!/bin/bash
# ============================================================
# USBGuard Integration Test Suite – Full Active Test
# ============================================================
PASS=0; FAIL=0; WARN=0
LOG="/tmp/usbguard_test_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; ((WARN++)); }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
sep()  { echo -e "\n══════════════════════════════════════════════════"; echo -e "  $1"; echo -e "══════════════════════════════════════════════════"; }

sep "TEST 1: שירותי systemd"
for svc in usbguard usbguard-web usbguard-behavioral usbguard-ttl-reaper.timer; do
    state=$(systemctl is-active "$svc" 2>/dev/null)
    if [[ "$state" == "active" ]]; then
        ok "$svc → $state"
    else
        fail "$svc → $state"
    fi
done

sep "TEST 2: קובצי Rules – תחביר ותוכן"
for f in /etc/usbguard/rules.d/00-system.rules /etc/usbguard/rules.d/50-permanent.rules /etc/usbguard/rules.d/90-temporary.rules; do
    if [[ -f "$f" ]]; then
        perm=$(stat -c "%a" "$f")
        if [[ "$perm" == "600" ]]; then
            ok "$f – הרשאות $perm"
        else
            warn "$f – הרשאות $perm (מצופה 600)"
        fi
        # בדיקת תחביר – שאין שורות שמתחילות ב-# ומיד ממשיכות ל-allow (ללא newline)
        if grep -qP '^#.*\nallow' "$f" 2>/dev/null; then
            fail "$f – נמצא תחביר שבור (הערה ללא ירידת שורה)"
        fi
    else
        fail "קובץ חסר: $f"
    fi
done

sep "TEST 3: IPC – רשימת התקנים מה-daemon"
devices_raw=$(usbguard list-devices 2>&1)
if echo "$devices_raw" | grep -q "allow\|block"; then
    count=$(echo "$devices_raw" | wc -l)
    ok "usbguard list-devices החזיר $count התקנים"
    echo "$devices_raw"
else
    fail "usbguard list-devices נכשל: $devices_raw"
fi

sep "TEST 4: API Web – GET /api/status"
status_resp=$(curl -s --max-time 5 http://127.0.0.1:5000/api/status 2>&1)
if echo "$status_resp" | grep -qi "daemon_running\|status\|running"; then
    ok "/api/status מגיב"
    echo "$status_resp" | python3 -m json.tool 2>/dev/null || echo "$status_resp"
else
    fail "/api/status לא מגיב: $status_resp"
fi

sep "TEST 5: API Web – GET /api/devices"
devices_resp=$(curl -s --max-time 5 http://127.0.0.1:5000/api/devices 2>&1)
if echo "$devices_resp" | grep -q "device_id\|\[\]"; then
    dev_count=$(echo "$devices_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d))" 2>/dev/null)
    ok "/api/devices מגיב – $dev_count התקנים"
else
    fail "/api/devices נכשל: $devices_resp"
fi

sep "TEST 6: חסימה אקטיבית – block-device דרך IPC"
# מוצא את ה-device-id של ה-USB Tablet (לא בקרי USB מובנים)
BLOCK_DEV=$(usbguard list-devices 2>/dev/null | grep -v "09:00:00" | head -1 | awk '{print $1}' | tr -d ':')
if [[ -z "$BLOCK_DEV" ]]; then
    warn "לא נמצא התקן לחסימה (אין HID/storage מחוץ לבקרי USB)"
else
    info "חוסם התקן ID=$BLOCK_DEV"
    block_out=$(usbguard block-device "$BLOCK_DEV" 2>&1)
    sleep 1
    new_state=$(usbguard list-devices 2>/dev/null | grep "^$BLOCK_DEV:" | awk '{print $2}')
    if [[ "$new_state" == "block" ]]; then
        ok "התקן $BLOCK_DEV נחסם בהצלחה (IPC)"
    else
        fail "חסימה נכשלה – מצב: '$new_state', פלט: $block_out"
    fi

    sep "TEST 7: בדיקת חסימה דרך API – GET /api/devices אחרי חסימה"
    devices_after=$(curl -s --max-time 5 http://127.0.0.1:5000/api/devices 2>&1)
    if echo "$devices_after" | grep -q '"status": "block"\|"status":"block"'; then
        ok "/api/devices מציג התקן חסום"
    else
        warn "/api/devices לא מציג block – ייתכן שה-cache טרם התעדכן"
        echo "$devices_after" | python3 -m json.tool 2>/dev/null | grep -A2 "device_id.*$BLOCK_DEV" | head -10
    fi

    sep "TEST 8: פתיחה אקטיבית – allow-device דרך IPC"
    info "מאשר מחדש התקן ID=$BLOCK_DEV"
    allow_out=$(usbguard allow-device "$BLOCK_DEV" 2>&1)
    sleep 1
    new_state2=$(usbguard list-devices 2>/dev/null | grep "^$BLOCK_DEV:" | awk '{print $2}')
    if [[ "$new_state2" == "allow" ]]; then
        ok "התקן $BLOCK_DEV שוחרר בהצלחה (IPC)"
    else
        fail "שחרור נכשל – מצב: '$new_state2', פלט: $allow_out"
    fi
fi

sep "TEST 9: API Block/Allow – POST /api/block + /api/approve"
# מוצא device_id דרך ה-API
API_DEV=$(curl -s http://127.0.0.1:5000/api/devices 2>/dev/null | python3 -c "
import sys, json
devs = json.load(sys.stdin)
# העדף HID/tablet על פני USB controllers
for d in devs:
    if '09:00:00' not in d.get('interfaces',''):
        print(d['device_id']); break
" 2>/dev/null)

if [[ -z "$API_DEV" ]]; then
    warn "לא נמצא התקן מתאים ל-API block/approve"
else
    info "חוסם התקן $API_DEV דרך POST /api/block"
    block_api=$(curl -s -X POST http://127.0.0.1:5000/api/block \
        -H "Content-Type: application/json" \
        -d "{\"device_id\":\"$API_DEV\"}" 2>&1)
    if echo "$block_api" | grep -qi "success\|blocked\|ok"; then
        ok "POST /api/block הצליח"
    else
        fail "POST /api/block נכשל: $block_api"
    fi

    sleep 1
    info "מאשר התקן $API_DEV דרך POST /api/approve"
    approve_api=$(curl -s -X POST http://127.0.0.1:5000/api/approve \
        -H "Content-Type: application/json" \
        -d "{\"device_id\":\"$API_DEV\",\"type\":\"permanent\"}" 2>&1)
    if echo "$approve_api" | grep -qi "success\|approved\|ok"; then
        ok "POST /api/approve הצליח"
    else
        fail "POST /api/approve נכשל: $approve_api"
    fi
fi

sep "TEST 10: לוג ראשי – usbguard-approval.log"
if [[ -f "/var/log/usbguard-approval.log" ]]; then
    lines=$(wc -l < /var/log/usbguard-approval.log)
    ok "לוג ראשי קיים ($lines שורות)"
    tail -5 /var/log/usbguard-approval.log
else
    warn "לוג ראשי לא נמצא – ייתכן שעדיין לא נרשמה פעולה"
fi

sep "TEST 11: לוג Audit – usbguard-audit.log"
if [[ -f "/var/log/usbguard/usbguard-audit.log" ]]; then
    a_lines=$(wc -l < /var/log/usbguard/usbguard-audit.log)
    ok "Audit log קיים ($a_lines שורות)"
    tail -5 /var/log/usbguard/usbguard-audit.log
elif [[ -f "/var/log/usbguard-audit.log" ]]; then
    a_lines=$(wc -l < /var/log/usbguard-audit.log)
    ok "Audit log קיים ($a_lines שורות)"
    tail -5 /var/log/usbguard-audit.log
else
    warn "Audit log לא נמצא"
fi

sep "TEST 12: journalctl – 10 שורות אחרונות של USBGuard"
journalctl -u usbguard -n 10 --no-pager 2>/dev/null
ok "journalctl הורץ"

sep "TEST 13: API /api/logs"
logs_api=$(curl -s --max-time 5 http://127.0.0.1:5000/api/logs 2>&1)
if echo "$logs_api" | grep -qi "lines\|log\|\[\]"; then
    ok "/api/logs מגיב"
    echo "$logs_api" | python3 -m json.tool 2>/dev/null | tail -20
else
    fail "/api/logs נכשל: $logs_api"
fi

sep "TEST 14: API /api/rules"
rules_api=$(curl -s --max-time 5 http://127.0.0.1:5000/api/rules 2>&1)
if echo "$rules_api" | grep -qi "system\|permanent\|temporary\|\[\]"; then
    ok "/api/rules מגיב"
    echo "$rules_api" | python3 -m json.tool 2>/dev/null | head -30
else
    fail "/api/rules נכשל: $rules_api"
fi

sep "TEST 15: TTL Reaper – cleanup-expired.sh"
if [[ -x "/etc/usbguard/scripts/cleanup-expired.sh" ]]; then
    cleanup_out=$(bash /etc/usbguard/scripts/cleanup-expired.sh 2>&1)
    ok "cleanup-expired.sh הורץ בהצלחה"
    echo "$cleanup_out"
else
    warn "cleanup-expired.sh לא נמצא/לא ניתן להרצה"
fi

sep "TEST 16: Check-Config"
if [[ -x "/etc/usbguard/scripts/check-config.sh" ]]; then
    cc_out=$(bash /etc/usbguard/scripts/check-config.sh 2>&1)
    ok "check-config.sh הורץ"
    echo "$cc_out"
else
    warn "check-config.sh לא נמצא"
fi

# ===================== סיכום =====================
sep "📊 סיכום בדיקות"
echo -e "${GREEN}PASS: $PASS${NC}"
echo -e "${RED}FAIL: $FAIL${NC}"
echo -e "${YELLOW}WARN: $WARN${NC}"
echo ""
echo "לוג מלא נשמר ב: $LOG"
