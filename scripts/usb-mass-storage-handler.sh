#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# USBGuard Mass Storage Handler - Production Ready
# Triggered by udev when a USB mass storage device is added.
# ==============================================================================

DEVK="${1:-unknown}"
DEVNAME="${2:-unknown}"
VENDOR_ID="${3:-}"
MODEL_ID="${4:-}"

readonly FORBIDDEN_CHARS='[$`;|&<>(){}\[\]!]'

sanitize_input() {
    local val="$1"
    if [[ "$val" =~ $FORBIDDEN_CHARS ]]; then
        logger -t usbguard-mass-storage "ERROR: Dangerous characters detected in arguments. Aborting."
        exit 1
    fi
}

sanitize_input "$DEVK"
sanitize_input "$DEVNAME"
[ -n "$VENDOR_ID" ] && sanitize_input "$VENDOR_ID"
[ -n "$MODEL_ID" ] && sanitize_input "$MODEL_ID"

logger -t usbguard-mass-storage "USB mass storage device added: $DEVNAME (kernel name: $DEVK, ID: ${VENDOR_ID}:${MODEL_ID})"

# Auto-block mass storage devices via the canonical approval path.
# Uses VID:PID from udev directly to avoid lsusb race conditions.
if [[ -n "$VENDOR_ID" && -n "$MODEL_ID" ]]; then
    local vidpid="${VENDOR_ID}:${MODEL_ID}"
    logger -t usbguard-mass-storage "Enforcing auto-block rule for mass storage device: ${vidpid}"

    if [[ -x "/etc/usbguard/scripts/usb-approve.sh" ]]; then
        /etc/usbguard/scripts/usb-approve.sh --vidpid "$vidpid" --block || \
            logger -t usbguard-mass-storage "WARN: usb-approve.sh returned non-zero status"
    else
        logger -t usbguard-mass-storage "ERROR: /etc/usbguard/scripts/usb-approve.sh not found or not executable"
    fi
fi

exit 0
