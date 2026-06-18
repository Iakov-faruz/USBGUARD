# USBGuard Approval Manager v3.0

מערכת לניהול, ניטור ובקרה של התקני USB, מעל מנוע האכיפה `usbguard`.
כוללת ממשק Web, ממשק TUI לשליטה ישירה, ניטור BadUSB אוטומטי, ו-API REST מלא.

---

## תוכן עניינים

- [תכונות](#תכונות)
- [ארכיטקטורה](#ארכיטקטורה)
- [דרישות מערכת](#דרישות-מערכת)
- [התקנה](#התקנה)
- [הסרה](#הסרה)
- [בדיקה](#בדיקה)
- [שימוש](#שימוש)
- [מבנה התיקיות](#מבנה-התיקיות)
- [API](#api)
- [לוגים](#לוגים)
- [ניפוי תקלות](#ניפוי-תקלות)
- [רישיון](#רישיון)

---

## תכונות

- **שליטה על התקני USB** – הצגה, אישור וחסימה של התקנים מחוברים
- **BadUSB Monitor** – ניטור אוטומטי של התקני HID (מקלדת/עכבר) עם זיהוי התקפה לפי קצב אירועים (EPS)
- **ניהול חוקרים** – חוקרי מערכת, קבועים, וזמניים עם TTL (פג תוקף אוטומטי)
- **Fingerprinting** – זיהוי התקנים לפי טביעת אצבע פיזית (lsusb -v)
- **IPC מהיר** – שימוש ב-usbguard-python (Socket IPC) עם נפילה אוטומטית ל-subprocess
- **Rate Limiting** – הגנה על ה-API מפני DoS (Flask-Limiter)
- **Error Sanitization** – הודעות שגיאה כלליות ב-Production, לוג מפורט בצד השרת
- **התקנה מאובטחת** – 8 שלבים, --dry-run, --force, אימות חבילות קיימות/מעודכנות
- **QA Testing** – master-checklist.sh (177 בדיקות) + run_tests.sh (22 בדיקות E2E)

---

## ארכיטקטורה

```
web/app.py ──── usbguard-python ──── USBGuard Daemon (IPC)
    │
    └──── subprocess ("usbguard list-devices") ──┘ (גיבוי)

scripts/badusb-monitor.py ──── evdev ──── POST /api/block
```

**מסלול מהיר:** Flask → usbguard-python (IPC) → USBGuard Daemon
**מסלול גיבוי:** Flask → subprocess → USBGuard Daemon
**BadUSB:** evdev → Events Per Second → חסימה אוטומטית דרך ה-API

---

## דרישות מערכת

- Linux (Kernel 4.15+)
- Bash 5.0+, Python 3.8+
- USBGuard 1.1.2+, systemd 245+, sudo
- חבילות Python: Flask, Flask-Limiter, (usbguard-python, evdev – אופציונליים)

---

## התקנה

```bash
# 1. שיבוט
git clone <url>
cd USBGUARD2

# 2. התקנה
sudo ./install.sh

# אופציות:
sudo ./install.sh --dry-run   # הצגת פעולות ללא ביצוע
sudo ./install.sh --force     # התקנה ללא אישור
```

הסקריפט בודק אילו חבילות מותקנות, אילו חסרות ואילו ניתנות לשדרוג, ומציג דוח לפני ההתקנה.

8 שלבי התקנה:
1. התקנת חבילות מערכת (usbguard, python3, python3-pip, python3-evdev, python3-flask)
2. יצירת קבוצה usbadmins
3. מבנה תיקיות (/etc/usbguard/)
4. תצורת USBGuard daemon
5. פריסת סקריפטים וקבצים
6. התקנת שירותי systemd
7. תצורת logrotate ו-sudoers
8. אימות סופי

לאחר ההתקנה: http://127.0.0.1:5000

---

## הסרה

```bash
sudo ./install.sh --uninstall
```

ההסרה כוללת:
- עצירת כל השירותים
- הסרת קבצי systemd
- הסרת חבילות USBGuard
- הסרת sudoers ו-logrotate
- הסרת תיקיית /etc/usbguard/
- הסרת קבצי לוג
- הסרת קבוצת usbadmins

---

## בדיקה

```bash
# בדיקה מקיפה (177 בדיקות)
sudo ./master-checklist.sh

# בדיקות E2E (22 בדיקות)
bash run_tests.sh

# בדיקות unit tests
python3 -m unittest unit_test.test_debug -v
python3 -m unittest unit_test.test_e2e_session -v

# בדיקות pytest
pytest -q
```

master-checklist.sh בודק:
- מבנה הפרויקט (37 קבצים)
- תחביר Bash (19 סקריפטים)
- תחביר Python (9 קבצים)
- ביטחון config-reader (4 בדיקות injection)
- פעולת logger
- מבנה rules.d
- BadUSB monitor
- תלויות Python
- unit tests
- התקנת install.sh
- systemd units
- הרשאות קבצים
- API endpoints
- לוגים
- CRLF / line endings

run_tests.sh בודק:
- שירותי systemd
- חוקרים (תחביר ותוכן)
- IPC list-devices
- API status/devices/rules/logs
- Block/Allow דרך IPC
- Block/Allow דרך API
- לוגים ו-audit
- cleanup-expired.sh
- check-config.sh

---

## שימוש

### Web

| דף | תיאור |
|------|--------|
| Dashboard | סטטוס דמון, Reaper Timer, כמות חוקרים פעילים |
| Devices | התקני USB מחוברים – חסומים ומורשים |
| Rules | ניהול חוקרים לכל הקטגוריות |
| Inspector | צפייה מפורטת, אישור/חסימה, טביעת אצבע |

### שורת פקודה

```bash
sudo /etc/usbguard/scripts/usb-approve.sh        # TUI לאישור התקנים
sudo /etc/usbguard/scripts/usbguard-status.sh     # מצב המערכת
sudo /etc/usbguard/scripts/import-rules.sh --file rules.json
sudo /etc/usbguard/scripts/export-rules.sh
```

### לוגים

```bash
tail -f /var/log/usbguard-approval.log     # לוג ראשי
tail -f /var/log/usbguard-badusb.log        # לוג BadUSB
tail -f /var/log/usbguard-web.log           # לוג Web
journalctl -u usbguard -f                   # לוג systemd
```

---

## מבנה התיקיות

```
USBGUARD2/
├── conf/
│   └── approval-manager.conf
├── logrotate/
│   └── usbguard-approval
├── rules.d/
│   ├── 00-system.rules
│   ├── 50-permanent.rules
│   └── 90-temporary.rules
├── scripts/
│   ├── lib/
│   │   ├── backup.sh
│   │   ├── config-reader.sh
│   │   ├── device-utils.sh
│   │   ├── lock.sh
│   │   ├── logger.sh
│   │   ├── stages-core.sh
│   │   ├── stages-io.sh
│   │   ├── time-guards.sh
│   │   └── validators.sh
│   ├── backup-rules.sh
│   ├── badusb-monitor.py
│   ├── check-config.sh
│   ├── cleanup-expired.sh
│   ├── export-rules.sh
│   ├── fix-project.sh
│   ├── import-rules.sh
│   ├── restore-rules.sh
│   ├── usb-approve.sh
│   └── usbguard-status.sh
├── sudoers/
│   └── usbguard-approval
├── systemd/
│   ├── usbguard-behavioral.service
│   ├── usbguard-ttl-reaper.service
│   ├── usbguard-ttl-reaper.timer
│   └── usbguard-web.service
├── unit_test/
│   ├── conftest.py
│   ├── run_tests.sh
│   ├── setup_dependencies.sh
│   ├── test_app.py
│   ├── test_badusb_monitor.py
│   ├── test_bash_logic.py
│   ├── test_debug.py
│   ├── test_e2e_session.py
│   ├── test_integration.py
│   └── test_security.py
├── web/
│   ├── static/
│   │   ├── css/
│   │   │   └── style.css
│   │   └── js/
│   │       └── script.js
│   ├── templates/
│   │   └── index.html
│   ├── app.py
│   └── start-web.sh
├── .gitattributes
├── install.sh
├── LICENSE
├── master-checklist.sh
├── README.md
└── run_tests.sh
```

---

## API

| נתיב | שיטה | קצב | תיאור |
|------|------|------|--------|
| /api/status | GET | – | מצב דמון + מונה חוקרים |
| /api/devices | GET | – | רשימת התקני USB |
| /api/rules | GET | – | פירוט חוקרים לפי קטגוריה |
| /api/device-detail | GET | – | lsusb -v מורחב |
| /api/verify-fingerprint | POST | – | השוואת טביעת אצבע |
| /api/approve | POST | 5/min | אישור התקן |
| /api/block | POST | 5/min | חסימת התקן |
| /api/change-status | POST | 5/min | שינוי סוג אישור |
| /api/logs | GET | – | 50 שורות לוג אחרונות |

### תשובות API

**GET /api/status:**
```json
{
  "daemon_active": true,
  "timer_active": true,
  "active_rules_count": 9
}
```

**POST /api/approve:**
```json
{
  "device_id": "11",
  "type": "P"
}
```
type: `P` = permanent, `T` = temporary (עם TTL)

**POST /api/block:**
```json
{
  "device_id": "11"
}
```

---

## לוגים

| קובץ | פורמט | תיאור |
|-------|--------|--------|
| `/var/log/usbguard-approval.log` | `[YYYY-MM-DD HH:MM:SS] [LEVEL] [USER] [COMPONENT] MSG` | לוג ראשי – אישורים, חסימות, גיבויים |
| `/var/log/usbguard/usbguard-audit.log` | `[timestamp] (A) uid=... result=...` | לוג ביקורת USBGuard native |
| `/var/log/usbguard-web.log` | `YYYY-MM-DD HH:MM:SS - name - LEVEL - MSG` | לוג Flask API |
| `/var/log/usbguard-badusb.log` | `YYYY-MM-DD HH:MM:SS - name - LEVEL - MSG` | לוג BadUSB monitor |
| `/var/log/usbguard-install.log` | (stdout) | לוג התקנה |

### רמות לוג
- `DEBUG` – פירוט מלא
- `INFO` – פעולות רגילות
- `WARN` – אזהרות
- `ERROR` – שגיאות
- `CRITICAL` – שגיאות קריטיות

---

## הרשאות

| נתיב | הרשאות | בעלים | תיאור |
|------|--------|--------|--------|
| `/etc/usbguard/rules.d/` | 750 | root:usbadmins | תיקיית חוקים (נגיש לקבוצה) |
| `/etc/usbguard/rules.d/*.rules` | 600 | root:root | קבצי חוקים |
| `/etc/usbguard/scripts/lib/*.sh` | 640 | root:root | ספריות Bash |
| `/etc/usbguard/scripts/*.sh` | 755 | root:root | סקריפטים |
| `/var/log/usbguard-*.log` | 660 | root:usbadmins | קבצי לוג |
| `/etc/sudoers.d/usbguard-approval` | 440 | root:root | sudoers |

### sudoers
```
%usbadmins ALL=(root) NOPASSWD: USBGUARD_APPROVE, USBGUARD_BACKUP, USBGUARD_RESTORE, USBGUARD_IMPORT, USBGUARD_EXPORT
```

---

## Git / Linux Compatibility

- `.gitattributes` מאכף `eol=lf` לכל הקבצים
- `dos2unix` רץ ב-install.sh על כל הקבצים
- CRLF → LF אוטומטי ב-git checkout
- תומך ב-Windows (WSL) ו-Linux natивית

---

## ניפוי תקלות

| בעיה | פתרון |
|------|--------|
| "usbguard-python not available" | `pip3 install usbguard` |
| IPC לא מגיב | `systemctl restart usbguard` |
| badusb-monitor לא עובד | `python3 -c "from evdev import list_devices; print(list_devices())"` |
| חסימות רבות מדי ב-API | Production: 200/day, 50/hour. Debug: מנוטרל |
| run_tests.sh: Permission denied | `sudo bash run_tests.sh` או `sudo usermod -aG usbadmins $USER` |
| rules.d לא נגיש | `sudo chmod 750 /etc/usbguard/rules.d && sudo chown root:usbadmins /etc/usbguard/rules.d` |

---

## רישיון

MIT – ראה [LICENSE](LICENSE).