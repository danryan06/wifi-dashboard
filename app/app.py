from flask import Flask, render_template, request, redirect, jsonify, flash
import os
import subprocess
import logging
import time
import json
from datetime import datetime
import threading
import psutil

app = Flask(__name__)
app.secret_key = 'wifi-test-dashboard-secret-key'

# =============================================================================
# CONFIGURATION
# =============================================================================
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = os.path.join(BASE_DIR, "configs", "ssid.conf")
SETTINGS_FILE = os.path.join(BASE_DIR, "configs", "settings.conf")
LOG_DIR = os.path.join(BASE_DIR, "logs")

IFACES = ["eth0", "wlan0", "wlan1"]
STATS_DIR = "/home/pi/wifi_test_dashboard/stats"
BASELINE_FILE = os.path.join(STATS_DIR, "io_baselines.json")
_MB = 1024 * 1024

# =============================================================================
# SINGLE STATS SYSTEM - KERNEL COUNTERS ONLY
# =============================================================================
# This is the ONLY stats tracking system - no competing approaches
_state_lock = threading.Lock()
_state = {
    "prev": {},          # {iface: {"rx": int, "tx": int}}
    "totals": {},        # {iface: {"download": int_bytes, "upload": int_bytes}}
    "last_ts": None,
}

def _read_kernel_counters():
    """Read current kernel network counters for all interfaces"""
    per = psutil.net_io_counters(pernic=True)
    now = {}
    for iface in IFACES:
        if iface in per:
            now[iface] = {"rx": per[iface].bytes_recv, "tx": per[iface].bytes_sent}
    return now

def _load_baseline():
    """Load baseline from disk (for persistence across app restarts)"""
    try:
        with open(BASELINE_FILE, "r") as f:
            data = json.load(f)
            data.setdefault("prev", {})
            data.setdefault("totals", {})
            data.setdefault("last_ts", time.time())
            return data
    except Exception:
        return {"prev": {}, "totals": {}, "last_ts": time.time()}

def _save_baseline():
    """Save baseline to disk (for persistence)"""
    os.makedirs(STATS_DIR, exist_ok=True)
    tmp = BASELINE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(_state, f)
    os.replace(tmp, BASELINE_FILE)

def get_throughput_stats():
    """
    SINGLE AUTHORITATIVE STATS FUNCTION
    Returns: dict with per-interface throughput (Mbps) and cumulative totals (MB)
    Based on kernel counters only - no competing stats systems
    """
    with _state_lock:
        # First run: initialize from disk if present
        if _state["last_ts"] is None or not _state["prev"]:
            data = _load_baseline()
            _state.update(data)
            if not _state["prev"]:
                _state["prev"] = _read_kernel_counters()
                _state["last_ts"] = time.time()
                for iface in IFACES:
                    _state["totals"].setdefault(iface, {"download": 0, "upload": 0})
                _save_baseline()
                # First response has no deltas yet
                out = {}
                for iface in IFACES:
                    t = _state["totals"].get(iface, {"download": 0, "upload": 0})
                    out[iface] = {
                        "download": 0.0,
                        "upload": 0.0,
                        "total_download": t["download"] / _MB,
                        "total_upload": t["upload"] / _MB,
                    }
                return out

        now = _read_kernel_counters()
        t = time.time()
        dt = max(t - (_state["last_ts"] or t), 1e-3)

        out = {}
        for iface in IFACES:
            prev = _state["prev"].get(iface)
            cur = now.get(iface, prev)
            
            if not cur:
                # Interface missing → zeros
                out[iface] = {
                    "download": 0.0,
                    "upload": 0.0,
                    "total_download": _state["totals"].get(iface, {"download": 0})["download"] / _MB,
                    "total_upload": _state["totals"].get(iface, {"upload": 0})["upload"] / _MB
                }
                continue

            if not prev:
                prev = cur

            # Bytes since last sample (prevent negatives from counter rollover)
            dr = max(0, cur["rx"] - prev["rx"])
            du = max(0, cur["tx"] - prev["tx"])

            # Calculate Mbps (bits per second / 1,000,000)
            out[iface] = {
                "download": (dr * 8.0) / dt / 1e6,
                "upload": (du * 8.0) / dt / 1e6
            }

            # Accumulate cumulative totals (bytes)
            tot = _state["totals"].setdefault(iface, {"download": 0, "upload": 0})
            tot["download"] += dr
            tot["upload"] += du

            out[iface]["total_download"] = tot["download"] / _MB
            out[iface]["total_upload"] = tot["upload"] / _MB

        _state["prev"] = now
        _state["last_ts"] = t
        _save_baseline()
        return out

