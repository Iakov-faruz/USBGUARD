#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# USBGuard Approval Manager - Master Checklist
# Version: 2.0 QA End-to-End
# ═══════════════════════════════════════════════════════════════════════════════
# הרצה:
#   ./master-checklist.sh
#   sudo ./master-checklist.sh   אחרי install מלא
# ═══════════════════════════════════════════════════════════════════════════════

set -uo pipefail

readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly RESET='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
SKIP_COUNT=0

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass() { ((PASS_COUNT++)); echo -e "  ${GREEN}PASS${RESET} $*"; }
fail() { ((FAIL_COUNT++)); echo -e "  ${RED}FAIL${RESET} $*"; }
warn() { ((WARN_COUNT++)); echo -e "  ${YELLOW}WARN${RESET} $*"; }
skip() { ((SKIP_COUNT++)); echo -e "  ${CYAN}SKIP${RESET} $*"; }
section() {
    echo ""
    echo -e "${BOLD}══════════════════════════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}  $*${RESET}"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════════${RESET}"
}

run_bash() {
    local label="$1"
    local script="$2"
    local output rc
    output=$(bash -lc "$script" 2>&1)
    rc=$?
    echo "$output"
    if [[ $rc -eq 0 ]]; then pass "$label"; else fail "$label"; fi
    return "$rc"
}

check_file() {
    local path="$1"
    local label="${2:-$path}"
    if [[ -f "$path" ]]; then pass "$label"; else fail "$label"; fi
}

check_dir() {
    local path="$1"
    local label="${2:-$path}"
    if [[ -d "$path" ]]; then pass "$label"; else fail "$label"; fi
}

check_exec() {
    local path="$1"
    local label="${2:-$path}"
    if [[ -x "$path" ]]; then pass "$label"; else fail "$label"; fi
}

check_command() {
    local cmd="$1"
    if command -v "$cmd" >/dev/null 2>&1; then pass "CLI command exists: $cmd"; else fail "CLI command missing: $cmd"; fi
}

check_import() {
    local pkg="$1"
    if python3 -c "import $pkg" >/dev/null 2>&1; then pass "Python import OK: $pkg"; else warn "Python import missing: $pkg"; fi
}

section "Section 0: Environment Basics"
echo -e "  ${CYAN}Whoami:${RESET} $(whoami)"
echo -e "  ${CYAN}Hostname:${RESET} $(hostname)"
echo -e "  ${CYAN}Uname:${RESET} $(uname -a)"
echo -e "  ${CYAN}Python:${RESET} $(python3 --version 2>/dev/null || echo 'not found')"
echo -e "  ${CYAN}Bash:${RESET} ${BASH_VERSION}"
pass "Environment info printed"

section "Section 1: CLI Dependencies"
for cmd in bash python3 pytest curl sudo systemctl awk grep sed tar gzip find stat; do
    check_command "$cmd"
done

section "Section 2: Project Structure"
for f in \
    scripts/lib/logger.sh \
    scripts/lib/config-reader.sh \
    scripts/lib/lock.sh \
    scripts/lib/backup.sh \
    scripts/lib/time-guards.sh \
    scripts/lib/validators.sh \
    scripts/lib/stages-core.sh \
    scripts/lib/stages-io.sh \
    scripts/lib/device-utils.sh \
    scripts/usb-approve.sh \
    scripts/cleanup-expired.sh \
    scripts/backup-rules.sh \
    scripts/restore-rules.sh \
    scripts/import-rules.sh \
    scripts/export-rules.sh \
    scripts/badusb-monitor.py \
    scripts/usbguard-status.sh \
    scripts/check-config.sh \
    web/app.py \
    web/start-web.sh \
    rules.d/00-system.rules \
    rules.d/50-permanent.rules \
    rules.d/90-temporary.rules \
    conf/approval-manager.conf \
    sudoers/usbguard-approval \
    logrotate/usbguard-approval \
    systemd/usbguard-ttl-reaper.service \
    systemd/usbguard-ttl-reaper.timer \
    systemd/usbguard-web.service \
    systemd/usbguard-behavioral.service \
    install.sh \
    master-checklist.sh \
    unit_test/test_debug.py \
    unit_test/test_badusb_monitor.py \
    unit_test/test_bash_logic.py \
    unit_test/test_app.py \
    unit_test/test_security.py \
    unit_test/test_integration.py \
    unit_test/test_e2e_session.py; do
    check_file "$PROJECT_ROOT/$f" "Project file exists: $f"
