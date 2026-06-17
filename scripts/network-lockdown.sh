#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
source "${LIB_DIR}/config-reader.sh" 2>/dev/null || true
source "${LIB_DIR}/logger.sh" 2>/dev/null || true
source "${LIB_DIR}/telemetry.sh" 2>/dev/null || true

source "${LIB_DIR}/network-lockdown.sh" 2>/dev/null || {
    echo "ERROR: Cannot load network-lockdown library" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: network-lockdown.sh [start|stop|reload|status|validate]
EOF
}

main() {
    local action="${1:-status}"
    case "$action" in
        start|apply)
            network_lockdown_apply
            ;;
        stop|destroy)
            network_lockdown_stop
            ;;
        reload)
            network_lockdown_stop >/dev/null
            network_lockdown_apply
            ;;
        status)
            network_lockdown_status
            ;;
        validate)
            if network_lockdown_validate; then
                echo "valid"
            else
                echo "invalid" >&2
                exit 1
            fi
            ;;
        --help|-h)
            usage
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
}

main "$@"