# =============================================================================
# LOGGING SETUP
# =============================================================================
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(os.path.join(LOG_DIR, "main.log")),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

def log_action(msg):
    """Log action to main log file"""
    logger.info(msg)

# =============================================================================
# CACHE CONTROL
# =============================================================================
@app.after_request
def after_request(response):
    """Prevent caching of API responses"""
    if request.path.startswith('/api/'):
        response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
        response.headers["Pragma"] = "no-cache"
        response.headers["Expires"] = "0"
    return response

# =============================================================================
# CONFIGURATION MANAGEMENT
# =============================================================================
def read_config():
    """Read SSID configuration"""
    ssid, password = "", ""
    try:
        if os.path.exists(CONFIG_FILE):
            with open(CONFIG_FILE, 'r') as f:
                lines = [line.strip() for line in f.readlines()]
                if len(lines) >= 2:
                    ssid, password = lines[0], lines[1]
        return ssid, password
    except Exception as e:
        logger.error(f"Error reading config: {e}")
        return "", ""

def write_config(ssid, password):
    """Write SSID configuration"""
    try:
        os.makedirs(os.path.dirname(CONFIG_FILE), exist_ok=True)
        with open(CONFIG_FILE, 'w') as f:
            f.write(f"{ssid}\n{password}\n")
        os.chmod(CONFIG_FILE, 0o600)
        return True
    except Exception as e:
        logger.error(f"Error writing config: {e}")
        return False

def get_interface_assignments():
    """Read interface assignment configuration"""
    assignments_file = os.path.join(BASE_DIR, "configs", "interface-assignments.conf")
    assignments = {
        'good_interface': 'wlan0',
        'good_type': 'unknown',
        'bad_interface': 'wlan1',
        'bad_type': 'unknown',
        'wired_interface': 'eth0',
        'auto_detected': False
    }

    try:
        if os.path.exists(assignments_file):
            with open(assignments_file, 'r') as f:
                for raw in f:
                    line = raw.strip()
                    if not line or line.startswith('#') or '=' not in line:
                        continue
                    key, value = [s.strip() for s in line.split('=', 1)]
                    value = value.strip('"\'')
                    k = key.lower()

                    if k in ('wifi_good_interface', 'good_interface'):
                        assignments['good_interface'] = value
                    elif k in ('wifi_good_interface_type', 'good_type'):
                        assignments['good_type'] = value
                    elif k in ('wifi_bad_interface', 'bad_interface'):
                        assignments['bad_interface'] = None if value in ('none', 'disabled', '') else value
                    elif k in ('wifi_bad_interface_type', 'bad_type'):
                        assignments['bad_type'] = value
                    elif k in ('wired_interface',):
                        assignments['wired_interface'] = value

            assignments['auto_detected'] = True
    except Exception as e:
        logger.error(f"Error reading interface assignments: {e}")

    return assignments

# =============================================================================
# LOG FILE MANAGEMENT
# =============================================================================
def read_log_file(log_file, lines=100):
    """Read lines from log file"""
    log_path = os.path.join(LOG_DIR, log_file)
    try:
        if os.path.exists(log_path):
            with open(log_path, 'r') as f:
                all_lines = f.readlines()
            return all_lines[-lines:] if lines != -1 else all_lines
        return []
    except Exception as e:
        logger.error(f"Error reading log file {log_file}: {e}")
        return [f"Error reading log: {e}"]

