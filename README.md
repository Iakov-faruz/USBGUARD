# USBGuard Approval Manager v3.0

מערכת לניהול, ניטור ובקרה של התקני USB, מעל מנוע האכיפה `usbguard`.  
כוללת ממשק Web, ממשק TUI לשליטה ישירה, ניטור BadUSB אוטומטי, ו-API REST מלא.

---

## תוכן עניינים

- [USBGuard Approval Manager v3.0](#usbguard-approval-manager-v30)
  - [תוכן עניינים](#תוכן-עניינים)
  - [תכונות](#תכונות)
  - [ארכיטקטורה](#ארכיטקטורה)
  - [דרישות מערכת](#דרישות-מערכת)
  - [התקנה](#התקנה)
  - [שימוש](#שימוש)
    - [Web](#web)
    - [שורת פקודה](#שורת-פקודה)
    - [לוגים](#לוגים)
  - [מבנה התיקיות](#מבנה-התיקיות)
  - [API](#api)
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
**BadUSB:** evdef → Events Per Second → חסימה אוטומטית דרך ה-API

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

לאחר ההתקנה: http://127.0.0.1:5000

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
journalctl -u usbguard-web -f               # לוג systemd
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
├── web/
│   ├── static/
│   │   ├── css/
│   │   │   └── style.css
│   │   └── js/
│   │       └── script.js
│   ├── templates/
│   │   └── index.html
│   ├── venv/                # סביבה וירטואלית (נוצרת מקומית)
│   ├── app.py
│   └── start-web.sh
├── deploy-lib.sh
├── deploy-uninstall.sh
├── deploy.sh
├── install.sh
├── run-usbguard-web.sh
├── start.sh
├── validate_all.sh
├── README.md
└── LICENSE
```

> לתיאור מפורט של כל קובץ ראה [FILE-REFERENCE.md](FILE-REFERENCE.md).

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

---

## ניפוי תקלות

| בעיה | פתרון |
|------|--------|
| "usbguard-python not available" | `pip3 install usbguard` |
| IPC לא מגיב | `systemctl restart usbguard` |
| badusb-monitor לא עובד | `python3 -c "from evdev import list_devices; print(list_devices())"` |
| חסימות רבות מדי ב-API | Production: 200/day, 50/hour. Debug: מנוטרל |

---

## רישיון

MIT – ראה [LICENSE](LICENSE).