done

section "Section 3: Bash Syntax Check"
for script in \
    scripts/lib/logger.sh \
    scripts/lib/config-reader.sh \
    scripts/lib/lock.sh \
    scripts/lib/backup.sh \
    scripts/lib/time-guards.sh \
    scripts/lib/validators.sh \
    scripts/lib/stages-core.sh \
    scripts/lib/stages-io.sh \
    scripts/lib/device-utils.sh \
    scripts/usb-approve.sh \
    scripts/cleanup-expired.sh \
    scripts/backup-rules.sh \
    scripts/restore-rules.sh \
    scripts/import-rules.sh \
    scripts/export-rules.sh \
    scripts/usbguard-status.sh \
    scripts/check-config.sh \
    install.sh \
    web/start-web.sh; do
    bash -n "$PROJECT_ROOT/$script" 2>/dev/null && pass "Bash syntax OK: $script" || fail "Bash syntax error: $script"
done

section "Section 4: Python Syntax Check"
for pyfile in \
    scripts/badusb-monitor.py \
    web/app.py \
    unit_test/test_debug.py \
    unit_test/test_badusb_monitor.py \
    unit_test/test_bash_logic.py \
    unit_test/test_app.py \
    unit_test/test_security.py \
    unit_test/test_integration.py \
    unit_test/test_e2e_session.py; do
    python3 -m py_compile "$PROJECT_ROOT/$pyfile" 2>/dev/null && pass "Python compile OK: $pyfile" || fail "Python compile error: $pyfile"
done

