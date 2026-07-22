from __future__ import annotations
import argparse, json, os, re, shutil, subprocess, sys, time
from pathlib import Path
from types import SimpleNamespace
from typing import Any, Dict, List, Optional, Tuple

from core.approver import Approver
from core.audit import AuditLogger
from core.backup_manager import create_backup, list_backups, restore_backup
from core.config import Config
from core.models import DeviceRecord
from core.policy_store import PolicyStore
from core.policy_sync import build_policy_file, reload_daemon, validate_rules_dir
from core.usbguard_client import USBGuardClient, UsbguardError
from core.validators import (
    check_clock_reasonable, check_config_file, check_daemon_active, check_disk_space,
    check_external_deps, check_root, check_rules_files_exist, check_rule_syntax,
    check_rule_duplicate, run_all_preflight_checks, validate_import_payload, validate_rule_file,
)

_TTL_RE = re.compile(r"#\s*ttl_epoch:\s*(\d+)", re.IGNORECASE)


def build_context(config_path: Optional[str] = None) -> SimpleNamespace:
    config = Config.load(config_path)
    config.ensure_dirs()
    store = PolicyStore(
        path=config.policy_store_file,
        backup_dir=config.backup_dir,
        keep_backups=config.keep_backups,
        lock_path=config.lock_file,
    )
    audit = AuditLogger(config.audit_file)
    client = USBGuardClient(config.usbguard_binary)
    approver = Approver(config, store, client, audit)
    return SimpleNamespace(config=config, store=store, audit=audit, client=client, approver=approver)


def print_devices(devices: List[DeviceRecord], as_json: bool = False) -> None:
    if as_json:
        print(json.dumps([d.to_dict() for d in devices], indent=2, ensure_ascii=False))
        return
    for d in devices:
        interfaces = ",".join(d.interfaces)
        print(f"{d.fingerprint}\t{d.state}\t{d.vid_pid}\t{d.serial}\t{d.via_port}\t{interfaces}")


# ==============================================================================
# Existing command handlers
# ==============================================================================
def cmd_status(args, ctx):
    devices = ctx.store.list_devices()
    counts: Dict[str, int] = {}
    for d in devices:
        counts[d.state] = counts.get(d.state, 0) + 1
    implicit_policy = ctx.client.get_parameter("ImplicitPolicyTarget")
    out = {
        "lockdown": ctx.store.meta_get("lockdown", False),
        "device_counts": counts,
        "implicit_policy_target": implicit_policy,
    }
    print(json.dumps(out, indent=2, ensure_ascii=False))


def cmd_scan(args, ctx):
    count = ctx.approver.sync_devices()
    print(json.dumps({"status": "ok", "synced": count}, indent=2))


def cmd_init_policy(args, ctx):
    added = ctx.approver.init_policy()
    print(json.dumps({
        "status": "ok",
        "rules_added": added,
        "note": "composite reject now at top (first-match)",
    }, indent=2))


def cmd_rebuild_policy(args, ctx):
    added = ctx.approver.init_policy(force_rebuild=True)
    print(json.dumps({
        "status": "ok",
        "rules_added": added,
        "note": "policy rebuilt from scratch",
    }, indent=2))


def cmd_devices_list(args, ctx):
    devices = ctx.store.list_devices(state=getattr(args, "state", None))
    print_devices(devices, as_json=args.json)


def cmd_devices_pending(args, ctx):
    devices = ctx.store.list_devices(state="pending")
    print_devices(devices, as_json=args.json)


def cmd_approve(args, ctx):
    try:
        device = ctx.approver.approve(
            fingerprint=args.fingerprint,
            permanent=args.permanent,
            ttl=args.ttl,
            actor=args.actor,
            port_bind=args.port_bind,
        )
        print(json.dumps(device.to_dict(), indent=2, ensure_ascii=False))
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)


def cmd_deny(args, ctx):
    try:
        device = ctx.approver.deny(
            fingerprint=args.fingerprint,
            actor=args.actor,
            reason=args.reason,
        )
        print(json.dumps(device.to_dict(), indent=2, ensure_ascii=False))
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)


def cmd_quarantine(args, ctx):
    try:
        device = ctx.approver.quarantine(
            fingerprint=args.fingerprint,
            actor=args.actor,
            reason=args.reason,
        )
        print(json.dumps(device.to_dict(), indent=2, ensure_ascii=False))
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)


