#!/usr/bin/env python3
# ═══════════════════════════════════════════════════════════════════════════════
# USBGuard Approval Manager - Flask Backend (usbguard-python + subprocess)
# Version: 3.1 (Unified QA-hardened, thread-safe, config-driven)
# ═══════════════════════════════════════════════════════════════════════════════

import os
import subprocess
import re
import json
import tempfile
import logging
import sys
import secrets
import hmac
import threading
from pathlib import Path
from types import SimpleNamespace
from typing import Any, Dict, List, Optional, Tuple

from flask import Flask, render_template, jsonify, request, session
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'core'))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'cli'))

from core.config import Config
from core.policy_store import PolicyStore
from core.audit import AuditLogger
from core.usbguard_client import USBGuardClient
from core.approver import Approver
from core.rules_renderer import render_allow, render_reject, composite_reject_rules

# ─── usbguard-python: Load with Fallback ──────────────────────────────────────
try:
    import usbguard
    from usbguard import DeviceManager, Rule
    USBGUARD_PYTHON_AVAILABLE = True
    logging.getLogger(__name__).info("usbguard-python loaded successfully (IPC mode)")
except ImportError:
    USBGUARD_PYTHON_AVAILABLE = False
    logging.getLogger(__name__).warning(
        "usbguard-python not available. Falling back to subprocess for device listing."
    )
    DeviceManager = None
    Rule = None

# ═══════════════════════════════════════════════════════════════════════════════
# Application Setup
# ═══════════════════════════════════════════════════════════════════════════════

DEBUG_MODE = os.environ.get('FLASK_DEBUG', 'False').lower() == 'true'
IS_PRODUCTION = not DEBUG_MODE

log_level = logging.DEBUG if DEBUG_MODE else logging.INFO

logging.basicConfig(
    level=log_level,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[logging.StreamHandler()]
)
logger = logging.getLogger(__name__)


