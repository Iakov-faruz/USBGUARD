# ==============================================================================
# חשיפת ממשק ה-API הציבורי של חבילת ה-Core
# מציג החוצה רק את המחלקות והפונקציות הנדרשות מחוץ למודול
# ==============================================================================
from .models import DeviceRecord, fingerprint_device, now_iso
from .config import Config
from .audit import AuditLogger
from .policy_store import PolicyStore
from .usbguard_client import USBGuardClient, UsbguardError
from .rules_renderer import render_allow, render_reject, composite_reject_rules
from .approver import Approver
from .policy_sync import sanitize_rule, rule_signature, normalize_active_rules, build_policy_file, verify_active, reload_daemon
from .backup_manager import create_backup, rotate_backups, list_backups, restore_backup
from .validators import (
    validate_rule, validate_rule_line, validate_rule_file, validate_import_payload,
    rule_signature as validator_rule_signature, check_rule_duplicate,
    check_root, check_user_allowed, check_daemon_active, check_rules_files_exist,
    check_rule_syntax, check_disk_space, check_external_deps, check_clock_reasonable,
    check_config_file, run_all_preflight_checks,
)

__all__ = [
    "DeviceRecord", "fingerprint_device", "now_iso",
    "Config", "AuditLogger", "PolicyStore",
    "USBGuardClient", "UsbguardError",
    "render_allow", "render_reject", "composite_reject_rules",
    "Approver",
    "sanitize_rule", "rule_signature", "normalize_active_rules", "build_policy_file", "verify_active", "reload_daemon",
    "create_backup", "rotate_backups", "list_backups", "restore_backup",
    "validate_rule", "validate_rule_line", "validate_rule_file", "validate_import_payload",
    "validator_rule_signature", "check_rule_duplicate",
    "check_root", "check_user_allowed", "check_daemon_active", "check_rules_files_exist",
    "check_rule_syntax", "check_disk_space", "check_external_deps", "check_clock_reasonable",
    "check_config_file", "run_all_preflight_checks",
]