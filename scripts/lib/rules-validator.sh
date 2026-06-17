#!/usr/bin/env bash
set -euo pipefail

if [[ "${USBGUARD_RULE_VALIDATOR_LOADED:-0}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi
USBGUARD_RULE_VALIDATOR_LOADED=1

readonly RULE_VALIDATOR_DEFAULT_RULES_DIR="/etc/usbguard/rules.d"
readonly RULE_VALIDATOR_REQUIRED_FILES=(00-system.rules 50-permanent.rules 90-temporary.rules)

_usbguard_rule_validator_python() {
    python3 - "$@" <<'PY'
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

VIDPID_RE = re.compile(r'^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$')
NUMERIC_ID_RE = re.compile(r'^[0-9]+$')
IFACE_RE = re.compile(r'^[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}$')
QUOTED_SAFE_RE = re.compile(r'^[A-Za-z0-9 _./\-:@+,#()=/]+$')
UNQUOTED_SAFE_RE = re.compile(r'^[A-Za-z0-9_.:@{} ,/-]+$')
KNOWN_ATTRS = {
    'id',
    'serial',
    'name',
    'hash',
    'with-interface',
    'via-port',
    'with-name',
    'with-connect-type',
    'parent-hash',
}
DANGEROUS = set(';|$&<>(){}[]!`\\')

def fail(line_no: int, reason: str) -> str:
    return f'ERROR:{line_no}:{reason}'


def tokenize(line: str) -> list[str]:
    tokens: list[str] = []
    cur: list[str] = []
    in_quote = False
    escaped = False
    for ch in line:
        if escaped:
            cur.append(ch)
            escaped = False
            continue
        if in_quote and ch == '\\':
            cur.append(ch)
            escaped = True
            continue
        if ch == '"':
            if in_quote:
                tokens.append('"' + ''.join(cur) + '"')
                cur = []
                in_quote = False
            else:
                if cur:
                    tokens.append(''.join(cur))
                    cur = []
                in_quote = True
            continue
        if ch.isspace() and not in_quote:
            if cur:
                tokens.append(''.join(cur))
                cur = []
            continue
        cur.append(ch)
    if in_quote:
        raise ValueError('unbalanced quote')
    if cur:
        tokens.append(''.join(cur))
    return tokens


def strip_comment(line: str) -> str:
    out: list[str] = []
    in_quote = False
    escaped = False
    for ch in line:
        if escaped:
            out.append(ch)
            escaped = False
            continue
        if in_quote and ch == '\\':
            out.append(ch)
            escaped = True
            continue
        if ch == '"':
            in_quote = not in_quote
            out.append(ch)
            continue
        if ch == '#' and not in_quote:
            break
        out.append(ch)
    return ''.join(out).strip()


def validate_quoted(value: str, attr: str) -> str | None:
    if not value:
        return f'{attr} requires a quoted value'
    if value[0] != '"' or value[-1] != '"':
        return f'{attr} must be quoted'
    inner = value[1:-1]
    if not QUOTED_SAFE_RE.match(inner):
        return f'{attr} contains unsupported characters'
    if any(ch in inner for ch in DANGEROUS):
        return f'{attr} contains shell-sensitive characters'
    return None


def validate_unquoted(value: str, attr: str) -> str | None:
    if not value:
        return f'{attr} requires a value'
    if not UNQUOTED_SAFE_RE.match(value):
        return f'{attr} contains unsupported characters'
    if any(ch in value for ch in DANGEROUS):
        return f'{attr} contains shell-sensitive characters'
    return None


def validate_interface_set(value: str) -> str | None:
    if value.startswith('{') and value.endswith('}'):
        inner = value[1:-1]
        if not inner:
            return 'with-interface set cannot be empty'
        parts = [p.strip() for p in inner.split(',')]
        if any(not p for p in parts):
            return 'with-interface set contains empty interface'
        if any(not IFACE_RE.match(p) for p in parts):
            return 'with-interface set contains invalid interface'
        return None
    if not IFACE_RE.match(value):
        return 'with-interface must be AA:BB:CC or {AA:BB:CC,...}'
    return None


def normalize_interface_sets(line: str) -> str:
    def repl(match: re.Match[str]) -> str:
        inner = match.group(1).strip()
        if ',' in inner:
            parts = [part.strip() for part in inner.split(',') if part.strip()]
        else:
            parts = [part.strip() for part in inner.split() if part.strip()]
        return '{' + ','.join(parts) + '}'

    return re.sub(r'with-interface\s+(\{.*?\})', repl, line)


def validate_rule(line: str) -> str:
    original = line
    line = normalize_interface_sets(strip_comment(line))
    if not line:
        return 'OK'
    if any(ord(ch) < 32 and ch not in '\t' for ch in line):
        return 'contains control characters'
    if line.startswith('#'):
        return 'OK'
    try:
        tokens = tokenize(line)
    except ValueError as exc:
        return str(exc)
    if not tokens:
        return 'OK'
    action = tokens[0]
    if action not in ('allow', 'block', 'reject'):
        return 'action must be allow, block, or reject'
    if len(tokens) < 3:
        return 'missing id attribute'
    if tokens[1] != 'id':
        return 'id attribute must immediately follow action'
    device_id = tokens[2]
    if not (VIDPID_RE.match(device_id) or NUMERIC_ID_RE.match(device_id)):
        return 'id must be VID:PID or numeric USBGuard id'
    i = 3
    while i < len(tokens):
        attr = tokens[i]
        if attr not in KNOWN_ATTRS:
            return f'unknown attribute: {attr}'
        if attr in ('serial', 'name', 'hash', 'via-port', 'with-name', 'parent-hash'):
            if attr in ('hash', 'parent-hash'):
                err = validate_quoted(tokens[i + 1] if i + 1 < len(tokens) else '', attr)
            else:
                err = validate_quoted(tokens[i + 1] if i + 1 < len(tokens) else '', attr)
            if err:
                return err
            i += 2
            continue
        if attr == 'with-interface':
            err = validate_interface_set(tokens[i + 1] if i + 1 < len(tokens) else '')
            if err:
                return err
            i += 2
            continue
        if attr == 'with-connect-type':
            err = validate_unquoted(tokens[i + 1] if i + 1 < len(tokens) else '', attr)
            if err:
                return err
            i += 2
            continue
        return f'attribute {attr} is not supported by validator'
    return 'OK'


def validate_file(path_text: str) -> list[str]:
    path = Path(path_text)
    if not path.exists():
        return [f'ERROR:0:file not found: {path}']
    try:
        lines = path.read_text(encoding='utf-8', errors='replace').splitlines()
    except OSError as exc:
        return [f'ERROR:0:cannot read {path}: {exc}']
    errors: list[str] = []
    for idx, line in enumerate(lines, 1):
        result = validate_rule(line)
        if result != 'OK':
            errors.append(f'ERROR:{idx}:{result}')
    return errors


def validate_import(path_text: str) -> list[str]:
    path = Path(path_text)
    if not path.exists():
        return [f'ERROR:0:file not found: {path}']
    try:
        data = json.loads(path.read_text(encoding='utf-8'))
    except Exception as exc:
        return [f'ERROR:0:invalid JSON: {exc}']
    if not isinstance(data, dict):
        return [f'ERROR:0:top-level JSON must be an object']
    if 'rules' not in data or not isinstance(data['rules'], dict):
        return [f'ERROR:0:missing object key: rules']
    allowed = {'system', 'permanent', 'temporary'}
    errors: list[str] = []
    for category, value in data['rules'].items():
        if category not in allowed:
            errors.append(f'ERROR:rules.{category}:unknown category')
            continue
        if not isinstance(value, list):
            errors.append(f'ERROR:rules.{category}:category must be a list')
            continue
        for idx, rule in enumerate(value, 1):
            if not isinstance(rule, str):
                errors.append(f'ERROR:rules.{category}[{idx}]:rule must be a string')
                continue
            result = validate_rule(rule)
            if result != 'OK':
                errors.append(f'ERROR:rules.{category}[{idx}]:{result}')
    return errors


mode = sys.argv[1]
args = sys.argv[2:]
if mode == 'rule':
    print(validate_rule(args[0]))
elif mode == 'file':
    errors = validate_file(args[0])
    print('\n'.join(errors) if errors else 'OK')
    raise SystemExit(1 if errors else 0)
elif mode == 'import':
    errors = validate_import(args[0])
    print('\n'.join(errors) if errors else 'OK')
    raise SystemExit(1 if errors else 0)
else:
    print('ERROR:unknown mode')
    raise SystemExit(2)
PY
}

validate_usbguard_rule_line() {
    local line="$1"
    local result
    result=$(_usbguard_rule_validator_python rule "$line" 2>/dev/null || echo "ERROR:validator failed")
    [[ "$result" == "OK" ]]
}

validate_usbguard_rule_file() {
    local file="$1"
    _usbguard_rule_validator_python file "$file"
}

validate_import_payload() {
    local file="$1"
    _usbguard_rule_validator_python import "$file"
}

validate_rules_dir() {
    local rules_dir="${1:-$RULE_VALIDATOR_DEFAULT_RULES_DIR}"
    local errors=0
    local rule_file

    if [[ ! -d "$rules_dir" ]]; then
        log_error "RULES" "Rules directory missing: $rules_dir" 2>/dev/null || true
        echo "ERROR: Rules directory missing: $rules_dir" >&2
        return 1
    fi

    for rule_file in "${RULE_VALIDATOR_REQUIRED_FILES[@]}"; do
        if [[ ! -f "${rules_dir}/${rule_file}" ]]; then
            log_error "RULES" "Required rules file missing: ${rules_dir}/${rule_file}" 2>/dev/null || true
            echo "ERROR: Required rules file missing: ${rules_dir}/${rule_file}" >&2
            errors=$((errors + 1))
        fi
    done

    for rule_file in "${rules_dir}"/*.rules; do
        [[ -f "$rule_file" ]] || continue
        if ! validate_usbguard_rule_file "$rule_file" >/dev/null; then
            validate_usbguard_rule_file "$rule_file" >&2 || true
            errors=$((errors + 1))
        fi
    done

    if [[ $errors -eq 0 ]]; then
        return 0
    fi
    return 1
}
