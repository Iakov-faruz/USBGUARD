from __future__ import annotations
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, Optional
import yaml

DEFAULT_CONFIG_PATH = "/etc/usbguard/protector.yaml"
LEGACY_CONFIG_PATH = "/etc/usbguard/approval-manager.conf"

@dataclass
class IdentityConfig:
    required: list[str] = field(default_factory=lambda: ["interfaces"])
    recommended: list[str] = field(default_factory=lambda: ["hash", "serial", "parent_hash", "via_port"])
    allow_no_hw_hash: bool = True
    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "IdentityConfig":
        data = data or {}
        return cls(
            required=data.get("required", ["interfaces"]),
            recommended=data.get("recommended", ["hash", "serial", "parent_hash", "via_port"]),
            allow_no_hw_hash=bool(data.get("allow_no_hw_hash", True)),
        )

@dataclass
class PortPolicyConfig:
    strict: bool = False
    mismatch_action: str = "review"
    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "PortPolicyConfig":
        data = data or {}
        return cls(strict=bool(data.get("strict", False)), mismatch_action=str(data.get("mismatch_action", "review")))

@dataclass
class CompositeConfig:
    reject_hid_mass_storage: bool = True
    reject_hid_cdc: bool = True
    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "CompositeConfig":
        data = data or {}
        return cls(reject_hid_mass_storage=bool(data.get("reject_hid_mass_storage", True)), reject_hid_cdc=bool(data.get("reject_hid_cdc", True)))

@dataclass
class Thresholds:
    eps_threshold: float = 20.0
    window_seconds: float = 1.0
    burst_chars: int = 30
    burst_window_seconds: float = 0.5
    low_variance_ms: float = 15.0
    immediate_typing_ms: int = 700
    cooldown_seconds: float = 10.0
    min_events_for_decision: int = 12
    on_unknown_suspicious: str = "alert_only"
    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "Thresholds":
        data = data or {}
        valid = set(cls.__dataclass_fields__.keys())
        return cls(**{k: v for k, v in data.items() if k in valid})

@dataclass
class Config:
    usbguard_binary: str
    data_dir: str
    config_dir: str
    log_dir: str
    run_dir: str
    policy_store_file: str
    backup_dir: str
    audit_file: str
    lock_file: str
    keep_backups: int
    identity: IdentityConfig
    port_policy: PortPolicyConfig
    composite: CompositeConfig
    thresholds: Thresholds

    @classmethod
    def load(cls, path: str | None = None) -> "Config":
        config_path = Path(path or DEFAULT_CONFIG_PATH)
        data: Dict[str, Any] = {}
        if config_path.exists():
            data = yaml.safe_load(config_path.read_text(encoding="utf-8")) or {}
        paths = data.get("paths", {})
        data_dir = paths.get("data_dir", "/var/lib/usbguard-manager")
        config_dir = paths.get("config_dir", "/etc/usbguard")
        log_dir = paths.get("log_dir", "/var/log/usbguard")
        run_dir = paths.get("run_dir", "/run/usbguard-manager")
        policy_store_file = paths.get("policy_store_file", f"{data_dir}/policy.json")
        backup_dir = paths.get("backup_dir", f"{data_dir}/backups")
        audit_file = paths.get("audit_file", f"{log_dir}/usbguard-approval-audit.jsonl")
        lock_file = paths.get("lock_file", f"{run_dir}/policy.lock")
        thresholds_file = data.get("thresholds_file", f"{config_dir}/thresholds.yaml")
        thresholds_data: Dict[str, Any] = {}
        thresholds_path = Path(thresholds_file)
        if thresholds_path.exists():
            thresholds_data = yaml.safe_load(thresholds_path.read_text(encoding="utf-8")) or {}
        return cls(
            usbguard_binary=data.get("usbguard_binary", "/usr/bin/usbguard"),
            data_dir=data_dir, config_dir=config_dir, log_dir=log_dir, run_dir=run_dir,
            policy_store_file=policy_store_file, backup_dir=backup_dir,
            audit_file=audit_file, lock_file=lock_file,
            keep_backups=int(data.get("keep_backups", 20)),
            identity=IdentityConfig.from_dict(data.get("identity", {})),
            port_policy=PortPolicyConfig.from_dict(data.get("port_policy", {})),
            composite=CompositeConfig.from_dict(data.get("composite", {})),
            thresholds=Thresholds.from_dict(thresholds_data),
        )
    def ensure_dirs(self) -> None:
        for d in (self.data_dir, self.config_dir, self.log_dir, self.run_dir, self.backup_dir):
            Path(d).mkdir(parents=True, exist_ok=True)