def cmd_lockdown_enable(args, ctx):
    ctx.approver.lockdown_enable(actor=args.actor)
    print(json.dumps({"status": "lockdown_enabled"}, indent=2))


def cmd_lockdown_disable(args, ctx):
    ctx.approver.lockdown_disable(actor=args.actor)
    print(json.dumps({"status": "lockdown_disabled", "note": "ImplicitPolicyTarget stays block for safety"}, indent=2))


def cmd_learn(args, ctx):
    proposals = ctx.approver.learn(duration=args.duration, actor=args.actor)
    print(json.dumps(proposals, indent=2, ensure_ascii=False))


def cmd_audit_tail(args, ctx):
    path = Path(ctx.config.audit_file)
    if not path.exists():
        return
    lines = path.read_text(encoding="utf-8").splitlines()
    for line in lines[-args.lines:]:
        print(line)


def cmd_daemon(args, ctx):
    ctx.audit.log("daemon_start", interval=args.interval)
    try:
        ctx.approver.init_policy(force_rebuild=False)
    except RuntimeError:
        ctx.audit.log("startup_policy_needs_rebuild", hint="Run: protector rebuild-policy --force")
    except Exception as e:
        ctx.audit.log("startup_policy_error", error=str(e))
    while True:
        try:
            ctx.approver.sync_devices()
            ctx.approver.expire_temporary()
        except Exception as e:
            ctx.audit.log("daemon_error", error=str(e))
        time.sleep(args.interval)


def cmd_hid_monitor(args, ctx):
    from detection.hid_monitor import run_cli
    run_cli(args.config)


# ==============================================================================
# New command handlers
# ==============================================================================
def cmd_cleanup_expired(args, ctx):
    rules_dir = str(Path(ctx.config.config_dir) / "rules.d")
    temp_file = Path(rules_dir) / "90-temporary.rules"
    rules_file = str(Path(ctx.config.config_dir) / "rules.conf")
    backup_dir = ctx.config.backup_dir

    if not check_clock_reasonable():
        print("ERROR: Clock jump detected, aborting cleanup", file=sys.stderr)
        sys.exit(1)

    if not temp_file.exists():
        print(json.dumps({"status": "ok", "removed": 0, "note": "no temporary rules file"}, indent=2))
        return

    backup = create_backup(rules_dir, backup_dir, ctx.config.keep_backups)
    if backup is None:
        print("ERROR: Backup failed, aborting cleanup", file=sys.stderr)
        sys.exit(1)

    now = int(time.time())
    kept: List[str] = []
    removed = 0
    for line in temp_file.read_text(encoding="utf-8").splitlines():
        m = _TTL_RE.search(line)
        if m:
            ttl_epoch = int(m.group(1))
            if ttl_epoch <= now:
                removed += 1
                continue
        kept.append(line)

    temp_file.write_text("\n".join(kept) + "\n", encoding="utf-8")
    temp_file.chmod(0o600)

    if not validate_rules_dir(rules_dir):
        if backup:
            restore_backup(backup, rules_dir)
            reload_daemon(rules_dir, rules_file)
        print("ERROR: Validation failed after cleanup, rolled back", file=sys.stderr)
        sys.exit(1)

    if reload_daemon(rules_dir, rules_file):
        ctx.audit.log("cleanup_expired", removed=removed, backup=backup)
        print(json.dumps({"status": "ok", "removed": removed, "backup": backup}, indent=2))
    else:
        if backup:
            restore_backup(backup, rules_dir)
            reload_daemon(rules_dir, rules_file)
        print("ERROR: Daemon reload failed after cleanup, rolled back", file=sys.stderr)
        sys.exit(1)


def cmd_backup(args, ctx):
    rules_dir = str(Path(ctx.config.config_dir) / "rules.d")
    backup = create_backup(rules_dir, ctx.config.backup_dir, ctx.config.keep_backups)
    if backup:
        ctx.audit.log("backup_created", path=backup)
        print(json.dumps({"status": "ok", "backup": backup}, indent=2))
    else:
        print("ERROR: Backup failed", file=sys.stderr)
        sys.exit(1)


