#!/usr/bin/env python3
# ═══════════════════════════════════════════════════════════════════════════════
# USBGuard BadUSB Behavioral Monitor Daemon
# Version: 1.0
# ═══════════════════════════════════════════════════════════════════════════════
# ניטור התנהגותי של התקני HID (מקלדת/עכבר) לאיתור BadUSB.
# המנגנון מודד Events Per Second (EPS) ומחסום התקנים שיוצרים קצב הקלדה
# לא אנושי (EPS > 20 למשך שנייה אחת).
#
# דרישות:
#   apt install python3-evdev
#
# בטיחות:
#   - רץ כ-root (נדרש לקריאת /dev/input/event*)
#   - מתקשר עם Flask API מקומי בלבד (127.0.0.1)
#   - שימוש ב-Rate Limiting פנימי למניעת הצפת API
# ═══════════════════════════════════════════════════════════════════════════════

import evdev
import select
import time
import json
import urllib.request
import urllib.error
import logging
import sys
import os
import signal
from collections import defaultdict

# ─── Configuration ─────────────────────────────────────────────────────────────
API_BLOCK_URL = "http://127.0.0.1:5000/api/block"
EPS_THRESHOLD = 20         # סף אירועים לשנייה
EPS_WINDOW_SEC = 1.0       # חלון זמן למדידת EPS
SCAN_INTERVAL_SEC = 1.0    # תדירות סריקת התקנים חדשים
COOLDOWN_SEC = 30          # זמן צינון לפני דיווח חוזר על אותו VidPid
LOG_FILE = "/var/log/usbguard-badusb.log"
PID_FILE = "/var/run/usbguard-badusb.pid"

# ─── Logger Setup ─────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger("badusb-monitor")

# ─── Global State ─────────────────────────────────────────────────────────────
running = True
event_counters = defaultdict(list)  # {device_path: [timestamp, ...]}
blocked_devices = {}                # {vid_pid: cooldown_until}
known_device_names = {}             # {device_path: name}


# ═══════════════════════════════════════════════════════════════════════════════
# Signal Handler
# ═══════════════════════════════════════════════════════════════════════════════
def signal_handler(signum, frame):
    """Handle graceful shutdown."""
    global running
    logger.info(f"Received signal {signum}, shutting down...")
    running = False


def write_pid_file():
    """Write PID file for systemd service management."""
    with open(PID_FILE, 'w') as f:
        f.write(str(os.getpid()))
    logger.debug(f"PID file written: {PID_FILE} ({os.getpid()})")


# ═══════════════════════════════════════════════════════════════════════════════
# Device Discovery
# ═══════════════════════════════════════════════════════════════════════════════
def discover_hid_devices():
    """
    Scan /dev/input/event* for HID devices.
    Returns a list of evdev.InputDevice objects that are keyboards.
    Filters by having keys like KEY_ENTER, KEY_A, etc.
    """
    devices = []
    try:
        for path in evdev.list_devices():
            try:
                dev = evdev.InputDevice(path)
                # Check if device has keyboard capabilities
                # We look for EV_KEY capability with a keyboard-like range
                caps = dev.capabilities()
                if evdev.ecodes.EV_KEY in caps:
                    keys = caps[evdev.ecodes.EV_KEY]
                    # Detect keyboard-like device: has letter keys (KEY_A=30...KEY_Z=56)
                    has_letter_keys = any(k in range(30, 57) for k in keys)
                    # Also detect mouse devices (has BTN_* keys)
                    has_btn_keys = any(k in range(256, 320) for k in keys)
                    
                    if has_letter_keys or has_btn_keys:
                        devices.append(dev)
                        if dev.path not in known_device_names:
                            known_device_names[dev.path] = f"{dev.name} ({dev.phys or 'N/A'})"
                            logger.info(f"Discovered HID device: {dev.path} - {dev.name} (phys: {dev.phys})")
            except (PermissionError, OSError, FileNotFoundError) as e:
                logger.debug(f"Cannot access {path}: {e}")
                continue
    except Exception as e:
        logger.error(f"Error scanning devices: {e}")
    return devices


