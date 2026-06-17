#!/usr/bin/env bash
set -euo pipefail

if [[ "${USBGUARD_NETWORK_LOCKDOWN_LOADED:-0}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi
USBGUARD_NETWORK_LOCKDOWN_LOADED=1

readonly NETWORK_LOCKDOWN_TABLE="usbguard_lockdown"
readonly NETWORK_LOCKDOWN_FAMILY="inet"
readonly NETWORK_LOCKDOWN_DEFAULT_CONFIG="/etc/usbguard/approval-manager.conf"

network_lockdown_get_conf() {
    local key="$1"
    local default="$2"
    if declare -F get_conf >/dev/null 2>&1; then
        get_conf "$key" "${NETWORK_LOCKDOWN_DEFAULT_CONFIG}" 2>/dev/null || printf '%s' "$default"
    else
        printf '%s' "$default"
    fi
}

network_lockdown_enabled() {
    local value
    value=$(network_lockdown_get_conf "NETWORK_LOCKDOWN_ENABLED" "true")
    value=${value,,}
    [[ "$value" == "true" || "$value" == "1" || "$value" == "yes" || "$value" == "on" ]]
}

network_lockdown_require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        echo "ERROR: network lockdown requires root" >&2
        return 1
    fi
}

network_lockdown_require_nft() {
    if ! command -v nft >/dev/null 2>&1; then
        echo "ERROR: nft command not found" >&2
        return 1
    fi
}

network_lockdown_generate() {
    local policy allow_local
    policy=$(network_lockdown_get_conf "NETWORK_LOCKDOWN_POLICY" "drop")
    allow_local=$(network_lockdown_get_conf "NETWORK_LOCKDOWN_ALLOW_LOCALHOST" "true")
    case "$policy" in
        drop|reject) ;;
        *) echo "ERROR: invalid NETWORK_LOCKDOWN_POLICY: $policy" >&2; return 1 ;;
    esac
    cat <<EOF
table inet ${NETWORK_LOCKDOWN_TABLE} {
    chain input {
        type filter hook input priority -100; policy ${policy};
        ct state established,related accept
EOF
    if [[ "$allow_local" == "true" || "$allow_local" == "1" || "$allow_local" == "yes" || "$allow_local" == "on" ]]; then
        cat <<'EOF'
        iifname "lo" accept
EOF
    fi
    cat <<EOF
    }

    chain forward {
        type filter hook forward priority -100; policy ${policy};
    }

    chain output {
        type filter hook output priority -100; policy ${policy};
        ct state established,related accept
EOF
    if [[ "$allow_local" == "true" || "$allow_local" == "1" || "$allow_local" == "yes" || "$allow_local" == "on" ]]; then
        cat <<'EOF'
        oifname "lo" accept
EOF
    fi
    cat <<EOF
    }
}
EOF
}

network_lockdown_validate() {
    network_lockdown_require_nft || return 1
    network_lockdown_generate | nft -c -f - >/dev/null 2>&1
}

network_lockdown_apply() {
    network_lockdown_require_root || return 1
    network_lockdown_require_nft || return 1
    if ! network_lockdown_enabled; then
        echo "disabled"
        return 0
    fi
    if ! network_lockdown_validate; then
        echo "ERROR: nftables validation failed" >&2
        return 1
    fi
    network_lockdown_generate | nft -f - >/dev/null 2>&1
    if declare -F emit_audit_event >/dev/null 2>&1; then
        emit_audit_event "network-lockdown" "apply" "success" "table=${NETWORK_LOCKDOWN_TABLE}"
    fi
    echo "applied"
}

network_lockdown_stop() {
    network_lockdown_require_root || return 1
    network_lockdown_require_nft || return 1
    nft delete table inet "${NETWORK_LOCKDOWN_TABLE}" 2>/dev/null || true
    if declare -F emit_audit_event >/dev/null 2>&1; then
        emit_audit_event "network-lockdown" "stop" "success" "table=${NETWORK_LOCKDOWN_TABLE}"
    fi
    echo "stopped"
}

network_lockdown_status_json() {
    local active="false"
    if command -v nft >/dev/null 2>&1 && nft list table inet "${NETWORK_LOCKDOWN_TABLE}" >/dev/null 2>&1; then
        active="true"
    fi
    python3 - "$active" <<'PY'
import json
import sys
from datetime import datetime, timezone
active = sys.argv[1] == "true"
print(json.dumps({
    "schema": "usbguard.network-lockdown.v1",
    "timestamp": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "table": "inet usbguard_lockdown",
    "active": active,
}, ensure_ascii=False, sort_keys=True))
PY
}

network_lockdown_status() {
    network_lockdown_status_json
}
