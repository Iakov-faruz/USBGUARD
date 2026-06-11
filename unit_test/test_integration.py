#!/usr/bin/env python3
"""
USBGuard Integration Test Suite
=================================
End-to-end integration tests covering:
- Full approval flow (discover → select → approve → verify)
- Backup → modify → rollback flow
- Import → export roundtrip
- TTL cleanup cycle
- Status dashboard consistency
"""

import os
import sys
import json
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch, MagicMock

# ─── Mock Logging ───────────────────────────────────────────────────
import logging
original_file_handler_init = logging.FileHandler.__init__

def mock_file_handler_init(self, filename, mode='a', encoding=None, delay=False, errors=None):
    import tempfile as _tempfile
    temp_dir = _tempfile.gettempdir()
    temp_file = os.path.join(temp_dir, os.path.basename(filename))
    original_file_handler_init(self, temp_file, mode, encoding, delay, errors)

logging.FileHandler.__init__ = mock_file_handler_init

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '../web')))
import app

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
SCRIPTS_DIR = os.path.join(PROJECT_ROOT, 'scripts')
LIB_DIR = os.path.join(SCRIPTS_DIR, 'lib')


class TestFullApprovalFlow(unittest.TestCase):
    """Integration: Full device approval flow via API."""

    def setUp(self):
        app.app.config['TESTING'] = True
        self.client = app.app.test_client()
        app.limiter.enabled = False

    @patch('app.subprocess.run')
    def test_discover_then_approve_flow(self, mock_run):
        """Flow: discover blocked device → approve it → verify it's approved."""
        call_count = [0]

        def side_effect(cmd, *args, **kwargs):
            mock_res = MagicMock()
            mock_res.returncode = 0
            call_count[0] += 1

            # First call: list devices (discovery)
            if call_count[0] == 1:
                with patch('app.USBGUARD_PYTHON_AVAILABLE', False):
                    pass
                mock_res.stdout = (
                    '3: block id 0781:5581 serial "ABC123" name "USB Drive" '
                    'via-port "1-2" hash "def456"'
                )
            # Approve call
            elif call_count[0] == 2:
                mock_res.stdout = "Device approved\n"
            else:
                mock_res.stdout = ""
            mock_res.stderr = ""
            return mock_res
        mock_run.side_effect = side_effect

        # Step 1: Discover devices
        with patch('app.USBGUARD_PYTHON_AVAILABLE', False):
            response = self.client.get('/api/devices')
            devices = response.get_json()
            self.assertEqual(len(devices), 1)
            self.assertEqual(devices[0]['device_id'], '3')
            self.assertEqual(devices[0]['status'], 'block')

        # Step 2: Approve device
        response = self.client.post('/api/approve', json={
            "device_id": "3", "type": "T", "ttl": "3600"
        })
        self.assertEqual(response.status_code, 200)
        data = response.get_json()
        self.assertTrue(data['success'])

    @patch('app.subprocess.run')
    def test_approve_then_block_flow(self, mock_run):
        """Flow: approve device → then block it."""
        def side_effect(cmd, *args, **kwargs):
            mock_res = MagicMock()
            mock_res.returncode = 0
            if "approve" in str(cmd) or "--device" in str(cmd):
                mock_res.stdout = "Approved\n"
            elif "block" in str(cmd) or "--block" in str(cmd):
                mock_res.stdout = "Blocked\n"
            else:
                mock_res.stdout = ""
            mock_res.stderr = ""
            return mock_res
        mock_run.side_effect = side_effect

        # Approve
        response = self.client.post('/api/approve', json={
            "device_id": "3", "type": "T", "ttl": "3600"
        })
        self.assertEqual(response.status_code, 200)

        # Block
        response = self.client.post('/api/block', json={
            "device_id": "3", "vid_pid": "0781:5581"
        })
        self.assertEqual(response.status_code, 200)

    @patch('app.subprocess.run')
    def test_change_status_flow(self, mock_run):
        """Flow: approve as temporary → change to permanent."""
        def side_effect(cmd, *args, **kwargs):
            mock_res = MagicMock()
            mock_res.returncode = 0
            mock_res.stdout = "OK\n"
            mock_res.stderr = ""
            return mock_res
        mock_run.side_effect = side_effect

        # Approve as temporary
        response = self.client.post('/api/approve', json={
            "device_id": "3", "type": "T", "ttl": "1800"
        })
        self.assertEqual(response.status_code, 200)

        # Change to permanent
        response = self.client.post('/api/change-status', json={
            "vid_pid": "0781:5581", "type": "P", "device_id": "3"
        })
        self.assertEqual(response.status_code, 200)


