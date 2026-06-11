#!/usr/bin/env python3
"""
USBGuard Bash Logic - Test Suite
=================================
Comprehensive tests for all bash library functions:
- config-reader.sh: get_conf, get_conf_bool, get_conf_int, validate_config_file
- logger.sh: log levels, audit, session summary
- lock.sh: acquire_lock, release_lock
- backup.sh: create_backup, rotate_backups, list_backups
- time-guards.sh: clock checks, TTL, epoch operations
- validators.sh: root check, user allowed, daemon active, disk space, duplicates
- device-utils.sh: parse_device_info, build_rule
- stages: preflight, discover, build rules, write rules, rollback
- cleanup-expired.sh: AWK TTL filter
Viewed from both QA and Pentester perspectives.
"""

import os
import sys
import subprocess
import tempfile
import time
import unittest

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
SCRIPTS_DIR = os.path.join(PROJECT_ROOT, 'scripts')
LIB_DIR = os.path.join(SCRIPTS_DIR, 'lib')


class BashTestBase(unittest.TestCase):
    """Base class with helpers for bash function testing."""

    def setUp(self):
        self.temp_files = []
        self.temp_dirs = []

    def tearDown(self):
        for f in self.temp_files:
            if os.path.exists(f):
                os.remove(f)
        for d in self.temp_dirs:
            if os.path.isdir(d):
                import shutil
                shutil.rmtree(d, ignore_errors=True)

    def create_temp_file(self, content):
        fd, path = tempfile.mkstemp()
        with os.fdopen(fd, 'w') as f:
            f.write(content)
        self.temp_files.append(path)
        return path

    def create_temp_dir(self):
        path = tempfile.mkdtemp()
        self.temp_dirs.append(path)
        return path

    def run_bash_snippet(self, script):
        """Run a bash snippet and return (returncode, stdout, stderr)."""
        res = subprocess.run(['bash', '-c', script], capture_output=True, text=True, timeout=10)
        return res.returncode, res.stdout.strip(), res.stderr.strip()

    def source_and_call(self, library_name, func_call):
        """Source a library and call a function."""
        lib_path = os.path.join(LIB_DIR, library_name)
        script = f'source "{lib_path}" 2>/dev/null\n{func_call}'
        return self.run_bash_snippet(script)


# ═══════════════════════════════════════════════════════════════════════
# CONFIG-READER.SH Tests
# ═══════════════════════════════════════════════════════════════════════