def cmd_restore(args, ctx):
    backup_dir = ctx.config.backup_dir
    rules_dir = str(Path(ctx.config.config_dir) / "rules.d")
    rules_file = str(Path(ctx.config.config_dir) / "rules.conf")

    backups = list_backups(backup_dir)
    if not backups:
        print("ERROR: No backups found", file=sys.stderr)
        sys.exit(1)

    if args.name:
        backup_file = str(Path(backup_dir) / args.name)
        if backup_file not in [str(Path(backup_dir) / b) for b in backups]:
            print(f"ERROR: Backup not found: {args.name}", file=sys.stderr)
            sys.exit(1)
    else:
        print("Available backups:")
        for b in backups:
            print(f"  {b}")
        backup_file = str(Path(backup_dir) / backups[0])

    pre_backup = create_backup(rules_dir, backup_dir, ctx.config.keep_backups)
    if restore_backup(backup_file, rules_dir):
        if reload_daemon(rules_dir, rules_file):
            ctx.audit.log("restore", from_backup=backup_file, pre_backup=pre_backup)
            print(json.dumps({"status": "ok", "restored": backup_file, "pre_backup": pre_backup}, indent=2))
        else:
            if pre_backup:
                restore_backup(pre_backup, rules_dir)
                reload_daemon(rules_dir, rules_file)
            print("ERROR: Daemon reload failed after restore, rolled back", file=sys.stderr)
            sys.exit(1)
    else:
        print("ERROR: Restore failed", file=sys.stderr)
        sys.exit(1)


def cmd_import_rules(args, ctx):
    rules_dir = str(Path(ctx.config.config_dir) / "rules.d")
    rules_file = str(Path(ctx.config.config_dir) / "rules.conf")

    errors = validate_import_payload(args.file)
    if errors:
        for e in errors:
            print(e, file=sys.stderr)
        sys.exit(1)

    try:
        data = json.loads(Path(args.file).read_text(encoding="utf-8"))
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)

    rules_map = data.get("rules", {})
    allowed = {"system", "permanent", "temporary"}
    category_map = {"system": "00-system.rules", "permanent": "50-permanent.rules", "temporary": "90-temporary.rules"}

    added = 0
    skipped = 0
    for category, rules in rules_map.items():
        if category not in allowed:
            continue
        target = Path(rules_dir) / category_map[category]
        if not target.exists():
            target.write_text("", encoding="utf-8")
            target.chmod(0o600)
        existing = target.read_text(encoding="utf-8").splitlines()
        for rule in rules:
            if check_rule_duplicate(rule, rules_dir):
                skipped += 1
                if not args.force:
                    continue
            existing.append(rule)
            added += 1
        target.write_text("\n".join(existing) + "\n", encoding="utf-8")
        target.chmod(0o600)

    if reload_daemon(rules_dir, rules_file):
        ctx.audit.log("import", file=args.file, added=added, skipped=skipped)
        print(json.dumps({"status": "ok", "added": added, "skipped": skipped}, indent=2))
    else:
        print("ERROR: Daemon reload failed after import", file=sys.stderr)
        sys.exit(1)


def cmd_export_rules(args, ctx):
    rules_dir = str(Path(ctx.config.config_dir) / "rules.d")
    category_map = {
        "00-system.rules": "system",
        "50-permanent.rules": "permanent",
        "90-temporary.rules": "temporary",
    }
    output: Dict[str, List[str]] = {"system": [], "permanent": [], "temporary": []}
    for fname, category in category_map.items():
        fpath = Path(rules_dir) / fname
        if fpath.exists():
            for line in fpath.read_text(encoding="utf-8").splitlines():
                stripped = line.strip()
                if stripped and not stripped.startswith("#"):
                    output[category].append(stripped)

    if args.format == "yaml":
        import yaml
        text = yaml.dump({"rules": output}, default_flow_style=False, allow_unicode=True, sort_keys=False)
    else:
        text = json.dumps({"rules": output}, indent=2, ensure_ascii=False)

    if args.output:
        Path(args.output).write_text(text, encoding="utf-8")
        print(json.dumps({"status": "ok", "output": args.output}, indent=2))
    else:
        print(text)


def cmd_healthcheck(args, ctx):
    results = []
    checks = [
        ("root", check_root(), "Must run as root"),
        ("clock", check_clock_reasonable(), "System clock reasonable"),
        ("daemon", args.skip_daemon or check_daemon_active(), "usbguard daemon active"),
        ("deps", check_external_deps(), "Required dependencies present"),
        ("config", check_config_file(args.config), "Config file valid"),
        ("rules_dir", check_rules_files_exist(str(Path(ctx.config.config_dir) / "rules.d")), "Rules directory complete"),
    ]

    disk_ok = check_disk_space(ctx.config.backup_dir)
    checks.append(("disk", disk_ok, f"Disk space available at {ctx.config.backup_dir}"))

    for name, ok, desc in checks:
        results.append({"check": name, "passed": ok, "description": desc})

    passed = sum(1 for r in results if r["passed"])
    total = len(results)
    status = "ok" if passed == total else "failed"
    print(json.dumps({"status": status, "passed": passed, "total": total, "checks": results}, indent=2))
    if status == "failed":
        sys.exit(1)