section "Section 5: Config-reader Security Tests"
run_bash "config-reader valid key returns plain" "
cd '$PROJECT_ROOT'
tmp=\$(mktemp)
printf 'KEY=plain\n' > \"\$tmp\"
source scripts/lib/config-reader.sh
value=\$(get_conf KEY \"\$tmp\")
rc=\$?
rm -f \"\$tmp\"
[[ \$rc -eq 0 && \"\$value\" == plain ]]
"

run_bash "config-reader rejects semicolon injection" "
cd '$PROJECT_ROOT'
tmp=\$(mktemp)
printf 'KEY=value; rm -rf /\n' > \"\$tmp\"
source scripts/lib/config-reader.sh
if get_conf KEY \"\$tmp\" >/dev/null 2>&1; then exit 1; fi
rm -f \"\$tmp\"
"

run_bash "config-reader rejects pipe injection" "
cd '$PROJECT_ROOT'
tmp=\$(mktemp)
printf 'KEY=abc|cat\n' > \"\$tmp\"
source scripts/lib/config-reader.sh
if get_conf KEY \"\$tmp\" >/dev/null 2>&1; then exit 1; fi
rm -f \"\$tmp\"
"

run_bash "config-reader rejects dollar injection" "
cd '$PROJECT_ROOT'
tmp=\$(mktemp)
printf 'KEY=\$(whoami)\n' > \"\$tmp\"
source scripts/lib/config-reader.sh
if get_conf KEY \"\$tmp\" >/dev/null 2>&1; then exit 1; fi
rm -f \"\$tmp\"
"

section "Section 6: Logger Functionality Test"
run_bash "logger writes INFO message to initialized file" "
cd '$PROJECT_ROOT'
tmplog=\$(mktemp)
source scripts/lib/logger.sh
init_logger \"\$tmplog\" >/dev/null 2>&1
log_info TEST hello >/dev/null 2>&1
grep -q '\[INFO\]' \"\$tmplog\" && grep -q 'hello' \"\$tmplog\"
rm -f \"\$tmplog\"
"

run_bash "logger timestamp format is valid" "
cd '$PROJECT_ROOT'
tmplog=\$(mktemp)
source scripts/lib/logger.sh
init_logger \"\$tmplog\" >/dev/null 2>&1
log_info TEST hello >/dev/null 2>&1
grep -qE '\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\]' \"\$tmplog\"
rm -f \"\$tmplog\"
"

section "Section 7: Rules.d Structure Check"
check_file "$PROJECT_ROOT/rules.d/00-system.rules" "00-system.rules exists"
run_bash "00-system.rules contains allow id rules" "
cd '$PROJECT_ROOT'
grep -q 'allow id' rules.d/00-system.rules
"
run_bash "00-system.rules has no allow-without-id" "
cd '$PROJECT_ROOT'
! grep -qE '^allow with-interface' rules.d/00-system.rules
"

section "Section 8: BadUSB Monitor"
run_bash "badusb-monitor.py imports and API URL is local" "
cd '$PROJECT_ROOT'
python3 - <<'PY'
import importlib.util
spec = importlib.util.spec_from_file_location('badusb', 'scripts/badusb-monitor.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
assert 'localhost' in mod.API_BLOCK_URL or '127.0.0.1' in mod.API_BLOCK_URL
PY
"

section "Section 9: Python Dependencies"
for pkg in flask flask_limiter evdev requests yaml pytest; do
    check_import "$pkg"
done
if python3 -c "import usbguard" >/dev/null 2>&1; then pass "Python import OK: usbguard (IPC mode available)"; else skip "Python import missing: usbguard (subprocess fallback will be used)"; fi

section "Section 10: Unit and Regression Tests"
run_bash "unittest test_debug" "cd '$PROJECT_ROOT' && python3 -m unittest unit_test.test_debug -v"
run_bash "unittest test_badusb_monitor" "cd '$PROJECT_ROOT' && python3 -m unittest unit_test.test_badusb_monitor -v"
run_bash "unittest test_e2e_session" "cd '$PROJECT_ROOT' && python3 -m unittest unit_test.test_e2e_session -v"
run_bash "pytest full suite" "cd '$PROJECT_ROOT' && pytest -q"

section "Section 11: Install.sh Verification"
run_bash "install.sh dry-run succeeds" "cd '$PROJECT_ROOT' && sudo ./install.sh --dry-run --force >/tmp/usbguard_install_dry_run.log"
if grep -q "break-system-packages" "$PROJECT_ROOT/install.sh"; then pass "install.sh uses --break-system-packages"; else fail "install.sh missing --break-system-packages"; fi
for pkg in python3 python3-pip python3-evdev python3-flask usbguard curl; do
    grep -qF "$pkg" "$PROJECT_ROOT/install.sh" && pass "install.sh includes package $pkg" || fail "install.sh missing package $pkg"
done
for lib in stages-core.sh stages-io.sh device-utils.sh; do
    grep -qF "$lib" "$PROJECT_ROOT/install.sh" && pass "install.sh deploys lib/$lib" || fail "install.sh missing lib/$lib"
done

section "Section 12: Systemd Unit Files"
for svc in \
    systemd/usbguard-ttl-reaper.service \
    systemd/usbguard-ttl-reaper.timer \
    systemd/usbguard-web.service \
    systemd/usbguard-behavioral.service; do
    check_file "$PROJECT_ROOT/$svc" "Systemd file exists: $svc"
done

section "Section 13: Post-install Filesystem Checks"
if [[ -d /etc/usbguard ]]; then
    check_dir "/etc/usbguard"
    for f in \
        /etc/usbguard/approval-manager.conf \
        /etc/usbguard/scripts/usb-approve.sh \
        /etc/usbguard/scripts/cleanup-expired.sh \
        /etc/usbguard/scripts/badusb-monitor.py \
        /etc/usbguard/scripts/lib/logger.sh \
        /etc/usbguard/scripts/lib/config-reader.sh \
        /etc/usbguard/scripts/lib/stages-core.sh \
        /etc/usbguard/scripts/lib/stages-io.sh \
        /etc/usbguard/scripts/lib/device-utils.sh \
        /etc/usbguard/rules.d/00-system.rules \
        /etc/usbguard/rules.d/50-permanent.rules \
        /etc/usbguard/rules.d/90-temporary.rules \
        /etc/usbguard/web/app.py \
        /etc/usbguard/web/start-web.sh; do
        check_file "$f" "Installed file exists: $f"
    done
    for f in /etc/usbguard/scripts/usb-approve.sh /etc/usbguard/scripts/cleanup-expired.sh /etc/usbguard/scripts/badusb-monitor.py /etc/usbguard/web/start-web.sh; do
        check_exec "$f" "Installed executable: $f"
    done
    getent group usbadmins >/dev/null 2>&1 && pass "Group usbadmins exists" || warn "Group usbadmins missing"
    [[ -f /etc/sudoers.d/usbguard-approval ]] && pass "Sudoers file exists" || warn "Sudoers file missing"
    [[ -f /etc/logrotate.d/usbguard-approval ]] && pass "Logrotate config exists" || warn "Logrotate config missing"
else
    skip "Post-install filesystem skipped: /etc/usbguard not found"
fi

section "Section 14: Post-install Config and Rules"
if [[ -f /etc/usbguard/approval-manager.conf ]]; then
    run_bash "installed config-reader reads deployed config" "
cd '$PROJECT_ROOT'
source scripts/lib/config-reader.sh
value=\$(get_conf TEMP_TTL_SECONDS /etc/usbguard/approval-manager.conf)
[[ \"\$value\" == 3600 ]]
"
fi
if [[ -d /etc/usbguard/rules.d ]]; then
    for f in /etc/usbguard/rules.d/*.rules; do
        [[ -f "$f" ]] || continue
        if grep -qE '^(allow|block|reject) id ' "$f"; then
            pass "Rule syntax OK: $f"
        else
            pass "Rule file has no active approval entries: $f"
        fi
        ! grep -qE '^allow with-interface' "$f" && pass "No invalid allow-without-id: $f" || fail "Invalid allow-without-id: $f"
    done
else
    skip "Installed rules skipped: /etc/usbguard/rules.d not found"
fi

section "Section 15: Systemd Runtime Checks"
for unit in usbguard.service usbguard-web.service usbguard-behavioral.service usbguard-ttl-reaper.timer; do
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
        pass "Systemd unit active: $unit"
    else
        warn "Systemd unit not active: $unit"
    fi
done

section "Section 16: End-to-End Core Session Simulation"
run_bash "E2E core approval session" "cd '$PROJECT_ROOT' && python3 -m unittest unit_test.test_e2e_session -v"

section "Section 17: API Checks"
if curl -s --max-time 2 http://127.0.0.1:5000/api/status >/dev/null 2>&1; then
    for path in /api/status /api/devices /api/rules /api/logs; do
        code=$(curl -s -o /tmp/usbguard_api_response.json -w '%{http_code}' "http://127.0.0.1:5000$path")
        if [[ "$code" == "200" ]]; then pass "API $path returns HTTP 200"; else warn "API $path returns HTTP $code"; fi
    done
else
    skip "API skipped: Flask service is not listening on 127.0.0.1:5000"
fi

section "Section 18: Logs"
for logfile in /var/log/usbguard-approval.log /var/log/usbguard-badusb.log /var/log/usbguard-web.log /var/log/usbguard-install.log; do
    [[ -f "$logfile" ]] && pass "Log file exists: $logfile" || warn "Log file missing: $logfile"
done
[[ -d /var/log/usbguard ]] && pass "/var/log/usbguard exists" || warn "/var/log/usbguard missing"

section "Section 19: Line Ending Checks"
crlf_count=0
for script in scripts/lib/logger.sh scripts/lib/config-reader.sh scripts/usb-approve.sh scripts/cleanup-expired.sh scripts/badusb-monitor.py install.sh master-checklist.sh; do
    if grep -qP '\r' "$PROJECT_ROOT/$script" 2>/dev/null; then fail "CRLF found in: $script"; ((crlf_count++)); fi
done
[[ $crlf_count -eq 0 ]] && pass "No CRLF found in main scripts"

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 20: Deployed Permissions (post-install)
# ═══════════════════════════════════════════════════════════════════════════════
section "Section 20: Deployed Permissions"

if [[ -d "/etc/usbguard/rules.d" ]]; then
    dir_perm=$(sudo stat -c "%a %U:%G" /etc/usbguard/rules.d 2>/dev/null)
    if echo "$dir_perm" | grep -q "750 root:usbadmins"; then
        pass "rules.d directory: 750 root:usbadmins"
    else
        warn "rules.d directory permissions: $dir_perm (expected 750 root:usbadmins)"
    fi
else
    skip "rules.d not installed yet"
fi

for lib in config-reader.sh logger.sh lock.sh backup.sh time-guards.sh validators.sh stages-core.sh stages-io.sh device-utils.sh; do
    lib_path="/etc/usbguard/scripts/lib/$lib"
    if sudo test -f "$lib_path"; then
        lib_perm=$(sudo stat -c "%a" "$lib_path" 2>/dev/null)
        if [[ "$lib_perm" == "640" || "$lib_perm" == "644" ]]; then
            pass "lib/$lib permissions: $lib_perm"
        else
            warn "lib/$lib permissions: $lib_perm (expected 640)"
        fi
    else
        skip "lib/$lib not installed yet"
    fi
done

for logfile in /var/log/usbguard-approval.log /var/log/usbguard-badusb.log /var/log/usbguard-web.log; do
    if sudo test -f "$logfile"; then
        log_perm=$(sudo stat -c "%a %U:%G" "$logfile" 2>/dev/null)
        if echo "$log_perm" | grep -q "660 root:usbadmins"; then
            pass "Log file permissions OK: $logfile ($log_perm)"
        else
            warn "Log file permissions: $logfile ($log_perm)"
        fi
    fi
done

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 21: run_tests.sh Syntax
# ═══════════════════════════════════════════════════════════════════════════════
section "Section 21: run_tests.sh Syntax"
if bash -n "$PROJECT_ROOT/run_tests.sh" 2>/dev/null; then
    pass "run_tests.sh syntax OK"
else
    fail "run_tests.sh syntax error"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 22: sudoers Validation
# ═══════════════════════════════════════════════════════════════════════════════
section "Section 22: Sudoers & Security"
if sudo test -f "/etc/sudoers.d/usbguard-approval"; then
    pass "sudoers file exists"
    if sudo visudo -c 2>/dev/null | grep -q "parsed OK"; then
        pass "sudoers syntax valid"
    else
        warn "sudoers validation issue"
    fi
else
    skip "sudoers file not installed yet"
fi

if [[ -f "/etc/logrotate.d/usbguard-approval" ]]; then
    pass "logrotate config exists"
else
    skip "logrotate config not installed yet"
fi

section "MASTER CHECKLIST SUMMARY"
echo -e "  ${GREEN}PASS: ${PASS_COUNT}${RESET}"
echo -e "  ${RED}FAIL: ${FAIL_COUNT}${RESET}"
echo -e "  ${YELLOW}WARN: ${WARN_COUNT}${RESET}"
echo -e "  ${CYAN}SKIP: ${SKIP_COUNT}${RESET}"
TOTAL=$((PASS_COUNT + FAIL_COUNT + WARN_COUNT + SKIP_COUNT))
echo -e "  Total checks: ${TOTAL}"

if [[ $FAIL_COUNT -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}  All critical checks passed.${RESET}"
else
    echo -e "${RED}${BOLD}  ${FAIL_COUNT} check(s) failed. Review above.${RESET}"
fi
