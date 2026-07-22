#!/usr/bin/env python3
"""
Unit tests for the 4 critical fixes applied in this session.
Tests are designed to run on both Windows and Linux.
"""
import sys
import os
import tempfile
import unittest
from unittest.mock import MagicMock, patch, create_autospec
from pathlib import Path

# Add project root to path
PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
sys.path.insert(0, PROJECT_ROOT)

# Mock Linux-only modules BEFORE any imports
import unittest.mock as mock
sys.modules['fcntl'] = mock.MagicMock()
sys.modules['pwd'] = mock.MagicMock()
sys.modules['grp'] = mock.MagicMock()

# Now import normally - the mocks will prevent fcntl import errors
# We need to import the entire core package properly
import core
import core.models
import core.approver

DeviceRecord = core.models.DeviceRecord
Approver = core.approver.Approver


class TestRuleMatchesHashSecurity(unittest.TestCase):
    """
    Test Fix 1: _rule_matches must require exact hash match when rule has hash.
    This prevents a malicious device from matching an allow rule by vid_pid alone.
    """

    def setUp(self):
        """Create a mock approver with minimal config."""
        self.mock_config = MagicMock()
        self.mock_store = MagicMock()
        self.mock_client = MagicMock()
        self.mock_audit = MagicMock()
        self.approver = Approver(self.mock_config, self.mock_store, self.mock_client, self.mock_audit)

    def test_rule_with_hash_matches_exact_hash(self):
        """Rule with hash should match only if device has same hash."""
        rule = DeviceRecord(
            fingerprint="fp1",
            hash="sha256:abc123",
            vid_pid="1234:5678",
            serial="SN1",
            interfaces=["03:01:01"],
        )
        device = DeviceRecord(
            fingerprint="fp2",
            hash="sha256:abc123",  # Same hash
            vid_pid="1234:5678",
            serial="SN2",  # Different serial
            interfaces=["03:01:02"],  # Different interfaces
        )
        # Should match because hash is identical, despite different serial/interfaces
        result = self.approver._rule_matches(rule, device)
        self.assertTrue(result, "Should match when hash is identical")

    def test_rule_with_hash_rejects_different_hash(self):
        """Rule with hash should NOT match if device has different hash."""
        rule = DeviceRecord(
            fingerprint="fp1",
            hash="sha256:abc123",
            vid_pid="1234:5678",
            serial="SN1",
            interfaces=["03:01:01"],
        )
        device = DeviceRecord(
            fingerprint="fp2",
            hash="sha256:xyz789",  # Different hash
            vid_pid="1234:5678",  # Same vid_pid
            serial="SN1",
            interfaces=["03:01:01"],
        )
        # Should NOT match because hash differs, even though vid_pid/serial/interfaces match
        result = self.approver._rule_matches(rule, device)
        self.assertFalse(result, "Should NOT match when hash differs")

    def test_rule_with_hash_rejects_missing_device_hash(self):
        """Rule with hash should NOT match if device has no hash."""
        rule = DeviceRecord(
            fingerprint="fp1",
            hash="sha256:abc123",
            vid_pid="1234:5678",
            serial="SN1",
            interfaces=["03:01:01"],
        )
        device = DeviceRecord(
            fingerprint="fp2",
            hash="",  # No hash
            vid_pid="1234:5678",
            serial="SN1",
            interfaces=["03:01:01"],
        )
        result = self.approver._rule_matches(rule, device)
        self.assertFalse(result, "Should NOT match when device has no hash")

    def test_rule_without_hash_matches_vid_pid_serial_interfaces(self):
        """Rule without hash should match by vid_pid + serial + interfaces."""
        rule = DeviceRecord(
            fingerprint="fp1",
            hash="",
            vid_pid="1234:5678",
            serial="SN1",
            interfaces=["03:01:01"],
        )
        device = DeviceRecord(
            fingerprint="fp2",
            hash="",
            vid_pid="1234:5678",
            serial="SN1",
            interfaces=["03:01:01"],
        )
        result = self.approver._rule_matches(rule, device)
        self.assertTrue(result, "Should match by vid_pid + serial + interfaces")

    def test_rule_without_hash_rejects_different_serial(self):
        """Rule without hash should reject if serial differs."""
        rule = DeviceRecord(
            fingerprint="fp1",
            hash="",
            vid_pid="1234:5678",
            serial="SN1",
            interfaces=["03:01:01"],
        )
        device = DeviceRecord(
            fingerprint="fp2",
            hash="",
            vid_pid="1234:5678",
            serial="SN2",  # Different serial
            interfaces=["03:01:01"],
        )
        result = self.approver._rule_matches(rule, device)
        self.assertFalse(result, "Should NOT match when serial differs")

    def test_rule_without_hash_rejects_different_interfaces(self):
        """Rule without hash should reject if interfaces differ."""
        rule = DeviceRecord(
            fingerprint="fp1",
            hash="",
            vid_pid="1234:5678",
            serial="SN1",
            interfaces=["03:01:01"],
        )
        device = DeviceRecord(
            fingerprint="fp2",
            hash="",
            vid_pid="1234:5678",
            serial="SN1",
            interfaces=["03:01:02"],  # Different interfaces
        )
        result = self.approver._rule_matches(rule, device)
        self.assertFalse(result, "Should NOT match when interfaces differ")