def setup_file_logging(log_file: str = '/var/log/usbguard-web.log') -> bool:
    """Attach web log file when daemon has write permission."""
    for handler in logger.handlers:
        if isinstance(handler, logging.FileHandler) and getattr(handler, 'baseFilename', None) == log_file:
            return True
    try:
        file_handler = logging.FileHandler(log_file)
    except PermissionError:
        logger.warning(f"Cannot write to web log file: {log_file}")
        return False
    file_handler.setFormatter(logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s'))
    logger.addHandler(file_handler)
    return True

setup_file_logging()

app = Flask(__name__)
app.secret_key = os.environ.get('FLASK_SECRET_KEY', secrets.token_hex(32))

# Rate Limiter
if DEBUG_MODE:
    limiter = Limiter(app=app, key_func=get_remote_address, enabled=False)
    logger.warning("⚠️ RUNNING IN DEBUG MODE - Rate limiting DISABLED")
else:
    limiter = Limiter(
        app=app,
        key_func=get_remote_address,
        default_limits=["200 per day", "50 per hour"]
    )
    logger.info("✅ Production mode - Rate limiting ENABLED")

# Paths (overridden at runtime by config via get_core_context)
LOG_FILE: str = "/var/log/usbguard-approval.log"
RULES_DIR: str = "/etc/usbguard/rules.d"
STATIC_DIR: str = os.path.join(os.path.dirname(__file__), "static")


# ═══════════════════════════════════════════════════════════════════════════════
# CSRF Protection (Double-Submit Cookie + Constant-Time Comparison)
# ═══════════════════════════════════════════════════════════════════════════════

def _get_csrf_token() -> str:
    if 'csrf_token' not in session:
        session['csrf_token'] = secrets.token_hex(32)
    return session['csrf_token']


@app.after_request
def _set_csrf_cookie(response):
    """Set CSRF token cookie on every response for double-submit pattern."""
    response.set_cookie('XSRF-TOKEN', _get_csrf_token(),
                        httponly=False, samesite='Lax', secure=False)
    return response


def _validate_csrf() -> bool:
    """Validate CSRF token using double-submit cookie + constant-time comparison."""
    header_token = request.headers.get('X-CSRFToken') or (request.json or {}).get('csrf_token')
    cookie_token = request.cookies.get('XSRF-TOKEN')
    token = header_token or cookie_token
    expected = session.get('csrf_token')
    if not token or not expected:
        return False
    return hmac.compare_digest(token, expected)


def csrf_protect(f):
    """Decorator: require valid CSRF token for state-changing methods."""
    def wrapper(*args, **kwargs):
        if request.method in ('POST', 'PUT', 'DELETE', 'PATCH'):
            if not _validate_csrf():
                return jsonify({"error": "CSRF token missing or invalid"}), 403
        return f(*args, **kwargs)
    wrapper.__name__ = f.__name__
    return wrapper


# ═══════════════════════════════════════════════════════════════════════════════
# Core Context (Thread-Safe Singleton with Lock)
# ═══════════════════════════════════════════════════════════════════════════════

_core_ctx: Optional[SimpleNamespace] = None
_core_ctx_lock = threading.Lock()


def get_core_context() -> SimpleNamespace:
    """Get or create core context singleton (thread-safe with double-checked locking)."""
    global _core_ctx, LOG_FILE, RULES_DIR
    if _core_ctx is None:
        with _core_ctx_lock:
            if _core_ctx is None:
                config = Config.load()
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
                # Use resolved config paths instead of hardcoded defaults
                LOG_FILE = config.audit_file
                RULES_DIR = str(Path(config.config_dir) / "rules.d")
                _core_ctx = SimpleNamespace(
                    config=config, store=store, audit=audit, client=client, approver=approver
                )
    return _core_ctx


def find_device_by_numeric_id(client: USBGuardClient, device_id: int) -> Optional[Dict[str, Any]]:
    """Find a DeviceRecord by its numeric usbguard device ID."""
    try:
        devices = client.list_devices()
        for d in devices:
            if d.observed_rule_id == device_id:
                return d.to_dict()
    except Exception:
        pass
    return None


# ═══════════════════════════════════════════════════════════════════════════════
# usbguard-python Helpers
# ═══════════════════════════════════════════════════════════════════════════════

def get_usbguard_bus():
    """
    Create a USBGuard DeviceManager IPC connection.
    Returns None if usbguard-python is unavailable or connection fails.
    """
    if not USBGUARD_PYTHON_AVAILABLE:
        return None
    try:
        bus = DeviceManager()
        bus.getDevices()  # Probe once to verify connection
        return bus
    except Exception as e:
        logger.warning(f"usbguard-python IPC connection failed: {e}")
        return None


def parse_device_from_ipc(device):
    """
    Convert a usbguard.Device object to a dictionary matching the API format.
    """
    try:
        dev_id = str(device.getID()) if hasattr(device, 'getID') else str(device.id)

        try:
            target = device.getTarget()
            status = target.name.lower() if hasattr(target, 'name') else str(target).lower()
        except Exception:
            status = "unknown"

        vid_pid = ""
        try:
            rule = device.getRule()
            if rule:
                vid_pid = f"{rule.getVendorID() or '0000'}:{rule.getProductID() or '0000'}"
        except Exception:
            pass

        name = "Unknown Device"
        serial = "N/A"
        try:
            attrs = device.getDeviceDescriptor()
            if attrs:
                name = attrs.get('name', name) or name
                serial = attrs.get('serial', serial) or serial
        except Exception:
            pass

        rule_str = ""
        try:
            rule = device.getRule()
            if rule:
                rule_str = str(rule)
        except Exception:
            pass

        if rule_str:
            m = re.search(r'name "([^"]*)"', rule_str)
            if m:
                name = m.group(1).strip()
            m = re.search(r'serial "([^"]*)"', rule_str)
            if m:
                serial = m.group(1)

        return {
            "device_id": dev_id,
            "status": status,
            "id": vid_pid,
            "serial": serial,
            "name": name,
            "port": "N/A",
            "hash": "N/A",
            "parent_hash": "N/A",
            "interfaces": "N/A",
            "connect_type": "N/A",
            "raw": str(device)
        }
    except Exception as e:
        logger.debug(f"IPC device parse error: {e}")
        return None


# ═══════════════════════════════════════════════════════════════════════════════
# Subprocess Fallback (Legacy)
# ═══════════════════════════════════════════════════════════════════════════════

def run_command(cmd: list, shell: bool = False) -> Tuple[str, str, int]:
    """
    Execute system commands with intelligent error reporting.
    - If running as root, sudo is stripped since it's redundant.
    - DEBUG mode: Full error details returned to client.
    - Production: Generic errors only, details in logs.
    """
    if isinstance(cmd, list) and cmd and cmd[0] == "sudo":
        if hasattr(os, 'geteuid') and os.geteuid() == 0:
            cmd = cmd[1:]
        else:
            logger.warning(f"Command requested sudo but not running as root: {' '.join(cmd)}")

    try:
        res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             text=True, shell=shell, timeout=15)

        if res.returncode != 0 and res.stderr:
            logger.error(f"Command failed: {' '.join(cmd) if isinstance(cmd, list) else cmd} | Error: {res.stderr.strip()}")
        elif res.returncode == 0 and res.stdout and DEBUG_MODE:
            logger.debug(f"Command succeeded: {' '.join(cmd) if isinstance(cmd, list) else cmd}")

        if res.returncode != 0:
            if DEBUG_MODE:
                return res.stdout, res.stderr, res.returncode
            return res.stdout, "Operation failed. Check server logs for details.", res.returncode
        return res.stdout, "", res.returncode

    except subprocess.TimeoutExpired:
        logger.error(f"Command timed out: {' '.join(cmd) if isinstance(cmd, list) else cmd}")
        err_msg = "Command timed out" if DEBUG_MODE else "Operation timed out"
        return "", err_msg, -1
    except Exception as e:
        logger.exception(f"Unexpected error running command: {' '.join(cmd) if isinstance(cmd, list) else cmd}")
        err_msg = str(e) if DEBUG_MODE else "Internal server error"
        return "", err_msg, -1


