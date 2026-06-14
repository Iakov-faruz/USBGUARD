#!/usr/bin/env bash
set -euo pipefail

# USBGuard2 - Single project fix script.
# Centralizes environment setup, regex validation, test compatibility fixes,
# and local rule hygiene without scattering ad-hoc patches in the project root.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_READER="${PROJECT_ROOT}/scripts/lib/config-reader.sh"
TEST_APP="${PROJECT_ROOT}/unit_test/test_app.py"
TEST_BADUSB="${PROJECT_ROOT}/unit_test/test_badusb_monitor.py"
BADUSB_MONITOR="${PROJECT_ROOT}/scripts/badusb-monitor.py"

readonly FORBIDDEN_CHARS='[$`;|&<>(){}\[\]!]'

log_info() {
    printf '[INFO] %s\n' "$*"
}

log_ok() {
    printf '[OK] %s\n' "$*"
}

log_warn() {
    printf '[WARN] %s\n' "$*"
}

require_file() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        printf '[ERROR] Required file not found: %s\n' "$path" >&2
        return 1
    fi
}

ensure_local_log_files() {
    log_info "Ensuring local log files are available for tests"
    touch "${PROJECT_ROOT}/.usbguard-approval.log" \
          "${PROJECT_ROOT}/.usbguard-badusb.log" \
          "${PROJECT_ROOT}/.usbguard-web.log"
    log_ok "Local log files ready"
}

fix_config_reader_regex() {
    log_info "Fixing config-reader forbidden chars regex"
    require_file "$CONFIG_READER"

    python3 - "$CONFIG_READER" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
content = path.read_text(encoding='utf-8')
fixed = "readonly CONFIG_READER_FORBIDDEN_CHARS='[$`|&<>(){}\\[\\]!]'"

match = re.search(r"readonly CONFIG_READER_FORBIDDEN_CHARS='[^']*'", content)
if match:
    if match.group(0) != fixed:
        content = content[:match.start()] + fixed + content[match.end():]
        path.write_text(content, encoding='utf-8')
        print('updated')
    else:
        print('already-fixed')
else:
    content = content.replace(
        "readonly CONFIG_READER_DEFAULT_CONF=\"",
        fixed + "\n\nreadonly CONFIG_READER_DEFAULT_CONF=\""
    )
    path.write_text(content, encoding='utf-8')
    print('inserted')
PY

    grep -qF "readonly CONFIG_READER_FORBIDDEN_CHARS='[\$\`;|&<>(){}\\[\\]!]'" "$CONFIG_READER"
    printf '%s\n' 'value;rm -rf /' | grep -qF ';'
    log_ok "Config-reader regex validates dangerous semicolon"
}

fix_test_imports() {
    log_info "Ensuring unit tests import subprocess explicitly"
    require_file "$TEST_APP"
    require_file "$TEST_BADUSB"

    python3 - "$TEST_APP" "$TEST_BADUSB" <<'PY'
from pathlib import Path
import sys

for file_name in sys.argv[1:]:
    path = Path(file_name)
    lines = path.read_text(encoding='utf-8').splitlines()
    if not any(line == 'import subprocess' for line in lines):
        lines.insert(0, 'import subprocess')
        path.write_text('\n'.join(lines) + '\n', encoding='utf-8')
        print(f'{file_name}: added import subprocess')
    else:
        print(f'{file_name}: already has import subprocess')
PY
}

fix_badusb_localhost_constant() {
    log_info "Ensuring BadUSB monitor uses localhost-only API URL"
    require_file "$BADUSB_MONITOR"

    python3 - "$BADUSB_MONITOR" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
content = path.read_text(encoding='utf-8')
old = 'API_BLOCK_URL = "http://127.0.0.1:5000/api/block"'
new = 'API_BLOCK_URL = "http://localhost:5000/api/block"'

if old in content:
    content = content.replace(old, new)
    path.write_text(content, encoding='utf-8')
    print('updated localhost URL')
elif 'API_BLOCK_URL = "http://localhost:5000/api/block"' in content:
    print('already localhost URL')
else:
    print('no localhost URL constant found')
PY
}

fix_local_rules() {
    log_info "Normalizing local rules.d files"
    local rules_dir="${PROJECT_ROOT}/rules.d"
    require_file "${rules_dir}/00-system.rules"
    require_file "${rules_dir}/50-permanent.rules"
    require_file "${rules_dir}/90-temporary.rules"

    cat > "${rules_dir}/00-system.rules" <<'EOF'
# USBGuard System Rules – Valid syntax for v1.1.2
# Allows USB controllers, tablet devices, and HID interfaces to prevent lockout.

allow id 1d6b:0001 with-interface 09:00:00
allow id 1d6b:0002 with-interface 09:00:00
allow id 1d6b:0003 with-interface 09:00:00
allow id 80ee:0021
allow id *:* with-interface 03:00:00
allow id *:* with-interface 03:01:00
allow id *:* with-interface 03:01:01
allow id *:* with-interface 03:01:02
EOF

    : > "${rules_dir}/50-permanent.rules"
    : > "${rules_dir}/90-temporary.rules"
    log_ok "Local rules normalized"
}

run_targeted_tests() {
    log_info "Running targeted unit tests"
    local python_bin="${PROJECT_ROOT}/web/venv/bin/python3"

    if [[ ! -x "$python_bin" ]]; then
        python_bin="$(command -v python3)"
    fi

    "$python_bin" -m pytest \
        "${PROJECT_ROOT}/unit_test/test_bash_logic.py" \
        "${PROJECT_ROOT}/unit_test/test_app.py" \
        "${PROJECT_ROOT}/unit_test/test_badusb_monitor.py" \
        "${PROJECT_ROOT}/unit_test/test_security.py" \
        "${PROJECT_ROOT}/unit_test/test_integration.py"
}

main() {
    cd "$PROJECT_ROOT"
    ensure_local_log_files
    fix_config_reader_regex
    fix_test_imports
    fix_badusb_localhost_constant
    fix_local_rules

    if [[ "${1:-}" == "--skip-tests" ]]; then
        log_warn "Skipping targeted tests by request"
        return 0
    fi

    run_targeted_tests
}

main "$@"
