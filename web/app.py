import os
import subprocess
import re
import json
from flask import Flask, render_template, jsonify, request

app = Flask(__name__)

# Paths and Configs
LOG_FILE = "/var/log/usbguard-approval.log"
RULES_DIR = "/etc/usbguard/rules.d"
STATIC_DIR = os.path.join(os.path.dirname(__file__), "static")

def run_command(cmd, shell=False):
    """Safely execute system commands and return stdout/stderr."""
    try:
        res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, shell=shell, timeout=15)
        return res.stdout, res.stderr, res.returncode
    except subprocess.TimeoutExpired:
        return "", "Command timeout", -1
    except Exception as e:
        return "", str(e), -1

def parse_lsusb_verbose(output):
    """Parse 'sudo lsusb -v -d VID:PID' output into structured JSON."""
    result = {
        "device": {},
        "configuration": None,
        "interfaces": [],
        "endpoints": [],
        "status": "",
        "raw": output
    }
    
    if not output.strip():
        return result
    
    lines = output.split('\n')
    current_section = None
    current_interface = None
    current_endpoint = None
    interface_count = -1
    endpoint_count = -1
    
    for line in lines:
        stripped = line.strip()
        lower = stripped.lower()
        
        # Device descriptor section
        if 'device descriptor:' in lower:
            current_section = 'device'
            continue
        elif 'configuration descriptor:' in lower:
            current_section = 'config'
            continue
        elif 'interface descriptor:' in lower:
            current_section = 'interface'
            interface_count += 1
            current_interface = {"index": interface_count, "descriptors": {}}
            result["interfaces"].append(current_interface)
            continue
        elif 'endpoint descriptor:' in lower:
            current_section = 'endpoint'
            endpoint_count += 1
            current_endpoint = {"index": endpoint_count, "descriptors": {}}
            result["endpoints"].append(current_endpoint)
            continue
        elif 'device qualifier' in lower:
            current_section = 'qualifier'
            continue
        elif 'device status:' in lower:
            current_section = 'status'
            # Try to grab status value after colon
            if ':' in stripped:
                status_val = stripped.split(':', 1)[1].strip()
                result["status"] = status_val
            continue
        elif 'bus powered' in lower or 'self powered' in lower:
            if current_section == 'config':
                result["configuration"] = result.get("configuration", {})
                result["configuration"]["power_type"] = stripped.strip('()')
            continue
        
        # Parse key: value pairs
        if ':' in stripped and not stripped.startswith('('):
            key, _, val = stripped.partition(':')
            key = key.strip()
            val = val.strip()
            
            if current_section == 'device':
                result["device"][key] = val
            elif current_section == 'config':
                if result.get("configuration") is None:
                    result["configuration"] = {}
                result["configuration"][key] = val
            elif current_section == 'interface' and current_interface is not None:
                current_interface["descriptors"][key] = val
            elif current_section == 'endpoint' and current_endpoint is not None:
                current_endpoint["descriptors"][key] = val
    
    # Also parse the first line (bus info)
    first_line = lines[0] if lines else ""
    bus_match = re.search(r'Bus (\d+) Device (\d+): ID ([0-9a-fA-F]{4}:[0-9a-fA-F]{4})\s*(.*)', first_line)
    if bus_match:
        result["bus_info"] = {
            "bus": bus_match.group(1),
            "device": bus_match.group(2),
            "id": bus_match.group(3),
            "description": bus_match.group(4).strip()
        }
    
    return result

def get_fingerprint_from_lsusb(output):
    """Extract a stable fingerprint from lsusb -v output."""
    parsed = parse_lsusb_verbose(output)
    dev = parsed.get("device", {})
    
    fingerprint = {
        "idVendor": dev.get("idVendor", ""),
        "idProduct": dev.get("idProduct", ""),
        "iManufacturer": dev.get("iManufacturer", ""),
        "iProduct": dev.get("iProduct", ""),
        "iSerial": dev.get("iSerial", ""),
        "bcdUSB": dev.get("bcdUSB", ""),
        "bDeviceClass": dev.get("bDeviceClass", "").split()[0] if dev.get("bDeviceClass") else "",
    }
    
    # Add interface classes if present
    if parsed.get("interfaces"):
        interface_classes = []
        for iface in parsed["interfaces"]:
            desc = iface.get("descriptors", {})
            b_class = desc.get("bInterfaceClass", "").split()[0] if desc.get("bInterfaceClass") else ""
            b_sub = desc.get("bInterfaceSubClass", "").split()[0] if desc.get("bInterfaceSubClass") else ""
            b_proto = desc.get("bInterfaceProtocol", "").split()[0] if desc.get("bInterfaceProtocol") else ""
            interface_classes.append({
                "class": b_class,
                "subclass": b_sub,
                "protocol": b_proto
            })
        fingerprint["interfaces"] = interface_classes
    
    return fingerprint