def parse_lsusb_verbose(output: str) -> Dict[str, Any]:
    """Parse 'lsusb -v -d VID:PID' output into structured JSON."""
    result: Dict[str, Any] = {
        "device": {},
        "configuration": None,
        "interfaces": [],
        "endpoints": [],
        "status": "",
        "raw": output
    }

    if not output.strip():
        return result

    lines = output.split('\n')
    current_section: Optional[str] = None
    current_interface: Optional[Dict] = None
    current_endpoint: Optional[Dict] = None
    interface_count = -1
    endpoint_count = -1

    for line in lines:
        stripped = line.strip()
        lower = stripped.lower()

        if 'device descriptor:' in lower:
            current_section = 'device'
            continue
        elif 'configuration descriptor:' in lower:
            current_section = 'config'
            continue
        elif 'interface descriptor:' in lower:
            current_section = 'interface'
            interface_count += 1
            current_interface = {"index": interface_count, "descriptors": {}}
            result["interfaces"].append(current_interface)
            continue
        elif 'endpoint descriptor:' in lower:
            current_section = 'endpoint'
            endpoint_count += 1
            current_endpoint = {"index": endpoint_count, "descriptors": {}}
            result["endpoints"].append(current_endpoint)
            continue
        elif 'device qualifier' in lower:
            current_section = 'qualifier'
            continue
        elif 'device status:' in lower:
            current_section = 'status'
            if ':' in stripped:
                result["status"] = stripped.split(':', 1)[1].strip()
            continue
        elif 'bus powered' in lower or 'self powered' in lower:
            if current_section == 'config':
                if result.get("configuration") is None:
                    result["configuration"] = {}
                result["configuration"]["power_type"] = stripped.strip('()')
            continue

        if ':' in stripped and not stripped.startswith('('):
            key, _, val = stripped.partition(':')
            key = key.strip()
            val = val.strip()

            if current_section == 'device':
                result["device"][key] = val
            elif current_section == 'config':
                if result.get("configuration") is None:
                    result["configuration"] = {}
                result["configuration"][key] = val
            elif current_section == 'interface' and current_interface is not None:
                current_interface["descriptors"][key] = val
            elif current_section == 'endpoint' and current_endpoint is not None:
                current_endpoint["descriptors"][key] = val

    if lines:
        m = re.search(r'Bus (\d+) Device (\d+): ID ([0-9a-fA-F]{4}:[0-9a-fA-F]{4})\s*(.*)', lines[0])
        if m:
            result["bus_info"] = {
                "bus": m.group(1),
                "device": m.group(2),
                "id": m.group(3),
                "description": m.group(4).strip()
            }

    return result


