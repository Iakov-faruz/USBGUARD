from __future__ import annotations
import sys, threading, time
from pathlib import Path
from typing import Any, Dict, Optional
from core.audit import AuditLogger
from core.config import Config
from core.policy_store import PolicyStore
from detection.keystroke_stats import KeystrokeStats
from detection.responder import Responder

try:
    from evdev import InputDevice, ecodes, list_devices
except Exception:
    InputDevice=None; ecodes=None; list_devices=None

class HidMonitor:
    def __init__(self, config: Config, store: PolicyStore, audit: AuditLogger, responder: Responder):
        self.config=config; self.store=store; self.audit=audit; self.responder=responder
        self.known: Dict[str, dict] = {}
        self.lock = threading.Lock()
    def run(self) -> None:
        self.audit.log("hid_monitor_start")
        if InputDevice is None or list_devices is None:
            self.audit.log("hid_monitor_missing_evdev"); raise RuntimeError("python3-evdev is not installed")
        while True:
            try: self.scan_once()
            except Exception as e: self.audit.log("hid_monitor_scan_error", error=str(e))
            time.sleep(2)
    def scan_once(self) -> None:
        try: paths=set(list_devices())
        except Exception as e:
            self.audit.log("evdev_list_error", error=str(e)); paths=set()
        with self.lock:
            for path in list(self.known.keys()):
                if path not in paths:
                    info=self.known.pop(path, None)
                    if info:
                        try:
                            info["stop"] = True
                            info["thread"].join(timeout=1)
                        except Exception: pass
                        self.audit.log("hid_monitor_device_removed", path=path)
        for path in paths:
            with self.lock:
                thread_info=self.known.get(path)
                if thread_info and thread_info["thread"].is_alive(): continue
            self.start_device(path)
    def start_device(self, path: str) -> None:
        usb_info=get_usb_info(path); stats=KeystrokeStats(self.config.thresholds)
        stop_flag={"stop": False}
        thread=threading.Thread(target=self._read_loop, args=(path, usb_info, stats, stop_flag), daemon=True)
        thread.start()
        with self.lock: self.known[path]={"thread":thread, "stop":stop_flag, "usb_info":usb_info}
        self.audit.log("hid_monitor_device_attached", path=path, usb_info=usb_info)
    def _read_loop(self, path: str, usb_info: Dict[str, Any], stats: KeystrokeStats, stop_flag: dict) -> None:
        try:
            device=InputDevice(path)
            for event in device.read_loop():
                if stop_flag.get("stop"): break
                if event.type!=ecodes.EV_KEY: continue
                if event.value!=1: continue
                ts=time.monotonic(); stats.add(ts)
                trigger,reason,metrics=stats.should_trigger(ts)
                if trigger:
                    self.responder.handle_suspicious(usb_info, reason, metrics); stats.reset()
        except Exception as e:
            if not stop_flag.get("stop"):
                self.audit.log("hid_monitor_read_error", path=path, error=str(e))

def _read_sysfs(path: Path) -> str:
    try: return path.read_text(encoding="utf-8").strip()
    except Exception: return ""

def get_usb_info(event_path: str) -> Dict[str, Any]:
    info: Dict[str, Any] = {"event_path":event_path,"vid_pid":"","serial":"","via_port":"","sysfs_path":""}
    event_name=Path(event_path).name
    sys_input=Path("/sys/class/input") / event_name / "device"
    if not sys_input.exists(): return info
    try: current=sys_input.resolve()
    except Exception: return info
    for _ in range(15):
        vendor=_read_sysfs(current / "idVendor"); product=_read_sysfs(current / "idProduct")
        if vendor and product:
            vid_pid=f"{vendor}:{product}"; serial=_read_sysfs(current / "serial")
            busnum=_read_sysfs(current / "busnum"); devpath=_read_sysfs(current / "devpath")
            via_port=f"{busnum}-{devpath}" if busnum and devpath else ""
            info.update({"vid_pid":vid_pid,"serial":serial,"via_port":via_port,"sysfs_path":str(current)}); break
        if current.parent==current: break
        current=current.parent
    return info

def run_cli(config_path: Optional[str] = None) -> None:
    config=Config.load(config_path); config.ensure_dirs()
    store=PolicyStore(path=config.policy_store_file, backup_dir=config.backup_dir, keep_backups=config.keep_backups, lock_path=config.lock_file)
    audit=AuditLogger(config.audit_file); responder=Responder(config, store, audit); monitor=HidMonitor(config, store, audit, responder); monitor.run()

if __name__=="__main__":
    config_path=sys.argv[1] if len(sys.argv)>1 else None
    run_cli(config_path)
