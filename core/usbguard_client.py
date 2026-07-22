from __future__ import annotations
import re, subprocess
from typing import List
from .models import DeviceRecord, fingerprint_device

class UsbguardError(RuntimeError): pass

class USBGuardClient:
    def __init__(self, binary: str = "/usr/bin/usbguard"):
        self.binary = binary
    def _run(self, args: List[str], check: bool = True) -> subprocess.CompletedProcess:
        cmd = [self.binary] + args
        proc = subprocess.run(cmd, text=True, capture_output=True, check=False)
        if check and proc.returncode != 0:
            raise UsbguardError(f"Command failed: {' '.join(cmd)}\nstdout: {proc.stdout.strip()}\nstderr: {proc.stderr.strip()}")
        return proc
    def list_devices(self) -> List[DeviceRecord]:
        proc = self._run(["list-devices"], check=False)
        return self._parse_listing(proc.stdout)
    def list_rules(self) -> List[DeviceRecord]:
        proc = self._run(["list-rules"], check=False)
        return self._parse_listing(proc.stdout)
    def append_rule(self, rule: str) -> None:
        self._run(["append-rule", rule])
    def remove_rule(self, rule_id: int) -> None:
        self._run(["remove-rule", str(rule_id)])
    def set_parameter(self, name: str, value: str) -> None:
        self._run(["set-parameter", name, value])
    def get_parameter(self, name: str) -> str:
        proc = self._run(["get-parameter", name], check=False)
        return proc.stdout.strip()
    def allow_device(self, device_id: int) -> bool:
        proc = self._run(["allow-device", str(device_id)], check=False)
        return proc.returncode == 0
    def _parse_listing(self, text: str) -> List[DeviceRecord]:
        records: List[DeviceRecord] = []
        line_re = re.compile(r"^\s*(\d+):\s+(allow|block|reject)\s+(.*)$")
        for line in text.splitlines():
            m = line_re.match(line)
            if not m: continue
            rule_id = int(m.group(1)); target = m.group(2); spec = m.group(3).strip()
            record = self._parse_spec(spec)
            if not record: continue
            record.observed_rule_id = rule_id; record.observed_target = target; record.raw_spec = spec
            records.append(record)
        return records
    def _parse_spec(self, spec: str) -> DeviceRecord | None:
        vid_pid = self._search(r"id\s+([0-9a-fA-F]{4}:[0-9a-fA-F]{4})", spec)
        serial = self._search(r'serial\s+"([^"]*)"', spec)
        hash_ = self._search(r'hash\s+"([^"]*)"', spec)
        parent_hash = self._search(r'parent-hash\s+"([^"]*)"', spec)
        via_port = self._search(r'via-port\s+"([^"]*)"', spec)
        name = self._search(r'name\s+"([^"]*)"', spec)
        interfaces = []
        m = re.search(r"with-interface\s*\{([^}]*)\}", spec)
        if m: interfaces = m.group(1).split()
        if not any([vid_pid, serial, hash_, parent_hash, interfaces]): return None
        fingerprint = fingerprint_device(hash_=hash_, vid_pid=vid_pid, serial=serial, parent_hash=parent_hash, interfaces=interfaces, via_port=via_port)
        return DeviceRecord(fingerprint=fingerprint, vid_pid=vid_pid, serial=serial, hash=hash_, parent_hash=parent_hash, via_port=via_port, interfaces=interfaces, name=name)
    @staticmethod
    def _search(pattern: str, text: str) -> str:
        import re
        m = re.search(pattern, text)
        return m.group(1) if m else ""
