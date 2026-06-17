#!/usr/bin/env python3
"""
Telemetry helpers for USBGuard services.

The module keeps Python services aligned with the shell telemetry layer:
structured JSON audit events, Prometheus-style text metrics, and safe logging
configuration. It is intentionally dependency-free so it can run on minimal
Ubuntu LTS hosts without extra packages.
"""

from __future__ import annotations

import json
import logging
import os
import time
from pathlib import Path
from typing import Any, Dict, Iterable, Mapping, Optional


class JsonFormatter(logging.Formatter):
    """Formatter that writes log records as JSON lines."""

    def format(self, record: logging.LogRecord) -> str:
        payload: Dict[str, Any] = {
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(record.created)),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        for key, value in getattr(record, "telemetry", {}).items():
            payload[key] = value
        return json.dumps(payload, ensure_ascii=False, sort_keys=True)


def setup_logging(
    log_file: str,
    level: int = logging.INFO,
    stream: bool = True,
) -> logging.Logger:
    """Configure a JSON logger for daemon execution."""
    logger = logging.getLogger("usbguard-telemetry")
    logger.setLevel(level)
    logger.propagate = False

    if any(isinstance(handler, logging.FileHandler) and getattr(handler, "baseFilename", None) == log_file for handler in logger.handlers):
        return logger

    try:
        Path(log_file).parent.mkdir(parents=True, exist_ok=True)
        file_handler = logging.FileHandler(log_file)
        file_handler.setFormatter(JsonFormatter())
        file_handler.setLevel(level)
        logger.addHandler(file_handler)
    except Exception as exc:
        logging.getLogger(__name__).debug("Cannot configure telemetry file handler: %s", exc)

    if stream:
        stream_handler = logging.StreamHandler()
        stream_handler.setFormatter(JsonFormatter())
        stream_handler.setLevel(level)
        logger.addHandler(stream_handler)

    return logger


def _read_env(name: str, default: str) -> str:
    return os.environ.get(name, default)


def emit_event(
    component: str,
    action: str,
    status: str,
    *,
    actor: Optional[str] = None,
    correlation_id: Optional[str] = None,
    source_ip: Optional[str] = None,
    labels: Optional[Mapping[str, Any]] = None,
    log_file: Optional[str] = None,
) -> None:
    """Append one structured audit event to a JSONL file."""
    try:
        audit_log = log_file or _read_env("USBGUARD_AUDIT_LOG", "/var/log/usbguard-approval-audit.jsonl")
        Path(audit_log).parent.mkdir(parents=True, exist_ok=True)

        payload = {
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "schema": "usbguard.audit.v1",
            "component": component,
            "action": action,
            "status": status,
            "actor": actor or os.environ.get("SUDO_USER") or os.environ.get("USER") or "unknown",
            "correlation_id": correlation_id or os.environ.get("USBGUARD_CORRELATION_ID", "local"),
            "source_ip": source_ip or os.environ.get("REMOTE_ADDR") or "local",
            "labels": dict(labels or {}),
        }
        with open(audit_log, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n")
    except Exception as exc:
        logging.getLogger(__name__).debug("Cannot emit telemetry event: %s", exc)


def record_metric(
    component: str,
    metric: str,
    value: float,
    *,
    labels: Optional[Mapping[str, Any]] = None,
    metrics_file: Optional[str] = None,
) -> None:
    """Append a Prometheus-compatible sample to a text metrics file."""
    try:
        metrics_path = metrics_file or _read_env("USBGUARD_METRICS_FILE", "/var/log/usbguard-approval.prom")
        Path(metrics_path).parent.mkdir(parents=True, exist_ok=True)

        label_items: Iterable[str]
        if labels:
            label_items = (f'{key}="{str(value).replace(chr(34), chr(92) + chr(34))}"' for key, value in labels.items())
        else:
            label_items = ()
        label_text = ",".join(label_items)
        labels_text = f'component="{component}"'
        if label_items:
            labels_text = f'{labels_text},{label_text}'

        with open(metrics_path, "a", encoding="utf-8") as handle:
            handle.write(f"{int(time.time())} {metric}{{{labels_text}}} {value}\n")
    except Exception as exc:
        logging.getLogger(__name__).debug("Cannot record telemetry metric: %s", exc)
