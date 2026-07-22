# תוכנית פעולה: הקשחת קובצי systemd
## USBGuard2 — Hardening Plan (COMPLETED ✅)

---

## סטטוס סופי — כל התיקונים בוצעו

| קובץ | תיקונים | סטטוס |
|------|---------|--------|
| **usbguard-behavioral.service** | 8 תיקונים | ✅ COMPLETED |
| **usbguard-protector.service** | 0 (כבר היה מתוקן) | ✅ ALREADY DONE |
| **usbguard-web.service** | 3 תיקונים | ✅ COMPLETED |
| **usbguard-ttl-reaper.service** | 2 תיקונים | ✅ COMPLETED |

---

## תיקונים שבוצעו

### usbguard-behavioral.service — 8 תיקונים

| # | תיקון | מה נעשה |
|---|-------|---------|
| 1 | **הסרת PrivateDevices=yes** | `PrivateDevices=yes` נמחק. הסיבה: חוסם גישה ל-`/dev/input/event*` הנדרש למוניטור HID |
| 2 | **הפעלת StateDirectory** | `StateDirectory=usbguard-manager` (0750) — הוסר ה-#. systemd יוצר תיקייה אוטומטית |
| 3 | **הפעלת LogsDirectory** | `LogsDirectory=usbguard` (0750) — הוסר ה-# |
| 4 | **הפעלת RuntimeDirectory** | `RuntimeDirectory=usbguard-manager` (0700) — הוסר ה-# |
| 5 | **HOME=/run/usbguard-manager** | שונה מ-`/tmp` ל-`/run/usbguard-manager` (תואם RuntimeDirectory) |
| 6 | **XDG_RUNTIME_DIR** | נוסף `Environment=XDG_RUNTIME_DIR=/run/usbguard-manager` |
| 7 | **ConditionPathExists** | נוסף `ConditionPathExists=/usr/local/bin/protector` ב-[Unit] |
| 8 | **SyslogIdentifier** | נוסף `SyslogIdentifier=usbguard-hid-monitor` |
| 9 | **Documentation=usbguard(8)** | שונה מ-`usbguard(1)` ל-`usbguard(8)` |
| 10 | **ReadWritePaths הוסר לחלוטין** | `ReadWritePaths=/etc/usbguard` נמחק. הפיילסיסטם read-only לחלוטין תחת `ProtectSystem=strict`. המוניטור מתקשר עם USBGuard דרך IPC בלבד |

### usbguard-web.service — 3 תיקונים

| # | תיקון | מה נעשה |
|---|-------|---------|
| 1 | **PartOf=usbguard.service** | נוסף ב-[Unit] לקישור lifecycle |
| 2 | **ConditionPathExists** | נוסף `ConditionPathExists=/usr/local/bin/protector` ב-[Unit] |
| 3 | **SystemCallFilter** | הוער ל-#. Flask משתמש ב-subprocess, `@system-service` עלול לחסום קריאות נחוצות כמו fork(). דורש בדיקה לפני הפעלה |

### usbguard-ttl-reaper.service — 2 תיקונים

| # | תיקון | מה נעשה |
|---|-------|---------|
| 1 | **ConditionPathExists** | נוסף `ConditionPathExists=/usr/local/bin/protector` ב-[Unit] |
| 2 | **PartOf=usbguard.service** | נוסף ב-[Unit] לקישור lifecycle |

(שימו לב: `SyslogIdentifier` ו-`HOME=/run/usbguard-manager` כבר היו קיימים — לא נדרש תיקון)

### usbguard-protector.service — 0 תיקונים (כבר היה מתוקן)

כבר הכיל את כל ההקשחות הדרושות:
- `StateDirectory=usbguard-manager` ✅
- `LogsDirectory=usbguard` ✅  
- `RuntimeDirectory=usbguard-manager` ✅
- `ConditionPathExists=/usr/local/bin/protector` ✅
- `SyslogIdentifier=usbguard-protector` ✅
- `HOME=/run/usbguard-manager` ✅
- `XDG_RUNTIME_DIR=/run/usbguard-manager` ✅
- `Documentation=man:usbguard(8)` ✅

### הגדרות אופציונליות שהושארו כהערה (לא הופעלו — דורשות בדיקה)

| הגדרה | שירות | סטטוס | הסבר |
|--------|-------|--------|-------|
| `SystemCallFilter=@system-service` | web.service | מוער (#) | Flask משתמש ב-subprocess — עלול להישבר |
| `MemoryDenyWriteExecute=yes` | כל השירותים | מוער (#) | ספריות Python (cffi, numpy) זקוקות ל-WX memory |

---

## בדיקות מומלצות אחרי השינויים

```bash
# 1. אימות תחביר כל קבצי השירות
sudo systemd-analyze verify /etc/systemd/system/*.service

# 2. טעינה מחדש של systemd
sudo systemctl daemon-reload

# 3. הפעלה מחדש של כל השירותים
sudo systemctl restart usbguard-behavioral.service
sudo systemctl restart usbguard-protector.service
sudo systemctl restart usbguard-web.service
sudo systemctl restart usbguard-ttl-reaper.service

# 4. בדיקת אבטחה
systemd-analyze security usbguard-behavioral.service

# 5. צפייה בלוגים
journalctl -u usbguard-hid-monitor -f
journalctl -u usbguard-protector -f
```

---

## סיכום

**10 תיקונים בסך הכל** ב-4 קבצי systemd:
- **behavioral (8):** `PrivateDevices` הוסר, `StateDirectory`/`LogsDirectory`/`RuntimeDirectory` הופעלו, `HOME` תוקן, `ConditionPathExists`/`SyslogIdentifier`/`Documentation`/`XDG_RUNTIME_DIR` נוספו, `ReadWritePaths` הוסר לחלוטין
- **web (3):** `PartOf`, `ConditionPathExists` נוספו, `SystemCallFilter` הוער
- **ttl-reaper (2):** `ConditionPathExists`, `PartOf` נוספו
- **protector (0):** כבר היה תקין מלכתחילה