def get_log_file_info(log_file):
    """Get information about a log file"""
    log_path = os.path.join(LOG_DIR, log_file)
    try:
        if os.path.exists(log_path):
            size = os.path.getsize(log_path)
            with open(log_path, 'r') as f:
                line_count = sum(1 for _ in f)
            
            return {
                'exists': True,
                'size_bytes': size,
                'size_mb': round(size / (1024 * 1024), 2),
                'line_count': line_count,
                'last_modified': datetime.fromtimestamp(os.path.getmtime(log_path)).strftime('%Y-%m-%d %H:%M:%S')
            }
        return {'exists': False}
    except Exception as e:
        logger.error(f"Error getting log file info {log_file}: {e}")
        return {'exists': False, 'error': str(e)}

# =============================================================================
# SYSTEM INFORMATION
# =============================================================================
def get_system_info():
    """Get system information"""
    try:
        # Get IP address
        ip_result = subprocess.run(['hostname', '-I'], capture_output=True, text=True, timeout=5)
        ip_address = ip_result.stdout.strip().split()[0] if ip_result.stdout.strip() else "Unknown"
        
        # Get interface information
        interfaces = {}
        ip_result = subprocess.run(['ip', '-o', 'addr'], capture_output=True, text=True, timeout=5)
        for line in ip_result.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 4:
                iface = parts[1]
                addr = parts[3]
                if iface not in interfaces:
                    interfaces[iface] = []
                interfaces[iface].append(addr)
        
        return {
            'ip_address': ip_address,
            'interfaces': interfaces,
            'timestamp': datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        }
    except Exception as e:
        logger.error(f"Error getting system info: {e}")
        return {
            'ip_address': "Error",
            'interfaces': {},
            'timestamp': datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        }

def get_service_status():
    """Get status of all services"""
    services = ['wifi-dashboard', 'wired-test', 'wifi-good', 'wifi-bad']
    status = {}
    
    for service in services:
        try:
            result = subprocess.run(['systemctl', 'is-active', f'{service}.service'], 
                                  capture_output=True, text=True, timeout=5)
            status[service] = result.stdout.strip()
        except Exception as e:
            status[service] = f"Error: {e}"
    
    return status

# =============================================================================
# ROUTES - MAIN PAGES
# =============================================================================
@app.route("/")
def index():
    """Main dashboard page"""
    ssid, _ = read_config()
    return render_template("dashboard.html", ssid=ssid)

@app.route("/traffic_control")
def traffic_control():
    """Traffic control management page"""
    return render_template("traffic_control.html")

# =============================================================================
# API ROUTES
# =============================================================================
@app.route("/status")
def status():
    """API endpoint for status information"""
    try:
        ssid, password = read_config()
        system_info = get_system_info()
        service_status = get_service_status()
        interface_assignments = get_interface_assignments()
        
        # Get recent logs from services
        logs = {
            'main': read_log_file('main.log', 50),
            'wired': read_log_file('wired.log', 50),
            'wifi-good': read_log_file('wifi-good.log', 50),
            'wifi-bad': read_log_file('wifi-bad.log', 50),
        }
        
        # Get log file information
        log_info = {}
        for log_name in logs.keys():
            log_info[log_name] = get_log_file_info(f'{log_name}.log')
        
        # Build log labels
        good_iface = interface_assignments.get("good_interface") or "wlan0"
        bad_iface = interface_assignments.get("bad_interface") or "wlan1"
        log_labels = {
            "main": "Install/Upgrade",
            "wired": "Wired Client + Traffic (eth0)",
            "wifi-good": f"Wi-Fi Good Client + Traffic ({good_iface})",
            "wifi-bad": f"Wi-Fi Bad Client - Auth Failures ({bad_iface})",
        }
        
        return jsonify({
            "ssid": ssid,
            "password_masked": "*" * len(password) if password else "",
            "system_info": system_info,
            "service_status": service_status,
            "interface_assignments": interface_assignments,
            "logs": logs,
            "log_info": log_info,
            "log_labels": log_labels,
            "success": True
        })

    except Exception as e:
        logger.error(f"Error in status endpoint: {e}")
        return jsonify({"success": False, "error": str(e)}), 500

