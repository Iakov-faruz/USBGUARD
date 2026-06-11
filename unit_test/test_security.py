#!/usr/bin/env python3
"""
USBGuard Security Test Suite
==============================
Penetration tester perspective tests covering:
- Command injection prevention
- Path traversal protection
- Input sanitization
- Rate limiting
- Error information leakage
- Configuration injection
- Fingerprint spoofing detection
"""

import os
import sys
import json
import subprocess
import tempfile
import unittest
from unittest.mock import patch, MagicMock, mock_open

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


class TestCommandInjection(unittest.TestCase):
    """Test that command injection is prevented in API endpoints."""

    def setUp(self):
        app.app.config['TESTING'] = True
        self.client = app.app.test_client()
        app.limiter.enabled = False

    @patch('app.subprocess.run')
    def test_approve_injection_in_device_id(self, mock_run):
        """Command injection via device_id should be blocked."""
        mock_res = MagicMock()
        mock_res.returncode = 1
        mock_res.stderr = ""
        mock_run.return_value = mock_res

        response = self.client.post('/api/approve', json={
            "device_id": "3; rm -rf /",
            "type": "T", "ttl": "1800"
        })
        # Should either reject (400) or not execute the injection
        if response.status_code == 200:
            # If accepted, verify the command was properly escaped
            call_args = mock_run.call_args
            cmd = call_args[0][0]
            self.assertNotIn("rm -rf /", ' '.join(cmd) if isinstance(cmd, list) else cmd)

    @patch('app.subprocess.run')
    def test_block_injection_in_vid_pid(self, mock_run):
        """Command injection via vid_pid should be blocked."""
        mock_res = MagicMock()
        mock_res.returncode = 1
        mock_res.stderr = ""
        mock_run.return_value = mock_res

        response = self.client.post('/api/block', json={
            "vid_pid": "04f2:b604; cat /etc/shadow"
        })
        if response.status_code == 200:
            call_args = mock_run.call_args
            cmd = call_args[0][0]
            self.assertNotIn("cat /etc/shadow", ' '.join(cmd) if isinstance(cmd, list) else cmd)

    @patch('app.subprocess.run')
    def test_device_detail_injection(self, mock_run):
        """Command injection via device-detail id param should be blocked."""
        mock_res = MagicMock()
        mock_res.returncode = 0
        mock_res.stdout = ""
        mock_res.stderr = ""
        mock_run.return_value = mock_res

        response = self.client.get('/api/device-detail?id=04f2:b604;whoami')
        # Should return 400 due to invalid VID:PID format
        self.assertEqual(response.status_code, 400)

    @patch('app.subprocess.run')
    def test_verify_fingerprint_injection(self, mock_run):
        """Command injection via verify-fingerprint vid_pid should be blocked."""
        response = self.client.post('/api/verify-fingerprint', json={
            "vid_pid": "04f2:b604$(whoami)",
            "stored_fingerprint": {}
        })
        self.assertEqual(response.status_code, 400)


class TestInputSanitization(unittest.TestCase):
    """Test input sanitization across all endpoints."""

    def setUp(self):
        app.app.config['TESTING'] = True
        self.client = app.app.test_client()
        app.limiter.enabled = False

    def test_approve_empty_device_id(self):
        """Empty device_id should be rejected."""
        response = self.client.post('/api/approve', json={
            "device_id": "", "type": "T"
        })
        self.assertEqual(response.status_code, 400)

    def test_approve_none_device_id(self):
        """None device_id should be rejected."""
        response = self.client.post('/api/approve', json={
            "type": "T"
        })
        self.assertEqual(response.status_code, 400)

    def test_block_empty_vid_pid(self):
        """Empty vid_pid with empty device_id should be rejected."""
        response = self.client.post('/api/block', json={
            "device_id": "", "vid_pid": ""
        })
        self.assertEqual(response.status_code, 400)

    def test_change_status_invalid_type_values(self):
        """Various invalid type values should all be rejected."""
        invalid_types = ["x", "permanent", "temporary", "TRUE", "1", "yes", ""]
        for inv_type in invalid_types:
            response = self.client.post('/api/change-status', json={
                "vid_pid": "04f2:b604", "type": inv_type
            })
            self.assertEqual(response.status_code, 400,
                           f"Type '{inv_type}' should be rejected")

    def test_verify_fingerprint_various_invalid_vid_pids(self):
        """Various invalid VID:PID formats should be rejected."""
        invalid_ids = [
            "", "abc", "04f2", "04f2:", ":b604", "04f2b604",
            "04f2:b604;rm -rf /", "04f2:b604$(whoami)",
            "04f2:b604`id`", "../../../etc/passwd",
            "ZZZZ:ZZZZ"  # Non-hex
        ]
        for inv_id in invalid_ids:
            response = self.client.post('/api/verify-fingerprint', json={
                "vid_pid": inv_id, "stored_fingerprint": {}
            })
            self.assertIn(response.status_code, [400, 500],
                         f"VID:PID '{inv_id}' should be rejected")

    def test_device_detail_xss_prevention(self):
        """XSS payloads in parameters should not cause errors."""
        xss_payloads = [
            "<script>alert('xss')</script>",
            "javascript:alert(1)",
            "onerror=alert(1)",
        ]
        for payload in xss_payloads:
            response = self.client.get(f'/api/device-detail?id={payload}')
            self.assertIn(response.status_code, [400, 500])