def cmd_check_config(args, ctx):
    errors = []
    config_path = args.config
    if not Path(config_path).exists():
        errors.append(f"Config file not found: {config_path}")
        print(json.dumps({"status": "error", "errors": errors}, indent=2))
        sys.exit(1)

    if not check_config_file(config_path):
        errors.append("Config file is invalid or unreadable")

    try:
        config = Config.load(config_path)
    except Exception as e:
        errors.append(f"Failed to load config: {e}")
        print(json.dumps({"status": "error", "errors": errors}, indent=2))
        sys.exit(1)

    required_dirs = [config.data_dir, config.config_dir, config.log_dir, config.run_dir, config.backup_dir]
    for d in required_dirs:
        p = Path(d)
        if not p.exists():
            errors.append(f"Missing directory: {d}")

    if not Path(config.usbguard_binary).exists():
        errors.append(f"usbguard binary not found: {config.usbguard_binary}")

    if errors:
        print(json.dumps({"status": "error", "errors": errors}, indent=2))
        sys.exit(1)

    print(json.dumps({
        "status": "ok",
        "config_file": config_path,
        "usbguard_binary": config.usbguard_binary,
        "rules_dir": str(Path(config.config_dir) / "rules.d"),
    }, indent=2))


def cmd_approve_tui(args, ctx):
    if not check_root():
        print("ERROR: Must run as root", file=sys.stderr)
        sys.exit(1)

    try:
        output = subprocess.run(
            [ctx.config.usbguard_binary, "list-devices", "--blocked"],
            capture_output=True, text=True, check=True,
        ).stdout
    except Exception as e:
        print(f"ERROR: Cannot list blocked devices: {e}", file=sys.stderr)
        sys.exit(1)

    blocked = []
    for line in output.splitlines():
        m = re.match(r"^\s*(\d+):\s+(block|reject)\s+(.*)$", line)
        if m:
            blocked.append((m.group(1), m.group(3)))

    if not blocked:
        print("No blocked devices found.")
        return

    menu_items = []
    for idx, (dev_id, spec) in enumerate(blocked):
        name = _extract_name(spec)
        vid_pid = _extract_vid_pid(spec)
        menu_items.append((str(idx), f"{name} ({vid_pid})", "ON"))

    whiptail_cmd = [
        "whiptail", "--title", "USB Device Approval", "--checklist",
        "Select USB devices to approve:", "20", "72", str(len(blocked)),
    ]
    for tag, text, status in menu_items:
        whiptail_cmd.extend([tag, text, status])

    try:
        result = subprocess.run(whiptail_cmd, capture_output=True, text=True)
    except FileNotFoundError:
        print("ERROR: whiptail not found, cannot run TUI", file=sys.stderr)
        sys.exit(1)

    if result.returncode != 0 or not result.stdout.strip():
        print("No devices selected or cancelled.")
        return

    selected_ids = [idx for idx in result.stdout.strip().split()]
    if not selected_ids:
        print("No devices selected.")
        return

    type_cmd = [
        "whiptail", "--title", "Approval Type", "--menu",
        "Choose approval type:", "12", "50", "2",
        "P", "Permanent",
        "T", "Temporary (300s TTL)",
    ]
    try:
        type_result = subprocess.run(type_cmd, capture_output=True, text=True)
    except FileNotFoundError:
        print("ERROR: whiptail not found", file=sys.stderr)
        sys.exit(1)

    if type_result.returncode != 0:
        print("Cancelled.")
        return

    approval_type = type_result.stdout.strip()
    permanent = approval_type == "P"
    ttl = 300

    rules_dir = str(Path(ctx.config.config_dir) / "rules.d")
    rules_file = str(Path(ctx.config.config_dir) / "rules.conf")
    backup = create_backup(rules_dir, ctx.config.backup_dir, ctx.config.keep_backups)
    if not backup:
        print("ERROR: Backup failed, aborting", file=sys.stderr)
        sys.exit(1)

    target_file = Path(rules_dir) / ("50-permanent.rules" if permanent else "90-temporary.rules")
    if not target_file.exists():
        target_file.write_text("", encoding="utf-8")
        target_file.chmod(0o600)

    created = 0
    for idx_str in selected_ids:
        idx = int(idx_str)
        dev_id, spec = blocked[idx]
        rule = _build_rule_from_spec(dev_id, spec, ttl if not permanent else 0)
        if rule is None:
            continue
        with open(target_file, "a", encoding="utf-8") as f:
            f.write(rule + "\n")
        try:
            ctx.client.allow_device(int(dev_id))
        except Exception:
            pass
        created += 1

    if not validate_rules_dir(rules_dir):
        restore_backup(backup, rules_dir)
        reload_daemon(rules_dir, rules_file)
        print("ERROR: Validation failed, rolled back", file=sys.stderr)
        sys.exit(1)

    if reload_daemon(rules_dir, rules_file):
        ctx.audit.log("approve_tui", count=created, type=approval_type, backup=backup)
        try:
            subprocess.run([
                "notify-send", "--icon=usbguard", "--urgency=normal",
                "--app-name=USBGuard Manager",
                "USB Devices Approved",
                f"Approved: {created} devices ({approval_type})",
            ], check=False, capture_output=True)
        except Exception:
            pass
        print(json.dumps({"status": "ok", "approved": created, "type": approval_type}, indent=2))
    else:
        restore_backup(backup, rules_dir)
        reload_daemon(rules_dir, rules_file)
        print("ERROR: Daemon reload failed, rolled back", file=sys.stderr)
        sys.exit(1)