@app.route("/api/throughput")
def api_throughput():
    """
    API endpoint for real-time throughput data
    Returns: Current Mbps + cumulative MB for all interfaces
    Uses SINGLE stats system (kernel counters only)
    """
    try:
        # Get interface assignments for filtering
        a = get_interface_assignments()
        candidates = {
            "eth0",
            a.get("good_interface", "wlan0"),
            a.get("bad_interface", "wlan1")
        }
        candidates = {i for i in candidates if i}

        # Get stats from SINGLE authoritative source
        stats_data = get_throughput_stats()

        # Get interface status from psutil
        io = psutil.net_io_counters(pernic=True)
        if_stats = psutil.net_if_stats()

        out = {}
        for iface in candidates:
            d = stats_data.get(iface, {
                "download": 0.0,
                "upload": 0.0,
                "total_download": 0.0,
                "total_upload": 0.0
            })
            i = io.get(iface)
            s = if_stats.get(iface)

            # Gather IP/MAC details
            ip_addr = ""
            mac_addr = ""
            try:
                ip_show = subprocess.run(['ip', '-o', '-4', 'addr', 'show', iface], capture_output=True, text=True, timeout=2)
                if ip_show.returncode == 0 and ip_show.stdout.strip():
                    # format: 2: eth0    inet 192.168.1.2/24 ...
                    parts = ip_show.stdout.strip().split()
                    if len(parts) >= 4:
                        ip_addr = parts[3].split('/')[0]
                link_show = subprocess.run(['ip', '-o', 'link', 'show', iface], capture_output=True, text=True, timeout=2)
                if link_show.returncode == 0 and link_show.stdout:
                    # look for 'link/ether xx:xx:xx:xx:xx:xx'
                    for token in link_show.stdout.split():
                        if token.count(':') == 5:
                            mac_addr = token
                            break
            except Exception:
                pass

            out[iface] = {
                "active": bool(s and s.isup),
                "download": round(float(d["download"]), 2),  # Mbps
                "upload": round(float(d["upload"]), 2),  # Mbps
                "rx_packets": int(getattr(i, "packets_recv", 0) or 0),
                "tx_packets": int(getattr(i, "packets_sent", 0) or 0),
                "total_download": round(float(d["total_download"]), 1),  # MB
                "total_upload": round(float(d["total_upload"]), 1),  # MB
                "ip": ip_addr,
                "mac": mac_addr,
            }

        return jsonify({
            "success": True,
            "throughput": out,
            "timestamp": datetime.utcnow().isoformat()
        })
    except Exception as e:
        logger.exception("throughput endpoint failed")
        return jsonify({
            "success": False,
            "error": str(e),
            "throughput": {},
            "timestamp": datetime.utcnow().isoformat()
        }), 500

@app.route("/api/logs/<log_name>")
def api_logs(log_name):
    """API endpoint for getting log content"""
    try:
        # Map friendly names to service logs
        assignments = get_interface_assignments()
        alias_map = {
            "good": "wifi-good",
            "good-client": "wifi-good",
            "bad": "wifi-bad",
            "bad-client": "wifi-bad",
            "wired": "wired",
            "ethernet": "wired"
        }
        gi = assignments.get("good_interface")
        bi = assignments.get("bad_interface")
        if gi:
            alias_map[gi] = "wifi-good"
        if bi:
            alias_map[bi] = "wifi-bad"
        log_name = alias_map.get(log_name, log_name)

        # Only expose valid service logs
        valid_logs = ["main", "wired", "wifi-good", "wifi-bad"]
        if log_name not in valid_logs:
            return jsonify({"success": False, "error": "Invalid log name"}), 400

        lines = int(request.args.get("lines", 200))
        all_lines = request.args.get("all", "false").lower() == "true"

        log_content = read_log_file(f"{log_name}.log", -1 if all_lines else lines)
        log_info = get_log_file_info(f"{log_name}.log")

        return jsonify({
            "success": True,
            "log_name": log_name,
            "content": log_content,
            "info": log_info,
            "lines_returned": len(log_content)
        })
    except Exception as e:
        logger.error(f"Error in logs API endpoint: {e}")
        return jsonify({"success": False, "error": str(e)}), 500