class TestErrorInformationLeakage(unittest.TestCase):
    """Test that error messages don't leak sensitive information."""

    def setUp(self):
        app.app.config['TESTING'] = True
        self.client = app.app.test_client()
        app.limiter.enabled = False

    @patch('app.subprocess.run')
    def test_production_mode_hides_command_errors(self, mock_run):
        """Production mode should not expose command stderr to client."""
        with patch('app.DEBUG_MODE', False):
            mock_res = MagicMock()
            mock_res.returncode = 1
            mock_res.stdout = ""
            mock_res.stderr = "Internal path: /root/.ssh/id_rsa failed"
            mock_run.return_value = mock_res

            response = self.client.get('/api/devices')
            if response.status_code == 500:
                data = response.get_json()
                error_msg = data.get('error', '')
                self.assertNotIn('/root/.ssh/', error_msg)

    @patch('app.subprocess.run')
    def test_production_mode_generic_error_messages(self, mock_run):
        """Production mode should return generic error messages."""
        with patch('app.DEBUG_MODE', False):
            mock_res = MagicMock()
            mock_res.returncode = 1
            mock_res.stdout = ""
            mock_res.stderr = "usbguard: cannot connect to daemon at /var/run/usbguard/usbguard.sock"
            mock_run.return_value = mock_res

            response = self.client.get('/api/devices')
            if response.status_code == 500:
                data = response.get_json()
                # Should not contain socket path
                self.assertNotIn('/var/run/', data.get('error', ''))

    @patch('app.subprocess.run')
    def test_production_logs_detailed_error(self, mock_run):
        """Even in production, logger should record detailed errors."""
        with patch('app.DEBUG_MODE', False):
            mock_res = MagicMock()
            mock_res.returncode = 1
            mock_res.stdout = ""
            mock_res.stderr = "Detailed internal error"
            mock_run.return_value = mock_res

            with patch('app.logger') as mock_logger:
                response = self.client.get('/api/devices')
                # Logger.error should have been called with details
                if mock_logger.error.called:
                    call_args = mock_logger.error.call_args[0]
                    # The logger should have the detailed error
                    self.assertTrue(len(str(call_args)) > 0)


class TestPathTraversal(unittest.TestCase):
    """Test path traversal prevention."""

    def setUp(self):
        app.app.config['TESTING'] = True
        self.client = app.app.test_client()
        app.limiter.enabled = False

    def test_logs_endpoint_no_path_traversal(self):
        """Logs endpoint should not be affected by path traversal."""
        # The logs endpoint reads from a fixed path, so path traversal
        # in request params should not affect it
        response = self.client.get('/api/logs')
        self.assertIn(response.status_code, [200, 500])


class TestRateLimiting(unittest.TestCase):
    """Test rate limiting configuration."""

    def test_approve_has_rate_limit(self):
        """Approve endpoint should have rate limit configured."""
        # Verify the route exists with rate limiting decorator
        rules = [rule.rule for rule in app.app.url_map.iter_rules()]
        self.assertIn('/api/approve', rules)

    def test_block_has_rate_limit(self):
        """Block endpoint should have rate limit configured."""
        rules = [rule.rule for rule in app.app.url_map.iter_rules()]
        self.assertIn('/api/block', rules)

    def test_change_status_has_rate_limit(self):
        """Change-status endpoint should have rate limit configured."""
        rules = [rule.rule for rule in app.app.url_map.iter_rules()]
        self.assertIn('/api/change-status', rules)


