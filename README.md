# USBGuard Protector v3.2

Unified Python CLI + optional Flask web interface for USBGuard policy management, behavioral monitoring, and audit logging.

## Architecture

```
Core (Python)
├── core/models.py          # DeviceRecord, fingerprinting
├── core/config.py          # YAML + legacy config parser
├── core/audit.py           # JSONL audit logger with flock
├── core/policy_store.py    # JSON policy store, atomic writes, backup rotation
├── core/usbguard_client.py # usbguard CLI/IPC wrapper
├── core/rules_renderer.py  # Rule rendering + composite reject generator
└── core/approver.py        # Approve/deny/quarantine/lockdown logic

CLI (Python)
└── cli/main.py             # Unified entrypoint: protector <subcommand>

Detection (Python)
├── detection/hid_monitor.py    # HID behavioral monitor with thread cleanup
├── detection/keystroke_stats.py # EPS, burst, variance, immediate typing
└── detection/responder.py      # Auto-quarantine responder

Web (Optional Flask)
└── web/app.py                  # Decoupled frontend, imports core directly

Config
├── config/protector.yaml       # Main config (paths, composite, identity)
└── config/thresholds.yaml      # HID detection thresholds
```

## Features

- **Unified Python CLI** — single `protector` binary replaces 15+ bash scripts
- **Policy Store** — JSON store with `fcntl.flock` atomic writes, automatic backup rotation (keep 20)
- **Audit Logging** — structured JSONL audit trail with atomic writes
- **Composite Reject Rules** — dynamic BadUSB protection (HID + Mass Storage, HID + CDC)
- **HID Behavioral Monitor** — thread-safe input monitoring with EPS/burst/variance detection
- **Auto-Quarantine** — suspicious devices automatically quarantined via responder pattern
- **Lockdown Mode** — `ImplicitPolicyTarget=block` via unified CLI
- **Learning Mode** — propose-only device scanning with composite detection
- **Optional Flask Web UI** — decoupled from core, direct Python imports
- **Systemd Hardening** — `ProtectSystem=strict`, `NoNewPrivileges`, `LockPersonality`

## Requirements

- Linux (Kernel 4.15+)
- Python 3.8+
- USBGuard 1.1.2+
- systemd 245+
- sudo

## Installation

```bash
sudo bash install.sh
```

Or with Makefile:
```bash
make install
```

## CLI Reference

| Command | Description |
|---------|-------------|
| `protector status` | Show daemon, lockdown, device counts |
| `protector scan` | Sync devices from usbguard into policy store |
| `protector init-policy` | Add composite reject rules at TOP |
| `protector devices list [--state] [--json]` | List tracked devices |
| `protector devices pending` | List pending devices |
| `protector approve <fingerprint> [--permanent] [--ttl] [--actor]` | Approve device |
| `protector deny <fingerprint> [--actor] [--reason]` | Deny device |
| `protector quarantine <fingerprint> [--actor] [--reason]` | Quarantine device |
| `protector lockdown enable` | Set ImplicitPolicyTarget=block |
| `protector lockdown disable` | Keep ImplicitPolicyTarget=block (safe default) |
| `protector learn [--duration] [--actor]` | Propose-only learning scan |
| `protector cleanup-expired` | Remove expired temporary rules |
| `protector backup` | Create rules backup |
| `protector restore` | Restore from backup |
| `protector import --file <path>` | Import rules from JSON |
| `protector export [--format json|yaml]` | Export rules |
| `protector healthcheck` | Pre-flight readiness check |
| `protector hid-monitor` | Run HID behavioral monitor |
| `protector daemon [--interval]` | Run protector daemon |
| `protector audit tail [--lines]` | Tail audit log |

All commands support `--json` output where applicable.

## Configuration

### `config/protector.yaml`

```yaml
usbguard_binary: /usr/bin/usbguard

paths:
  data_dir: /var/lib/usbguard-manager
  config_dir: /etc/usbguard
  log_dir: /var/log/usbguard
  run_dir: /run/usbguard-manager
  policy_store_file: /var/lib/usbguard-manager/policy.json
  backup_dir: /var/lib/usbguard-manager/backups
  audit_file: /var/log/usbguard/audit.jsonl
  lock_file: /run/usbguard-manager/policy.lock

keep_backups: 20

composite:
  reject_hid_mass_storage: true
  reject_hid_cdc: true
```

### `config/thresholds.yaml`

```yaml
eps_threshold: 20.0
burst_chars: 30
low_variance_ms: 15.0
immediate_typing_ms: 700
cooldown_seconds: 10.0
min_events_for_decision: 12
on_unknown_suspicious: alert_only
```

## Directory Structure

```
/opt/usbguard-protector/
├── core/                    # Python core modules
├── cli/                     # CLI entrypoint
├── detection/               # HID monitor modules
├── venv/                    # Python virtual environment

/etc/usbguard/
├── protector.yaml           # Main config
├── thresholds.yaml          # Detection thresholds
├── approval-manager.conf    # Legacy config (backward compatible)
├── rules.d/
│   ├── 00-system.rules      # System rules + composite rejects
│   ├── 50-permanent.rules   # Permanent approvals
│   └── 90-temporary.rules   # Temporary approvals with TTL
└── scripts/
    ├── detect-host-input.sh # udev host input detection
    └── usb-mass-storage-handler.sh  # udev mass storage handler

/var/lib/usbguard-manager/
├── policy.json              # Device policy store
└── backups/                 # Automatic backup rotation

/var/log/usbguard/
├── audit.jsonl              # Structured audit log
└── usbguard-approval.log    # Legacy log

/run/usbguard-manager/
└── policy.lock              # Atomic lock file
```

## Systemd Services

| Service | Description |
|---------|-------------|
| `usbguard-protector.service` | Unified daemon (sync + expire loop) |
| `usbguard-behavioral.service` | HID behavioral monitor |
| `usbguard-ttl-reaper.timer` | Cleanup expired temporary rules (every 5min) |
| `usbguard-web.service` | Optional Flask web interface |

## Sudoers

`usbadmins` group members can run the unified CLI without password:

```
Cmnd_Alias USBGUARD_PROTECTOR=/usr/local/bin/protector
%usbadmins ALL=(root) NOPASSWD: USBGUARD_PROTECTOR
```

## Migration Notes

- **Fresh install recommended** — no production deployments to migrate
- Existing `00-system.rules` composite rejects are preserved
- Existing `approval-manager.conf` settings are read as fallback
- Python policy store is created fresh at `/var/lib/usbguard-manager/policy.json`

## Removed Components

- Flask API routes replaced by direct Python core imports
- nftables network lockdown removed (use `protector lockdown enable` instead)
- 15+ bash scripts replaced by unified `protector` CLI
- `badusb-monitor.py` replaced by `detection/hid_monitor.py`

## License

MIT
