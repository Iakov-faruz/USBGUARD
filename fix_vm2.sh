#!/bin/bash
# USBGuard2 - Phase 2: Fix bash scripts for tests
# Run: echo '1' | sudo -S bash fix_vm2.sh

set -e
cd /home/yp/USBGUARD2

echo "=== Fix 1: Create ALL log files ==="
sudo touch /var/log/usbguard-approval.log
sudo touch /var/log/usbguard-badusb.log
sudo touch /var/log/usbguard-web.log
sudo chmod 666 /var/log/usbguard-approval.log
sudo chmod 666 /var/log/usbguard-badusb.log
sudo chmod 666 /var/log/usbguard-web.log
echo "OK - log files ready"

echo "=== Fix 2: Verify config-reader.sh regex ==="
grep 'CONFIG_READER_FORBIDDEN_CHARS=' scripts/lib/config-reader.sh
# Test the regex
echo "value;rm -rf" | grep -qE '[$`;|&<>(){}[\]!]' && echo "REGEX: matches dangerous chars OK" || echo "REGEX FAIL"

echo "=== Fix 3: Run tests now ==="
echo ""
echo "--- test_bash_logic.py ---"
web/venv/bin/python3 -m pytest unit_test/test_bash_logic.py -v 2>&1 | tail -20 || true

echo ""
echo "--- test_app.py ---"
web/venv/bin/python3 -m pytest unit_test/test_app.py -v 2>&1 | tail -20 || true