@app.route("/traffic_status")
def traffic_status():
    """API endpoint for traffic generation status"""
    try:
        a = get_interface_assignments()
        items = [
            ('wired-test', a.get('wired_interface', 'eth0'),
             'Wired Client with Integrated Heavy Traffic', 'wired.log'),
            ('wifi-good', a.get('good_interface', 'wlan0'),
             'Wi-Fi Good Client with Integrated Traffic + Roaming', 'wifi-good.log'),
        ]
        if a.get('bad_interface'):
            items.append(
                ('wifi-bad', a['bad_interface'],
                 'Wi-Fi Bad Client (Auth Failures for Mist PCAP)', 'wifi-bad.log')
            )

        # Get throughput stats from SINGLE source
        throughput_data = get_throughput_stats()

        traffic_status_data = {}

        for service_name, interface, description, log_file in items:
            try:
                # Service status
                result = subprocess.run(
                    ['systemctl', 'is-active', f'{service_name}.service'],
                    capture_output=True, text=True, timeout=5
                )
                status = result.stdout.strip()

                # IP info
                ip_result = subprocess.run(
                    ['ip', 'addr', 'show', interface],
                    capture_output=True, text=True, timeout=5
                )
                ip_info = "Not available"
                if ip_result.returncode == 0:
                    for ln in ip_result.stdout.splitlines():
                        ln = ln.strip()
                        if ln.startswith('inet '):
                            ip_info = ln.split()[1]
                            break

                # Recent logs
                recent = read_log_file(log_file, lines=20)
                info = get_log_file_info(log_file)
                exists = bool(info.get('exists'))

                # Get stats from SINGLE source
                stats = throughput_data.get(interface, {
                    "total_download": 0.0,
                    "total_upload": 0.0
                })

                traffic_status_data[interface] = {
                    'service_name': service_name,
                    'service_status': status,
                    'description': description,
                    'ip_address': ip_info,
                    'recent_logs': recent,
                    'log_file_exists': exists,
                    'total_download_mb': round(stats.get("total_download", 0), 1),
                    'total_upload_mb': round(stats.get("total_upload", 0), 1),
                }

            except Exception as e:
                traffic_status_data[interface] = {
                    'service_name': service_name,
                    'service_status': f'error: {e}',
                    'description': description,
                    'ip_address': 'unknown',
                    'recent_logs': [],
                    'log_file_exists': False,
                    'total_download_mb': 0,
                    'total_upload_mb': 0,
                }

        return jsonify({"interfaces": traffic_status_data, "success": True})
    except Exception as e:
        logger.error(f"Error in traffic_status endpoint: {e}")
        return jsonify({"success": False, "error": str(e)}), 500

# =============================================================================
# CONTROL ROUTES
# =============================================================================
@app.route("/update_wifi", methods=["POST"])
def update_wifi():
    """Update Wi-Fi configuration"""
    try:
        new_ssid = request.form.get("ssid", "").strip()
        new_password = request.form.get("password", "").strip()

        if not new_ssid or not new_password:
            flash("Both SSID and password are required", "error")
            return redirect("/")

        if write_config(new_ssid, new_password):
            log_action(f"Wi-Fi config updated via UI: SSID={new_ssid}")
            flash("Wi-Fi configuration updated successfully", "success")

            # Non-blocking restarts
            try:
                subprocess.run(['sudo', 'systemctl', 'restart', '--no-block', 'wifi-good.service'])
                subprocess.run(['sudo', 'systemctl', 'restart', '--no-block', 'wifi-bad.service'])
                flash("Wi-Fi services restarting...", "info")
            except Exception as e:
                logger.error(f"Error restarting services: {e}")
                flash("Configuration saved but failed to restart services", "warning")
        else:
            flash("Failed to update configuration", "error")

    except Exception as e:
        logger.error(f"Error updating Wi-Fi config: {e}")
        flash(f"Error updating configuration: {e}", "error")

    return redirect("/")