@app.route('/')
def index():
    return render_template('index.html')

@app.route('/api/status', methods=['GET'])
def get_status():
    """Retrieve Systemd service status for usbguard and the reaper timer."""
    _, _, rc_daemon = run_command(["systemctl", "is-active", "--quiet", "usbguard"])
    daemon_active = (rc_daemon == 0)

    _, _, rc_timer = run_command(["systemctl", "is-active", "--quiet", "usbguard-ttl-reaper.timer"])
    timer_active = (rc_timer == 0)

    rules_count = 0
    stdout, _, rc = run_command(["sudo", "/etc/usbguard/scripts/usb-approve.sh", "--list-rules"])
    if rc == 0:
        try:
            data = json.loads(stdout)
            for cat in ["system", "permanent", "temporary"]:
                for line in data.get(cat, []):
                    if line.strip().startswith('allow'):
                        rules_count += 1
        except:
            pass

    return jsonify({
        "daemon_active": daemon_active,
        "timer_active": timer_active,
        "active_rules_count": rules_count
    })

@app.route('/api/devices', methods=['GET'])
def get_devices():
    """Retrieve list of USB devices detected by USBGuard, with deep field parsing."""
    stdout, stderr, rc = run_command(["usbguard", "list-devices"])
    if rc != 0:
        return jsonify({"error": f"Failed to list devices: {stderr}"}), 500

    devices = []
    
    for line in stdout.strip().split('\n'):
        if not line:
            continue
        
        parts = line.split(' ', 2)
        if len(parts) < 2:
            continue
            
        dev_id = parts[0].replace(':', '')
        status = parts[1]
        
        vid_pid = ""
        vid_pid_match = re.search(r'id ([0-9a-fA-F]{4}:[0-9a-fA-F]{4})', line)
        if vid_pid_match:
            vid_pid = vid_pid_match.group(1)

        serial = "N/A"
        serial_match = re.search(r'serial "([^"]*)"', line)
        if serial_match:
            serial = serial_match.group(1)

        name = "Unknown Device"
        name_match = re.search(r'name "([^"]*)"', line)
        if name_match:
            name = name_match.group(1).strip()

        port = "N/A"
        port_match = re.search(r'via-port (\S+)', line)
        if port_match:
            port = port_match.group(1)

        dev_hash = "N/A"
        hash_match = re.search(r'hash "([^"]*)"', line)
        if hash_match:
            dev_hash = hash_match.group(1)

        parent_hash = "N/A"
        phash_match = re.search(r'parent-hash "([^"]*)"', line)
        if phash_match:
            parent_hash = phash_match.group(1)

        interfaces = "N/A"
        intf_match = re.search(r'with-interface \{([^}]+)\}', line)
        if intf_match:
            interfaces = intf_match.group(1)
        else:
            intf_match_single = re.search(r'with-interface (\S+)', line)
            if intf_match_single:
                interfaces = intf_match_single.group(1)

        connect_type = "N/A"
        conn_match = re.search(r'with-connect-type "([^"]*)"', line)
        if conn_match:
            connect_type = conn_match.group(1)

        devices.append({
            "device_id": dev_id,
            "status": status,
            "id": vid_pid,
            "serial": serial,
            "name": name,
            "port": port,
            "hash": dev_hash,
            "parent_hash": parent_hash,
            "interfaces": interfaces,
            "connect_type": connect_type,
            "raw": line
        })

    return jsonify(devices)

@app.route('/api/device-detail', methods=['GET'])
def get_device_detail():
    """
    Run 'sudo lsusb -v -d VID:PID' to fetch verbose USB device details.
    Returns parsed JSON including manufacturer, serial, interface classes, etc.
    """
    vid_pid = request.args.get('id', '')
    
    if not vid_pid or ':' not in vid_pid:
        # If no VID:PID given, try to list all devices first
        stdout, stderr, rc = run_command(["lsusb"])
        if rc != 0:
            return jsonify({"error": f"lsusb failed: {stderr}"}), 500
        
        devices_raw = []
        for line in stdout.strip().split('\n'):
            if not line.strip():
                continue
            m = re.search(r'ID\s+([0-9a-fA-F]{4}:[0-9a-fA-F]{4})\s+(.+)', line)
            if m:
                devices_raw.append({"id": m.group(1), "desc": m.group(2).strip()})
        
        return jsonify({"devices": devices_raw})
    
    # Validate VID:PID format
    if not re.match(r'^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$', vid_pid):
        return jsonify({"error": "Invalid VID:PID format"}), 400
    
    stdout, stderr, rc = run_command(["sudo", "lsusb", "-v", "-d", vid_pid])
    if rc != 0:
        return jsonify({
            "error": f"lsusb -v failed for {vid_pid}: {stderr}",
            "note": "Device may not be connected or needs sudo"
        }), 500
    
    parsed = parse_lsusb_verbose(stdout)
    fingerprint = get_fingerprint_from_lsusb(stdout)
    
    return jsonify({
        "vid_pid": vid_pid,
        "parsed": parsed,
        "fingerprint": fingerprint
    })