def get_fingerprint_from_lsusb(output: str) -> Dict[str, Any]:
    """Extract a stable fingerprint from lsusb -v output."""
    parsed = parse_lsusb_verbose(output)
    dev = parsed.get("device", {})

    fingerprint: Dict[str, Any] = {
        "idVendor": dev.get("idVendor", ""),
        "idProduct": dev.get("idProduct", ""),
        "iManufacturer": dev.get("iManufacturer", ""),
        "iProduct": dev.get("iProduct", ""),
        "iSerial": dev.get("iSerial", ""),
        "bcdUSB": dev.get("bcdUSB", ""),
        "bDeviceClass": dev.get("bDeviceClass", "").split()[0] if dev.get("bDeviceClass") else "",
    }

    if parsed.get("interfaces"):
        interface_classes = []
        for iface in parsed["interfaces"]:
            desc = iface.get("descriptors", {})
            interface_classes.append({
                "class": desc.get("bInterfaceClass", "").split()[0] if desc.get("bInterfaceClass") else "",
                "subclass": desc.get("bInterfaceSubClass", "").split()[0] if desc.get("bInterfaceSubClass") else "",
                "protocol": desc.get("bInterfaceProtocol", "").split()[0] if desc.get("bInterfaceProtocol") else "",
            })
        fingerprint["interfaces"] = interface_classes

    return fingerprint


# ═══════════════════════════════════════════════════════════════════════════════
# API Routes
# ═══════════════════════════════════════════════════════════════════════════════

@app.route('/')
def index():
    return render_template('index.html')


@app.route('/api/status', methods=['GET'])
def get_status():
    """Retrieve systemd service status for usbguard and the reaper timer."""
    _, _, rc_daemon = run_command(["systemctl", "is-active", "--quiet", "usbguard"])
    _, _, rc_timer = run_command(["systemctl", "is-active", "--quiet", "usbguard-ttl-reaper.timer"])

    ctx = get_core_context()
    devices = ctx.store.list_devices()
    rules_count = len([d for d in devices if d.state in ("approved-permanent", "approved-temporary")])

    return jsonify({
        "daemon_active": (rc_daemon == 0),
        "timer_active": (rc_timer == 0),
        "active_rules_count": rules_count
    })


@app.route('/api/devices', methods=['GET'])
def get_devices():
    """
    Retrieve list of USB devices via usbguard-python IPC (fast path)
    with automatic fallback to subprocess (legacy).
    """
    devices: List[Dict] = []

    # Fast Path: usbguard-python IPC
    bus = get_usbguard_bus()
    if bus is not None:
        try:
            ipc_devices = bus.getDevices()
            for device in ipc_devices:
                parsed = parse_device_from_ipc(device)
                if parsed:
                    devices.append(parsed)
            if devices:
                logger.debug(f"IPC: Retrieved {len(devices)} device(s) via usbguard-python")
                return jsonify(devices)
        except Exception as e:
            logger.warning(f"IPC device listing failed, falling back to subprocess: {e}")

    # Fallback: subprocess
    stdout, stderr, rc = run_command(["usbguard", "list-devices"])
    if rc != 0:
        error_msg = stderr if DEBUG_MODE else "Failed to communicate with USBGuard daemon"
        logger.error(f"Failed to list devices: {stderr}")
        return jsonify({"error": error_msg}), 500

    for line in stdout.strip().split('\n'):
        if not line:
            continue
        parts = line.split(' ', 2)
        if len(parts) < 2:
            continue

        dev_id = parts[0].replace(':', '')
        status = parts[1]

        vid_pid = _extract_re(r'id ([0-9a-fA-F]{4}:[0-9a-fA-F]{4})', line, "")
        serial = _extract_re(r'serial "([^"]*)"', line, "N/A")
        name = _extract_re(r'name "([^"]*)"', line, "Unknown Device")
        port = _extract_re(r'via-port (\S+)', line, "N/A")
        dev_hash = _extract_re(r'hash "([^"]*)"', line, "N/A")
        parent_hash = _extract_re(r'parent-hash "([^"]*)"', line, "N/A")

        interfaces = "N/A"
        m = re.search(r'with-interface \{([^}]+)\}', line)
        if m:
            interfaces = m.group(1).strip()
        else:
            m = re.search(r'with-interface (\S+)', line)
            if m:
                interfaces = m.group(1)

        connect_type = _extract_re(r'with-connect-type "([^"]*)"', line, "N/A")

        devices.append({
            "device_id": dev_id, "status": status, "id": vid_pid,
            "serial": serial, "name": name, "port": port,
            "hash": dev_hash, "parent_hash": parent_hash,
            "interfaces": interfaces, "connect_type": connect_type, "raw": line
        })

    logger.debug(f"Subprocess: Retrieved {len(devices)} device(s)")
    return jsonify(devices)


