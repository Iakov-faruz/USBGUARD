from __future__ import annotations
import os
import re
import shutil
import stat
import subprocess
import sys
from pathlib import Path
from typing import List, Optional, Tuple

# ─── Rule Validation Port ─────────────────────────────────────────────────────
_VIDPID_RE = re.compile(r"^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$")
_NUMERIC_ID_RE = re.compile(r"^[0-9]+$")
_IFACE_RE = re.compile(r"^[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}$")
_QUOTED_SAFE_RE = re.compile(r'^[A-Za-z0-9 _./\-:@+,#()=/]+$')
_UNQUOTED_SAFE_RE = re.compile(r'^[A-Za-z0-9_.:@{} ,/-]+$')
_KNOWN_ATTRS = {
    "id", "serial", "name", "hash", "with-interface",
    "via-port", "with-name", "with-connect-type", "parent-hash",
}
_DANGEROUS = set(";|$&<>(){}[]!`\\")


def _normalize_interface(value: str) -> str:
    if value.startswith("{") and value.endswith("}"):
        parts = [p.strip() for p in value[1:-1].split(",") if p.strip()]
        return "{" + ",".join(parts) + "}"
    return value


def _tokens(line: str) -> List[str]:
    result: List[str] = []
    cur: List[str] = []
    in_quote = False
    escape = False
    for ch in line:
        if escape:
            cur.append(ch)
            escape = False
            continue
        if in_quote and ch == "\\":
            cur.append(ch)
            escape = True
            continue
        if ch == '"':
            if in_quote:
                result.append('"' + "".join(cur) + '"')
                cur = []
                in_quote = False
            else:
                if cur:
                    result.append("".join(cur))
                    cur = []
                in_quote = True
            continue
        if ch.isspace() and not in_quote:
            if cur:
                result.append("".join(cur))
                cur = []
            continue
        cur.append(ch)
    if in_quote:
        raise ValueError("unbalanced quote")
    if cur:
        result.append("".join(cur))
    return result


def _strip_comment(line: str) -> str:
    out: List[str] = []
    in_quote = False
    escape = False
    for ch in line:
        if escape:
            out.append(ch)
            escape = False
            continue
        if in_quote and ch == "\\":
            out.append(ch)
            escape = True
            continue
        if ch == '"':
            in_quote = not in_quote
            out.append(ch)
            continue
        if ch == "#" and not in_quote:
            break
        out.append(ch)
    return "".join(out).strip()


def _validate_quoted(value: str, attr: str) -> Optional[str]:
    if not value:
        return f"{attr} requires a quoted value"
    if value[0] != '"' or value[-1] != '"':
        return f"{attr} must be quoted"
    inner = value[1:-1]
    if not _QUOTED_SAFE_RE.match(inner):
        return f"{attr} contains unsupported characters"
    if any(ch in inner for ch in _DANGEROUS):
        return f"{attr} contains shell-sensitive characters"
    return None


def _validate_unquoted(value: str, attr: str) -> Optional[str]:
    if not value:
        return f"{attr} requires a value"
    if not _UNQUOTED_SAFE_RE.match(value):
        return f"{attr} contains unsupported characters"
    if any(ch in value for ch in _DANGEROUS):
        return f"{attr} contains shell-sensitive characters"
    return None


def _validate_interface_set(value: str) -> Optional[str]:
    if value.startswith("{") and value.endswith("}"):
        inner = value[1:-1]
        if not inner:
            return "with-interface set cannot be empty"
        parts = [p.strip() for p in inner.split(",")]
        if any(not p for p in parts):
            return "with-interface set contains empty interface"
        if any(not _IFACE_RE.match(p) for p in parts):
            return "with-interface set contains invalid interface"
        return None
    if not _IFACE_RE.match(value):
        return "with-interface must be AA:BB:CC or {AA:BB:CC,...}"
    return None


def _normalize_interface_sets(line: str) -> str:
    def repl(match: re.Match) -> str:
        inner = match.group(1).strip()
        if ',' in inner:
            parts = [part.strip() for part in inner.split(',') if part.strip()]
        else:
            parts = [part.strip() for part in inner.split() if part.strip()]
        return 'with-interface {' + ','.join(parts) + '}'
    return re.sub(r"with-interface\s+\{(.*?)\}", repl, line)


