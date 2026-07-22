from __future__ import annotations
import signal, sys, threading, time
from dataclasses import dataclass, field
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


@dataclass
class DeviceSession:
    """Tracks the runtime state of a single monitored HID device."""
    thread: Optional[threading.Thread] = None
    stop_event: threading.Event = field(default_factory=threading.Event)
    device: Optional[InputDevice] = None
    usb_info: Dict[str, Any] = field(default_factory=dict)


@dataclass
class FailureState:
    """Tracks failure metrics for a device path (backoff + rate limiting)."""
    count: int = 0
    last_failure: float = 0.0
    last_log: float = 0.0


class HidMonitor:
    def __init__(self, config: Config, store: PolicyStore, audit: AuditLogger, responder: Responder):
        self.config = config
        self.store = store
        self.audit = audit
        self.responder = responder
        self.known: Dict[str, DeviceSession] = {}
        self.failures: Dict[str, FailureState] = {}
        self.lock = threading.Lock()
        self._shutdown = threading.Event()

    def run(self) -> None:
        self.audit.log("hid_monitor_start")
        if InputDevice is None or list_devices is None:
            self.audit.log("hid_monitor_missing_evdev")
            raise RuntimeError("python3-evdev is not installed")
        # Graceful shutdown on SIGTERM/SIGINT
        signal.signal(signal.SIGTERM, self._handle_signal)
        signal.signal(signal.SIGINT, self._handle_signal)
        while not self._shutdown.is_set():
            try:
                self.scan_once()
            except Exception as e:
                self.audit.log("hid_monitor_scan_error", error=str(e))
            self._shutdown.wait(timeout=2)
        self._cleanup_all()

    def _handle_signal(self, signum, frame):
        self.audit.log("hid_monitor_shutdown_signal", signal=signum)
        self._shutdown.set()

    def _cleanup_all(self) -> None:
        """Stop all device threads and close all InputDevice handles."""
        with self.lock:
            paths = list(self.known.keys())
        for path in paths:
            self._remove_device(path)
        self.audit.log("hid_monitor_stopped", devices_removed=len(paths))

    def scan_once(self) -> None:
        try:
            paths = set(list_devices())
        except Exception as e:
            self.audit.log("evdev_list_error", error=str(e))
            paths = set()

        # Collect removed paths while holding lock, remove after
        with self.lock:
            removed = [p for p in self.known if p not in paths]
        for path in removed:
            self._remove_device(path)

        # Start new devices (check backoff while holding lock, start after)
        to_start = []
        with self.lock:
            for path in paths:
                session = self.known.get(path)
                if session and session.thread and session.thread.is_alive():
                    continue
                # Check backoff: skip devices that have failed recently
                failure = self.failures.get(path)
                if failure and failure.count >= 5 and time.monotonic() - failure.last_failure < 30:
                    continue  # Backoff: skip for 30s after 5 consecutive failures
                to_start.append(path)
        for path in to_start:
            self.start_device(path)

    def _remove_device(self, path: str) -> None:
        """Stop a device thread and close its InputDevice handle."""
        with self.lock:
            session = self.known.pop(path, None)
        if session is None:
            return
        session.stop_event.set()
        # Close the device to break any blocking read_loop() immediately
        if session.device is not None:
            try:
                session.device.close()
            except Exception:
                pass
        if session.thread is not None:
            try:
                session.thread.join(timeout=2)
                if session.thread.is_alive():
                    self.audit.log("hid_monitor_thread_timeout", path=path)
            except Exception:
                pass
        self.audit.log("hid_monitor_device_removed", path=path)

    def start_device(self, path: str) -> None:
        usb_info = get_usb_info(path)
        stats = KeystrokeStats(self.config.thresholds)
        session = DeviceSession(
            thread=None,
            stop_event=threading.Event(),
            device=None,
            usb_info=usb_info,
        )
        thread = threading.Thread(target=self._read_loop, args=(path, usb_info, stats, session.stop_event), daemon=True)
        # Register session BEFORE starting thread to prevent race condition
        # where scan_once sees the path as untracked and starts a duplicate
        with self.lock:
            session.thread = thread
            self.known[path] = session
        thread.start()
        self.audit.log("hid_monitor_device_attached", path=path, usb_info=usb_info)

    def _read_loop(self, path: str, usb_info: Dict[str, Any], stats: KeystrokeStats, stop_event: threading.Event) -> None:
        device = None
        try:
            device = InputDevice(path)
            # Store device reference so _remove_device can close it
            with self.lock:
                session = self.known.get(path)
                if session:
                    session.device = device
            # Reset failure state after successful open
            failure = self.failures.get(path)
            if failure:
                failure.count = 0
                failure.last_failure = 0.0
            for event in device.read_loop():
                if stop_event.is_set():
                    break
                if event.type != ecodes.EV_KEY:
                    continue
                if event.value != 1:
                    continue
                # סינון כפתורי עכבר (BTN_LEFT=272 עד BTN_TASK=288)
                if 272 <= event.code <= 288:
                    continue
                ts = time.monotonic()
                stats.add(ts)
                trigger, reason, metrics = stats.should_trigger(ts)
                if trigger:
                    self.responder.handle_suspicious(usb_info, reason, metrics)
                    stats.reset()
        except Exception as e:
            if not stop_event.is_set():
                failure = self.failures.get(path)
                if failure is None:
                    failure = FailureState()
                    self.failures[path] = failure
                failure.count += 1
                failure.last_failure = time.monotonic()
                # Rate-limited error logging: only log once per path per 30 seconds
                if time.monotonic() - failure.last_log > 30:
                    self.audit.log("hid_monitor_read_error", path=path, error=str(e))
                    failure.last_log = time.monotonic()
        finally:
            if device is not None:
                try:
                    device.close()
                except Exception:
                    pass
            # Clean up from known dict if still present
            with self.lock:
                self.known.pop(path, None)


def _read_sysfs(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8").strip()
    except Exception:
        return ""


def get_usb_info(event_path: str) -> Dict[str, Any]:
    info: Dict[str, Any] = {"event_path": event_path, "vid_pid": "", "serial": "", "via_port": "", "sysfs_path": ""}
    event_name = Path(event_path).name
    sys_input = Path("/sys/class/input") / event_name / "device"
    if not sys_input.exists():
        return info
    try:
        current = sys_input.resolve()
    except Exception:
        return info
    while current != current.parent:
        vendor = _read_sysfs(current / "idVendor")
        product = _read_sysfs(current / "idProduct")
        if vendor and product:
            vid_pid = f"{vendor}:{product}"
            serial = _read_sysfs(current / "serial")
            busnum = _read_sysfs(current / "busnum")
            devpath = _read_sysfs(current / "devpath")
            via_port = f"{busnum}-{devpath}" if busnum and devpath else ""
            info.update({"vid_pid": vid_pid, "serial": serial, "via_port": via_port, "sysfs_path": str(current)})
            break
        current = current.parent
    return info


def run_cli(config_path: Optional[str] = None) -> None:
    config = Config.load(config_path)
    config.ensure_dirs()
    store = PolicyStore(path=config.policy_store_file, backup_dir=config.backup_dir, keep_backups=config.keep_backups, lock_path=config.lock_file)
    audit = AuditLogger(config.audit_file)
    responder = Responder(config, store, audit)
    monitor = HidMonitor(config, store, audit, responder)
    monitor.run()


if __name__ == "__main__":
    config_path = sys.argv[1] if len(sys.argv) > 1 else None
    run_cli(config_path)