def _extract_re(pattern: str, text: str, default: str = "") -> str:
    m = re.search(pattern, text)
    return m.group(1) if m else default


@app.route('/api/device-detail', methods=['GET'])
@limiter.limit("20 per minute")
def get_device_detail():
    """
    Run 'lsusb -v -d VID:PID' to fetch verbose USB device details.
    Returns parsed JSON including manufacturer, serial, interface classes, etc.
    """
    vid_pid = request.args.get('id', '')

    if not vid_pid:
        stdout, stderr, rc = run_command(["lsusb"])
        if rc != 0:
            return jsonify({"error": stderr if DEBUG_MODE else "Failed to list USB devices"}), 500
        devices_raw = []
        for line in stdout.strip().split('\n'):
            m = re.search(r'ID\s+([0-9a-fA-F]{4}:[0-9a-fA-F]{4})\s+(.+)', line)
            if m:
                devices_raw.append({"id": m.group(1), "desc": m.group(2).strip()})
        return jsonify({"devices": devices_raw})

    if not re.match(r'^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$', vid_pid):
        return jsonify({"error": "Invalid VID:PID format"}), 400

    stdout, stderr, rc = run_command(["lsusb", "-v", "-d", vid_pid])
    if rc != 0:
        error_msg = stderr if DEBUG_MODE else "Failed to read device details"
        logger.error(f"lsusb -v failed for {vid_pid}: {stderr}")
        return jsonify({"error": error_msg, "note": "Device may not be connected"}), 500

    parsed = parse_lsusb_verbose(stdout)
    fingerprint = get_fingerprint_from_lsusb(stdout)

    return jsonify({
        "vid_pid": vid_pid,
        "parsed": parsed,
        "fingerprint": fingerprint
    })


