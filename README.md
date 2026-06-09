```markdown
# USBGuard Approval Manager v3.0

מערכת ארגונית, שקופה ומבוקרת מעל מנוע האכיפה usbguard, המשלבת ממשק TUI (שורת פקודה מונחה תפריטים) וממשק Web אחוד, לצד מנגנוני הגנה מתקדמים מפני התקפות BadUSB וניהול מחזור חיים אוטומטי של אישורים זמניים (TTL).

---

## 📂 ארכיטקטורה
```text
USBGUARD2/
├── conf/
│   └── approval-manager.conf        ← תצורה מרכזית
├── scripts/
│   ├── usb-approve.sh               ← TUI לאישור התקנים (זרימה ראשית)
│   ├── usbguard-status.sh           ← סקריפט בדיקת בריאות המערכת (Health Check)
│   ├── cleanup-expired.sh           ← ניקוי TTL (AWK State Machine)
│   ├── backup-rules.sh              ← גיבוי יזום של קובצי חוקים
│   ├── restore-rules.sh             ← שחזור מנוהל מגיבוי קיים
│   ├── export-rules.sh              ← ייצוא חוקים לפורמט JSON
│   ├── import-rules.sh              ← ייבוא חוקים מפורמט JSON
│   ├── badusb-monitor.py            ← מנוע ניטור התנהגותי (evdev EPS Engine)
│   └── lib/
│       ├── config-reader.sh        ← Parser בטוח לקובץ תצורה (ללא source)
│       ├── logger.sh               ← מנגנון רישום ב-5 רמות + Audit Trail
│       ├── lock.sh                 ← מעטפת פקודות flock למניעת Race Conditions
│       ├── backup.sh               ← ניהול רוטציית גיבויים ואטומיות קבצים
│       ├── validators.sh           ← בדיקות תחביר (Syntax Checks) ו-Pre-flight
│       ├── time-guards.sh          ← זיהוי ומניעת מניפולציות של קפיצות שעון
│       └── device-utils.sh         ← כלי עזר לחילוץ ואימות נתוני התקנים
├── rules.d/
│   ├── 00-system.rules             ← חוקי מערכת (מוגנים מפני דריסה)
│   ├── 50-permanent.rules          ← אישורי התקנים קבועים
│   └── 90-temporary.rules          ← אישורים זמניים מבוססי TTL
├── systemd/
│   ├── usbguard-web.service        ← שירות ניהול ממשק ה-Web (Flask)
│   ├── usbguard-behavioral.service ← שירות הרקע לניטור התקפות BadUSB
│   ├── usbguard-ttl-reaper.service ← שירות Oneshot לניקוי חוקים פגי תוקף
│   └── usbguard-ttl-reaper.timer   ← טריגר ריצה ל-Reaper (כל 5 דקות)
├── logrotate/
│   └── usbguard-approval           ← הגדרות סבב לוגים שבועי מובנה
├── sudoers/
│   └── usbguard-approval           ← הרשאות sudo מוגבלות ומאובטחות
├── web/
│   ├── app.py                      ← שרת ה-Backend ב-Flask (REST API)
│   ├── start-web.sh                ← סקריפט אתחול פנימי לסביבת ה-Web
│   ├── static/
│   └── templates/
└── install.sh                       ← סקריפט התקנה/הסרה מלאה המרכזי

```

---

## 📋 דרישות מערכת

| רכיב / תוכנה | גרסה מינימלית | תפקיד במערכת |
| --- | --- | --- |
| **Linux** | Kernel 4.15+ | תמיכה בליבת המערכת וזיהוי קלט |
| **Bash** | 5.0+ | הרצת סקריפטים ואינטראקציית TUI |
| **Python** | 3.8+ | שרת ה-Web ומנוע ה-BadUSB |
| **USBGuard** | 1.1.2+ | מנוע האכיפה והחסימה ברמת הקרנל |
| **systemd** | 245+ | ניהול שירותי הרקע, הטיימר ומחזורי החיים |
| **whiptail** | 0.52+ | ממשק המשתמש הגרפי בטרמינל (TUI) |
| **util-linux (flock)** | 2.20+ | מניעת Race Conditions וריצות כפולות |
| **gawk / mawk** | 1.4+ | ניתוח קובצי חוקים וניהול מכונת מצבי ה-TTL |
| **Flask + Limiter** | מובנה ב-venv | ניהול ה-Web, אבטחת ה-API ו-Rate Limiting |
| **evdev** *(אופציונלי)* | מובנה למערכת | נדרש עבור מנוע ניטור ההתנהגותי BadUSB |

---

## 🛠️ התקנה

### התקנה רגילה ומלאה של המערכת

```bash
sudo ./install.sh