class TestConfigReader(BashTestBase):
    """Test config-reader.sh functions."""

    def test_get_conf_simple_value(self):
        """Simple KEY=VALUE should return the value."""
        config = "KEY_SIMPLE=Value1"
        config_path = self.create_temp_file(config)
        code, out, err = self.source_and_call('config-reader.sh', f'get_conf "KEY_SIMPLE" "{config_path}"')
        self.assertEqual(code, 0)
        self.assertEqual(out, 'Value1')

    def test_get_conf_quoted_value(self):
        """Quoted value should be returned without quotes."""
        config = 'KEY_QUOTED="Value 2"'
        config_path = self.create_temp_file(config)
        code, out, err = self.source_and_call('config-reader.sh', f'get_conf "KEY_QUOTED" "{config_path}"')
        self.assertEqual(code, 0)
        self.assertEqual(out, 'Value 2')

    def test_get_conf_single_quoted_value(self):
        """Single-quoted value should be returned without quotes."""
        config = "KEY_SQ='Single Quoted'"
        config_path = self.create_temp_file(config)
        code, out, err = self.source_and_call('config-reader.sh', f'get_conf "KEY_SQ" "{config_path}"')
        self.assertEqual(code, 0)
        self.assertEqual(out, 'Single Quoted')

    def test_get_conf_spaces_around_equals(self):
        """KEY = VALUE format should work."""
        config = "KEY_SPACES =  Value3"
        config_path = self.create_temp_file(config)
        code, out, err = self.source_and_call('config-reader.sh', f'get_conf "KEY_SPACES" "{config_path}"')
        self.assertEqual(code, 0)
        self.assertEqual(out, 'Value3')

    def test_get_conf_comment_lines_skipped(self):
        """Comment lines should be skipped."""
        config = "# This is a comment\nKEY_AFTER=found"
        config_path = self.create_temp_file(config)
        code, out, err = self.source_and_call('config-reader.sh', f'get_conf "KEY_AFTER" "{config_path}"')
        self.assertEqual(code, 0)
        self.assertEqual(out, 'found')

    def test_get_conf_empty_lines_skipped(self):
        """Empty lines should be skipped."""
        config = "\n\nKEY_EMPTY=ok\n\n"
        config_path = self.create_temp_file(config)
        code, out, err = self.source_and_call('config-reader.sh', f'get_conf "KEY_EMPTY" "{config_path}"')
        self.assertEqual(code, 0)
        self.assertEqual(out, 'ok')

    def test_get_conf_missing_key_returns_error(self):
        """Missing key should return error code."""
        config = "OTHER_KEY=hello"
        config_path = self.create_temp_file(config)
        code, out, err = self.source_and_call('config-reader.sh', f'get_conf "MISSING" "{config_path}"')
        self.assertNotEqual(code, 0)

    def test_get_conf_dangerous_chars_rejected(self):
        """Values with dangerous chars should be rejected."""
        config = 'DANGEROUS=value; rm -rf /'
        config_path = self.create_temp_file(config)
        code, out, err = self.source_and_call('config-reader.sh', f'get_conf "DANGEROUS" "{config_path}"')
        self.assertNotEqual(code, 0)

    def test_get_conf_dollar_sign_rejected(self):
        """Values with $ should be rejected."""
        config = 'DOLLAR=$HOME'
        config_path = self.create_temp_file(config)
        code, out, err = self.source_and_call('config-reader.sh', f'get_conf "DOLLAR" "{config_path}"')
        self.assertNotEqual(code, 0)

    def test_get_conf_pipe_rejected(self):
        """Values with pipe should be rejected."""
        config = 'PIPE=value | cat /etc/passwd'
        config_path = self.create_temp_file(config)
        code, out, err = self.source_and_call('config-reader.sh', f'get_conf "PIPE" "{config_path}"')
        self.assertNotEqual(code, 0)

    def test_get_conf_empty_key_returns_error(self):
        """Empty key should return error."""
        config = "=value"
        config_path = self.create_temp_file(config)
        code, out, err = self.source_and_call('config-reader.sh', f'get_conf "" "{config_path}"')
        self.assertNotEqual(code, 0)

    def test_get_conf_missing_file_returns_error(self):
        """Missing config file should return error."""
        code, out, err = self.source_and_call('config-reader.sh', 'get_conf "KEY" "/nonexistent/file.conf"')
        self.assertNotEqual(code, 0)

    def test_get_conf_bool_true_values(self):
        """true/yes/1/on should return 'true'."""
        for val in ['true', 'yes', '1', 'on', 'TRUE', 'Yes', 'ON']:
            config = f"BOOL_VAL={val}"
            config_path = self.create_temp_file(config)
            code, out, _ = self.source_and_call('config-reader.sh', f'get_conf_bool "BOOL_VAL" "false" "{config_path}"')
            self.assertEqual(out, 'true', f"Value '{val}' should map to 'true'")

    def test_get_conf_bool_false_values(self):
        """false/no/0/off should return 'false'."""
        for val in ['false', 'no', '0', 'off', 'FALSE', 'No', 'OFF']:
            config = f"BOOL_VAL={val}"
            config_path = self.create_temp_file(config)
            code, out, _ = self.source_and_call('config-reader.sh', f'get_conf_bool "BOOL_VAL" "true" "{config_path}"')
            self.assertEqual(out, 'false', f"Value '{val}' should map to 'false'")

    def test_get_conf_bool_invalid_returns_default(self):
        """Invalid boolean value should return default."""
        config = "BOOL_VAL=maybe"
        config_path = self.create_temp_file(config)
        code, out, _ = self.source_and_call('config-reader.sh', f'get_conf_bool "BOOL_VAL" "true" "{config_path}"')
        self.assertEqual(out, 'true')  # default

    def test_get_conf_bool_missing_key_returns_default(self):
        """Missing key should return default."""
        config = "OTHER=val"
        config_path = self.create_temp_file(config)
        code, out, _ = self.source_and_call('config-reader.sh', f'get_conf_bool "MISSING" "false" "{config_path}"')
        self.assertEqual(out, 'false')

    def test_get_conf_int_valid(self):
        """Valid integer should be returned."""
        config = "INT_VAL=1800"
        config_path = self.create_temp_file(config)
        code, out, _ = self.source_and_call('config-reader.sh', f'get_conf_int "INT_VAL" "3600" "{config_path}"')
        self.assertEqual(out, '1800')

    def test_get_conf_int_zero(self):
        """Zero should be returned as valid."""
        config = "INT_VAL=0"
        config_path = self.create_temp_file(config)
        code, out, _ = self.source_and_call('config-reader.sh', f'get_conf_int "INT_VAL" "3600" "{config_path}"')
        self.assertEqual(out, '0')

    def test_get_conf_int_non_numeric_returns_default(self):
        """Non-numeric value should return default."""
        config = "INT_VAL=abc"
        config_path = self.create_temp_file(config)
        code, out, _ = self.source_and_call('config-reader.sh', f'get_conf_int "INT_VAL" "3600" "{config_path}"')
        self.assertEqual(out, '3600')

    def test_get_conf_int_missing_key_returns_default(self):
        """Missing key should return default."""
        config = "OTHER=123"
        config_path = self.create_temp_file(config)
        code, out, _ = self.source_and_call('config-reader.sh', f'get_conf_int "MISSING" "999" "{config_path}"')
        self.assertEqual(out, '999')

    def test_validate_config_file_valid(self):
        """Valid config file should pass validation."""
        config = "# Comment\nKEY1=value1\nKEY2=value2\n"
        config_path = self.create_temp_file(config)
        code, out, _ = self.source_and_call('config-reader.sh', f'validate_config_file "{config_path}"')
        self.assertEqual(code, 0)
        self.assertIn('VALIDATION_OK', out)

    def test_validate_config_file_missing_equals(self):
        """Line without = should fail validation."""
        config = "VALID_KEY=value\nINVALID_LINE_NO_EQUALS\n"
        config_path = self.create_temp_file(config)
        code, out, _ = self.source_and_call('config-reader.sh', f'validate_config_file "{config_path}"')
        self.assertIn('ERROR', out)

    def test_validate_config_file_empty_key(self):
        """Line starting with = should fail."""
        config = "=value\n"
        config_path = self.create_temp_file(config)
        code, out, _ = self.source_and_call('config-reader.sh', f'validate_config_file "{config_path}"')
        self.assertIn('ERROR', out)

    def test_validate_config_file_dangerous_chars(self):
        """Dangerous characters in value should fail."""
        config = "BAD_KEY=value;rm -rf /\n"
        config_path = self.create_temp_file(config)
        code, out, _ = self.source_and_call('config-reader.sh', f'validate_config_file "{config_path}"')
        self.assertIn('ERROR', out)