@app.route('/api/verify-fingerprint', methods=['POST'])
@limiter.limit("10 per minute")
@csrf_protect
def verify_fingerprint():
    """
    Verify a device's current fingerprint against a stored fingerprint.
    Returns match percentage and any mismatches.
    """
    data = request.json or {}
    vid_pid = data.get("vid_pid", "")

    if not vid_pid or not re.match(r'^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$', vid_pid):
        return jsonify({"error": "Invalid VID:PID"}), 400

    stored_fp = data.get("stored_fingerprint", {})

    stdout, stderr, rc = run_command(["lsusb", "-v", "-d", vid_pid])
    if rc != 0:
        error_msg = stderr if DEBUG_MODE else "Cannot read device. Is it still connected?"
        logger.error(f"Cannot read device for verification: {stderr}")
        return jsonify({"error": error_msg}), 500

    current_fp = get_fingerprint_from_lsusb(stdout)

    if not stored_fp:
        return jsonify({
            "has_stored": False,
            "current_fingerprint": current_fp,
            "message": "No stored fingerprint found. This device has not been fingerprinted yet."
        })

    mismatches = []
    matches = 0
    total_fields = 0

    scalar_fields = ["idVendor", "idProduct", "iManufacturer", "iProduct", "iSerial", "bcdUSB", "bDeviceClass"]
    for field in scalar_fields:
        stored_val = stored_fp.get(field, "")
        current_val = current_fp.get(field, "")
        if stored_val and current_val:
            total_fields += 1
            if stored_val == current_val:
                matches += 1
            else:
                mismatches.append({
                    "field": field,
                    "stored": stored_val,
                    "current": current_val,
                    "severity": "high" if field in ["iSerial", "bDeviceClass"] else "medium"
                })

    stored_interfaces = stored_fp.get("interfaces", [])
    current_interfaces = current_fp.get("interfaces", [])

    if stored_interfaces and current_interfaces:
        for i, (s_iface, c_iface) in enumerate(zip(stored_interfaces, current_interfaces)):
            for key in ["class", "subclass", "protocol"]:
                s_val = s_iface.get(key, "")
                c_val = c_iface.get(key, "")
                if s_val and c_val:
                    total_fields += 1
                    if s_val == c_val:
                        matches += 1
                    else:
                        mismatches.append({
                            "field": f"interface[{i}].bInterface{key.capitalize()}",
                            "stored": s_val,
                            "current": c_val,
                            "severity": "critical" if key == "class" else "high"
                        })

    match_pct = round((matches / total_fields * 100)) if total_fields > 0 else 0

    return jsonify({
        "has_stored": True,
        "current_fingerprint": current_fp,
        "matches": matches,
        "total_fields": total_fields,
        "match_percentage": match_pct,
        "mismatches": mismatches,
        "verdict": "TRUSTED" if match_pct >= 80 and len(mismatches) == 0 else (
            "SUSPICIOUS" if match_pct >= 50 else "DANGEROUS"
        ),
        "message": _get_verdict_message(match_pct, mismatches)
    })


def _get_verdict_message(match_pct: int, mismatches: List[Dict]) -> str:
    if match_pct >= 80 and len(mismatches) == 0:
        return "✅ Device identity confirmed. All fingerprints match."
    elif match_pct >= 80 and len(mismatches) > 0:
        severe = [m for m in mismatches if m.get("severity") in ("critical", "high")]
        if severe:
            return f"⚠️ Mostly matches ({match_pct}%), but {len(severe)} critical field(s) differ. Verify before trusting."
        return f"✅ Mostly matches ({match_pct}%). Minor variations detected."
    elif match_pct >= 50:
        return f"⚠️ Suspicious ({match_pct}% match). Device may be spoofed."
    else:
        return f"🚨 DANGEROUS ({match_pct}% match). Device fingerprint does NOT match stored profile!"


@app.route('/api/rules', methods=['GET'])
def get_rules():
    """Retrieve all parsed active rules from usbguard daemon."""
    ctx = get_core_context()
    try:
        rules = ctx.client.list_rules()
    except Exception as e:
        logger.error(f"Failed to get rules: {e}")
        return jsonify([])

    result = []
    for rule in rules:
        if rule.observed_target not in ("allow", "block", "reject"):
            continue
        interfaces = " ".join(rule.interfaces) if rule.interfaces else "N/A"
        result.append({
            "rule": rule.raw_spec or "",
            "filename": "active",
            "category": "active",
            "id": rule.vid_pid or "",
            "name": rule.name or "Unknown Device",
            "serial": rule.serial or "N/A",
            "hash": rule.hash or "N/A",
            "interfaces": interfaces,
            "ttl_epoch": None,
            "fingerprint": None
        })

    return jsonify(result)


