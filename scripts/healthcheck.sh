#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/usbguard/approval-manager.conf"
INCLUDE_DAEMON=false

usage() {
    cat <<'EOF'
Usage: healthcheck.sh [OPTIONS]

Options:
  --ready          Include USBGuard daemon readiness in the result.
  --skip-daemon    Do not require usbguard daemon to be active.
  --help, -h       Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ready)
            INCLUDE_DAEMON=true
            shift
            ;;
        --skip-daemon)
            INCLUDE_DAEMON=false
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

require_file() {
    local path="$1"
    local label="$2"
    if [[ ! -f "$path" ]]; then
        echo "healthcheck: ${label} missing: ${path}" >&2
        exit 1
    fi
}

require_dir() {
    local path="$1"
    local label="$2"
    if [[ ! -d "$path" ]]; then
        echo "healthcheck: ${label} missing: ${path}" >&2
        exit 1
    fi
}

require_writable_dir() {
    local path="$1"
    local label="$2"
    mkdir -p "$path" 2>/dev/null || {
        echo "healthcheck: ${label} is not writable: ${path}" >&2
        exit 1
    }
}

require_file "$CONFIG_FILE" "configuration file"

rules_system=$(grep -oP '^RULES_SYSTEM=\K.*' "$CONFIG_FILE" 2>/dev/null || echo "/etc/usbguard/rules.d/00-system.rules")
rules_permanent=$(grep -oP '^RULES_PERMANENT=\K.*' "$CONFIG_FILE" 2>/dev/null || echo "/etc/usbguard/rules.d/50-permanent.rules")
rules_temporary=$(grep -oP '^RULES_TEMPORARY=\K.*' "$CONFIG_FILE" 2>/dev/null || echo "/etc/usbguard/rules.d/90-temporary.rules")
backup_dir=$(grep -oP '^BACKUP_DIR=\K.*' "$CONFIG_FILE" 2>/dev/null || echo "/etc/usbguard/backups")
state_dir=$(grep -oP '^STATE_DIR=\K.*' "$CONFIG_FILE" 2>/dev/null || echo "/var/lib/usbguard-manager")
log_file=$(grep -oP '^LOG_FILE=\K.*' "$CONFIG_FILE" 2>/dev/null || echo "/var/log/usbguard-approval.log")

require_dir "$(dirname "$rules_system")" "rules directory"
require_file "$rules_system" "system rules file"
require_file "$rules_permanent" "permanent rules file"
require_file "$rules_temporary" "temporary rules file"
require_writable_dir "$backup_dir" "backup directory"
require_writable_dir "$state_dir" "state directory"
require_writable_dir "$(dirname "$log_file")" "log directory"

if [[ "$INCLUDE_DAEMON" == "true" ]]; then
    if ! systemctl is-active --quiet usbguard 2>/dev/null; then
        echo "healthcheck: USBGuard daemon is not active" >&2
        exit 1
    fi
fi

if ! date +%s >/dev/null; then
    echo "healthcheck: system clock is unavailable" >&2
    exit 1
fi

if ! df -Pm "$(dirname "$backup_dir")" >/dev/null 2>&1; then
    echo "healthcheck: cannot check backup disk space" >&2
    exit 1
fi

echo "ready"
exit 0
