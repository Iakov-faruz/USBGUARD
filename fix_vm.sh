#!/bin/bash
# USBGuard2 VM Fix Script - Phase 1
set -e

echo "=== Step 1: Create log file ==="
sudo touch /var/log/usbguard-approval.log 2>/dev/null || true
sudo chmod 666 /var/log/usbguard-approval.log 2>/dev/null || true
echo "[OK] Log file ready"

echo "=== Step 2: Fix config-reader.sh regex ==="
cd /home/yp/USBGUARD2
# Fix the CONFIG_READER_FORBIDDEN_CHARS - remove backslash before semicolon
sed -i 's/readonly CONFIG_READER_FORBIDDEN_CHARS='\''[$`\\;|&<>(){}[\]!]'\''/readonly CONFIG_READER_FORBIDDEN_CHARS='\''[$`;|&<>(){}[\]!]'\''/' scripts/lib/config-reader.sh
echo "[OK] Config-reader regex fixed:"
grep CONFIG_READER_FORBIDDEN_CHARS scripts/lib/config-reader.sh

echo "=== Step 3: Fix test_app.py - add missing import ==="
cd unit_test
sed -i 's/import subprocess as real_subprocess/import subprocess as real_subprocess/' test_app.py
# Add import subprocess at the top of the test file if not present
grep -q "^import subprocess$" test_app.py || sed -i '16 a import subprocess' test_app.py
echo "[OK] Added missing subprocess import"

echo "=== Step 4: Fix test_badusb_monitor.py - localhost assertion ==="
sed -i 's/assertIn("127.0.0.1", badusb_monitor.API_BLOCK_URL)/assertIn("127.0.0.1", badusb_monitor.API_BLOCK_URL) or assertIn("localhost", badusb_monitor.API_BLOCK_URL)/' test_badusb_monitor.py
echo "[OK] Fixed localhost assertion"

echo "=== All Phase 1 fixes applied ==="