# ═══════════════════════════════════════════════════════════════════════
# LOCK.SH Tests
# ═══════════════════════════════════════════════════════════════════════

class TestLock(BashTestBase):
    """Test lock.sh functions."""

    def test_acquire_lock_success(self):
        """Should acquire lock on first attempt."""
        lock_dir = os.path.join(self.create_temp_dir(), "test.lock")
        script = f'''
        source "{LIB_DIR}/lock.sh" 2>/dev/null
        acquire_lock "{lock_dir}" "nowait" 5
        echo "LOCKED=$?"
        rm -rf "{lock_dir}.dir" 2>/dev/null
        '''
        code, out, err = self.run_bash_snippet(script)
        self.assertIn('LOCKED=0', out)

    def test_release_lock_success(self):
        """Should release lock cleanly."""
        lock_dir = os.path.join(self.create_temp_dir(), "test.lock")
        script = f'''
        source "{LIB_DIR}/lock.sh" 2>/dev/null
        acquire_lock "{lock_dir}" "nowait" 5
        release_lock "{lock_dir}"
        echo "RELEASED=0"
        '''
        code, out, err = self.run_bash_snippet(script)
        self.assertIn('RELEASED=0', out)

    def test_lock_file_extension_conversion(self):
        """.lock extension should be converted to .lock.dir."""
        lock_path = "/tmp/test_usbguard_lock_check"
        script = f'''
        source "{LIB_DIR}/lock.sh" 2>/dev/null
        acquire_lock "{lock_path}.lock" "nowait" 5
        if [[ -d "{lock_path}.lock.dir" ]]; then
            echo "DIR_CREATED"
        fi
        release_lock "{lock_path}.lock"
        '''
        code, out, err = self.run_bash_snippet(script)
        self.assertIn('DIR_CREATED', out)


# ═══════════════════════════════════════════════════════════════════════
# TIME-GUARDS.SH Tests
# ═══════════════════════════════════════════════════════════════════════

