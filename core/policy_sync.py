from __future__ import annotations
import os
import re
import subprocess
import tempfile
from pathlib import Path
from typing import List, Optional

from .usbguard_client import USBGuardClient
from .validators import validate_rule_file

_TTL_RE = re.compile(r"#\s*ttl_epoch:\s*(\d+)", re.IGNORECASE)


def sanitize_rule(line: str) -> str:
    line = _remove_dynamic_fields(line)
    line = re.sub(r"[ \t]+", " ", line)
    line = line.strip()
    return line


def _remove_dynamic_fields(line: str) -> str:
    line = re.sub(r"[ \t]+parent-hash[ \t]+\"[^\"]*\"", "", line)
    line = re.sub(r"[ \t]+with-connect-type[ \t]+(\"[^\"]*\"|[^ \t]+)", "", line)
    return line


def device_signature(rule: str) -> str:
    vid_pid = _search(r"id[ \t]+([0-9a-fA-F]{4}:[0-9a-fA-F]{4})", rule)
    iface = _search(r"with-interface[ \t]+([0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2})", rule)
    if vid_pid and iface:
        return f"id {vid_pid} with-interface {iface}"
    return sanitize_rule(rule)


def rule_signature(rule: str) -> str:
    sig = device_signature(rule)
    if sig.startswith("id "):
        return f"allow {sig}"
    return sanitize_rule(rule)


def normalize_active_rules(client: Optional[USBGuardClient] = None, binary: str = "/usr/bin/usbguard") -> List[str]:
    if client is None:
        client = USBGuardClient(binary)
    proc = client._run(["list-rules"], check=False)
    out = []
    for line in proc.stdout.splitlines():
        line = re.sub(r"^\s*\d+:\s*", "", line)
        if not line.strip():
            continue
        out.append(rule_signature(line))
    return out


def rules_dir(config_dir: str = "/etc/usbguard") -> str:
    return str(Path(config_dir) / "rules.d")


def required_rules() -> List[str]:
    return ["00-system.rules", "50-permanent.rules", "90-temporary.rules"]


def validate_rules_dir(rules_dir_path: str) -> bool:
    p = Path(rules_dir_path)
    if not p.is_dir():
        return False
    for rf in required_rules():
        if not (p / rf).is_file():
            return False
    return True


def build_policy_file(rules_dir_path: str, rules_file: str, client: Optional[USBGuardClient] = None) -> bool:
    import tempfile

    if not validate_rules_dir(rules_dir_path):
        return False

    tmp = None
    try:
        fd, tmp_path = tempfile.mkstemp(prefix="usbguard_policy_sync_", suffix=".tmp")
        os.close(fd)
        tmp = Path(tmp_path)
        tmp.write_text("", encoding="utf-8")

        p = Path(rules_dir_path)
        for rf in required_rules():
            fpath = p / rf
            if not fpath.is_file() or fpath.stat().st_size == 0:
                continue
            with open(tmp, "a", encoding="utf-8") as fh:
                fh.write(f"\n# BEGIN {rf}\n")
            for line in fpath.read_text(encoding="utf-8", errors="replace").splitlines():
                if not line.strip():
                    continue
                with open(tmp, "a", encoding="utf-8") as fh:
                    fh.write(sanitize_rule(line) + "\n")
            with open(tmp, "a", encoding="utf-8") as fh:
                fh.write(f"# END {rf}\n")

        errors = validate_rule_file(str(tmp))
        if errors:
            tmp.unlink(missing_ok=True)
            return False

        Path(rules_file).parent.mkdir(parents=True, exist_ok=True)
        tmp.replace(rules_file)
        Path(rules_file).chmod(0o600)
        try:
            os.chown(str(rules_file), 0, 0)
        except (AttributeError, PermissionError, OSError):
            pass
        return True
    except Exception:
        if tmp and tmp.exists():
            tmp.unlink(missing_ok=True)
        return False


def verify_active(rules_file: str, client: Optional[USBGuardClient] = None) -> bool:
    p = Path(rules_file)
    if not p.is_file():
        return False
    active = set(normalize_active_rules(client))
    if not active:
        return False
    for line in p.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        sig = rule_signature(line)
        if not sig or sig not in active:
            return False
    return True


def reload_daemon(rules_dir_path: str, rules_file: str, client: Optional[USBGuardClient] = None) -> bool:
    if not build_policy_file(rules_dir_path, rules_file, client):
        return False

    try:
        subprocess.run(["systemctl", "reload", "usbguard"], check=False, capture_output=True, timeout=60)
    except Exception:
        pass

    try:
        subprocess.run(["systemctl", "restart", "usbguard"], check=False, capture_output=True, timeout=60)
    except Exception:
        pass

    try:
        subprocess.run(["pkill", "-HUP", "usbguard-daemon"], check=False, capture_output=True, timeout=10)
    except Exception:
        pass

    for _ in range(30):
        try:
            r = subprocess.run(["systemctl", "is-active", "--quiet", "usbguard"], capture_output=True, timeout=5)
            if r.returncode == 0:
                return verify_active(rules_file, client)
        except Exception:
            pass
        import time
        time.sleep(1)
    return False


def _search(pattern: str, text: str) -> str:
    m = re.search(pattern, text)
    return m.group(1) if m else ""