def extract_vidpid_from_device(device):
    """
    Extract VID:PID from an evdev input device.
    evdev provides phys like "usb-0000:00:14.0-1/input0"
    We try to read from device info or sysfs.
    """
    try:
        # Try reading from sysfs
        syspath = os.path.realpath(f"/sys/class/input/{os.path.basename(device.path)}/device")
        if os.path.exists(syspath):
            modalias_path = os.path.join(syspath, "modalias")
            if os.path.exists(modalias_path):
                with open(modalias_path, 'r') as f:
                    modalias = f.read().strip()
                # Parse modalias: usb:v1234p5678d...
                import re
                match = re.search(r'v([0-9a-fA-F]{4})p([0-9a-fA-F]{4})', modalias)
                if match:
                    return f"{match.group(1).lower()}:{match.group(2).lower()}"
    except (FileNotFoundError, PermissionError, OSError) as e:
        logger.debug(f"Cannot read VID:PID from sysfs for {device.path}: {e}")
    
    return None


# ═══════════════════════════════════════════════════════════════════════════════
# EPS Measurement & Anomaly Detection
# ═══════════════════════════════════════════════════════════════════════════════
def measure_eps(device_path):
    """
    Calculate Events Per Second for a given device within the time window.
    Removes old events outside the window and returns current EPS.
    """
    now = time.time()
    counter = event_counters.get(device_path, [])
    
    # Remove events outside the window
    cutoff = now - EPS_WINDOW_SEC
    counter = [t for t in counter if t > cutoff]
    event_counters[device_path] = counter
    
    return len(counter)


def record_event(device_path):
    """Record a new event timestamp for a device."""
    now = time.time()
    event_counters[device_path].append(now)
    
    # Limit memory: keep only events from last 5 seconds
    cutoff = now - 5.0
    event_counters[device_path] = [t for t in event_counters[device_path] if t > cutoff]


# ═══════════════════════════════════════════════════════════════════════════════
# API Communication
# ═══════════════════════════════════════════════════════════════════════════════
def block_device(vid_pid):
    """
    Send a block request to the Flask API.
    Uses urllib (standard library, no extra deps) to POST to /api/block.
    """
    if vid_pid in blocked_devices and time.time() < blocked_devices[vid_pid]:
        logger.debug(f"Device {vid_pid} in cooldown, skipping block request")
        return False
    
    payload = json.dumps({"vid_pid": vid_pid}).encode('utf-8')
    req = urllib.request.Request(
        API_BLOCK_URL,
        data=payload,
        headers={'Content-Type': 'application/json'},
        method='POST'
    )
    
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            if resp.status == 200:
                result = json.loads(resp.read().decode('utf-8'))
                if result.get('success'):
                    logger.warning(f"🚨 BLOCKED SUSPICIOUS DEVICE: {vid_pid}")
                    blocked_devices[vid_pid] = time.time() + COOLDOWN_SEC
                    return True
                else:
                    logger.error(f"Block API returned error for {vid_pid}: {result.get('error')}")
            else:
                logger.error(f"Block API returned status {resp.status} for {vid_pid}")
    except urllib.error.HTTPError as e:
        # 5xx errors from API should be logged but not retried immediately
        logger.error(f"HTTP error blocking {vid_pid}: {e.code} {e.reason}")
    except urllib.error.URLError as e:
        logger.error(f"API unreachable (URLError) for {vid_pid}: {e.reason}")
    except (TimeoutError, OSError) as e:
        logger.error(f"Network error blocking {vid_pid}: {e}")
    
    return False


