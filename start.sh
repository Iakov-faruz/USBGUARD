#!/bin/bash


# ═══════════════════════════════════════════════════════════════
# USBGuard Approval Manager - Full Installation Script
# Version: 2.2 (Fixed for USBGuard 1.1.2)
# ═══════════════════════════════════════════════════════════════

# ─── שלב 1: התקנת תלותים ──────────────────────────────────────
sudo apt install -y ntpdate
sudo ntpdate ntp.ubuntu.com

sudo apt update
sudo apt upgrade -y
sudo apt install -y usbguard whiptail gawk util-linux tar gzip systemd dos2unix
dpkg -l usbguard

# ─── שלב 2: יצירת קבוצת usbadmins ─────────────────────────────
sudo groupadd -f usbadmins
sudo usermod -aG usbadmins $USER
newgrp usbadmins
groups $USER | grep usbadmins

# ─── שלב 3: יצירת מבנה תיקיות ─────────────────────────────────
sudo mkdir -p /etc/usbguard/rules.d
sudo mkdir -p /etc/usbguard/scripts/lib
sudo mkdir -p /etc/usbguard/backups
sudo mkdir -p /var/lib/usbguard-manager
sudo mkdir -p /var/lock

# ─── שלב 4: יצירת קובץ קונפיגורציה לדמון ──────────────────────
sudo tee /etc/usbguard/usbguard-daemon.conf > /dev/null << 'EOF'
RuleFolder=/etc/usbguard/rules.d
ImplicitPolicyTarget=block
PresentDevicePolicy=apply-policy
InsertedDevicePolicy=apply-policy
RestoreControllerDeviceState=true
DeviceManagerBackend=uevent
IPCAllowedUsers=root
IPCAllowedGroups=usbadmins
AuditBackend=FileAudit
AuditFilePath=/var/log/usbguard/usbguard-audit.log
HidePII=false
EOF

sudo chmod 600 /etc/usbguard/usbguard-daemon.conf



# ─── שלב 5: הגדרת משתנה BASE ──────────────────────────────────
# ⚠ שים לב: עדכן את הנתיב לתיקייה שבה נמצאים הקבצים המתוקנים
# (usbguard-manager_test, לא usbguard-manager המקורי)
BASE="/home/yp/Documents/usbguard-manager_test"
echo "Using BASE: $BASE"
if [[ ! -d "$BASE/scripts" ]]; then
    echo "ERROR: BASE directory not found at: $BASE"
    echo "Please update the BASE variable above to point to your working directory."
    exit 1
fi

# ─── שלב 6: העתקת קובץ קונפיג ראשי ────────────────────────────
sudo cp "$BASE/conf/approval-manager.conf" /etc/usbguard/
sudo chmod 600 /etc/usbguard/approval-manager.conf

# ─── שלב 7: העתקת קבצי חוקים (כל קובץ בנפרד) ─────────────────
sudo cp "$BASE/rules.d/00-system.rules" /etc/usbguard/rules.d/
sudo cp "$BASE/rules.d/50-permanent.rules" /etc/usbguard/rules.d/
sudo cp "$BASE/rules.d/90-temporary.rules" /etc/usbguard/rules.d/

# ─── שלב 8: הרשאות לקבצי חוקים (600) ──────────────────────────
sudo chmod 600 /etc/usbguard/rules.d/00-system.rules
sudo chmod 600 /etc/usbguard/rules.d/50-permanent.rules
sudo chmod 600 /etc/usbguard/rules.d/90-temporary.rules

# ─── שלב 9: העתקת קבצי סקריפטים ראשיים (כל קובץ בנפרד) ───────
sudo cp "$BASE/scripts/backup-rules.sh" /etc/usbguard/scripts/
sudo cp "$BASE/scripts/cleanup-expired.sh" /etc/usbguard/scripts/
sudo cp "$BASE/scripts/restore-rules.sh" /etc/usbguard/scripts/
sudo cp "$BASE/scripts/usb-approve.sh" /etc/usbguard/scripts/