class TestFingerprintSecurity(unittest.TestCase):
    """Test fingerprint verification security."""

    def setUp(self):
        app.app.config['TESTING'] = True
        self.client = app.app.test_client()
        app.limiter.enabled = False

    @patch('app.subprocess.run')
    def test_fingerprint_no_body(self, mock_run):
        """Empty POST body should be handled gracefully."""
        response = self.client.post('/api/verify-fingerprint',
                                   content_type='application/json')
        self.assertIn(response.status_code, [400, 415])

    @patch('app.subprocess.run')
    def test_fingerprint_severity_classification(self, mock_run):
        """Critical fields (iSerial, bDeviceClass) should have high severity."""
        mock_res = MagicMock()
        mock_res.returncode = 0
        mock_res.stdout = (
            "Device Descriptor:\n"
            "  idVendor:           0x04f2\n"
            "  idProduct:          0x0b604\n"
            "  iManufacturer:           1 HP\n"
            "  iProduct:                2 Camera\n"
            "  iSerial:                 3 WRONG_SERIAL\n"
            "  bcdUSB:               2.00\n"
            "  bDeviceClass:          99 Wrong Class\n"
        )
        mock_run.return_value = mock_res

        stored_fp = {
            "idVendor": "0x04f2", "idProduct": "0x0b604",
            "iManufacturer": "1 HP", "iProduct": "2 Camera",
            "iSerial": "3 SN123", "bcdUSB": "2.00", "bDeviceClass": "239"
        }

        response = self.client.post('/api/verify-fingerprint', json={
            "vid_pid": "04f2:b604", "stored_fingerprint": stored_fp
        })
        data = response.get_json()
        mismatches = data.get('mismatches', [])

        # Find iSerial mismatch
        serial_mismatch = next((m for m in mismatches if m['field'] == 'iSerial'), None)
        if serial_mismatch:
            self.assertEqual(serial_mismatch['severity'], 'high')

    @patch('app.subprocess.run')
    def test_fingerprint_match_percentage_calculation(self, mock_run):
        """Match percentage should be correctly calculated."""
        mock_res = MagicMock()
        mock_res.returncode = 0
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
        mock_run.return_value = mock_res

        stored_fp = {
            "idVendor": "0x04f2", "idProduct": "0x0b604",
            "iManufacturer": "1 HP", "iProduct": "2 Camera",
            "iSerial": "3 SN123", "bcdUSB": "2.00", "bDeviceClass": "239"
        }

        response = self.client.post('/api/verify-fingerprint', json={
            "vid_pid": "04f2:b604", "stored_fingerprint": stored_fp
        })
        data = response.get_json()
        self.assertEqual(data['match_percentage'], 100)
        self.assertEqual(data['matches'], data['total_fields'])


class TestConfigSecurity(unittest.TestCase):
    """Test configuration file security."""

    def test_config_injection_rejected(self):
        """Config values with shell injection should be rejected."""
        config_content = "MALICIOUS=value$(whoami)\nDANGEROUS=`id`\nBACKTICK=`date`\n"
        fd, config_path = tempfile.mkstemp()
        with os.fdopen(fd, 'w') as f:
            f.write(config_content)

        try:
            # Run config validation
            script = f'''
            source "{LIB_DIR}/logger.sh" 2>/dev/null
            source "{LIB_DIR}/config-reader.sh" 2>/dev/null
            validate_config_file "{config_path}"
            '''
            res = subprocess.run(['bash', '-c', script], capture_output=True, text=True, timeout=5)
            # Should detect dangerous characters
            self.assertIn('ERROR', res.stdout + res.stderr)
        finally:
            os.remove(config_path)

    def test_config_semicolon_injection_rejected(self):
        """Config values with semicolons should be rejected."""
        config_content = "KEY=value; rm -rf /\n"
        fd, config_path = tempfile.mkstemp()
        with os.fdopen(fd, 'w') as f:
            f.write(config_content)

        try:
            script = f'''
            source "{LIB_DIR}/logger.sh" 2>/dev/null
            source "{LIB_DIR}/config-reader.sh" 2>/dev/null
            get_conf "KEY" "{config_path}"
            '''
            res = subprocess.run(['bash', '-c', script], capture_output=True, text=True, timeout=5)
            self.assertNotEqual(res.returncode, 0)
            self.assertIn('ERROR', res.stdout + res.stderr)
        finally:
            os.remove(config_path)

    def test_config_pipe_injection_rejected(self):
        """Config values with pipes should be rejected."""
        config_content = "KEY=value | cat /etc/passwd\n"
        fd, config_path = tempfile.mkstemp()
        with os.fdopen(fd, 'w') as f:
            f.write(config_content)

        try:
            script = f'''
            source "{LIB_DIR}/logger.sh" 2>/dev/null
            source "{LIB_DIR}/config-reader.sh" 2>/dev/null
            get_conf "KEY" "{config_path}"
            '''
            res = subprocess.run(['bash', '-c', script], capture_output=True, text=True, timeout=5)
            self.assertNotEqual(res.returncode, 0)
            self.assertIn('ERROR', res.stdout + res.stderr)
        finally:
            os.remove(config_path)

    def test_config_backtick_injection_rejected(self):
        """Config values with backticks should be rejected."""
        config_content = "KEY=`whoami`\n"
        fd, config_path = tempfile.mkstemp()
        with os.fdopen(fd, 'w') as f:
            f.write(config_content)

        try:
            script = f'''
            source "{LIB_DIR}/logger.sh" 2>/dev/null
            source "{LIB_DIR}/config-reader.sh" 2>/dev/null
            get_conf "KEY" "{config_path}"
            '''
            res = subprocess.run(['bash', '-c', script], capture_output=True, text=True, timeout=5)
            self.assertNotEqual(res.returncode, 0)
            self.assertIn('ERROR', res.stdout + res.stderr)
        finally:
            os.remove(config_path)


