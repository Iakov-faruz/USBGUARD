#!/usr/bin/env python3
"""Debug tests for USBGuard2 bash scripts"""
import subprocess
import os
import sys

os.chdir(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

# Test 1: config-reader.sh dangerous chars
print("=== Test 1: dangerous chars ===")
with open("/tmp/danger.conf", "w") as f:
    f.write("KEY=value; rm -rf /\n")
res = subprocess.run(["bash", "-c", "source scripts/lib/config-reader.sh && get_conf KEY /tmp/danger.conf"], capture_output=True, text=True, timeout=5)
print(f"  stdout: {res.stdout!r}")
print(f"  stderr: {res.stderr!r}")
print(f"  rc: {res.returncode}")
print(f"  PASS: {res.returncode != 0} (expected non-zero)")

# Test 2: logger.sh
print("\n=== Test 2: logger ===")
res = subprocess.run(["bash", "-c", "source scripts/lib/logger.sh && init_logger /tmp/test_usb.log && log_info TEST hello && cat /tmp/test_usb.log"], capture_output=True, text=True, timeout=5)
print(f"  stdout: {res.stdout!r}")
print(f"  stderr: {res.stderr!r}")
print(f"  rc: {res.returncode}")
print(f"  PASS: {'hello' in res.stdout} (expected 'hello' in output)")

# Test 3: cleanup-expired
print("\n=== Test 3: cleanup-expired ===")
with open("/tmp/test_cleanup.rules", "w") as f:
    f.write("allow id AAAA:BBBB serial TEST name Test\n# ttl_epoch: 9999999999\n")
res = subprocess.run(["bash", "-c", "source scripts/lib/logger.sh 2>/dev/null; source scripts/lib/config-reader.sh 2>/dev/null; source scripts/lib/lock.sh 2>/dev/null; source scripts/lib/time-guards.sh 2>/dev/null; source scripts/cleanup-expired.sh 2>/dev/null; _awk_ttl_filter 3000 /tmp/test_cleanup.rules"], capture_output=True, text=True, timeout=5)
print(f"  stdout: {res.stdout!r}")
print(f"  stderr: {res.stderr!r}")
print(f"  rc: {res.returncode}")
print(f"  PASS: {'AAAA:BBBB' in res.stdout} (expected rule in output)")

# Test 4: logger init with LOG_FILE
print("\n=== Test 4: logger with LOG_FILE env ===")
res = subprocess.run(["bash", "-c", "USBGUARD_LOG_FILE=/tmp/test_usb2.log source scripts/lib/logger.sh && init_logger /tmp/test_usb2.log && log_info TEST test123 && cat /tmp/test_usb2.log"], capture_output=True, text=True, timeout=5)
print(f"  stdout: {res.stdout!r}")
print(f"  stderr: {res.stderr!r}")
print(f"  rc: {res.returncode}")

print("\n=== DONE ===")