def validate_rule(line: str) -> str:
    original = line
    line = _normalize_interface_sets(_strip_comment(line))
    if not line:
        return "OK"
    if any(ord(ch) < 32 and ch not in "\t" for ch in line):
        return "contains control characters"
    if line.startswith("#"):
        return "OK"
    try:
        tokens = _tokens(line)
    except ValueError as exc:
        return str(exc)
    if not tokens:
        return "OK"
    action = tokens[0]
    if action not in ("allow", "block", "reject"):
        return "action must be allow, block, or reject"
    if len(tokens) < 3:
        return "missing id attribute"
    if tokens[1] != "id":
        return "id attribute must immediately follow action"
    device_id = tokens[2]
    if not (_VIDPID_RE.match(device_id) or _NUMERIC_ID_RE.match(device_id)):
        return "id must be VID:PID or numeric USBGuard id"
    i = 3
    while i < len(tokens):
        attr = tokens[i]
        if attr not in _KNOWN_ATTRS:
            return f"unknown attribute: {attr}"
        if attr in ("serial", "name", "hash", "via-port", "with-name", "parent-hash"):
            val = tokens[i + 1] if i + 1 < len(tokens) else ""
            if attr in ("hash", "parent-hash"):
                err = _validate_quoted(val, attr)
            else:
                err = _validate_quoted(val, attr)
            if err:
                return err
            i += 2
            continue
        if attr == "with-interface":
            val = tokens[i + 1] if i + 1 < len(tokens) else ""
            err = _validate_interface_set(val)
            if err:
                return err
            i += 2
            continue
        if attr == "with-connect-type":
            val = tokens[i + 1] if i + 1 < len(tokens) else ""
            err = _validate_unquoted(val, attr)
            if err:
                return err
            i += 2
            continue
        return f"attribute {attr} is not supported by validator"
    return "OK"


def validate_rule_line(line: str) -> bool:
    return validate_rule(line) == "OK"


def validate_rule_file(path_text: str) -> List[str]:
    p = Path(path_text)
    if not p.exists():
        return [f"ERROR:0:file not found: {p}"]
    try:
        lines = p.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as exc:
        return [f"ERROR:0:cannot read {p}: {exc}"]
    errors: List[str] = []
    for idx, line in enumerate(lines, 1):
        result = validate_rule(line)
        if result != "OK":
            errors.append(f"ERROR:{idx}:{result}")
    return errors


def validate_import_payload(path_text: str) -> List[str]:
    import json
    p = Path(path_text)
    if not p.exists():
        return [f"ERROR:0:file not found: {p}"]
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except Exception as exc:
        return [f"ERROR:0:invalid JSON: {exc}"]
    if not isinstance(data, dict):
        return ["ERROR:0:top-level JSON must be an object"]
    if "rules" not in data or not isinstance(data["rules"], dict):
        return ["ERROR:0:missing object key: rules"]
    allowed = {"system", "permanent", "temporary"}
    errors: List[str] = []
    for category, value in data["rules"].items():
        if category not in allowed:
            errors.append(f"ERROR:rules.{category}:unknown category")
            continue
        if not isinstance(value, list):
            errors.append(f"ERROR:rules.{category}:category must be a list")
            continue
        for idx, rule in enumerate(value, 1):
            if not isinstance(rule, str):
                errors.append(f"ERROR:rules.{category}[{idx}]:rule must be a string")
                continue
            result = validate_rule(rule)
            if result != "OK":
                errors.append(f"ERROR:rules.{category}[{idx}]:{result}")
    return errors


def rule_signature(rule_line: str) -> Optional[Tuple]:
    attrs: dict = {}
    toks = _tokens(_strip_comment(rule_line))
    if not toks or toks[0] not in ("allow", "block"):
        return None
    attrs["action"] = toks[0]
    i = 1
    while i < len(toks):
        key = toks[i]
        if key in ("id", "serial", "name", "hash", "with-interface"):
            if key == "with-interface":
                i += 1
                value = toks[i] if i < len(toks) else ""
                if value.startswith("{"):
                    parts = [value]
                    while i + 1 < len(toks) and not value.endswith("}"):
                        i += 1
                        value += " " + toks[i]
                        parts.append(toks[i])
                    value = "".join(parts)
                attrs[key] = _normalize_interface(value)
            else:
                i += 1
                attrs[key] = toks[i] if i < len(toks) else ""
            i += 1
            continue
        i += 1
    return tuple(attrs.get(k, "") for k in ("action", "id", "serial", "name", "hash", "with-interface"))