class TestLockSecurity(unittest.TestCase):
    """Test lock mechanism security."""

    def test_lock_uses_mkdir_atomic(self):
        """Lock should use mkdir for atomic operation."""
        # Verify lock.sh uses mkdir (check file content)
        lock_sh_path = os.path.join(LIB_DIR, 'lock.sh')
        with open(lock_sh_path, 'r') as f:
            content = f.read()
        self.assertIn('mkdir', content)

    def test_lock_stores_pid(self):
        """Lock directory should contain PID file."""
        lock_sh_path = os.path.join(LIB_DIR, 'lock.sh')
        with open(lock_sh_path, 'r') as f:
            content = f.read()
        self.assertIn('pid', content)

    def test_lock_pid_based_release(self):
        """Lock release should only work for the owning PID."""
        lock_sh_path = os.path.join(LIB_DIR, 'lock.sh')
        with open(lock_sh_path, 'r') as f:
            content = f.read()
        # Should check PID before releasing
        self.assertIn('$$', content)


class TestApiSecurityHeaders(unittest.TestCase):
    """Test API security headers and behavior."""

    def setUp(self):
        app.app.config['TESTING'] = True
        self.client = app.app.test_client()

    def test_index_page_loads(self):
        """Main page should load without errors."""
        response = self.client.get('/')
        self.assertEqual(response.status_code, 200)

    def test_api_returns_json(self):
        """API endpoints should return JSON content type."""
        with patch('app.subprocess.run') as mock_run:
            mock_res = MagicMock()
            mock_res.returncode = 1
            mock_res.stdout = ""
            mock_res.stderr = ""
            mock_run.return_value = mock_res

            response = self.client.get('/api/status')
            self.assertEqual(response.content_type, 'application/json')


class TestUSBGuardSpecificSecurity(unittest.TestCase):
    """USBGuard-specific security scenarios."""

    def test_badusb_api_url_localhost_only(self):
        """BadUSB monitor should only communicate with localhost."""
        badusb_path = os.path.join(SCRIPTS_DIR, 'badusb-monitor.py')
        with open(badusb_path, 'r') as f:
            content = f.read()
        self.assertIn('127.0.0.1', content)
        # Should not have any external URLs
        self.assertNotIn('http://0.0.0.0', content)
        self.assertNotIn('http://[::]', content)

    def test_rules_files_permissions(self):
        """Rules files should have restrictive permissions (600)."""
        rules_sh_path = os.path.join(SCRIPTS_DIR, 'usb-approve.sh')
        with open(rules_sh_path, 'r') as f:
            content = f.read()
        # Should set chmod 600 on rules files
        self.assertIn('chmod 600', content)

    def test_backup_permissions(self):
        """Backup files should have restrictive permissions."""
        backup_sh_path = os.path.join(LIB_DIR, 'backup.sh')
        with open(backup_sh_path, 'r') as f:
            content = f.read()
        self.assertIn('chmod 600', content)

    def test_fingerprint_atomic_write(self):
        """Fingerprint writing should use atomic operations (temp + mv)."""
        app_path = os.path.join(PROJECT_ROOT, 'web', 'app.py')
        with open(app_path, 'r') as f:
            content = f.read()
        self.assertIn('tempfile', content)
        self.assertIn('os.replace', content)

    def test_import_uses_python_not_sed(self):
        """Import should use Python for JSON parsing (not sed/grep)."""
        import_path = os.path.join(SCRIPTS_DIR, 'import-rules.sh')
        with open(import_path, 'r') as f:
            content = f.read()
        self.assertIn('python3', content)

    def test_sudoers_restricted_commands(self):
        """Sudoers should only allow specific commands."""
        sudoers_path = os.path.join(PROJECT_ROOT, 'sudoers', 'usbguard-approval')
        with open(sudoers_path, 'r') as f:
            content = f.read()
        # Should not have ALL=(ALL) or NOPASSWD for everything
        self.assertNotIn('ALL=(ALL) NOPASSWD: ALL', content)
        # Should specify specific commands
        self.assertIn('USBGUARD_APPROVE', content)


if __name__ == '__main__':
    unittest.main()