@app.route('/api/verify-fingerprint', methods=['POST'])
def verify_fingerprint():
    """
    Verify a device's current fingerprint against a stored fingerprint.
    Returns match percentage and any mismatches.
    """
    data = request.json or {}
    vid_pid = data.get("vid_pid", "")
    
    if not vid_pid or not re.match(r'^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$', vid_pid):
        return jsonify({"error": "Invalid VID:PID"}), 400
    
    stored_fp = data.get("stored_fingerprint", {})
    
    # Get current fingerprint
    stdout, stderr, rc = run_command(["sudo", "lsusb", "-v", "-d", vid_pid])
    if rc != 0:
        return jsonify({"error": f"Cannot read device: {stderr}"}), 500
    
    current_fp = get_fingerprint_from_lsusb(stdout)
    
    if not stored_fp:
        # No stored fingerprint - return current one for saving
        return jsonify({
            "has_stored": False,
            "current_fingerprint": current_fp,
            "message": "No stored fingerprint found. This device has not been fingerprinted yet."
        })
    
    # Compare fingerprints
    mismatches = []
    matches = 0
    total_fields = 0
    
    # Compare scalar fields
    scalar_fields = ["iManufacturer", "iProduct", "iSerial", "bcdUSB", "bDeviceClass"]
    for field in scalar_fields:
        stored_val = stored_fp.get(field, "")
        current_val = current_fp.get(field, "")
        if stored_val and current_val:
            total_fields += 1
            if stored_val == current_val:
                matches += 1
            else:
                mismatches.append({
                    "field": field,
                    "stored": stored_val,
                    "current": current_val,
                    "severity": "high" if field in ["iSerial", "bDeviceClass"] else "medium"
                })
    
    # Compare interface classes if present
    stored_interfaces = stored_fp.get("interfaces", [])
    current_interfaces = current_fp.get("interfaces", [])
    
    if stored_interfaces and current_interfaces:
        for i, (s_iface, c_iface) in enumerate(zip(stored_interfaces, current_interfaces)):
            for key in ["class", "subclass", "protocol"]:
                s_val = s_iface.get(key, "")
                c_val = c_iface.get(key, "")
                if s_val and c_val:
                    total_fields += 1
                    if s_val == c_val:
                        matches += 1
                    else:
                        mismatches.append({
                            "field": f"interface[{i}].bInterface{key.capitalize()}",
                            "stored": s_val,
                            "current": c_val,
                            "severity": "critical" if key == "class" else "high"
                        })
    
    match_pct = round((matches / total_fields * 100)) if total_fields > 0 else 0
    
    return jsonify({
        "has_stored": True,
        "current_fingerprint": current_fp,
        "matches": matches,
        "total_fields": total_fields,
        "match_percentage": match_pct,
        "mismatches": mismatches,
        "verdict": "TRUSTED" if match_pct >= 80 and len(mismatches) == 0 else (
            "SUSPICIOUS" if match_pct >= 50 else "DANGEROUS"
        ),
        "message": _get_verdict_message(match_pct, mismatches)
    })

def _get_verdict_message(match_pct, mismatches):
    if match_pct >= 80 and len(mismatches) == 0:
        return "✅ Device identity confirmed. All fingerprints match."
    elif match_pct >= 80 and len(mismatches) > 0:
        severe = [m for m in mismatches if m.get("severity") in ("critical", "high")]
        if severe:
            return f"⚠️ Mostly matches ({match_pct}%), but {len(severe)} critical field(s) differ. Verify before trusting."
        return f"✅ Mostly matches ({match_pct}%). Minor variations detected."
    elif match_pct >= 50:
        return f"⚠️ Suspicious ({match_pct}% match). Device may be spoofed."
    else:
        return f"🚨 DANGEROUS ({match_pct}% match). Device fingerprint does NOT match stored profile!"