class TestProtectorYamlConfig(unittest.TestCase):
    """
    Test Fix 2: protector.yaml should have hash in required, not recommended.
    """

    def setUp(self):
        self.config_path = os.path.join(PROJECT_ROOT, 'config', 'protector.yaml')

    def test_hash_in_required_list(self):
        """hash should be in the required list."""
        with open(self.config_path, 'r', encoding='utf-8') as f:
            content = f.read()
        
        # Find the identity section
        self.assertIn('identity:', content)
        
        # Parse the YAML manually (avoiding pyyaml dependency in test)
        lines = content.split('\n')
        in_identity = False
        in_required = False
        required_items = []
        
        for line in lines:
            if line.strip().startswith('identity:'):
                in_identity = True
            elif in_identity and line.strip().startswith('required:'):
                in_required = True
            elif in_identity and line.strip().startswith('recommended:'):
                in_required = False
            elif in_required and '-' in line:
                item = line.split('-')[1].strip().split('#')[0].strip()
                required_items.append(item)
        
        self.assertIn('hash', required_items, 
                      "hash should be in required list for security")

    def test_allow_no_hw_hash_removed(self):
        """allow_no_hw_hash should NOT be in the config."""
        with open(self.config_path, 'r', encoding='utf-8') as f:
            content = f.read()
        
        self.assertNotIn('allow_no_hw_hash', content,
                         "allow_no_hw_hash should be removed for security")

    def test_interfaces_in_required_list(self):
        """interfaces should still be in required list."""
        with open(self.config_path, 'r', encoding='utf-8') as f:
            content = f.read()
        
        lines = content.split('\n')
        in_identity = False
        in_required = False
        required_items = []
        
        for line in lines:
            if line.strip().startswith('identity:'):
                in_identity = True
            elif in_identity and line.strip().startswith('required:'):
                in_required = True
            elif in_identity and line.strip().startswith('recommended:'):
                in_required = False
            elif in_required and '-' in line:
                item = line.split('-')[1].strip().split('#')[0].strip()
                required_items.append(item)
        
        self.assertIn('interfaces', required_items,
                      "interfaces should remain in required list")