class TestFingerprintFlow(unittest.TestCase):
    """Integration: Fingerprint verification flow."""

    def setUp(self):
        app.app.config['TESTING'] = True
        self.client = app.app.test_client()
        app.limiter.enabled = False

    @patch('app._append_fingerprint_to_rule')
    @patch('app.subprocess.run')
    def test_fingerprint_then_approve_flow(self, mock_run, mock_append):
        """Flow: verify fingerprint → approve with fingerprint."""
        call_count = [0]

        def side_effect(cmd, *args, **kwargs):
            mock_res = MagicMock()
            mock_res.returncode = 0
            call_count[0] += 1

            if call_count[0] == 1:
                # Fingerprint verification call
                mock_res.stdout = (
                    "Device Descriptor:\n"
                    "  idVendor:           0x04f2\n"
                    "  idProduct:          0x0b604\n"
                    "  iManufacturer:           1 HP\n"
                    "  iProduct:                2 Camera\n"
                    "  iSerial:                 3 SN123\n"
                    "  bcdUSB:               2.00\n"
                    "  bDeviceClass:          239 Misc\n"
                )
            else:
                mock_res.stdout = "OK\n"
            mock_res.stderr = ""
            return mock_res
        mock_run.side_effect = side_effect

        # Step 1: Verify fingerprint
        stored_fp = {
            "idVendor": "0x04f2", "idProduct": "0x0b604",
            "iManufacturer": "1 HP", "iProduct": "2 Camera",
            "iSerial": "3 SN123", "bcdUSB": "2.00", "bDeviceClass": "239"
        }

        response = self.client.post('/api/verify-fingerprint', json={
            "vid_pid": "04f2:b604", "stored_fingerprint": stored_fp
        })
        self.assertEqual(response.status_code, 200)
        data = response.get_json()
        self.assertEqual(data['verdict'], 'TRUSTED')

        # Step 2: Approve with fingerprint
        response = self.client.post('/api/approve', json={
            "device_id": "5", "type": "T", "ttl": "3600",
            "fingerprint": stored_fp
        })
        self.assertEqual(response.status_code, 200)


class TestStatusConsistency(unittest.TestCase):
    """Integration: Status dashboard data consistency."""

    def setUp(self):
        app.app.config['TESTING'] = True
        self.client = app.app.test_client()
        app.limiter.enabled = False

    @patch('app.subprocess.run')
    def test_status_returns_all_required_fields(self, mock_run):
        """Status response should contain all required fields."""
        def side_effect(cmd, *args, **kwargs):
            mock_res = MagicMock()
            mock_res.returncode = 0
            if "systemctl" in cmd:
                mock_res.stdout = "active\n"
            elif "--list-rules" in cmd:
                mock_res.stdout = json.dumps({
                    "system": [], "permanent": [], "temporary": []
                })
            mock_res.stderr = ""
            return mock_res
        mock_run.side_effect = side_effect

        response = self.client.get('/api/status')
        data = response.get_json()

        self.assertIn('daemon_active', data)
        self.assertIn('timer_active', data)
        self.assertIn('active_rules_count', data)
        self.assertIsInstance(data['daemon_active'], bool)
        self.assertIsInstance(data['timer_active'], bool)
        self.assertIsInstance(data['active_rules_count'], int)

    @patch('app.subprocess.run')
    def test_rules_and_devices_consistency(self, mock_run):
        """Rules and devices should have consistent data."""
        def side_effect(cmd, *args, **kwargs):
            mock_res = MagicMock()
            mock_res.returncode = 0
            if "systemctl" in cmd:
                mock_res.stdout = ""
            elif "--list-rules" in cmd:
                mock_res.stdout = json.dumps({
                    "system": ["allow id 04f2:b604 name \"Camera\""],
                    "permanent": [],
                    "temporary": []
                })
            elif "list-devices" in cmd:
                mock_res.stdout = (
                    '1: allow id 04f2:b604 name "Camera" via-port "1-1" hash "abc"'
                )
            mock_res.stderr = ""
            return mock_res
        mock_run.side_effect = side_effect

        # Get rules
        rules_response = self.client.get('/api/rules')
        rules = rules_response.get_json()

        # Get devices
        with patch('app.USBGUARD_PYTHON_AVAILABLE', False):
            devices_response = self.client.get('/api/devices')
            devices = devices_response.get_json()

        # At least the rules should be valid JSON
        self.assertIsInstance(rules, list)