def _extract_name(spec: str) -> str:
    m = re.search(r'name\s+"([^"]+)"', spec)
    return m.group(1) if m else "Unknown Device"


def _extract_vid_pid(spec: str) -> str:
    m = re.search(r'id\s+([0-9a-fA-F]{4}:[0-9a-fA-F]{4})', spec)
    return m.group(1) if m else "????:????"


def _build_rule_from_spec(dev_id: str, spec: str, ttl: int = 0) -> Optional[str]:
    vid_pid = _extract_vid_pid(spec)
    name_m = re.search(r'name\s+"([^"]+)"', spec)
    hash_m = re.search(r'hash\s+"([^"]+)"', spec)
    iface_m = re.search(r"with-interface\s+\{([^}]+)\}", spec)
    if not vid_pid or vid_pid == "????:????":
        return None
    rule = f'allow id {vid_pid}'
    if name_m:
        rule += f' name "{name_m.group(1)}"'
    if hash_m:
        rule += f' hash "{hash_m.group(1)}"'
    if iface_m:
        ifaces = " ".join(iface_m.group(1).split())
        rule += f' with-interface {{{ifaces}}}'
    if ttl > 0:
        epoch = int(time.time()) + ttl
        rule += f"\n# ttl_epoch: {epoch}"
    return rule


