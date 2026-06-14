#!/usr/bin/env python3
"""Unit tests for USBGuard2 Bash scripts."""

import os
import subprocess
import tempfile
import unittest

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
SCRIPTS_DIR = os.path.join(PROJECT_ROOT, 'scripts')
LIB_DIR = os.path.join(SCRIPTS_DIR, 'lib')


class TestBashScripts(unittest.TestCase):
    """Validate core Bash helpers used by the project."""

    def run_bash(self, script):
        result = subprocess.run(
            ['bash', '-c', script],
            cwd=PROJECT_ROOT,
            capture_output=True,
            text=True,
            timeout=10,
        )
        return result

    def test_config_reader_rejects_dangerous_chars(self):
        """Dangerous shell characters must be rejected."""
        with tempfile.NamedTemporaryFile('w', delete=False) as config_file:
            config_file.write('KEY=value; rm -rf /\n')
            config_path = config_file.name

        try:
            result = self.run_bash(
                f'source "{LIB_DIR}/config-reader.sh" 2>/dev/null && '
                f'get_conf KEY "{config_path}"'
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('ERROR', result.stdout + result.stderr)
        finally:
            os.remove(config_path)

    def test_logger_writes_to_file(self):
        """Logger helper should write to the configured log file."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            log_path = os.path.join(tmp_dir, 'test.log')
            result = self.run_bash(
                f'source "{LIB_DIR}/logger.sh" 2>/dev/null && '
                f'init_logger "{log_path}" && '
                f'log_info TEST hello && '
                f'cat "{log_path}"'
            )
            self.assertTrue(result.returncode == 0)
            self.assertTrue('hello' in result.stdout or 'hello' in result.stderr)

    def test_cleanup_expired_keeps_valid_ttl_rule(self):
        """cleanup-expired.sh should keep non-expired TTL rules."""
        with tempfile.NamedTemporaryFile('w', delete=False) as rules_file:
            rules_file.write('allow id AAAA:BBBB serial TEST name Test\n')
            rules_file.write('# ttl_epoch: 9999999999\n')
            rules_path = rules_file.name

        try:
            result = self.run_bash(
                f'source "{LIB_DIR}/logger.sh" 2>/dev/null; '
                f'source "{LIB_DIR}/config-reader.sh" 2>/dev/null; '
                f'source "{LIB_DIR}/lock.sh" 2>/dev/null; '
                f'source "{LIB_DIR}/time-guards.sh" 2>/dev/null; '
                f'source "{SCRIPTS_DIR}/cleanup-expired.sh" 2>/dev/null; '
                f'_awk_ttl_filter 3000 "{rules_path}"'
            )
            self.assertEqual(result.returncode, 0)
            self.assertIn('AAAA:BBBB', result.stdout)
        finally:
            os.remove(rules_path)


if __name__ == '__main__':
    unittest.main()
