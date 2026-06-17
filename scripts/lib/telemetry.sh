#!/usr/bin/env bash
# ==============================================================================
# USBGuard Approval Manager - Telemetry Library
# ==============================================================================
# ספריית תצפיתיות מרכזית לרישום אירועי ביקורת מובנים ומדדים קלים לצריכה.
# המטרה היא להפריד את כתיבת הלוג העסקי מהסקריפטים השונים, לאפשר audit trail
# יציב ל-JSONL, ולאפשר ייצוא עתידי ל-Prometheus/ELK ללא שינוי בקוד העסקי.
# ==============================================================================

if [[ "${TELEMETRY_LOADED:-0}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi
TELEMETRY_LOADED=1

readonly TELEMETRY_DEFAULT_AUDIT_LOG="/var/log/usbguard-approval-audit.jsonl"
readonly TELEMETRY_DEFAULT_METRICS_LOG="/var/log/usbguard-approval.prom"

# ─── תצורה גלובלית ───────────────────────────────────────────────────────────
TELEMETRY_ENABLED="${TELEMETRY_ENABLED:-true}"
TELEMETRY_AUDIT_FILE="${TELEMETRY_AUDIT_FILE:-}"
TELEMETRY_METRICS_FILE="${TELEMETRY_METRICS_FILE:-}"
TELEMETRY_CORRELATION_ID="${USBGUARD_CORRELATION_ID:-}"
TELEMETRY_SOURCE_IP="${USBGUARD_SOURCE_IP:-${REMOTE_ADDR:-local}}"

# ─── אתחול תצורה מהקונפיגורציה ──────────────────────────────────────────────
_telemetry_load_config() {
    local config_file="${1:-/etc/usbguard/approval-manager.conf}"

    if declare -F get_conf >/dev/null 2>&1; then
        TELEMETRY_ENABLED=$(get_conf "TELEMETRY_ENABLED" "$config_file" 2>/dev/null || echo "$TELEMETRY_ENABLED")
        TELEMETRY_AUDIT_FILE=$(get_conf "AUDIT_LOG_FILE" "$config_file" 2>/dev/null || echo "$TELEMETRY_AUDIT_FILE")
        TELEMETRY_METRICS_FILE=$(get_conf "METRICS_FILE" "$config_file" 2>/dev/null || echo "$TELEMETRY_METRICS_FILE")
    fi

    TELEMETRY_AUDIT_FILE="${TELEMETRY_AUDIT_FILE:-$TELEMETRY_DEFAULT_AUDIT_LOG}"
    TELEMETRY_METRICS_FILE="${TELEMETRY_METRICS_FILE:-$TELEMETRY_DEFAULT_METRICS_LOG}"
    TELEMETRY_ENABLED="${TELEMETRY_ENABLED:-true}"
}

# ─── מזהה קורלציה ───────────────────────────────────────────────────────────
telemetry_correlation_id() {
    if [[ -z "$TELEMETRY_CORRELATION_ID" ]]; then
        if [[ -r /proc/sys/kernel/random/uuid ]]; then
            TELEMETRY_CORRELATION_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || date '+%s')
        else
            TELEMETRY_CORRELATION_ID="$(date '+%s')-$$"
        fi
        export USBGUARD_CORRELATION_ID="$TELEMETRY_CORRELATION_ID"
    fi

    printf '%s' "$TELEMETRY_CORRELATION_ID"
}

# ─── זהות מבצע ──────────────────────────────────────────────────────────────
telemetry_actor() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        printf '%s' "$SUDO_USER"
    elif [[ -n "${USER:-}" ]]; then
        printf '%s' "$USER"
    elif [[ -n "${LOGNAME:-}" ]]; then
        printf '%s' "$LOGNAME"
    else
        whoami 2>/dev/null || printf 'unknown'
    fi
}

# ─── כתיבת אירוע audit כ-JSON line ─────────────────────────────────────────
emit_audit_event() {
    local component="$1"
    local action="$2"
    local status="$3"
    shift 3 || true

    _telemetry_load_config

    if [[ "$TELEMETRY_ENABLED" != "true" && "$TELEMETRY_ENABLED" != "1" && "$TELEMETRY_ENABLED" != "yes" ]]; then
        return 0
    fi

    local actor correlation_id timestamp details
    actor=$(telemetry_actor)
    correlation_id=$(telemetry_correlation_id)
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')
    details="$*"

    local log_dir
    log_dir=$(dirname "$TELEMETRY_AUDIT_FILE" 2>/dev/null || echo "/var/log")
    mkdir -p "$log_dir" 2>/dev/null || return 0

    python3 - "$component" "$actor" "$action" "$status" "$correlation_id" "$TELEMETRY_SOURCE_IP" "$details" <<'PY' >> "$TELEMETRY_AUDIT_FILE" 2>/dev/null || true
import json
import sys
from datetime import datetime, timezone

component, actor, action, status, correlation_id, source_ip, details = sys.argv[1:]
labels = {}
for item in details.split():
    if "=" not in item:
        continue
    key, value = item.split("=", 1)
    labels[key] = value

payload = {
    "timestamp": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "schema": "usbguard.audit.v1",
    "component": component,
    "actor": actor,
    "action": action,
    "status": status,
    "correlation_id": correlation_id,
    "source_ip": source_ip,
    "labels": labels,
}
print(json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
PY
}

# ─── כתיבת מדד טקסטואלי תואם Prometheus ────────────────────────────────────
record_metric() {
    local component="$1"
    local metric="$2"
    local value="$3"
    shift 3 || true

    _telemetry_load_config

    if [[ "$TELEMETRY_ENABLED" != "true" && "$TELEMETRY_ENABLED" != "1" && "$TELEMETRY_ENABLED" != "yes" ]]; then
        return 0
    fi

    if [[ ! "$value" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        return 0
    fi

    local metric_dir labels
    metric_dir=$(dirname "$TELEMETRY_METRICS_FILE" 2>/dev/null || echo "/var/log")
    mkdir -p "$metric_dir" 2>/dev/null || return 0

    labels=""
    for item in "$@"; do
        if [[ "$item" =~ ^[a-zA-Z_][a-zA-Z0-9_]*=.*$ ]]; then
            local key="${item%%=*}"
            local value="${item#*=}"
            value="${value//\\/\\\\}"
            value="${value//\"/\\\"}"
            labels+=" ${key}=\"${value}\""
        fi
    done
    labels="${labels# }"

    printf '%s %s{component="%s"%s} %s\n' \
        "$(date +%s)" \
        "$metric" \
        "$component" \
        "${labels:+,$labels}" \
        "$value" >> "$TELEMETRY_METRICS_FILE" 2>/dev/null || true
    return 0
}

# ─── סיכום פעולה ────────────────────────────────────────────────────────────
emit_operation_result() {
    local component="$1"
    local action="$2"
    local status="$3"
    local duration_sec="${4:-0}"
    shift 4 || true

    emit_audit_event "$component" "$action" "$status" "duration_sec=$duration_sec" "$@"
    record_metric "$component" "usbguard_operation_duration_seconds" "$duration_sec" "action=$action" "status=$status" "$@"
    record_metric "$component" "usbguard_operation_total" 1 "action=$action" "status=$status" "$@"
}

_telemetry_load_config
