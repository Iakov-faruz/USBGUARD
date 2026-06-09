# USBGuard2 - תיאור מפורט של כל קובץ

---

## תוכן העניינים

- [USBGuard2 - תיאור מפורט של כל קובץ](#usbguard2---תיאור-מפורט-של-כל-קובץ)
  - [תוכן העניינים](#תוכן-העניינים)
  - [שורש הפרויקט](#שורש-הפרויקט)
  - [conf/](#conf)
  - [logrotate/](#logrotate)
  - [rules.d/](#rulesd)
  - [scripts](#scripts)
    - [scripts/lib](#scriptslib)
  - [sudoers](#sudoers)
  - [systemd](#systemd)
  - [web](#web)

---

## שורש הפרויקט

| קובץ | תיאור |
|------|--------|
| **install.sh** | סקריפט ההתקנה הראשי. 8 שלבים: Preflight → Packages → Groups → Directories → Daemon Config → Deploy Files → Services → Security. תומך ב--dry-run וב--force. מבצע אימות חבילות (קיימות/חסרות/עדכניות) לפני ההתקנה. |
| **deploy.sh** | סקריפט פריסה חלופי (גרסה 2.3). 9 שלבים כולל Web UI venv. פחות מעודכן מ-install.sh. |
| **deploy-lib.sh** | ספריית עזר ל-deploy.sh. |
| **deploy-uninstall.sh** | סקריפט להסרת ההתקנה. |
| **start.sh** | סקריפט התקנה ישן (גרסה 2.2). 20 שלבים ידניים. נשמר לתאימות לאחור. |
| **run-usbguard-web.sh** | הפעלת ממשק האינטרנט ישירות (dev/prod modes). |
| **validate_all.sh** | בדיקת תקינות (syntax validation) לכל סקריפטי ה-bash בפרויקט. |
| **README.md** | תיעוד הפרויקט. |
| **LICENSE** | רישיון MIT. |

---

## conf/

| קובץ | תיאור |
|------|--------|
| **approval-manager.conf** | קובץ הקונפיגורציה המרכזי. מגדיר: TTL לאישורים זמניים, כמות גיבויים לשמור, התראות שולחניות, רמת לוג, נתיבי קבצי חוקים ועוד. |

---

## logrotate/

| קובץ | תיאור |
|------|--------|
| **usbguard-approval** | קונפיגורציית logrotate לקבצי הלוג של הפרויקט (/var/log/usbguard-*.log). מבצע רוטציה שבועית, שומר 4 גיבויים דחוסים. |

---

## rules.d/

| קובץ | תיאור |
|------|--------|
| **00-system.rules** | חוקרי מערכת – נוצרים על ידי `usbguard generate-policy`. מוגנים מפני שינוי על ידי הסקריפטים (מניעת Lockout). |
| **50-permanent.rules** | אישורים קבועים – התקנים שאושרו לצמיתות. לא נמחקים אוטומטית. |
| **90-temporary.rules** | אישורים זמניים עם TTL – כל חוקר מלווה בהערה `# ttl_epoch:<timestamp>`. נמחקים אוטומטית על ידי ה-Reaper. |

---

## scripts

| קובץ | תיאור |
|------|--------|
| **usb-approve.sh** | הסקריפט המרכזי. TUI (ממשק מסוף) לאישור וחסימת התקני USB. כולל: בדיקות מקדימות, גילוי התקנים חסומים, בחירה מרובה, אישור קבוע/זמני, גיבוי אוטומטי, כתיבה + אימות + טעינה מחדש. תומך גם ב--list-rules, --block, --cleanup-expired. |
| **badusb-monitor.py** | ניטור התנהגותי של התקני HID. משתמש ב-evdev לקריאה מ-/dev/input/event*. מודד Events Per Second (EPS) עם סף 20 לשנייה. חוסם התקנים חשודים דרך POST /api/block. רץ כ-systemd service. |
| **cleanup-expired.sh** | ניקוי חוקרים שפג תוקפם מקובץ 90-temporary.rules. משתמש ב-AWK State Machine עם 4 מצבים (0-3) לפרסור בטוח של קובץ החוקרים ומחיקת חוקרים שפג תוקפם. |
| **backup-rules.sh** | גיבוי ידני של כל קבצי החוקרים ל-/etc/usbguard/backups/ עם תאריך ושעה. |
| **restore-rules.sh** | שחזור מגיבוי קיים. יוצר גיבוי אוטומטי של המצב הנוכחי לפני השחזור (Rollback מובנה). |
| **import-rules.sh** | ייבוא חוקרים מקובץ JSON. כולל: אימות JSON, בדיקת כפילויות מול קבצי rules קיימים (באמצעות validators.sh), גיבוי אוטומטי לפני ייבוא, הרשאות 600. משתמש ב-Python לפרסור JSON (לא AWK). |
| **export-rules.sh** | יצוא כל החוקרים לפורמט JSON מאורגן לפי קטגוריות (system/permanent/temporary). |
| **check-config.sh** | בדיקת קונפיגורציה מלאה: וידוא קבצי חוקים, הרשאות, סטטוס דמון, שעון מערכת, חלל דיסק. |
| **usbguard-status.sh** | הצגת סטטוס המערכת: דמון USBGuard, Reaper Timer, חוקרים פעילים, מונה התקנים. |

### scripts/lib

| קובץ | תיאור |
|------|--------|
| **backup.sh** | פונקציות גיבוי מתקדמות: גיבוי + רוטציה (מגביל מספר גיבויים), שחזור בטוח, atomic writes. |
| **config-reader.sh** | קריאה בטוחה של קובץ הקונפיגורציה. משתמש ב-grep (ללא source) למניעת הזרקת קוד. |
| **device-utils.sh** | פונקציות עזר לעבודה עם התקני USB: זיהוי VID:PID, חילוץ מידע מה规则的. |
| **lock.sh** | מנגנון נעילה גלובלי (flock) למניעת Race Conditions בין סקריפטים. |
| **logger.sh** | מערכת לוגינג עם 5 רמות (DEBUG/INFO/WARN/ERROR/CRITICAL + AUDIT). כותב ל-/var/log/usbguard-approval.log. |
| **stages-core.sh** | פונקציות ליבה לניהול שלבי הסקריפט (init, cleanup, rollback). |
| **stages-io.sh** | פונקציות קלט/פלט: אישור משתמש, תצוגת רשימות (multiselect), הודעות. |
| **time-guards.sh** | זיהוי קפיצות שעון (backward jumps), שמירת epoch אחרון, הגנה מפני State Corruption. |
| **validators.sh** | בדיקות מקדימות: root, דמון פעיל, קבצי חוקים קיימים, חבילות נדרשות, כפילויות rules, חלל דיסק, sudoers. |

---

## sudoers

| קובץ | תיאור |
|------|--------|
| **usbguard-approval** | הרשאות sudo מוגבלות למשתמשי קבוצת usbadmins. מאפשר הרצת usb-approve.sh, backup-rules.sh, restore-rules.sh, import-rules.sh, export-rules.sh כ-root ללא סיסמה. |

---

## systemd

| קובץ | תיאור |
|------|--------|
| **usbguard-web.service** | שירות systemd להפעלת Flask Web UI. Type=simple. Restart=on-failure. |
| **usbguard-behavioral.service** | שירות systemd להרצת BadUSB Monitor (badusb-monitor.py). רץ כ-root (נדרש ל-evdev). Restart=on-failure. |
| **usbguard-ttl-reaper.service** | שירות oneshot להרצת cleanup-expired.sh. מופעל על ידי timer. |
| **usbguard-ttl-reaper.timer** | Timer systemd שמפעיל את reaper service כל 5 דקות. |

---

## web

| קובץ | תיאור |
|------|--------|
| **app.py** | Flask Backend (גרסה 3.0). 9 API endpoints. תמיכה ב-usbguard-python IPC (fast path) עם fallback ל-subprocess. Rate Limiting, Error Sanitization (Production/Debug). |
| **start-web.sh** | סקריפט עזר להפעלת השרת (dev/prod modes). |
| **templates/index.html** | תבנית HTML ראשית (Jinja2) לממשק האינטרנט. |
| **static/css/style.css** | עיצוב הממשק (dark theme, Material Design-inspired). |
| **static/js/script.js** | צד הלקוח – JavaScript מלא. כולל פונקציית escapeHtml() ל-XSS prevention (בשימוש ב-34+ מקומות). טוען נתונים ב-Live Refresh (10 שניות). |
| **venv/** | סביבה וירטואלית של Python (נוצרת באופן מקומי על ידי deploy.sh, לא חלק מהקוד עצמו). |