@app.route('/api/approve', methods=['POST'])
@limiter.limit("5 per minute")
@csrf_protect
def approve_device():
    """Approve a selected blocked device via core approver, with optional fingerprint."""
    data = request.json or {}
    device_id = data.get("device_id")
    approval_type = data.get("type", "T")
    ttl = data.get("ttl", 3600)

    if not device_id or not str(device_id).isdigit():
        return jsonify({"error": "Invalid device ID"}), 400
    device_id_int = int(device_id)
    if device_id_int < 0 or device_id_int > 99999:
        return jsonify({"error": "Device ID out of range"}), 400
    if approval_type not in ["P", "T"]:
        return jsonify({"error": "Invalid approval type. Must be P or T."}), 400

    ctx = get_core_context()
    try:
        devices = ctx.client.list_devices()
        target = None
        for d in devices:
            if d.observed_rule_id == device_id_int:
                target = d
                break
        if not target:
            return jsonify({"error": f"Device {device_id} not found in usbguard"}), 404

        approved = ctx.approver.approve(
            fingerprint=target.fingerprint,
            permanent=(approval_type == "P"),
            ttl=int(ttl),
            actor="web",
            port_bind=False,
        )
        logger.info(f"Device {device_id} approved as {approval_type}")
        return jsonify({
            "success": True,
            "message": f"Successfully approved device {device_id} ({'Permanent' if approval_type == 'P' else 'Temporary'})",
            "output": approved.to_dict() if DEBUG_MODE else None
        })
    except Exception as e:
        error_msg = str(e) if DEBUG_MODE else "Failed to approve device. Check logs."
        logger.error(f"Failed to approve device {device_id}: {e}")
        return jsonify({"success": False, "error": error_msg}), 500


ALLOWED_FP_KEYS = {'idVendor', 'idProduct', 'iManufacturer', 'iProduct',
                   'iSerial', 'bcdUSB', 'bDeviceClass', 'interfaces'}


def _sanitize_fingerprint(fp):
    if not isinstance(fp, dict):
        return None
    return {k: v for k, v in fp.items() if k in ALLOWED_FP_KEYS}


def _append_fingerprint_to_rule(device_id: str, fingerprint: dict) -> bool:
    """Append a fingerprint comment to the rule file atomically and safely."""
    fingerprint = _sanitize_fingerprint(fingerprint)
    if not fingerprint:
        return False
    vendor = fingerprint.get('idVendor', '').replace('0x', '').strip()
    product = fingerprint.get('idProduct', '').replace('0x', '').strip()
    rule_vid_pid = f"{vendor}:{product}"

    for filename in sorted(os.listdir(RULES_DIR)):
        if not filename.endswith('.rules'):
            continue
        filepath = os.path.join(RULES_DIR, filename)
        try:
            with open(filepath, 'r') as f:
                lines = f.readlines()

            modified = False
            for i, line in enumerate(lines):
                if re.search(rf'\ballow\s+id\s+{re.escape(rule_vid_pid)}\b', line):
                    fp_comment = f"# fingerprint: {json.dumps(fingerprint)}\n"
                    lines.insert(i + 1, fp_comment)
                    modified = True
                    break

            if modified:
                dir_name = os.path.dirname(filepath)
                fd, tmp_path = tempfile.mkstemp(dir=dir_name, prefix='.tmp_rule_')
                try:
                    with os.fdopen(fd, 'w') as f:
                        f.writelines(lines)
                    os.chmod(tmp_path, 0o600)
                    try:
                        os.chown(tmp_path, 0, 0)
                    except (AttributeError, PermissionError, OSError):
                        pass
                    os.replace(tmp_path, filepath)
                    logger.info(f"Added fingerprint to rule for {rule_vid_pid}")
                    return True
                except Exception as e:
                    logger.error(f"Failed to write fingerprint: {e}")
                    if os.path.exists(tmp_path):
                        os.remove(tmp_path)
                    return False
        except Exception as e:
            logger.error(f"Failed to process {filename}: {e}")

    return False