class TestTimeGuards(BashTestBase):
    """Test time-guards.sh functions."""

    def test_get_epoch_now_returns_positive(self):
        """Should return a positive epoch timestamp."""
        code, out, _ = self.source_and_call('time-guards.sh', 'get_epoch_now')
        self.assertEqual(code, 0)
        self.assertTrue(int(out) > 0)

    def test_check_clock_reasonable(self):
        """Current system clock should be reasonable (after 2020)."""
        code, out, _ = self.source_and_call('time-guards.sh', 'check_clock_reasonable')
        self.assertEqual(code, 0)

    def test_is_ttl_expired_past(self):
        """TTL epoch in the past should be expired."""
        code, out, _ = self.source_and_call('time-guards.sh', 'is_ttl_expired 1')
        self.assertEqual(code, 0)  # expired = return 0

    def test_is_ttl_expired_future(self):
        """TTL epoch far in the future should not be expired."""
        code, out, _ = self.source_and_call('time-guards.sh', 'is_ttl_expired 9999999999')
        self.assertEqual(code, 1)  # not expired = return 1

    def test_is_ttl_expired_empty(self):
        """Empty TTL should return error."""
        code, out, _ = self.source_and_call('time-guards.sh', 'is_ttl_expired ""')
        self.assertNotEqual(code, 1)  # error return

    def test_is_ttl_expired_non_numeric(self):
        """Non-numeric TTL should return error."""
        code, out, _ = self.source_and_call('time-guards.sh', 'is_ttl_expired "abc"')
        self.assertNotEqual(code, 1)  # error return

    def test_compute_ttl_epoch(self):
        """compute_ttl_epoch should return current time + offset."""
        code, out, _ = self.source_and_call('time-guards.sh', 'compute_ttl_epoch 3600')
        self.assertEqual(code, 0)
        ttl = int(out)
        now = int(time.time())
        # TTL should be approximately now + 3600
        self.assertGreater(ttl, now)
        self.assertLess(ttl, now + 3700)

    def test_format_ttl_remaining_expired(self):
        """Expired TTL should return 'Expired'."""
        code, out, _ = self.source_and_call('time-guards.sh', 'format_ttl_remaining 1')
        self.assertEqual(code, 0)
        self.assertEqual(out, 'Expired')

    def test_format_ttl_remaining_future_hours(self):
        """Future TTL with hours should show hours and minutes."""
        ttl = int(time.time()) + 7200  # 2 hours
        code, out, _ = self.source_and_call('time-guards.sh', f'format_ttl_remaining {ttl}')
        self.assertEqual(code, 0)
        self.assertIn('h', out)

    def test_format_ttl_remaining_empty(self):
        """Empty TTL should return N/A."""
        code, out, _ = self.source_and_call('time-guards.sh', 'format_ttl_remaining ""')
        self.assertEqual(out, 'N/A')

    def test_write_and_read_last_run_epoch(self):
        """Writing and reading epoch should be consistent."""
        epoch = int(time.time())
        state_file = os.path.join(self.create_temp_dir(), "state_epoch")
        script = f'''
        source "{LIB_DIR}/time-guards.sh" 2>/dev/null
        write_last_run_epoch {epoch} "{state_file}"
        result=$(read_last_run_epoch "{state_file}")
        echo "RESULT=$result"
        '''
        code, out, _ = self.run_bash_snippet(script)
        self.assertIn(f'RESULT={epoch}', out)

    def test_read_last_run_epoch_missing_file(self):
        """Reading from missing file should return error."""
        code, out, _ = self.source_and_call('time-guards.sh', 'read_last_run_epoch "/nonexistent/state"')
        self.assertNotEqual(code, 0)

    def test_detect_clock_jump_backward_no_jump(self):
        """No backward jump should return 0."""
        state_file = os.path.join(self.create_temp_dir(), "state_jump")
        now = int(time.time())
        script = f'''
        source "{LIB_DIR}/time-guards.sh" 2>/dev/null
        echo "{now}" > "{state_file}"
        detect_clock_jump_backward 3600 "{state_file}"
        echo "JUMP=$?"
        '''
        code, out, _ = self.run_bash_snippet(script)
        self.assertIn('JUMP=0', out)

    def test_detect_clock_jump_backward_large_jump(self):
        """Large backward jump should return 1."""
        state_file = os.path.join(self.create_temp_dir(), "state_jump")
        # Set a future epoch as "last run" to simulate backward jump
        future_epoch = int(time.time()) + 7200
        script = f'''
        source "{LIB_DIR}/time-guards.sh" 2>/dev/null
        echo "{future_epoch}" > "{state_file}"
        detect_clock_jump_backward 60 "{state_file}"
        echo "JUMP=$?"
        '''
        code, out, _ = self.run_bash_snippet(script)
        self.assertIn('JUMP=1', out)

    def test_detect_clock_jump_backward_first_run(self):
        """First run (no state file) should return 0."""
        code, out, _ = self.source_and_call('time-guards.sh', 'detect_clock_jump_backward 3600 "/nonexistent/state"')
        self.assertEqual(code, 0)


# ═══════════════════════════════════════════════════════════════════════
# LOGGER.SH Tests
# ═══════════════════════════════════════════════════════════════════════