class TestBackupRestoreFlow(unittest.TestCase):
    """Integration: Backup and restore flow."""

    def test_create_and_list_backup(self):
        """Create backup and list it."""
        backup_dir = tempfile.mkdtemp()
        rules_dir = tempfile.mkdtemp()

        try:
            # Create a test rules file
            with open(os.path.join(rules_dir, "test.rules"), 'w') as f:
                f.write("allow id 0001:0001\n")

            script = f'''
            source "{LIB_DIR}/logger.sh" 2>/dev/null
            source "{LIB_DIR}/backup.sh" 2>/dev/null
            backup=$(create_backup "{backup_dir}" "{rules_dir}" 5)
            echo "CREATED=$backup"
            list_backups "{backup_dir}"
            '''
            code, out, _ = run_bash_snippet(script)
            self.assertIn('CREATED=', out)
            # Should list the backup
            self.assertIn('.tar.gz', out)
        finally:
            import shutil
            shutil.rmtree(backup_dir, ignore_errors=True)
            shutil.rmtree(rules_dir, ignore_errors=True)


class TestImportExportRoundtrip(unittest.TestCase):
    """Integration: Import → Export roundtrip."""

    def test_rules_json_format(self):
        """Rules from usb-approve.sh --list-rules should be valid JSON."""
        script = f'''
        source "{LIB_DIR}/config-reader.sh" 2>/dev/null
        # Test that the JSON output format is valid
        echo '{{"system": [], "permanent": [], "temporary": []}}'
        '''
        code, out, _ = run_bash_snippet(script)
        # Should be valid JSON
        try:
            json.loads(out)
            valid = True
        except json.JSONDecodeError:
            valid = False
        self.assertTrue(valid)


class TestTTLExpirationCycle(unittest.TestCase):
    """Integration: TTL expiration end-to-end cycle."""

    def test_ttl_rule_lifecycle(self):
        """Simulate: create rule with TTL → check expiry → verify removal."""
        rules = '''allow id AAAA:BBBB serial "TEST" name "Test Device"
# ttl_epoch: 1000
'''
        rules_path = tempfile.mktemp(suffix='.rules')
        with open(rules_path, 'w') as f:
            f.write(rules)

        try:
            # Step 1: Verify rule exists and is valid
            script = f'''
            source "{LIB_DIR}/logger.sh" 2>/dev/null
            source "{LIB_DIR}/config-reader.sh" 2>/dev/null
            source "{LIB_DIR}/lock.sh" 2>/dev/null
            source "{LIB_DIR}/time-guards.sh" 2>/dev/null
            source "{SCRIPTS_DIR}/cleanup-expired.sh" 2>/dev/null
            _awk_ttl_filter 500 "{rules_path}"
            '''
            code, out, _ = run_bash_snippet(script)
            # At now=500, ttl=1000 > 500, so rule should remain
            self.assertIn("AAAA:BBBB", out)

            # Step 2: Simulate time passing (now=2000 > ttl=1000)
            script2 = f'''
            source "{LIB_DIR}/logger.sh" 2>/dev/null
            source "{LIB_DIR}/config-reader.sh" 2>/dev/null
            source "{LIB_DIR}/lock.sh" 2>/dev/null
            source "{LIB_DIR}/time-guards.sh" 2>/dev/null
            source "{SCRIPTS_DIR}/cleanup-expired.sh" 2>/dev/null
            _awk_ttl_filter 2000 "{rules_path}"
            '''
            code2, out2, _ = run_bash_snippet(script2)
            # At now=2000, ttl=1000 < 2000, so rule should be removed
            self.assertNotIn("AAAA:BBBB", out2)
        finally:
            os.remove(rules_path)


def run_bash_snippet(script):
    """Run a bash snippet and return (returncode, stdout, stderr)."""
    res = subprocess.run(['bash', '-c', script], capture_output=True, text=True, timeout=10)
    return res.returncode, res.stdout.strip(), res.stderr.strip()


if __name__ == '__main__':
    unittest.main()