# ==============================================================================
# Parser builder
# ==============================================================================
def build_parser():
    parser = argparse.ArgumentParser(prog="protector")
    parser.add_argument("--config", default="/etc/usbguard/protector.yaml", help="Path to protector.yaml")
    sub = parser.add_subparsers(dest="command", required=True)

    p_status = sub.add_parser("status", help="Show status")
    p_status.set_defaults(func=cmd_status)

    p_scan = sub.add_parser("scan", help="Sync devices from USBGuard into policy store")
    p_scan.set_defaults(func=cmd_scan)

    p_init = sub.add_parser("init-policy", help="Add baseline composite reject rules at TOP")
    p_init.set_defaults(func=cmd_init_policy)

    p_rebuild = sub.add_parser("rebuild-policy", help="Rebuild all rules: composite first, then allows")
    p_rebuild.add_argument("--force", action="store_true", required=True, help="Confirm full rebuild")
    p_rebuild.set_defaults(func=cmd_rebuild_policy)

    p_devices = sub.add_parser("devices", help="Device commands")
    devices_sub = p_devices.add_subparsers(dest="devices_command", required=True)

    p_devices_list = devices_sub.add_parser("list", help="List devices")
    p_devices_list.add_argument("--state", default=None)
    p_devices_list.add_argument("--json", action="store_true")
    p_devices_list.set_defaults(func=cmd_devices_list)

    p_devices_pending = devices_sub.add_parser("pending", help="List pending devices")
    p_devices_pending.add_argument("--json", action="store_true")
    p_devices_pending.set_defaults(func=cmd_devices_pending)

    p_approve = sub.add_parser("approve", help="Approve device")
    p_approve.add_argument("fingerprint")
    p_approve.add_argument("--permanent", action="store_true")
    p_approve.add_argument("--ttl", type=int, default=300)
    p_approve.add_argument("--actor", default="cli")
    p_approve.add_argument("--port-bind", action="store_true")
    p_approve.set_defaults(func=cmd_approve)

    p_deny = sub.add_parser("deny", help="Deny device")
    p_deny.add_argument("fingerprint")
    p_deny.add_argument("--actor", default="cli")
    p_deny.add_argument("--reason", default="")
    p_deny.set_defaults(func=cmd_deny)

    p_quarantine = sub.add_parser("quarantine", help="Quarantine device")
    p_quarantine.add_argument("fingerprint")
    p_quarantine.add_argument("--actor", default="cli")
    p_quarantine.add_argument("--reason", default="")
    p_quarantine.set_defaults(func=cmd_quarantine)

    p_lockdown = sub.add_parser("lockdown", help="Lockdown controls")
    lockdown_sub = p_lockdown.add_subparsers(dest="lockdown_command", required=True)

    p_lockdown_enable = lockdown_sub.add_parser("enable")
    p_lockdown_enable.add_argument("--actor", default="cli")
    p_lockdown_enable.set_defaults(func=cmd_lockdown_enable)

    p_lockdown_disable = lockdown_sub.add_parser("disable")
    p_lockdown_disable.add_argument("--actor", default="cli")
    p_lockdown_disable.set_defaults(func=cmd_lockdown_disable)

    p_learn = sub.add_parser("learn", help="Learning mode, propose only")
    p_learn.add_argument("--duration", type=int, default=30)
    p_learn.add_argument("--actor", default="cli")
    p_learn.set_defaults(func=cmd_learn)

    p_audit = sub.add_parser("audit", help="Audit commands")
    audit_sub = p_audit.add_subparsers(dest="audit_command", required=True)

    p_audit_tail = audit_sub.add_parser("tail")
    p_audit_tail.add_argument("--lines", type=int, default=50)
    p_audit_tail.set_defaults(func=cmd_audit_tail)

    p_daemon = sub.add_parser("daemon", help="Run protector daemon")
    p_daemon.add_argument("--interval", type=int, default=5)
    p_daemon.set_defaults(func=cmd_daemon)

    p_hid = sub.add_parser("hid-monitor", help="Run HID monitor")
    p_hid.set_defaults(func=cmd_hid_monitor)

    # cleanup-expired
    p_cleanup = sub.add_parser("cleanup-expired", help="Remove expired temporary rules")
    p_cleanup.set_defaults(func=cmd_cleanup_expired)

    # backup
    p_backup = sub.add_parser("backup", help="Backup rules.d to tar.gz")
    p_backup.set_defaults(func=cmd_backup)

    # restore
    p_restore = sub.add_parser("restore", help="Restore rules from backup")
    p_restore.add_argument("--name", default=None, help="Backup filename")
    p_restore.set_defaults(func=cmd_restore)

    # import
    p_import = sub.add_parser("import", help="Import rules from JSON")
    p_import.add_argument("--file", required=True, help="JSON file path")
    p_import.add_argument("--force", action="store_true", help="Allow duplicates")
    p_import.set_defaults(func=cmd_import_rules)

    # export
    p_export = sub.add_parser("export", help="Export rules to JSON or YAML")
    p_export.add_argument("--format", choices=["json", "yaml"], default="json")
    p_export.add_argument("--output", default=None, help="Output file path")
    p_export.set_defaults(func=cmd_export_rules)

    # healthcheck
    p_health = sub.add_parser("healthcheck", help="Run pre-flight health checks")
    p_health.add_argument("--ready", action="store_true", help="Exit 0 only if all checks pass")
    p_health.add_argument("--skip-daemon", action="store_true", help="Skip daemon check")
    p_health.set_defaults(func=cmd_healthcheck)

    # check-config
    p_checkcfg = sub.add_parser("check-config", help="Validate configuration")
    p_checkcfg.set_defaults(func=cmd_check_config)

    # approve-tui
    p_approvetui = sub.add_parser("approve-tui", help="Interactive TUI approval with whiptail")
    p_approvetui.set_defaults(func=cmd_approve_tui)

    return parser


# ==============================================================================
# Main entry point
# ==============================================================================
def main():
    parser = build_parser()
    args = parser.parse_args()
    ctx = build_context(args.config)
    args.func(args, ctx)


if __name__ == "__main__":
    main()