def check_rule_duplicate(rule: str, rules_dir: str) -> bool:
    if not rule:
        return False
    p = Path(rules_dir)
    if not p.is_dir():
        return False
    wanted = rule_signature(rule)
    if wanted is None:
        return False
    for path in sorted(p.glob("*.rules")):
        try:
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        for line in lines:
            existing = rule_signature(line)
            if existing is not None and existing == wanted:
                return True
    return False


# ─── Validators Port ─────────────────────────────────────────────────────────
_MIN_DISK_MB = 50


def check_root() -> bool:
    try:
        return os.geteuid() == 0
    except AttributeError:
        return False


def check_user_allowed(allowed_users: str = "root", allowed_groups: str = "wheel") -> bool:
    current_user = os.environ.get("USER", "root")
    if current_user == "root":
        return True
    for u in allowed_users.split(","):
        u = u.strip()
        if u == current_user:
            return True
    for g in allowed_groups.split(","):
        g = g.strip()
        try:
            groups = subprocess.run(["groups", current_user], capture_output=True, text=True, check=True).stdout
            if re.search(rf"\b{re.escape(g)}\b", groups):
                return True
        except Exception:
            pass
    return False


def check_daemon_active() -> bool:
    try:
        r = subprocess.run(["systemctl", "is-active", "--quiet", "usbguard"], capture_output=True, timeout=10)
        return r.returncode == 0
    except Exception:
        return False


def check_rules_files_exist(rules_dir: str = "/etc/usbguard/rules.d") -> bool:
    p = Path(rules_dir)
    if not p.is_dir():
        return False
    required = ["00-system.rules", "50-permanent.rules", "90-temporary.rules"]
    missing = sum(1 for rf in required if not (p / rf).is_file())
    return missing == 0


def check_rule_syntax(rule_file: str) -> bool:
    p = Path(rule_file)
    if not p.is_file():
        return True
    errors = validate_rule_file(str(p))
    return len(errors) == 0


def check_disk_space(path: str, min_mb: int = _MIN_DISK_MB) -> bool:
    p = Path(path)
    if not p.exists():
        p = p.parent
    try:
        usage = shutil.disk_usage(str(p))
        available_mb = usage.free / (1024 * 1024)
        return available_mb >= min_mb
    except Exception:
        return False


def check_external_deps() -> bool:
    deps = ["usbguard"]
    missing = 0
    for dep in deps:
        if not shutil.which(dep):
            missing += 1
    return missing == 0


def check_clock_reasonable(min_epoch: int = 1577836800) -> bool:
    try:
        now = int(subprocess.run(["date", "+%s"], capture_output=True, text=True, check=True).stdout.strip())
        return now >= min_epoch
    except Exception:
        return False


def check_config_file(config_path: str) -> bool:
    p = Path(config_path)
    if not p.is_file():
        return False
    if not os.access(str(p), os.R_OK):
        return False
    try:
        data = p.read_text(encoding="utf-8", errors="replace")
        if config_path.endswith(".yaml") or config_path.endswith(".yml"):
            import yaml
            yaml.safe_load(data)
        elif config_path.endswith(".conf"):
            for line in data.splitlines():
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" not in line:
                    return False
    except Exception:
        return False
    return True


def run_all_preflight_checks(config_path: str = "/etc/usbguard/protector.yaml") -> List[Tuple[str, bool, str]]:
    checks: List[Tuple[str, bool, str]] = []
    checks.append(("root", check_root(), "Must run as root"))
    checks.append(("clock", check_clock_reasonable(), "System clock is reasonable"))
    checks.append(("daemon", check_daemon_active(), "usbguard daemon active"))
    checks.append(("deps", check_external_deps(), "Required dependencies present"))
    checks.append(("config", check_config_file(config_path), "Config file valid"))
    checks.append(("rules_dir", check_rules_files_exist(), "Rules directory complete"))
    return checks