```

### הרצת התקנה במצב בדיקה ללא ביצוע שינויים (Dry-Run)

```bash
sudo ./install.sh --dry-run

```

### הרצת התקנה מאולצת ללא בקשת אישורים ומענה על שאלות

```bash
sudo ./install.sh --force

```

### הסרה מלאה ומאובטחת של ה-Manager ושירותי ה-Systemd מהשרת

```bash
sudo ./install.sh --uninstall

```

---

## 🚀 אתחול ראשוני והפעלה

### יצירת חוקי מערכת בסיסיים למניעת חסימת המקלדת והעכבר הנוכחיים

```bash
sudo usbguard generate-policy > /etc/usbguard/rules.d/00-system.rules

```

### טעינה מחדש של הגדרות השירותים ב-Systemd

```bash
sudo systemctl daemon-reload

```

### הפעלת מנוע האכיפה של USBGuard

```bash
sudo systemctl enable --now usbguard

```

### הפעלת הטיימר לניקוי אוטומטי של חוקים זמניים (TTL Reaper)

```bash
sudo systemctl enable --now usbguard-ttl-reaper.timer

```

### הפעלת שירות הניטור ההתנהגותי נגד מתקפות BadUSB

```bash
sudo systemctl enable --now usbguard-behavioral.service

```

### הפעלת שירות ה-Backend וממשק הניהול ב-Web

```bash
sudo systemctl enable --now usbguard-web.service

```

> **כתובת גישה לממשק ה-Web לאחר ההפעלה:** `http://127.0.0.1:5000`

---

## 🖥️ שימוש בממשק TUI (שורת פקודה)

### הפעלת ממשק הניהול והאישור האנושי בטרמינל

```bash
sudo /etc/usbguard/scripts/usb-approve.sh

```

### הרצת בדיקת בריאות וסטטוס מקיפה לכל רכיבי המערכת

```bash
sudo /etc/usbguard/scripts/usbguard-status.sh

```

### הרצה ידנית קשיחה של סקריפט ניקוי החוקים הזמניים שפג תוקפם

```bash
sudo /etc/usbguard/scripts/cleanup-expired.sh

```

---

## 🌐 ממשק Web וניהול גרפי

* **Dashboard:** מצב שירותי המערכת, ה-Timer וכמות החוקים הפעילים בכל קטגוריה.
* **Devices:** תצוגת התקנים מחוברים, מורשים וחסומים בזמן אמת.
* **Rules:** ניהול, צפייה ומחיקת חוקים קיימים (מערכת, קבועים, זמניים).
* **Inspector:** תחקור עומק חומרתי של התקן ספציפי והפקת טביעת אצבע לפי `lsusb -v`.

---

## 🔄 גיבוי, שחזור והפצת חוקים

### יצירת גיבוי יזום של קובצי החוקים הקיימים במערכת

```bash
sudo /etc/usbguard/scripts/backup-rules.sh

```

### שחזור מבוקר של קובצי החוקים מתוך הגיבויים הזמינים (כולל רוטציה)

```bash
sudo /etc/usbguard/scripts/restore-rules.sh

```

### ייצוא של כל חוקי המערכת הקיימים לקובץ JSON חיצוני

```bash
sudo /etc/usbguard/scripts/export-rules.sh --file /tmp/rules.json

```

### ייבוא של חוקים מקובץ JSON וסנכרונם לתוך תיקיית החוקים הפעילה

```bash
sudo /etc/usbguard/scripts/import-rules.sh --file /tmp/rules.json

```

