from __future__ import annotations
from typing import List
from .config import Config
from .models import DeviceRecord

def _quote(value: str) -> str:
    escaped = value.replace('"', r"\"")
    return f'"{escaped}"'

def render_rule(device: DeviceRecord, target: str) -> str:
    parts = [target]
    if device.vid_pid: parts.append(f"id {device.vid_pid}")
    if device.serial: parts.append(f"serial {_quote(device.serial)}")
    if device.hash: parts.append(f"hash {_quote(device.hash)}")
    if device.parent_hash: parts.append(f"parent-hash {_quote(device.parent_hash)}")
    if device.via_port: parts.append(f"via-port {_quote(device.via_port)}")
    if device.interfaces:
        interfaces = " ".join(device.interfaces)
        parts.append(f"with-interface {{ {interfaces} }}")
    if len(parts) == 1:
        raise ValueError("Cannot render rule: device has no identifying attributes")
    return " ".join(parts)

def render_allow(device: DeviceRecord) -> str:
    return render_rule(device, "allow")

def render_reject(device: DeviceRecord) -> str:
    return render_rule(device, "reject")

def composite_reject_rules(config: Config) -> List[str]:
    rules: List[str] = []
    if config.composite.reject_hid_mass_storage:
        rules.extend(["reject with-interface { 03:01:01 08:06:50 }","reject with-interface { 03:01:02 08:06:50 }","reject with-interface { 03:00:00 08:06:50 }"])
    if config.composite.reject_hid_cdc:
        rules.extend(["reject with-interface { 03:01:01 02:02:01 }","reject with-interface { 03:01:02 02:02:01 }"])
    return rules
