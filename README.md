# USBGuard Approval Manager v2.2

מערכת ניהול אנושית, שקופה ומבוקרת מעל מנוע האכיפה `usbguard`, המאפשרת למנהל מערכת לגלות, לזהות ולאשר התקני USB חסומים בממשק TUI אחיד.

## ארכיטקטורה

```
usbguard-manager/
├── conf/
│   └── approval-manager.conf       ← תצורה מרכזית
├── scripts/
│   ├── usb-approve.sh              ← TUI ראשי (זרימה A)
│   ├── cleanup-expired.sh          ← ניקוי TTL (AWK State Machine)
│   ├── backup-rules.sh             ← גיבוי יזום
│   ├── restore-rules.sh            ← שחזור מגיבוי
│   └── lib/
│       ├── config-reader.sh        ← Parser בטוח (ללא source)
│       ├── logger.sh               ← 5 רמות + audit trail
│       ├── lock.sh                 ← flock wrappers
│       ├── backup.sh               ← גיבוי + רוטציה + שחזור
│       ├── validators.sh           ← pre-flight + syntax checks
│       └── time-guards.sh          ← זיהוי קפיצות שעון
├── rules.d/
│   ├── 00-system.rules             ← חוקי מערכת (מוגנים)
│   ├── 50-permanent.rules          ← אישורים קבועים
│   └── 90-temporary.rules          ← אישורים זמניים (TTL)
├── systemd/
│   ├── usbguard-ttl-reaper.service ← oneshot service
│   └── usbguard-ttl-reaper.timer   ← כל 5 דקות
├── logrotate/
│   └── usbguard-approval           ← סבב לוגים שבועי
├── sudoers/
│   └── usbguard-approval           ← הרשאות sudo מוגבלות
├── deploy.sh                       ← התקנה אוטומטית + validation
└── README.md
```

## דרישות מערכת

| תוכנה | גרסה מינימלית |
|--------|----------------|
| Bash | 5.0+ |
| USBGuard | 1.1.2+ |
| whiptail | 0.52+ |
| util-linux (flock) | 2.20+ |
| gawk/mawk | - |
| systemd | 245+ |

## התקנה מהירה

```bash
# 1. העתק את התיקייה לשרת לינוקס
# 2. הרץ כ-root:
sudo ./deploy.sh

# 3. צור מדיניות מערכת:
sudo usbguard generate-policy > /etc/usbguard/rules.d/00-system.rules

# 4. הפעל את usbguard:
sudo systemctl enable --now usbguard

# 5. הרץ אישור:
sudo /etc/usbguard/scripts/usb-approve.sh
```

## שימוש

### אישור התקני USB

```bash
sudo usb-approve.sh
```

הסקריפט ידריך אותך בשלבים:
1. בדיקות מקדימות
2. גילוי התקנים חסומים
3. בחירה מרובה (multiselect)
4. בחירת סוג אישור (Permanent / Temporary)
5. גיבוי אוטומטי
6. כתיבה + אימות + טעינה מחדש
7. התראה שולחנית

### ניקוי אוטומטי

מתבצע כל 5 דקות דרך systemd timer:

```bash
systemctl status usbguard-ttl-reaper.timer
```

### גיבוי ידני

```bash
sudo backup-rules.sh
```

### שחזור מגיבוי

```bash
sudo restore-rules.sh
```

## תצורה

קובץ התצורה: `/etc/usbguard/approval-manager.conf`

פרמטרים עיקריים:
- `TEMP_TTL_SECONDS` — TTL לאישורים זמניים (ברירת מחדל: 3600)
- `BACKUP_KEEP` — מספר גיבויים לשמור (ברירת מחדל: 5)
- `NOTIFY_DESKTOP` — התראות שולחניות (true/false)
- `LOG_LEVEL` — DEBUG/INFO/WARN/ERROR/CRITICAL

## לוגים

```bash
# צפייה בזמן אמת
tail -f /var/log/usbguard-approval.log

# חיפוש שגיאות
grep ERROR /var/log/usbguard-approval.log

# אירועי ביקורת
grep AUDIT /var/log/usbguard-approval.log
```

## ניטור

```bash
# סטטוס timer
systemctl status usbguard-ttl-reaper.timer

# חוקים זמניים פעילים
grep -c "ttl_epoch" /etc/usbguard/rules.d/90-temporary.rules

# גיבויים זמינים
ls -lth /etc/usbguard/backups/

# התקנים חסומים
sudo usbguard list-devices --blocked
```

## אבטחה

- **ללא `source`** על קבצי תצורה (מניעת הזרקת קוד)
- **flock גלובלי** למניעת Race Conditions
- **Atomic writes** (temp file + mv)
- **Rollback אוטומטי** בכל כשל reload
- **חוקי מערכת מוגנים** (מניעת Lockout)
- **Time Guards** לזיהוי קפיצות שעון
- **Quoting מלא** על כל משתנה

## גרסה

**2.2** — Production-Grade