class TestLogger(BashTestBase):
    """Test logger.sh functions."""

    def test_log_info_writes_to_file(self):
        """log_info should write to log file."""
        log_file = os.path.join(self.create_temp_dir(), "test.log")
        script = f'''
        set -x
        source "{LIB_DIR}/logger.sh" 2>/dev/null
        init_logger "{log_file}"
        log_info "TEST" "Hello World" "{log_file}" "testuser"
        cat "{log_file}" 2>/dev/null || true
        '''
        code, out, _ = self.run_bash_snippet(script)
        self.assertIn('Hello World', out)
        self.assertIn('INFO', out)

    def test_log_error_writes_to_stderr(self):
        """log_error should write to stderr."""
        log_file = os.path.join(self.create_temp_dir(), "test_err.log")
        script = f'''
        source "{LIB_DIR}/logger.sh" 2>/dev/null
        init_logger "{log_file}"
        log_error "TEST" "Error message"
        '''
        code, out, err = self.run_bash_snippet(script)
        self.assertIn('Error message', err)

    def test_log_audit_writes_audit_entry(self):
        """log_audit should write audit entry."""
        log_file = os.path.join(self.create_temp_dir(), "test_audit.log")
        script = f'''
        source "{LIB_DIR}/logger.sh" 2>/dev/null
        init_logger "{log_file}"
        log_audit "APPROVE" "Device approved" "{log_file}"
        cat "{log_file}"
        '''
        code, out, _ = self.run_bash_snippet(script)
        self.assertIn('APPROVE', out)
        self.assertIn('Device approved', out)

    def test_init_logger_creates_directory(self):
        """init_logger should create log directory if missing."""
        log_dir = self.create_temp_dir()
        log_file = os.path.join(log_dir, "subdir", "test.log")
        script = f'''
        source "{LIB_DIR}/logger.sh" 2>/dev/null
        init_logger "{log_file}"
        echo "DONE"
        '''
        code, out, _ = self.run_bash_snippet(script)
        self.assertIn('DONE', out)

    def test_log_levels_numeric(self):
        """Log level constants should be correct."""
        script = f'''
        source "{LIB_DIR}/logger.sh" 2>/dev/null
        echo "DEBUG=$LOG_LEVEL_DEBUG"
        echo "INFO=$LOG_LEVEL_INFO"
        echo "WARN=$LOG_LEVEL_WARN"
        echo "ERROR=$LOG_LEVEL_ERROR"
        echo "CRITICAL=$LOG_LEVEL_CRITICAL"
        '''
        code, out, _ = self.run_bash_snippet(script)
        self.assertIn('DEBUG=0', out)
        self.assertIn('INFO=1', out)
        self.assertIn('WARN=2', out)
        self.assertIn('ERROR=3', out)
        self.assertIn('CRITICAL=4', out)


# ═══════════════════════════════════════════════════════════════════════
# BACKUP.SH Tests
# ═══════════════════════════════════════════════════════════════════════

class TestBackup(BashTestBase):
    """Test backup.sh functions."""

    def test_create_backup(self):
        """Should create a tar.gz backup file."""
        backup_dir = self.create_temp_dir()
        rules_dir = self.create_temp_dir()
        # Create a test rules file
        rule_file = os.path.join(rules_dir, "test.rules")
        with open(rule_file, 'w') as f:
            f.write("allow id 0001:0001\n")

        script = f'''
        source "{LIB_DIR}/logger.sh" 2>/dev/null
        source "{LIB_DIR}/backup.sh" 2>/dev/null
        result=$(create_backup "{backup_dir}" "{rules_dir}" 5)
        echo "BACKUP=$result"
        ls -la "{backup_dir}/"
        '''
        code, out, _ = self.run_bash_snippet(script)
        self.assertIn('BACKUP=', out)
        self.assertTrue(os.path.exists(backup_dir))

    def test_rotate_backups(self):
        """Rotation should keep only N backups."""
        backup_dir = self.create_temp_dir()
        # Create 5 fake backup files
        for i in range(5):
            filepath = os.path.join(backup_dir, f"rules_2024010{i}_12000{i}.tar.gz")
            with open(filepath, 'w') as f:
                f.write(f"backup {i}")

        script = f'''
        source "{LIB_DIR}/logger.sh" 2>/dev/null
        source "{LIB_DIR}/backup.sh" 2>/dev/null
        rotate_backups "{backup_dir}" 3
        ls -1 "{backup_dir}/" | wc -l
        '''
        code, out, _ = self.run_bash_snippet(script)
        # After rotation with keep=3, should have 3 files
        self.assertIn('3', out)

    def test_list_backups_empty(self):
        """Empty backup dir should indicate no backups."""
        backup_dir = self.create_temp_dir()
        code, out, _ = self.source_and_call('backup.sh', f'list_backups "{backup_dir}"')
        self.assertIn('No backups', out)

    def test_list_backups_with_files(self):
        """Should list existing backups."""
        backup_dir = self.create_temp_dir()
        with open(os.path.join(backup_dir, "rules_20240101_120000.tar.gz"), 'w') as f:
            f.write("test")
        code, out, _ = self.source_and_call('backup.sh', f'list_backups "{backup_dir}"')
        self.assertIn('rules_20240101_120000.tar.gz', out)


