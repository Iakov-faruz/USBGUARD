from __future__ import annotations
import hashlib, json
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()

def fingerprint_device(hash_: str = "", vid_pid: str = "", serial: str = "", parent_hash: str = "", interfaces: Optional[List[str]] = None, via_port: str = "") -> str:
    if hash_:
        return f"hash:{hash_}"
    material = json.dumps({"vid_pid": vid_pid, "serial": serial, "parent_hash": parent_hash, "interfaces": sorted(interfaces or []), "via_port": via_port}, sort_keys=True)
    digest = hashlib.sha256(material.encode("utf-8")).hexdigest()
    return f"sha256:{digest}"

@dataclass
class DeviceRecord:
    fingerprint: str
    vid_pid: str = ""
    serial: str = ""
    hash: str = ""
    parent_hash: str = ""
    via_port: str = ""
    interfaces: List[str] = field(default_factory=list)
    name: str = ""
    state: str = "new"
    first_seen: str = ""
    last_seen: str = ""
    approved_by: str = ""
    approved_at: str = ""
    expires_at: str = ""
    risk_score: int = 0
    flags: List[str] = field(default_factory=list)
    observed_rule_id: Optional[int] = None
    observed_target: str = ""
    raw_spec: str = ""
    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)
    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "DeviceRecord":
        valid = set(cls.__dataclass_fields__.keys())
        return cls(**{k: v for k, v in data.items() if k in valid})
    def add_flag(self, flag: str) -> None:
        if flag not in self.flags:
            self.flags.append(flag)