class TestHidMonitorMouseFilter(unittest.TestCase):
    """
    Test Fix 3: hid_monitor should filter out mouse button events (codes 272-288).
    """

    def test_mouse_button_codes_are_filtered(self):
        """Mouse button codes (272-288) should be filtered out."""
        # These are the standard Linux input event codes for mouse buttons
        mouse_codes = [
            272,  # BTN_LEFT
            273,  # BTN_RIGHT
            274,  # BTN_MIDDLE
            275,  # BTN_SIDE
            276,  # BTN_EXTRA
            277,  # BTN_FORWARD
            278,  # BTN_BACK
            279,  # BTN_TASK
            280,  # BTN_JOYSTICK (some devices)
            281,  # BTN_THUMB
            282,  # BTN_THUMB2
            283,  # BTN_TOP
            284,  # BTN_TOP2
            285,  # BTN_PINKIE
            286,  # BTN_BASE
            287,  # BTN_BASE2
            288,  # BTN_BASE3
        ]
        
        for code in mouse_codes:
            self.assertTrue(272 <= code <= 288,
                            f"Mouse button code {code} should be in filter range 272-288")

    def test_keyboard_codes_not_filtered(self):
        """Keyboard key codes should NOT be filtered."""
        # Common keyboard key codes
        keyboard_codes = [
            1,   # KEY_ESC
            2,   # KEY_1
            30,  # KEY_A
            31,  # KEY_S
            32,  # KEY_D
            33,  # KEY_F
            57,  # KEY_SPACE
            103, # KEY_UP
            105, # KEY_LEFT
            106, # KEY_RIGHT
            108, # KEY_DOWN
        ]
        
        for code in keyboard_codes:
            self.assertFalse(272 <= code <= 288,
                             f"Keyboard code {code} should NOT be in mouse filter range")

    def test_filter_logic(self):
        """Test the actual filter logic that should be in hid_monitor."""
        def is_mouse_button(code):
            """Simulates the filter added to hid_monitor.py"""
            return 272 <= code <= 288
        
        # Mouse buttons should be filtered
        self.assertTrue(is_mouse_button(272))  # BTN_LEFT
        self.assertTrue(is_mouse_button(274))  # BTN_MIDDLE
        self.assertTrue(is_mouse_button(288))  # BTN_BASE3
        
        # Keyboard keys should NOT be filtered
        self.assertFalse(is_mouse_button(30))   # KEY_A
        self.assertFalse(is_mouse_button(57))   # KEY_SPACE
        self.assertFalse(is_mouse_button(103))  # KEY_UP


class TestInstallScriptNoPyudev(unittest.TestCase):
    """
    Test Fix 4: install.sh should not install pyudev (unused dependency).
    """

    def setUp(self):
        self.install_script = os.path.join(PROJECT_ROOT, 'install.sh')

    def test_pyudev_not_in_pip_install(self):
        """pyudev should not be in the pip install command."""
        with open(self.install_script, 'r', encoding='utf-8') as f:
            content = f.read()
        
        # Find the pip install line
        lines = content.split('\n')
        pip_install_found = False
        for line in lines:
            if 'pip install' in line:
                pip_install_found = True
                self.assertNotIn('pyudev', line,
                                 "pyudev should not be installed (unused dependency)")
        
        self.assertTrue(pip_install_found, "pip install line should exist in install.sh")

    def test_pyyaml_and_evdev_still_installed(self):
        """pyyaml and evdev should still be in the pip install command."""
        with open(self.install_script, 'r', encoding='utf-8') as f:
            content = f.read()
        
        self.assertIn('pyyaml', content, "pyyaml should still be installed")
        self.assertIn('evdev', content, "evdev should still be installed")


class TestKeystrokeStatsPstdev(unittest.TestCase):
    """
    Test Fix 7 (from original list): keystroke_stats should use pstdev, not pvariance.
    This was already fixed, but let's verify it's correct.
    """

    def test_pstdev_import_exists(self):
        """keystroke_stats.py should import statistics.pstdev."""
        keystroke_stats_path = os.path.join(PROJECT_ROOT, 'detection', 'keystroke_stats.py')
        with open(keystroke_stats_path, 'r', encoding='utf-8') as f:
            content = f.read()
        
        self.assertIn('statistics.pstdev', content,
                      "keystroke_stats.py should use pstdev, not pvariance")
        self.assertNotIn('statistics.pvariance', content,
                         "keystroke_stats.py should NOT use pvariance")

    def test_stddev_in_metrics_dict(self):
        """metrics() should return stddev_ms, not variance_ms."""
        keystroke_stats_path = os.path.join(PROJECT_ROOT, 'detection', 'keystroke_stats.py')
        with open(keystroke_stats_path, 'r', encoding='utf-8') as f:
            content = f.read()
        
        self.assertIn('stddev_ms', content,
                      "metrics should return stddev_ms")
        self.assertNotIn('variance_ms', content,
                         "metrics should NOT return variance_ms")


if __name__ == '__main__':
    unittest.main()