@app.route('/api/block', methods=['POST'])
@limiter.limit("5 per minute")
@csrf_protect
def block_device():
    """Block a device immediately and remove its rules file persistence."""
    data = request.json or {}
    device_id = data.get("device_id")
    vid_pid = data.get("vid_pid")

    if not device_id and not vid_pid:
        return jsonify({"error": "Device ID or VID:PID is required"}), 400

    ctx = get_core_context()
    try:
        if device_id:
            devices = ctx.client.list_devices()
            target = None
            for d in devices:
                if d.observed_rule_id == int(device_id):
                    target = d
                    break
            if not target:
                return jsonify({"error": f"Device {device_id} not found"}), 404
            ctx.approver.deny(target.fingerprint, actor="web", reason="blocked via web")
        else:
            ctx.approver.deny(vid_pid, actor="web", reason="blocked via web")
        logger.info(f"Blocked device: {vid_pid or device_id}")
        return jsonify({
            "success": True,
            "message": f"Successfully blocked device {vid_pid or 'ID: ' + str(device_id)}"
        })
    except Exception as e:
        error_msg = str(e) if DEBUG_MODE else "Failed to block device. Check logs."
        logger.error(f"Failed to block device {vid_pid or device_id}: {e}")
        return jsonify({"success": False, "error": error_msg}), 500


@app.route('/api/change-status', methods=['POST'])
@limiter.limit("5 per minute")
@csrf_protect
def change_status():
    """Change approval status (e.g. from permanent to temporary, or update TTL)."""
    data = request.json or {}
    device_id = data.get("device_id")
    vid_pid = data.get("vid_pid")
    new_type = data.get("type")
    ttl = data.get("ttl", 3600)

    if not vid_pid:
        return jsonify({"error": "VID:PID is required"}), 400
    if new_type not in ["P", "T"]:
        return jsonify({"error": "Invalid approval type. Must be P or T."}), 400

    ctx = get_core_context()
    try:
        existing = ctx.store.get_device_by_any(vid_pid)
        if not existing:
            return jsonify({"error": "Device not found in policy store"}), 404

        if existing.state.startswith("approved"):
            ctx.approver.deny(existing.fingerprint, actor="web", reason="status change")

        if device_id:
            device = ctx.approver.approve(
                fingerprint=existing.fingerprint,
                permanent=(new_type == "P"),
                ttl=int(ttl),
                actor="web",
                port_bind=False,
            )
            logger.info(f"Changed status for {vid_pid} to {new_type}")
            return jsonify({
                "success": True,
                "message": f"Successfully changed status of device {vid_pid} to {'Permanent' if new_type == 'P' else 'Temporary'}"
            })
        else:
            return jsonify({
                "success": False,
                "error": "Device must be connected to apply status changes (rule recreation requires hardware signature scanning)."
            }), 400
    except Exception as e:
        error_msg = str(e) if DEBUG_MODE else "Failed to rewrite rule. Check logs."
        logger.error(f"Failed to change status for {vid_pid}: {e}")
        return jsonify({"success": False, "error": error_msg}), 500


@app.route('/api/logs', methods=['GET'])
def get_logs():
    """Fetch the latest 50 lines from the audit log."""
    if not os.path.exists(LOG_FILE):
        return jsonify({"logs": ["No logs available yet."]})

    try:
        with open(LOG_FILE, 'r') as file:
            lines = file.readlines()
            last_lines = [line.strip() for line in lines[-50:]]
            return jsonify({"logs": last_lines})
    except Exception as e:
        logger.error(f"Failed to read logs: {e}")
        if DEBUG_MODE:
            return jsonify({"error": f"Failed to read logs: {str(e)}"}), 500
        return jsonify({"error": "Failed to read logs"}), 500


# ═══════════════════════════════════════════════════════════════════════════════
# Entry Point
# ═══════════════════════════════════════════════════════════════════════════════

if __name__ == '__main__':
    print("=" * 60)
    if DEBUG_MODE:
        print("🔧 RUNNING IN DEBUG MODE - Full error details will be exposed")
        print("⚠️  DO NOT use this in production!")
    else:
        print("🔒 RUNNING IN PRODUCTION MODE - Errors are sanitized")
        print("✅ Detailed errors are written to /var/log/usbguard-web.log")

    if USBGUARD_PYTHON_AVAILABLE:
        print("✅ usbguard-python: AVAILABLE (IPC mode)")
    else:
        print("⚠️  usbguard-python: NOT AVAILABLE (subprocess fallback)")

    print("=" * 60)
    print(f"📍 Server running on: http://127.0.0.1:5000")
    print("=" * 60)

    app.run(
        host='127.0.0.1',
        port=5000,
        debug=DEBUG_MODE
    )