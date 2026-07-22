from __future__ import annotations
from typing import Any, Dict, Optional
from core.approver import Approver
from core.audit import AuditLogger
from core.config import Config
from core.policy_store import PolicyStore
from core.usbguard_client import USBGuardClient
from core.policy_sync import reload_daemon
from pathlib import Path

class Responder:
    def __init__(self, config: Config, store: PolicyStore, audit: AuditLogger):
        self.config=config; self.store=store; self.audit=audit
        self.client=USBGuardClient(config.usbguard_binary)
        self.approver=Approver(config, store, self.client, audit)
    def handle_suspicious(self, usb_info: Dict[str, Any], reason: str, metrics: Dict[str, float]) -> None:
        record=self.store.find_by_attributes(vid_pid=usb_info.get("vid_pid"), serial=usb_info.get("serial"), via_port=usb_info.get("via_port"))
        if record:
            try:
                self.approver.quarantine(record.fingerprint, actor="hid-monitor", reason=reason)
                self.audit.log("badusb_quarantine", actor="hid-monitor", fingerprint=record.fingerprint, reason=reason, metrics=metrics, usb_info=usb_info); return
            except Exception as e:
                self.audit.log("badusb_quarantine_failed", actor="hid-monitor", fingerprint=record.fingerprint, error=str(e)); return
        self.audit.log("badusb_unknown_suspicious", actor="hid-monitor", reason=reason, metrics=metrics, usb_info=usb_info)
        action=self.config.thresholds.on_unknown_suspicious
        if action=="lockdown":
            try:
                self.approver.lockdown_enable(actor="hid-monitor")
                # Reload daemon to enforce lockdown immediately
                rules_dir = str(Path(self.config.config_dir) / "rules.d")
                rules_file = str(Path(self.config.config_dir) / "rules.conf")
                reload_daemon(rules_dir, rules_file)
                self.audit.log("hid_monitor_lockdown_with_reload", actor="hid-monitor")
            except Exception as e:
                self.audit.log("hid_monitor_lockdown_failed", error=str(e))
        elif action=="block":
            # Block unknown suspicious devices - create reject rule via composite
            try:
                from core.rules_renderer import render_reject
                from core.models import DeviceRecord, fingerprint_device
                vid_pid = usb_info.get("vid_pid", "")
                serial = usb_info.get("serial", "")
                via_port = usb_info.get("via_port", "")
                fp = fingerprint_device(vid_pid=vid_pid, serial=serial, via_port=via_port)
                device = DeviceRecord(fingerprint=fp, vid_pid=vid_pid, serial=serial, via_port=via_port)
                reject_rule = render_reject(device)
                self.client.append_rule(reject_rule)
                self.audit.log("badusb_blocked_unknown", actor="hid-monitor", reason=reason, usb_info=usb_info, rule=reject_rule)
            except Exception as e:
                self.audit.log("badusb_block_failed", error=str(e))
        # action == "alert_only": already logged above, do nothing else