@app.route('/api/rules', methods=['GET'])
def get_rules():
    """Retrieve all parsed active rules from 00-system, 50-permanent, and 90-temporary."""
    stdout, stderr, rc = run_command(["sudo", "/etc/usbguard/scripts/usb-approve.sh", "--list-rules"])
    if rc != 0:
        return jsonify([])

    try:
        data = json.loads(stdout)
    except Exception as e:
        return jsonify([])

    rules = []
    
    categories = {
        "system": ("System", "00-system.rules"),
        "permanent": ("Permanent", "50-permanent.rules"),
        "temporary": ("Temporary", "90-temporary.rules")
    }

    for cat_key, (category_name, filename) in categories.items():
        lines = data.get(cat_key, [])
        i = 0
        while i < len(lines):
            line = lines[i].strip()
            if line.startswith('allow') or line.startswith('block'):
                rule_text = line
                ttl = None
                fingerprint = None
                
                # If temporary rule, check if next line is the ttl_epoch comment
                if cat_key == "temporary" and i + 1 < len(lines):
                    next_line = lines[i+1].strip()
                    if next_line.startswith("# ttl_epoch:"):
                        ttl_val = next_line.replace("# ttl_epoch:", "").strip()
                        if ttl_val.isdigit():
                            ttl = int(ttl_val)
                
                # Check for fingerprint comment (can be anywhere after the rule)
                for j in range(i + 1, min(i + 5, len(lines))):
                    check_line = lines[j].strip()
                    if check_line.startswith("# fingerprint:"):
                        fp_str = check_line.replace("# fingerprint:", "").strip()
                        try:
                            fingerprint = json.loads(fp_str)
                        except:
                            pass
                        break
                
                # Extract VID:PID
                vid_pid = ""
                vid_pid_match = re.search(r'id ([0-9a-fA-F]{4}:[0-9a-fA-F]{4})', rule_text)
                if vid_pid_match:
                    vid_pid = vid_pid_match.group(1)

                # Extract name
                name = "Unknown Device"
                name_match = re.search(r'name "([^"]*)"', rule_text)
                if name_match:
                    name = name_match.group(1).strip()

                # Extract serial
                serial = "N/A"
                serial_match = re.search(r'serial "([^"]*)"', rule_text)
                if serial_match:
                    serial = serial_match.group(1)

                # Extract hash
                dev_hash = "N/A"
                hash_match = re.search(r'hash "([^"]*)"', rule_text)
                if hash_match:
                    dev_hash = hash_match.group(1)

                # Extract interfaces
                interfaces = "N/A"
                intf_match = re.search(r'with-interface \{([^}]+)\}', rule_text)
                if intf_match:
                    interfaces = intf_match.group(1)
                else:
                    intf_match_single = re.search(r'with-interface (\S+)', rule_text)
                    if intf_match_single:
                        interfaces = intf_match_single.group(1)

                rules.append({
                    "rule": rule_text,
                    "filename": filename,
                    "category": category_name,
                    "id": vid_pid,
                    "name": name,
                    "serial": serial,
                    "hash": dev_hash,
                    "interfaces": interfaces,
                    "ttl_epoch": ttl,
                    "fingerprint": fingerprint
                })
            i += 1

    return jsonify(rules)

@app.route('/api/approve', methods=['POST'])
def approve_device():
    """Approve a selected blocked device via sudo usb-approve.sh, with optional fingerprint."""
    data = request.json or {}
    device_id = data.get("device_id")
    approval_type = data.get("type", "T")  # "T" for Temporary, "P" for Permanent
    ttl = data.get("ttl", "3600")
    fingerprint = data.get("fingerprint")  # Optional fingerprint to store

    if not device_id:
        return jsonify({"error": "Device ID is required"}), 400
    if approval_type not in ["P", "T"]:
        return jsonify({"error": "Invalid approval type. Must be P or T."}), 400

    cmd = ["sudo", "/etc/usbguard/scripts/usb-approve.sh", "--device", str(device_id), "--type", approval_type]
    if approval_type == "T" and ttl:
        cmd.extend(["--ttl", str(ttl)])

    stdout, stderr, rc = run_command(cmd)

    if rc == 0:
        # If fingerprint provided, append it to the rule file
        if fingerprint:
            _append_fingerprint_to_rule(device_id, fingerprint)
        
        return jsonify({
            "success": True,
            "message": f"Successfully approved device {device_id} ({'Permanent' if approval_type == 'P' else 'Temporary'})",
            "output": stdout
        })
    else:
        return jsonify({
            "success": False,
            "error": f"Failed to approve device: {stderr or stdout}"
        }), 500