# ═══════════════════════════════════════════════════════════════════════════════
# Main Monitoring Loop
# ═══════════════════════════════════════════════════════════════════════════════
def monitor_loop():
    """Main loop: monitor HID devices for anomalous behavior."""
    global running
    
    logger.info("BadUSB Behavioral Monitor started")
    logger.info(f"EPS Threshold: {EPS_THRESHOLD}, Window: {EPS_WINDOW_SEC}s")
    logger.info(f"Block API: {API_BLOCK_URL}")
    logger.info(f"Log file: {LOG_FILE}")
    
    monitored_devices = []
    last_scan_time = 0
    
    while running:
        try:
            now = time.time()
            
            # Periodically scan for new devices
            if now - last_scan_time >= SCAN_INTERVAL_SEC:
                discovered = discover_hid_devices()
                
                # Close old devices and refresh list
                for dev in monitored_devices:
                    if dev.path not in [d.path for d in discovered]:
                        try:
                            dev.close()
                        except:
                            pass
                
                monitored_devices = discovered
                last_scan_time = now
                logger.debug(f"Monitoring {len(monitored_devices)} HID device(s)")
            
            if not monitored_devices:
                time.sleep(SCAN_INTERVAL_SEC)
                continue
            
            # Use select to read events from all devices with a short timeout
            try:
                readable, _, _ = select.select(monitored_devices, [], [], 0.5)
            except (ValueError, OSError) as e:
                logger.error(f"Select error: {e}")
                time.sleep(SCAN_INTERVAL_SEC)
                continue
            
            for dev in readable:
                try:
                    for event in dev.read():
                        if event.type == evdev.ecodes.EV_KEY:
                            # Only count key press events (value == 1)
                            if event.value == 1:
                                record_event(dev.path)
                                
                                # Measure EPS
                                eps = measure_eps(dev.path)
                                
                                # Check threshold
                                if eps > EPS_THRESHOLD:
                                    vid_pid = extract_vidpid_from_device(dev)
                                    
                                    if vid_pid:
                                        logger.warning(
                                            f"⚠️ Suspicious activity detected!"
                                            f" Device: {known_device_names.get(dev.path, dev.path)}"
                                            f" | VID:PID: {vid_pid}"
                                            f" | EPS: {eps}"
                                        )
                                        block_device(vid_pid)
                                    else:
                                        logger.warning(
                                            f"⚠️ Cannot identify device at {dev.path}"
                                            f" | EPS: {eps}"
                                        )
                                elif eps > EPS_THRESHOLD * 0.5:
                                    # Log high activity but below threshold (diagnostic)
                                    logger.debug(f"High EPS ({eps}) on {dev.path}, below threshold")
                except (BlockingIOError, OSError, PermissionError) as e:
                    logger.debug(f"Error reading {dev.path}: {e}")
                    continue
                except Exception as e:
                    logger.error(f"Unexpected error reading {dev.path}: {e}")
                    continue
        
        except KeyboardInterrupt:
            logger.info("Received interrupt signal, shutting down...")
            running = False
            break
        except Exception as e:
            logger.error(f"Unexpected error in main loop: {e}")
            time.sleep(SCAN_INTERVAL_SEC)
            continue
    
    # Cleanup
    logger.info("Shutting down, closing device handles...")
    for dev in monitored_devices:
        try:
            dev.close()
        except:
            pass
    
    # Clean PID file
    if os.path.exists(PID_FILE):
        try:
            os.remove(PID_FILE)
        except:
            pass
    
    logger.info("BadUSB Monitor stopped")


# ═══════════════════════════════════════════════════════════════════════════════
# Entry Point
# ═══════════════════════════════════════════════════════════════════════════════
def main():
    # Register signal handlers for graceful shutdown
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)
    
    # Check root privileges
    if os.geteuid() != 0:
        logger.error("Must run as root (required for /dev/input/event* access)")
        print("ERROR: Must run as root (use sudo)", file=sys.stderr)
        sys.exit(1)
    
    # Write PID file
    try:
        write_pid_file()
    except PermissionError:
        logger.error(f"Cannot write PID file: {PID_FILE} (run as root)")
        sys.exit(1)
    
    # Verify evdev module is available
    try:
        import evdev
    except ImportError:
        logger.error("python3-evdev module is not installed")
        print("ERROR: python3-evdev is required. Install with: apt install python3-evdev", file=sys.stderr)
        sys.exit(1)
    
    # Start monitoring
    try:
        monitor_loop()
    except Exception as e:
        logger.exception(f"Fatal error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()