@app.route("/traffic_action", methods=["POST"])
def traffic_action():
    """Start/stop/restart services"""
    try:
        interface = request.form.get("interface")
        action = request.form.get("action")

        if not interface or not action:
            return jsonify({"success": False, "error": "Missing interface or action"}), 400
        if action not in ['start', 'stop', 'restart']:
            return jsonify({"success": False, "error": "Invalid action"}), 400

        # Map interface to service
        a = get_interface_assignments()
        service_map = {
            a.get('wired_interface', 'eth0'): 'wired-test',
            a.get('good_interface', 'wlan0'): 'wifi-good',
        }
        if a.get('bad_interface'):
            service_map[a['bad_interface']] = 'wifi-bad'

        service_name = service_map.get(interface)
        if not service_name:
            return jsonify({"success": False, "error": "No service mapped for interface"}), 400

        # Non-blocking control
        result = subprocess.run(
            ['sudo', 'systemctl', action, '--no-block', f'{service_name}.service'],
            capture_output=True, text=True, timeout=10
        )

        if result.returncode == 0:
            log_action(f"Service {service_name} {action} via UI (iface={interface})")
            return jsonify({"success": True, "message": f"{service_name} {action} issued"})
        else:
            logger.error(f"Failed to {action} {service_name}: {result.stderr}")
            return jsonify({"success": False, "error": f"Failed to {action} {service_name}"}), 500

    except Exception as e:
        logger.error(f"Error with traffic_action: {e}")
        return jsonify({"success": False, "error": str(e)}), 500

@app.route("/set_netem", methods=["POST"])
def set_netem():
    """Configure network emulation on specified interface"""
    try:
        interface = request.form.get("interface", "wlan0")
        latency = request.form.get("latency", "0")
        loss = request.form.get("loss", "0")
        jitter = request.form.get("jitter", "0")
        bandwidth = request.form.get("bandwidth", "0")

        # Call the netem helper script
        script_path = os.path.join(BASE_DIR, "scripts", "apply_netem.sh")
        result = subprocess.run(
            ['sudo', 'bash', script_path, interface, latency, loss, jitter, bandwidth],
            capture_output=True, text=True, timeout=30
        )

        if result.returncode == 0:
            log_action(f"Applied netem on {interface}: latency={latency}ms, loss={loss}%, jitter={jitter}ms, bw={bandwidth}Mbit")
            flash(f"Network emulation applied on {interface}", "success")
        else:
            flash(f"Failed to apply network emulation: {result.stderr}", "error")

    except Exception as e:
        logger.error(f"Error setting netem: {e}")
        flash(f"Error configuring network emulation: {e}", "error")

    return redirect("/")

@app.route("/reboot", methods=["POST"])
def reboot():
    """Reboot system"""
    try:
        log_action("System reboot requested via UI")
        subprocess.Popen(["sudo", "reboot"])
        return jsonify({"success": True, "message": "System rebooting..."}), 200
    except Exception as e:
        logger.error(f"Error rebooting: {e}")
        return jsonify({"success": False, "error": str(e)}), 500

@app.route("/shutdown", methods=["POST"])
def shutdown():
    """Shutdown system"""
    try:
        log_action("System shutdown requested via UI")
        subprocess.Popen(["sudo", "poweroff"])
        return jsonify({"success": True, "message": "System shutting down..."}), 200
    except Exception as e:
        logger.error(f"Error shutting down: {e}")
        return jsonify({"success": False, "error": str(e)}), 500

@app.route("/api/traffic_intensity")
def api_traffic_intensity():
    """Get current traffic intensity settings"""
    try:
        # Read from settings.conf
        settings = {}
        if os.path.exists(SETTINGS_FILE):
            with open(SETTINGS_FILE, 'r') as f:
                for line in f:
                    line = line.strip()
                    if '=' in line and not line.startswith('#'):
                        key, value = line.split('=', 1)
                        settings[key.strip()] = value.strip().strip('"')
        
        intensities = {
            'eth0': settings.get('ETH0_TRAFFIC_INTENSITY', 'heavy'),
            'wlan0': settings.get('WLAN0_TRAFFIC_INTENSITY', 'medium'),
            'wlan1': settings.get('WLAN1_TRAFFIC_INTENSITY', 'light')
        }
        
        return jsonify({"success": True, "intensities": intensities})
    except Exception as e:
        logger.error(f"Error reading traffic intensity: {e}")
        return jsonify({"success": False, "error": str(e)}), 500