def _append_fingerprint_to_rule(device_id, fingerprint):
    """Append a fingerprint comment to the rule file that contains the device."""
    # Build VID:PID in rule format (xxxx:xxxx) from fingerprint fields
    vendor = fingerprint.get('idVendor', '').replace('0x', '').strip()
    product = fingerprint.get('idProduct', '').replace('0x', '').strip()
    rule_vid_pid = f"{vendor}:{product}"
    
    for filename in sorted(os.listdir(RULES_DIR)):
        if not filename.endswith('.rules'):
            continue
        filepath = os.path.join(RULES_DIR, filename)
        try:
            with open(filepath, 'r') as f:
                lines = f.readlines()
            
            # Find the rule that matches this device
            for i, line in enumerate(lines):
                if f"allow id {rule_vid_pid}" in line:
                    # Insert fingerprint comment after the rule line
                    fp_comment = f"# fingerprint: {json.dumps(fingerprint)}\n"
                    lines.insert(i + 1, fp_comment)
                    with open(filepath, 'w') as f:
                        f.writelines(lines)
                    return True
        except:
            pass
    return False

@app.route('/api/block', methods=['POST'])
def block_device():
    """Block a device immediately and remove its rules file persistence."""
    data = request.json or {}
    device_id = data.get("device_id")
    vid_pid = data.get("vid_pid")

    if not device_id and not vid_pid:
        return jsonify({"error": "Device ID or VID:PID is required"}), 400

    cmd = ["sudo", "/etc/usbguard/scripts/usb-approve.sh"]
    if device_id:
        cmd.extend(["--block", str(device_id)])
    if vid_pid:
        cmd.extend(["--vidpid", str(vid_pid)])

    stdout, stderr, rc = run_command(cmd)

    if rc == 0:
        return jsonify({
            "success": True,
            "message": f"Successfully blocked and removed persistence for {vid_pid or 'ID: ' + str(device_id)}"
        })
    else:
        return jsonify({
            "success": False,
            "error": f"Failed to block device: {stderr or stdout}"
        }), 500

@app.route('/api/change-status', methods=['POST'])
def change_status():
    """Change approval status (e.g. from permanent to temporary, or update TTL)."""
    data = request.json or {}
    device_id = data.get("device_id")
    vid_pid = data.get("vid_pid")
    new_type = data.get("type")  # "P" or "T"
    ttl = data.get("ttl", "3600")

    if not vid_pid:
        return jsonify({"error": "VID:PID is required"}), 400
    if new_type not in ["P", "T"]:
        return jsonify({"error": "Invalid approval type. Must be P or T."}), 400

    # 1. Delete existing persistent rule (from both files)
    cmd_delete = ["sudo", "/etc/usbguard/scripts/usb-approve.sh", "--vidpid", str(vid_pid)]
    _, _, rc_delete = run_command(cmd_delete)

    if rc_delete != 0:
        return jsonify({"success": False, "error": "Failed to remove previous authorization rules file entries."}), 500

    # If the device is currently connected and we have a Device ID, approve it with the new configuration
    if device_id:
        cmd_approve = ["sudo", "/etc/usbguard/scripts/usb-approve.sh", "--device", str(device_id), "--type", new_type]
        if new_type == "T" and ttl:
            cmd_approve.extend(["--ttl", str(ttl)])

        stdout, stderr, rc_approve = run_command(cmd_approve)
        if rc_approve == 0:
            return jsonify({
                "success": True,
                "message": f"Successfully changed status of device {vid_pid} to {'Permanent' if new_type == 'P' else 'Temporary'}"
            })
        else:
            return jsonify({"success": False, "error": f"Failed to rewrite rule: {stderr or stdout}"}), 500
    else:
        return jsonify({
            "success": False,
            "error": "Device must be connected to apply status changes (rule recreation requires hardware signature scanning)."
        }), 400

@app.route('/api/logs', methods=['GET'])
def get_logs():
    """Fetch the latest 50 lines from the audit log."""
    if not os.path.exists(LOG_FILE):
        return jsonify({"logs": ["No logs available yet."]})
    
    try:
        with open(LOG_FILE, 'r') as file:
            lines = file.readlines()
            last_lines = [line.strip() for line in lines[-50:]]
            return jsonify({"logs": last_lines})
    except Exception as e:
        return jsonify({"error": f"Failed to read logs: {str(e)}"}), 500

if __name__ == '__main__':
    app.run(host='127.0.0.1', port=5000, debug=True)