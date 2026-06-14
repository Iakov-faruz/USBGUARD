#!/usr/bin/env python3
"""End-to-end session tests for USBGuard2 core approval flow."""

import os
import tempfile
import unittest

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
SCRIPTS_DIR = os.path.join(PROJECT_ROOT, 'scripts')
LIB_DIR = os.path.join(SCRIPTS_DIR, 'lib')


class TestEndToEndSession(unittest.TestCase):
    """Validate the local approval session flow without systemd or web."""

    def run_bash(self, script):
        return subprocess_run(script)

    def test_local_session_flow(self):
        """Build, write, log, and clean temporary approval rules."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            device_line = '0: block id 0781:5581 serial TEST123 name "Test Flash" hash abc123 via-port 1-2'
            permanent_rules = os.path.join(tmp_dir, '50-permanent.rules')
            temporary_rules = os.path.join(tmp_dir, '90-temporary.rules')
            log_path = os.path.join(tmp_dir, 'session.log')

            script = f'''
            set -euo pipefail
            export PROJECT_ROOT="{PROJECT_ROOT}"
            source "$PROJECT_ROOT/scripts/lib/logger.sh"
            source "$PROJECT_ROOT/scripts/lib/config-reader.sh"
            source "$PROJECT_ROOT/scripts/lib/device-utils.sh"
            BLOCKED_DEVICES=()
            mapfile -t BLOCKED_DEVICES < <(printf '%s\n' '{device_line}')
            rule=$(_build_rule 0)
            [[ "$rule" == 'allow id 0781:5581 serial "TEST123" name "Test Flash" hash "abc123"' ]]
            init_logger "{log_path}"
            log_info APPROVE "session start"
            log_audit APPROVE "device=$rule ttl=60"
            printf '%s\n' "$rule" > "{permanent_rules}"
            printf '%s\n' "$rule" > "{temporary_rules}"
            printf '# ttl_epoch: 1\n' >> "{temporary_rules}"
            printf '\nallow id 0951:1666 serial KEEP name "Keep Me"\n# ttl_epoch: 9999999999\n' >> "{temporary_rules}"
            source "$PROJECT_ROOT/scripts/lib/lock.sh"
            source "$PROJECT_ROOT/scripts/lib/time-guards.sh"
            source "$PROJECT_ROOT/scripts/cleanup-expired.sh" 2>/dev/null || true
            _awk_ttl_filter 999 "{temporary_rules}" > "{tmp_dir}/filtered.rules"
            mv "{tmp_dir}/filtered.rules" "{temporary_rules}"
            grep -q '0781:5581' "{permanent_rules}"
            grep -q '0951:1666' "{temporary_rules}"
            if grep -q '0781:5581' "{temporary_rules}"; then
                echo 'expired rule still present' >&2
                exit 1
            fi
            grep -q 'session start' "{log_path}"
            grep -q 'APPROVE' "{log_path}"
            echo ok
            '''
            result = self.run_bash(script)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('ok', result.stdout)


def subprocess_run(script):
    import subprocess
    return subprocess.run(
        ['bash', '-lc', script],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        timeout=20,
    )


if __name__ == '__main__':
    unittest.main()