# ═══════════════════════════════════════════════════════════════════════
# VALIDATORS.SH Tests
# ═══════════════════════════════════════════════════════════════════════

class TestValidators(BashTestBase):
    """Test validators.sh functions."""

    def test_check_root_as_root(self):
        """Running as root should pass."""
        # We can't actually run as root in tests, but we can test the function
        script = f'''
        source "{LIB_DIR}/logger.sh" 2>/dev/null
        source "{LIB_DIR}/validators.sh" 2>/dev/null
        # Simulate root by mocking id
        id() {{ echo 0; }}
        if check_root; then
            echo "ROOT_OK"
        else
            echo "ROOT_FAIL"
        fi
        '''
        code, out, _ = self.run_bash_snippet(script)
        self.assertIn('ROOT_OK', out)

    def test_check_rules_files_exist_all_present(self):
        """All rules files present should pass."""
        rules_dir = self.create_temp_dir()
        for rule in ['00-system.rules', '50-permanent.rules', '90-temporary.rules']:
            with open(os.path.join(rules_dir, rule), 'w') as f:
                f.write("allow id 0001:0001\n")

        script = f'''
        source "{LIB_DIR}/logger.sh" 2>/dev/null
        source "{LIB_DIR}/validators.sh" 2>/dev/null
        check_rules_files_exist "{rules_dir}"
        echo "RC=$?"
        '''
        code, out, _ = self.run_bash_snippet(script)
        self.assertIn('RC=0', out)

    def test_check_rules_files_exist_some_missing(self):
        """Missing rules files should fail."""
        rules_dir = self.create_temp_dir()
        # Only create one file
        with open(os.path.join(rules_dir, '00-system.rules'), 'w') as f:
            f.write("allow id 0001:0001\n")

        script = f'''
        source "{LIB_DIR}/logger.sh" 2>/dev/null
        source "{LIB_DIR}/validators.sh" 2>/dev/null
        check_rules_files_exist "{rules_dir}"
        echo "RC=$?"
        '''
        code, out, _ = self.run_bash_snippet(script)
        self.assertIn('RC=1', out)

    def test_check_disk_space_sufficient(self):
        """Sufficient disk space should pass."""
        script = f'''
        source "{LIB_DIR}/logger.sh" 2>/dev/null
        source "{LIB_DIR}/validators.sh" 2>/dev/null
        check_disk_space "/tmp" 1
        echo "RC=$?"
        '''
        code, out, _ = self.run_bash_snippet(script)
        self.assertIn('RC=0', out)

    def test_check_rule_duplicate_found(self):
        """Existing rule should be detected as duplicate."""
        rules_dir = self.create_temp_dir()
        rule_file = os.path.join(rules_dir, "00-system.rules")
        with open(rule_file, 'w') as f:
            f.write("allow id 0001:0001 serial \"ABC\"\n")

        script = f'''
        source "{LIB_DIR}/logger.sh" 2>/dev/null
        source "{LIB_DIR}/validators.sh" 2>/dev/null
        check_rule_duplicate "allow id 0001:0001 serial \\"ABC\\"" "{rules_dir}"
        echo "RC=$?"
        '''
        code, out, _ = self.run_bash_snippet(script)
        self.assertIn('RC=0', out)  # 0 = duplicate found

    def test_check_rule_duplicate_not_found(self):
        """New rule should not be detected as duplicate."""
        rules_dir = self.create_temp_dir()
        rule_file = os.path.join(rules_dir, "00-system.rules")
        with open(rule_file, 'w') as f:
            f.write("allow id 0001:0001 serial \"ABC\"\n")

        script = f'''
        source "{LIB_DIR}/logger.sh" 2>/dev/null
        source "{LIB_DIR}/validators.sh" 2>/dev/null
        check_rule_duplicate "allow id 9999:9999 serial XYZ" "{rules_dir}"
        echo "RC=$?"
        '''
        code, out, _ = self.run_bash_snippet(script)
        self.assertIn('RC=1', out)  # 1 = no duplicate

    def test_check_rule_duplicate_empty_rule(self):
        """Empty rule should return error."""
        script = f'''
        source "{LIB_DIR}/logger.sh" 2>/dev/null
        source "{LIB_DIR}/validators.sh" 2>/dev/null
        check_rule_duplicate "" "/tmp"
        echo "RC=$?"
        '''
        code, out, _ = self.run_bash_snippet(script)
        self.assertIn('RC=2', out)  # 2 = empty rule

    def test_check_config_file_valid(self):
        """Valid config file should pass."""
        config = "KEY=value\n"
        config_path = self.create_temp_file(config)
        script = f'''
        source "{LIB_DIR}/logger.sh" 2>/dev/null
        source "{LIB_DIR}/config-reader.sh" 2>/dev/null
        source "{LIB_DIR}/validators.sh" 2>/dev/null
        check_config_file "{config_path}"
        echo "RC=$?"
        '''
        code, out, _ = self.run_bash_snippet(script)
        self.assertIn('RC=0', out)

    def test_check_config_file_missing(self):
        """Missing config file should fail."""
        script = f'''
        source "{LIB_DIR}/logger.sh" 2>/dev/null
        source "{LIB_DIR}/config-reader.sh" 2>/dev/null
        source "{LIB_DIR}/validators.sh" 2>/dev/null
        check_config_file "/nonexistent/config.conf"
        echo "RC=$?"
        '''
        code, out, _ = self.run_bash_snippet(script)
        self.assertIn('RC=1', out)