---

## 🛡️ ניטור BadUSB והגנה התנהגותית

### צפייה בזמן אמת בלוג שירות הניטור של מתקפות HID והזרקת קוד

```bash
journalctl -u usbguard-behavioral -f

```

### בדיקה ידנית מהירה של כל התקני ה-HID ובקרי ה-USB המזוהים במערכת

```bash
sudo lsusb

```

---

## 📊 לוגים

### צפייה משולבת בזמן אמת בכל קובצי הלוג של המערכת במקביל

```bash
tail -f /var/log/usbguard-*.log

```

### צפייה בלוג הליבה המרכזי ואירועי הביקורת (AUDIT)

```bash
tail -f /var/log/usbguard-approval.log

```

### צפייה בלוג שרת ה-Web, הבקשות שמתקבלות וה-API

```bash
tail -f /var/log/usbguard-web.log

```

### צפייה בלוג של מנוע זיהוי ההתקפות וחריגות ה-EPS

```bash
tail -f /var/log/usbguard-badusb.log

```

---

## 🔍 ניטור, תחזוקה ותצורה

### הצגת רשימת ההתקנים החסומים כעת ישירות מתוך דמון האכיפה

```bash
sudo usbguard list-devices --blocked

```

### בדיקת סטטוס הריצה והזמן הנותר להפעלת ה-TTL Reaper Timer

```bash
systemctl status usbguard-ttl-reaper.timer

```

### בדיקת מספר החוקים הזמניים הפעילים כרגע בתוך קובץ החוקים

```bash
grep -c "ttl_epoch" /etc/usbguard/rules.d/90-temporary.rules

```

### צפייה ברשימת הגיבויים הזמינים בשרת ומידת העדכניות שלהם

```bash
ls -lth /etc/usbguard/backups/

```

### פתיחת קובץ התצורה המרכזי לעריכה ידנית

```bash
sudo nano /etc/usbguard/approval-manager.conf

```

---

## 🔐 אבטחה והרשאות

### בדיקת תוכן חוקי המערכת המוגנים (מוגנים מפני עריכה או מחיקה)

```bash
sudo cat /etc/usbguard/rules.d/00-system.rules

```

### בדיקת הגדרות והרשאות ה-Sudoers המוגבלות שהוקצו למערכת

```bash
sudo cat /etc/sudoers.d/usbguard-approval

```

---

## 🛡️ מנגנוני אבטחה מובנים (Hardening)

* **ללא source על קבצי תצורה:** Parser טקסטואלי מבודד לחלוטין לקריאת קובץ הקונפיגורציה, המונע הזרקת קוד והרצת פקודות זדוניות.
* **flock גלובלי:** סינכרוניזציה מלאה בין ממשק ה-TUI לממשק ה-Web למניעת Race Conditions ודריסת חוקים הדדית.
* **Atomic writes:** כתיבת קובצי חוקים לקובץ זמני (`.tmp`), ביצוע ולידציה מלאה ורק אז החלפה אטומית באמצעות `mv`.
* **Rollback אוטומטי:** שחזור מצב תקין אחרון באופן אוטומטי מתיקיית הגיבויים בכל כשל של טעינת חוקים מחדש (`reload`).
* **Anti-Lockout:** חסימת האפשרות לערוך או למחוק את חוקי המערכת המוגנים (`00-system.rules`) דרך הממשקים כדי למנוע נעילת בקרים ומקלדות הליבה של השרת.
* **BadUSB Monitor:** הגנה אקטיבית מפני התקפות הזרקת קוד זדוניות (כמו Rubber Ducky) על ידי ניטור רציף של אירועי קלט מהקרנל (`evdev`) וחסימה אוטומטית בחריגה מסף ה-EPS.
* **Time Guards:** זיהוי ומניעת מניפולציות וקפיצות שעון לאחור (Clock Skew) שנועדו להאריך את תוקפם של חוקי TTL פגי תוקף.

---

## 📄 רישיון

פרויקט זה מופץ תחת רישיון **MIT**. ראה קובץ `LICENSE` לפרטים נוספים.

```

```
