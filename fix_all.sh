#!/bin/bash
# USBGuard2 - Fix all issues for tests to pass
# Run: bash fix_all.sh

set -e
cd /home/yp/USBGUARD2

echo "=== Fix 1: Create log files ==="
sudo touch /var/log/usbguard-approval.log /var/log/usbguard-badusb.log
sudo chmod 666 /var/log/usbguard-approval.log /var/log/usbguard-badusb.log
echo "OK - log files ready"

echo "=== Fix 2: Fix config-reader.sh regex ==="
python3 -c "
with open('scripts/lib/config-reader.sh', 'r') as f:
    c = f.read()
old = \"['\"'\"'\$\`\\\\;|&<>(){}[\\\\]!]'\"
# Read current line
import re
m = re.search(r\"CONFIG_READER_FORBIDDEN_CHARS='([^']+)'\", c)
print(f\"Current: {m.group(1) if m else 'NOT FOUND'}\")
# Replace the line
new_line = \"readonly CONFIG_READER_FORBIDDEN_CHARS='[\\\$\`;|&<>(){}[\\\\]!]'\"
c = re.sub(r\"readonly CONFIG_READER_FORBIDDEN_CHARS='[^']+'\", new_line, c)
with open('scripts/lib/config-reader.sh', 'w') as f:
    f.write(c)
print('Fixed regex')
"
grep CONFIG_READER_FORBIDDEN_CHARS scripts/lib/config-reader.sh

echo "=== Fix 3: Test the regex ==="
echo "value; rm -rf /" | grep -qE '[$`;|&<>(){}[\]!]' && echo "REGEX OK - matches dangerous chars" || echo "REGEX FAIL"

echo "=== Fix 4: Run tests with verbose ==="
echo ""
echo "--- test_bash_logic.py ---"
cd /home/yp/USBGUARD2
web/venv/bin/python3 unit_test/test_bash_logic.py 2>&1 || true

echo ""
echo "--- test_app.py ---"
web/venv/bin/python3 unit_test/test_app.py 2>&1 || true

echo ""
echo "--- test_badusb_monitor.py ---"
web/venv/bin/python3 unit_test/test_badusb_monitor.py 2>&1 || true

echo ""
echo "--- test_security.py ---"
web/venv/bin/python3 unit_test/test_security.py 2>&1 || true

echo ""
echo "--- test_integration.py ---"
web/venv/bin/python3 unit_test/test_integration.py 2>&1 || true