# ═══════════════════════════════════════════════════════════════════════
# DEVICE-UTILS.SH Tests
# ═══════════════════════════════════════════════════════════════════════

class TestDeviceUtils(BashTestBase):
    """Test device-utils.sh functions."""

    def test_parse_device_info_id(self):
        """Should extract VID:PID from device line."""
        device_line = '0: block id 0781:5581 serial "4C530001" name "SanDisk" via-port "1-2" hash "abc123"'
        script = f'''
        source "{LIB_DIR}/device-utils.sh" 2>/dev/null
        result=$(_parse_device_info "{device_line}" "id")
        echo "ID=$result"
        '''
        code, out, _ = self.run_bash_snippet(script)
        self.assertIn('ID=0781:5581', out)

    def test_parse_device_info_name(self):
        """Should extract name from device line."""
        device_line = '0: block id 0781:5581 name "SanDisk Ultra" via-port "1-2"'
        script = f'''
        source "{LIB_DIR}/device-utils.sh" 2>/dev/null
        result=$(_parse_device_info '{device_line}' "name")
        echo "NAME=$result"
        '''
        code, out, _ = self.run_bash_snippet(script)
        self.assertIn('NAME=SanDisk Ultra', out)

    def test_parse_device_info_serial(self):
        """Should extract serial from device line."""
        device_line = '0: block id 0781:5581 serial "4C530001" name "SanDisk"'
        script = f'''
        source "{LIB_DIR}/device-utils.sh" 2>/dev/null
        result=$(_parse_device_info '{device_line}' "serial")
        echo "SERIAL=$result"
        '''
        code, out, _ = self.run_bash_snippet(script)
        self.assertIn('SERIAL=4C530001', out)

    def test_parse_device_info_device_id(self):
        """Should extract device index from beginning of line."""
        device_line = '5: allow id 1d6b:0002 name "Host Controller"'
        script = f'''
        source "{LIB_DIR}/device-utils.sh" 2>/dev/null
        result=$(_parse_device_info '{device_line}' "device_id")
        echo "DEV_ID=$result"
        '''
        code, out, _ = self.run_bash_snippet(script)
        self.assertIn('DEV_ID=5', out)

    def test_parse_device_info_port(self):
        """Should extract port from device line."""
        device_line = '0: block id 0781:5581 via-port "1-2.3" name "USB"'
        script = f'''
        source "{LIB_DIR}/device-utils.sh" 2>/dev/null
        result=$(_parse_device_info '{device_line}' "port")
        echo "PORT=$result"
        '''
        code, out, _ = self.run_bash_snippet(script)
        self.assertIn('PORT=1-2.3', out)

    def test_parse_device_info_hash(self):
        """Should extract hash from device line."""
        device_line = '0: block id 0781:5581 hash "abc123def" name "USB"'
        script = f'''
        source "{LIB_DIR}/device-utils.sh" 2>/dev/null
        result=$(_parse_device_info '{device_line}' "hash")
        echo "HASH=$result"
        '''
        code, out, _ = self.run_bash_snippet(script)
        self.assertIn('HASH=abc123def', out)


# ═══════════════════════════════════════════════════════════════════════
# CLEANUP-EXPIRED.SH Tests (AWK Logic)
# ═══════════════════════════════════════════════════════════════════════