# ─── שלב 10: העתקת קבצי ספריית lib (כל קובץ בנפרד) ───────────
sudo cp "$BASE/scripts/lib/backup.sh" /etc/usbguard/scripts/lib/
sudo cp "$BASE/scripts/lib/config-reader.sh" /etc/usbguard/scripts/lib/
sudo cp "$BASE/scripts/lib/lock.sh" /etc/usbguard/scripts/lib/
sudo cp "$BASE/scripts/lib/logger.sh" /etc/usbguard/scripts/lib/
sudo cp "$BASE/scripts/lib/time-guards.sh" /etc/usbguard/scripts/lib/
sudo cp "$BASE/scripts/lib/validators.sh" /etc/usbguard/scripts/lib/

# ─── שלב 11: הרשאות לסקריפטים ראשיים (755) ────────────────────
sudo chmod 755 /etc/usbguard/scripts/backup-rules.sh
sudo chmod 755 /etc/usbguard/scripts/cleanup-expired.sh
sudo chmod 755 /etc/usbguard/scripts/restore-rules.sh
sudo chmod 755 /etc/usbguard/scripts/usb-approve.sh

# ─── שלב 12: הרשאות לקבצי lib (640) ───────────────────────────
sudo chmod 640 /etc/usbguard/scripts/lib/backup.sh
sudo chmod 640 /etc/usbguard/scripts/lib/config-reader.sh
sudo chmod 640 /etc/usbguard/scripts/lib/lock.sh
sudo chmod 640 /etc/usbguard/scripts/lib/logger.sh
sudo chmod 640 /etc/usbguard/scripts/lib/time-guards.sh
sudo chmod 640 /etc/usbguard/scripts/lib/validators.sh

# ─── שלב 13: שינוי בעלות על כל ספריית scripts ─────────────────
sudo chown -R root:root /etc/usbguard/scripts

# ─── שלב 14: העתקת קבצי systemd timer ─────────────────────────
sudo cp "$BASE/systemd/usbguard-ttl-reaper.service" /etc/systemd/system/
sudo cp "$BASE/systemd/usbguard-ttl-reaper.timer" /etc/systemd/system/

# ─── שלב 15: העתקת קובץ logrotate ─────────────────────────────
sudo cp "$BASE/logrotate/usbguard-approval" /etc/logrotate.d/

# ─── שלב 16: יצירת קובץ sudoers (ללא כוכבית) ──────────────────
sudo tee /etc/sudoers.d/usbguard-approval > /dev/null << 'EOF'
Cmnd_Alias USBGUARD_APPROVE=/etc/usbguard/scripts/usb-approve.sh
Cmnd_Alias USBGUARD_BACKUP=/etc/usbguard/scripts/backup-rules.sh
Cmnd_Alias USBGUARD_RESTORE=/etc/usbguard/scripts/restore-rules.sh

%usbadmins ALL=(root) NOPASSWD: USBGUARD_APPROVE, USBGUARD_BACKUP, USBGUARD_RESTORE
EOF

sudo chmod 440 /etc/sudoers.d/usbguard-approval
sudo chown root:root /etc/sudoers.d/usbguard-approval
sudo visudo -c   # אמור להדפיס "parsed OK"


# sudoers
# sudo cp "$BASE/sudoers/usbguard-approval" /etc/sudoers.d/
# sudo dos2unix /etc/sudoers.d/usbguard-approval 2>/dev/null || true


# ─── שלב 17: הפעלת הדמון ──────────────────────────────────────
sudo systemctl enable --now usbguard
sleep 3
sudo systemctl status usbguard --no-pager -l

# ─── שלב 18: יצירת קובץ הלוג והרשאות ──────────────────────────
sudo touch /var/log/usbguard-approval.log
sudo chmod 660 /var/log/usbguard-approval.log
sudo chown root:usbadmins /var/log/usbguard-approval.log

# ─── שלב 19: הפעלת timer ───────────────────────────────────────
sudo systemctl daemon-reload
sudo systemctl enable --now usbguard-ttl-reaper.timer
sudo systemctl status usbguard-ttl-reaper.timer

# ─── שלב 20: בדיקה סופית ──────────────────────────────────────



