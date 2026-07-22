from __future__ import annotations
import fcntl, json, shutil
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Dict, List, Optional
from .models import DeviceRecord, now_iso

class PolicyStore:
    def __init__(self, path: str, backup_dir: str, keep_backups: int = 10, lock_path: Optional[str] = None):
        self.path = Path(path); self.backup_dir = Path(backup_dir); self.keep_backups = keep_backups
        self.lock_path = Path(lock_path or self.path.with_suffix(".lock"))
        self.path.parent.mkdir(parents=True, exist_ok=True); self.backup_dir.mkdir(parents=True, exist_ok=True); self.lock_path.parent.mkdir(parents=True, exist_ok=True)
    def _default_data(self) -> Dict[str, Any]:
        return {"version": 1, "meta": {}, "devices": {}}
    @contextmanager
    def _lock(self):
        with open(self.lock_path, "a", encoding="utf-8") as f:
            fcntl.flock(f.fileno(), fcntl.LOCK_EX)
            try: yield
            finally: fcntl.flock(f.fileno(), fcntl.LOCK_UN)
    def _load_unlocked(self) -> Dict[str, Any]:
        if not self.path.exists(): return self._default_data()
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
            if not isinstance(data, dict): raise ValueError("not dict")
            data.setdefault("version",1); data.setdefault("meta",{}); data.setdefault("devices",{}); return data
        except Exception:
            corrupt = self.path.with_suffix(".corrupt")
            try: self.path.replace(corrupt)
            except Exception: pass
            return self._default_data()
    def _backup_unlocked(self) -> None:
        if not self.path.exists(): return
        ts = now_iso().replace(":","").replace("+00:00","Z")
        backup_path = self.backup_dir / f"policy-{ts}.json"
        shutil.copy2(self.path, backup_path); self._prune_backups()
    def _prune_backups(self) -> None:
        backups = sorted(self.backup_dir.glob("policy-*.json"), key=lambda p: p.stat().st_mtime, reverse=True)
        for old in backups[self.keep_backups:]:
            try: old.unlink()
            except Exception: pass
    def _save_unlocked(self, data: Dict[str, Any]) -> None:
        self._backup_unlocked()
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False, sort_keys=True), encoding="utf-8")
        tmp.chmod(0o600); tmp.replace(self.path)
    def load(self) -> Dict[str, Any]:
        with self._lock(): return self._load_unlocked()
    def save(self, data: Dict[str, Any]) -> None:
        with self._lock(): self._save_unlocked(data)
    def upsert_device(self, device: DeviceRecord) -> DeviceRecord:
        with self._lock():
            data = self._load_unlocked()
            existing_raw = data["devices"].get(device.fingerprint)
            if existing_raw:
                existing = DeviceRecord.from_dict(existing_raw)
                device.first_seen = existing.first_seen or device.first_seen or now_iso()
                # Merge flags from existing and new, preserving all flags from both
                merged_flags = list(set(existing.flags + device.flags))
                device.flags = sorted(merged_flags)
                # Preserve existing metadata that shouldn't be overwritten
                if existing.risk_score > device.risk_score:
                    device.risk_score = existing.risk_score
                if existing.state in ("quarantined", "denied") and device.state not in ("quarantined", "denied"):
                    # Don't downgrade quarantined/denied state without explicit action
                    device.state = existing.state
            else:
                device.first_seen = device.first_seen or now_iso()
            device.last_seen = now_iso()
            data["devices"][device.fingerprint] = device.to_dict()
            self._save_unlocked(data); return device
    def get_device(self, fingerprint: str) -> Optional[DeviceRecord]:
        with self._lock():
            data = self._load_unlocked()
            raw = data["devices"].get(fingerprint)
            return DeviceRecord.from_dict(raw) if raw else None
    def get_device_by_any(self, key: str) -> Optional[DeviceRecord]:
        with self._lock():
            data = self._load_unlocked()
            if key in data["devices"]: return DeviceRecord.from_dict(data["devices"][key])
            for raw in data["devices"].values():
                device = DeviceRecord.from_dict(raw)
                if (device.fingerprint.startswith(key) or (device.hash and device.hash.startswith(key)) or (device.serial and device.serial == key)):
                    return device
            return None
    def list_devices(self, state: Optional[str] = None) -> List[DeviceRecord]:
        with self._lock():
            data = self._load_unlocked()
            devices = [DeviceRecord.from_dict(raw) for raw in data["devices"].values()]
        if state: devices = [d for d in devices if d.state == state]
        return sorted(devices, key=lambda d: d.last_seen or "", reverse=True)
    def set_state(self, fingerprint: str, state: str, actor: str = "system", reason: str = "", extra: Optional[Dict[str, Any]] = None) -> bool:
        with self._lock():
            data = self._load_unlocked()
            raw = data["devices"].get(fingerprint)
            if not raw: return False
            device = DeviceRecord.from_dict(raw); device.state = state
            if extra:
                for k,v in extra.items():
                    if hasattr(device,k): setattr(device,k,v)
            if reason: device.add_flag(reason)
            data["devices"][fingerprint] = device.to_dict(); self._save_unlocked(data); return True
    def find_by_attributes(self, vid_pid: Optional[str] = None, serial: Optional[str] = None, via_port: Optional[str] = None, hash_: Optional[str] = None) -> Optional[DeviceRecord]:
        with self._lock():
            data = self._load_unlocked()
            candidates = []
            for raw in data["devices"].values():
                device = DeviceRecord.from_dict(raw); score=0
                if hash_ and device.hash and device.hash==hash_: score+=100
                if vid_pid and device.vid_pid and device.vid_pid==vid_pid: score+=10
                if serial and device.serial and device.serial==serial: score+=20
                if via_port and device.via_port and device.via_port==via_port: score+=5
                if score>0: candidates.append((score,device))
            if not candidates: return None
            candidates.sort(key=lambda item: item[0], reverse=True); return candidates[0][1]
    def meta_get(self, key: str, default: Any = None) -> Any:
        with self._lock(): return self._load_unlocked()["meta"].get(key, default)
    def meta_set(self, key: str, value: Any) -> None:
        with self._lock():
            data=self._load_unlocked(); data["meta"][key]=value; self._save_unlocked(data)