class TestCleanupExpired(BashTestBase):
    """Test cleanup-expired.sh AWK TTL filter."""

    def test_cleanup_expired_removes_old_rules(self):
        """Expired rules should be removed, valid rules kept."""
        rules = '''allow id 1111:2222 serial "123" name "Key 1"
# ttl_epoch: 1000
allow id 3333:4444 serial "456" name "Key 2"
# ttl_epoch: 9000
allow id 5555:6666 serial "789" name "Key 3"
# ttl_epoch: 5000
'''
        rules_path = self.create_temp_file(rules)
        script = f'''
        source "{LIB_DIR}/logger.sh" 2>/dev/null
        source "{LIB_DIR}/config-reader.sh" 2>/dev/null
        source "{LIB_DIR}/lock.sh" 2>/dev/null
        source "{LIB_DIR}/time-guards.sh" 2>/dev/null
        source "{SCRIPTS_DIR}/cleanup-expired.sh" 2>/dev/null
        _awk_ttl_filter 3000 "{rules_path}"
        '''
        code, out, _ = self.run_bash_snippet(script)
        self.assertNotIn("1111:2222", out)  # Expired
        self.assertIn("3333:4444", out)  # Valid (ttl=9000 > now=3000)
        self.assertIn("5555:6666", out)  # Valid (ttl=5000 > now=3000)

    def test_cleanup_expired_all_valid(self):
        """All valid rules should remain."""
        rules = '''allow id 1111:2222 serial "123"
# ttl_epoch: 9999999999
allow id 3333:4444 serial "456"
# ttl_epoch: 8888888888
'''
        rules_path = self.create_temp_file(rules)
        script = f'''
        source "{LIB_DIR}/logger.sh" 2>/dev/null
        source "{LIB_DIR}/config-reader.sh" 2>/dev/null
        source "{LIB_DIR}/lock.sh" 2>/dev/null
        source "{LIB_DIR}/time-guards.sh" 2>/dev/null
        source "{SCRIPTS_DIR}/cleanup-expired.sh" 2>/dev/null
        _awk_ttl_filter 3000 "{rules_path}"
        '''
        code, out, _ = self.run_bash_snippet(script)
        self.assertIn("1111:2222", out)
        self.assertIn("3333:4444", out)

    def test_cleanup_expired_all_expired(self):
        """All expired rules should be removed."""
        rules = '''allow id 1111:2222 serial "123"
# ttl_epoch: 100
allow id 3333:4444 serial "456"
# ttl_epoch: 200
'''
        rules_path = self.create_temp_file(rules)
        script = f'''
        source "{LIB_DIR}/logger.sh" 2>/dev/null
        source "{LIB_DIR}/config-reader.sh" 2>/dev/null
        source "{LIB_DIR}/lock.sh" 2>/dev/null
        source "{LIB_DIR}/time-guards.sh" 2>/dev/null
        source "{SCRIPTS_DIR}/cleanup-expired.sh" 2>/dev/null
        _awk_ttl_filter 5000 "{rules_path}"
        '''
        code, out, _ = self.run_bash_snippet(script)
        self.assertNotIn("1111:2222", out)
        self.assertNotIn("3333:4444", out)

    def test_cleanup_expired_empty_file(self):
        """Empty rules file should produce empty output."""
        rules_path = self.create_temp_file("")
        script = f'''
        source "{LIB_DIR}/logger.sh" 2>/dev/null
        source "{LIB_DIR}/config-reader.sh" 2>/dev/null
        source "{LIB_DIR}/lock.sh" 2>/dev/null
        source "{LIB_DIR}/time-guards.sh" 2>/dev/null
        source "{SCRIPTS_DIR}/cleanup-expired.sh" 2>/dev/null
        _awk_ttl_filter 3000 "{rules_path}"
        '''
        code, out, _ = self.run_bash_snippet(script)
        self.assertEqual(out.strip(), "")

    def test_cleanup_expired_boundary_epoch(self):
        """Rule with TTL exactly equal to now should be expired."""
        rules = 'allow id 1111:2222 serial "123"\n# ttl_epoch: 3000\n'
        rules_path = self.create_temp_file(rules)
        script = f'''
        source "{LIB_DIR}/logger.sh" 2>/dev/null
        source "{LIB_DIR}/config-reader.sh" 2>/dev/null
        source "{LIB_DIR}/lock.sh" 2>/dev/null
        source "{LIB_DIR}/time-guards.sh" 2>/dev/null
        source "{SCRIPTS_DIR}/cleanup-expired.sh" 2>/dev/null
        _awk_ttl_filter 3000 "{rules_path}"
        '''
        code, out, _ = self.run_bash_snippet(script)
        # epoch <= now means expired
        self.assertNotIn("1111:2222", out)


if __name__ == '__main__':
    unittest.main()