@app.route("/update_traffic_intensity", methods=["POST"])
def update_traffic_intensity():
    """Update traffic intensity settings"""
    try:
        eth0_intensity = request.form.get("eth0_intensity", "heavy")
        wlan0_intensity = request.form.get("wlan0_intensity", "medium")
        wlan1_intensity = request.form.get("wlan1_intensity", "light")
        restart_services = request.form.get("restart_services", "false") == "true"
        
        # Validate intensity values
        valid_intensities = ['light', 'medium', 'heavy']
        if eth0_intensity not in valid_intensities or \
           wlan0_intensity not in valid_intensities or \
           wlan1_intensity not in valid_intensities:
            return jsonify({"success": False, "error": "Invalid intensity value"}), 400
        
        # Read current settings
        settings_lines = []
        if os.path.exists(SETTINGS_FILE):
            with open(SETTINGS_FILE, 'r') as f:
                settings_lines = f.readlines()
        
        # Update or add intensity settings
        updated = {
            'ETH0_TRAFFIC_INTENSITY': False,
            'WLAN0_TRAFFIC_INTENSITY': False,
            'WLAN1_TRAFFIC_INTENSITY': False
        }
        
        new_lines = []
        for line in settings_lines:
            stripped = line.strip()
            if stripped.startswith('ETH0_TRAFFIC_INTENSITY='):
                new_lines.append(f'ETH0_TRAFFIC_INTENSITY="{eth0_intensity}"\n')
                updated['ETH0_TRAFFIC_INTENSITY'] = True
            elif stripped.startswith('WLAN0_TRAFFIC_INTENSITY='):
                new_lines.append(f'WLAN0_TRAFFIC_INTENSITY="{wlan0_intensity}"\n')
                updated['WLAN0_TRAFFIC_INTENSITY'] = True
            elif stripped.startswith('WLAN1_TRAFFIC_INTENSITY='):
                new_lines.append(f'WLAN1_TRAFFIC_INTENSITY="{wlan1_intensity}"\n')
                updated['WLAN1_TRAFFIC_INTENSITY'] = True
            else:
                new_lines.append(line)
        
        # Add missing settings
        if not updated['ETH0_TRAFFIC_INTENSITY']:
            new_lines.append(f'\nETH0_TRAFFIC_INTENSITY="{eth0_intensity}"\n')
        if not updated['WLAN0_TRAFFIC_INTENSITY']:
            new_lines.append(f'WLAN0_TRAFFIC_INTENSITY="{wlan0_intensity}"\n')
        if not updated['WLAN1_TRAFFIC_INTENSITY']:
            new_lines.append(f'WLAN1_TRAFFIC_INTENSITY="{wlan1_intensity}"\n')
        
        # Write back to file
        with open(SETTINGS_FILE, 'w') as f:
            f.writelines(new_lines)
        
        log_action(f"Traffic intensity updated: eth0={eth0_intensity}, wlan0={wlan0_intensity}, wlan1={wlan1_intensity}")
        
        # Restart services if requested
        if restart_services:
            try:
                subprocess.run(['sudo', 'systemctl', 'restart', '--no-block', 'wired-test.service'])
                subprocess.run(['sudo', 'systemctl', 'restart', '--no-block', 'wifi-good.service'])
                subprocess.run(['sudo', 'systemctl', 'restart', '--no-block', 'wifi-bad.service'])
                log_action("Services restarted after traffic intensity update")
            except Exception as e:
                logger.error(f"Error restarting services: {e}")
                return jsonify({"success": True, "warning": "Settings saved but failed to restart services"}), 200
        
        return jsonify({"success": True, "message": "Traffic intensity updated successfully"})
    except Exception as e:
        logger.error(f"Error updating traffic intensity: {e}")
        return jsonify({"success": False, "error": str(e)}), 500

# =============================================================================
# STARTUP
# =============================================================================
if __name__ == "__main__":
    log_action("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    log_action("Wi-Fi Test Dashboard v5.1.0-optimized starting")
    log_action("Single stats system: Kernel counters only")
    log_action("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    app.run(host="0.0.0.0", port=5000, debug=False)