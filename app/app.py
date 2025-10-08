from flask import Flask, render_template, request, redirect, jsonify, flash
import os
import subprocess
import logging
import time
import re
import json
from datetime import datetime
import psutil

app = Flask(__name__)
app.secret_key = 'wifi-test-dashboard-secret-key'

# Configuration
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = os.path.join(BASE_DIR, "configs", "ssid.conf")
SETTINGS_FILE = os.path.join(BASE_DIR, "configs", "settings.conf")
LOG_DIR = os.path.join(BASE_DIR, "logs")

@app.after_request
def after_request(response):
    # Prevent caching of API responses
    if request.path.startswith('/api/'):
        response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
        response.headers["Pragma"] = "no-cache"
        response.headers["Expires"] = "0"
    return response

# Throughput monitoring with persistent storage
last_stats = {}
last_stats_time = 0

# Setup logging with rotation
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
    """Log action to main log file with rotation"""
    logger.info(msg)
    # Check if main log needs rotation
    rotate_log_if_needed(os.path.join(LOG_DIR, "main.log"))

def rotate_log_if_needed(log_path, max_size_mb=10, keep_backups=5):
    """Rotate log file if it exceeds max_size_mb"""
    try:
        if not os.path.exists(log_path):
            return
        
        # Check file size
        size_mb = os.path.getsize(log_path) / (1024 * 1024)
        if size_mb > max_size_mb:
            # Rotate existing backups
            for i in range(keep_backups - 1, 0, -1):
                old_backup = f"{log_path}.{i}"
                new_backup = f"{log_path}.{i + 1}"
                if os.path.exists(old_backup):
                    if i == keep_backups - 1:
                        os.remove(old_backup)  # Remove oldest
                    else:
                        os.rename(old_backup, new_backup)
            
            # Move current log to .1
            if os.path.exists(log_path):
                os.rename(log_path, f"{log_path}.1")
            
            logger.info(f"Rotated log file: {log_path} (was {size_mb:.1f}MB)")
    except Exception as e:
        logger.error(f"Error rotating log {log_path}: {e}")

def read_config():
    """Read SSID configuration"""
    ssid, password = "", ""
    try:
        if os.path.exists(CONFIG_FILE):
            with open(CONFIG_FILE, 'r') as f:
                lines = [line.strip() for line in f.readlines()]
                if len(lines) >= 2:
                    ssid, password = lines[0], lines[1]
        # ALWAYS return a tuple
        return ssid, password
    except Exception as e:
        # Log the error and return safe defaults; don't return Response objects here
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

def read_log_file(log_file, lines=100, offset=0):
    """Read lines from log file with support for pagination and larger amounts"""
    log_path = os.path.join(LOG_DIR, log_file)
    try:
        if os.path.exists(log_path):
            with open(log_path, 'r') as f:
                all_lines = f.readlines()
                
            # If offset is provided, start from that line
            if offset > 0:
                all_lines = all_lines[offset:]
            
            # Return the requested number of lines, or all if less available
            if lines == -1:  # -1 means return all lines
                return all_lines
            else:
                return all_lines[-lines:] if not offset else all_lines[:lines]
        return []
    except Exception as e:
        logger.error(f"Error reading log file {log_file}: {e}")
        return [f"Error reading log: {e}"]

def get_log_file_info(log_file):
    """Get information about a log file (size, line count, etc.)"""
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

def get_network_stats():
    """Get network interface statistics from /proc/net/dev"""
    stats = {}
    try:
        with open('/proc/net/dev', 'r') as f:
            lines = f.readlines()
            
        for line in lines[2:]:  # Skip header lines
            if ':' in line:
                parts = line.split(':')
                iface = parts[0].strip()
                
                # Skip loopback and other virtual interfaces
                if iface in ['lo'] or 'docker' in iface or 'veth' in iface:
                    continue
                
                # Parse stats
                fields = parts[1].split()
                if len(fields) >= 9:
                    stats[iface] = {
                        'rx_bytes': int(fields[0]),
                        'tx_bytes': int(fields[8]),
                        'rx_packets': int(fields[1]),
                        'tx_packets': int(fields[9]),
                        'timestamp': time.time()
                    }
    except Exception as e:
        logger.error(f"Error reading network stats: {e}")
    
    return stats

def read_persistent_stats(interface):
    """FIXED: Read persistent stats with better error handling"""
    stats_file = os.path.join(BASE_DIR, "stats", f"stats_{interface}.json")
    
    # Ensure stats directory exists
    stats_dir = os.path.join(BASE_DIR, "stats")
    os.makedirs(stats_dir, exist_ok=True)
    
    try:
        if os.path.exists(stats_file):
            with open(stats_file, 'r') as f:
                data = json.load(f)
                # Validate data structure
                return {
                    'download': max(0, int(data.get('download', 0))),
                    'upload': max(0, int(data.get('upload', 0))),
                    'timestamp': float(data.get('timestamp', time.time()))
                }
        else:
            # Create initial stats file
            initial_stats = {
                'download': 0, 
                'upload': 0, 
                'timestamp': time.time()
            }
            with open(stats_file, 'w') as f:
                json.dump(initial_stats, f)
            return initial_stats
            
    except (json.JSONDecodeError, ValueError, IOError) as e:
        logger.error(f"Error reading persistent stats for {interface}: {e}")
        # Return safe defaults
        return {
            'download': 0, 
            'upload': 0, 
            'timestamp': time.time()
        }

def calculate_throughput():
    """
    FIXED: Calculate throughput with better error handling and interface filtering
    """
    global last_stats, last_stats_time

    now = time.time()
    current_stats = get_network_stats()
    throughput = {}

    # Build service map from assignments with error handling
    try:
        a = get_interface_assignments()
        good_iface = a.get('good_interface', 'wlan0')
        bad_iface = a.get('bad_interface', 'wlan1')
        wired_iface = a.get('wired_interface', 'eth0')

        service_map = {
            wired_iface: 'wired-test',
            good_iface: 'wifi-good',
        }
        if bad_iface and bad_iface != 'none':
            service_map[bad_iface] = 'wifi-bad'
    except Exception as e:
        logger.error(f"Error reading interface assignments: {e}")
        good_iface, bad_iface, wired_iface = 'wlan0', 'wlan1', 'eth0'
        service_map = {
            'eth0': 'wired-test',
            'wlan0': 'wifi-good',
            'wlan1': 'wifi-bad'
        }

    # FIXED: Only include physical interfaces, filter out virtual ones
    candidates = set()
    for iface in current_stats.keys():
        # Skip virtual interfaces
        if any(skip in iface for skip in ['lo', 'docker', 'veth', 'br-']):
            continue
        candidates.add(iface)
    
    # Always include our expected interfaces even if not in current stats
    candidates.update({wired_iface, good_iface})
    if bad_iface and bad_iface != 'none':
        candidates.add(bad_iface)

    # Compute deltas
    have_prev = bool(last_stats) and last_stats_time > 0
    dt = max(0.001, now - (last_stats_time or now))  # Avoid division by zero

    for iface in candidates:
        cur = current_stats.get(iface)
        prev = last_stats.get(iface) if have_prev else None

        # Calculate rates
        if cur and prev:
            rx_rate = max(0, (cur['rx_bytes'] - prev['rx_bytes']) / dt)
            tx_rate = max(0, (cur['tx_bytes'] - prev['tx_bytes']) / dt)
            rx_pkts = max(0, (cur['rx_packets'] - prev['rx_packets']))
            tx_pkts = max(0, (cur['tx_packets'] - prev['tx_packets']))
        else:
            rx_rate = tx_rate = 0.0
            rx_pkts = tx_pkts = 0

        # FIXED: Better service active detection
        active = False
        try:
            svc = service_map.get(iface, '')
            if svc:
                r = subprocess.run(['systemctl', 'is-active', f'{svc}.service'],
                                   capture_output=True, text=True, timeout=2)
                active = (r.stdout.strip() == 'active')
            else:
                # For interfaces without services, check if they have an IP
                active = bool(cur and cur.get('rx_bytes', 0) > 0)
        except Exception:
            active = False

        # Get persistent totals with error handling
        try:
            totals = read_persistent_stats(iface)
        except Exception as e:
            logger.error(f"Error reading persistent stats for {iface}: {e}")
            totals = {'download': 0, 'upload': 0, 'timestamp': now}

        throughput[iface] = {
            'download': rx_rate,  # bytes/s
            'upload': tx_rate,    # bytes/s  
            'active': active,
            'rx_packets': rx_pkts,
            'tx_packets': tx_pkts,
            'total_download': totals.get('download', 0),
            'total_upload': totals.get('upload', 0),
            'stats_timestamp': totals.get('timestamp', now),
        }

    # Update for next calculation
    last_stats = current_stats
    last_stats_time = now
    
    return throughput

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
        
        # Get netem status
        try:
            assignments = get_interface_assignments()
            good_iface = assignments.get('good_interface', 'wlan0')
            netem_result = subprocess.run(['tc', 'qdisc', 'show', 'dev', good_iface], 
                                        capture_output=True, text=True, timeout=5)
            netem_status = netem_result.stdout.strip() if netem_result.returncode == 0 else "No netem configured"
        except Exception:
            netem_status = "Error checking netem status"
        
        # Get NetworkManager connection status
        nm_result = subprocess.run(['nmcli', 'connection', 'show', '--active'], 
                                 capture_output=True, text=True, timeout=5)
        active_connections = nm_result.stdout.strip() if nm_result.returncode == 0 else "Error getting connections"
        
        return {
            'ip_address': ip_address,
            'interfaces': interfaces,
            'netem_status': netem_status,
            'active_connections': active_connections,
            'timestamp': datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        }
    except Exception as e:
        logger.error(f"Error getting system info: {e}")
        return {
            'ip_address': "Error",
            'interfaces': {},
            'netem_status': f"Error: {e}",
            'active_connections': f"Error: {e}",
            'timestamp': datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        }

def get_service_status():
    """Get status of all INTEGRATED services"""
    # INTEGRATED SERVICES ONLY - no separate traffic services
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

def get_interface_assignments():
    """Read and return interface assignment information (supports lower/upper-case keys)"""
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

def get_interface_capabilities():
    """Get detailed interface capabilities and status"""
    interfaces = {}
    
    try:
        # Get all network interfaces
        result = subprocess.run(['ip', 'link', 'show'], capture_output=True, text=True, timeout=5)
        
        for line in result.stdout.splitlines():
            if ':' in line and ('wlan' in line or 'eth' in line):
                parts = line.split(':')
                if len(parts) >= 2:
                    iface = parts[1].strip()
                    
                    # Get basic info
                    state = 'DOWN'
                    if 'state UP' in line:
                        state = 'UP'
                    elif 'state DOWN' in line:
                        state = 'DOWN'
                    
                    # Get IP address
                    ip_result = subprocess.run(['ip', 'addr', 'show', iface], 
                                             capture_output=True, text=True, timeout=5)
                    ip_addr = None
                    for ip_line in ip_result.stdout.splitlines():
                        if 'inet ' in ip_line and '127.0.0.1' not in ip_line:
                            ip_addr = ip_line.strip().split()[1]
                            break
                    
                    # Determine interface type
                    iface_type = 'unknown'
                    capabilities = []
                    
                    if iface.startswith('eth'):
                        iface_type = 'ethernet'
                        capabilities = ['wired', 'high_bandwidth']
                    elif iface.startswith('wlan'):
                        iface_type = 'wifi'
                        
                        # Try to determine if built-in or USB
                        try:
                            device_path = os.readlink(f'/sys/class/net/{iface}/device')
                            if 'mmc' in device_path or 'sdio' in device_path:
                                capabilities.append('builtin')
                                # Check if it's a dual-band Pi
                                with open('/proc/cpuinfo', 'r') as f:
                                    cpuinfo = f.read()
                                    if any(model in cpuinfo for model in ['Raspberry Pi 4', 'Raspberry Pi 3 Model B Plus', 'Raspberry Pi Zero 2']):
                                        capabilities.append('dual_band')
                                    else:
                                        capabilities.append('2.4ghz_only')
                            elif 'usb' in device_path:
                                capabilities.append('usb')
                                capabilities.append('2.4ghz_only')  # Assume 2.4GHz unless detected otherwise
                        except:
                            capabilities.append('unknown_type')
                    
                    # Get wireless info if available
                    wireless_info = {}
                    if iface.startswith('wlan'):
                        try:
                            # Try to get current connection info
                            nm_result = subprocess.run(['nmcli', '-t', '-f', 'ACTIVE,SSID,SIGNAL,FREQ', 'dev', 'wifi'], 
                                                     capture_output=True, text=True, timeout=5)
                            for nm_line in nm_result.stdout.splitlines():
                                if nm_line.startswith('yes:'):
                                    parts = nm_line.split(':')
                                    if len(parts) >= 4:
                                        wireless_info = {
                                            'ssid': parts[1] if parts[1] else None,
                                            'signal': parts[2] if parts[2] else None,
                                            'frequency': parts[3] if parts[3] else None
                                        }
                        except:
                            pass
                    
                    interfaces[iface] = {
                        'name': iface,
                        'type': iface_type,
                        'state': state,
                        'ip_address': ip_addr,
                        'capabilities': capabilities,
                        'wireless_info': wireless_info
                    }
                    
    except Exception as e:
        logger.error(f"Error getting interface capabilities: {e}")
    
    return interfaces

@app.route("/")
def index():
    """Main dashboard page"""
    ssid, _ = read_config()
    return render_template("dashboard.html", ssid=ssid)

def build_log_labels(assignments: dict) -> dict:
    good_iface = assignments.get("good_interface") or "wlan0"
    bad_iface  = assignments.get("bad_interface") or "wlan1"
    return {
        "main":        "Install/Upgrade",
        "wired":       "Wired Client + Heavy Traffic (eth0)",
        "wifi-good":   f"Wi-Fi Good Client + Traffic ({good_iface})",
        "wifi-bad":    f"Wi-Fi Bad Client - Auth Failures ({bad_iface})",
    }

@app.route("/status")
def status():
    """API endpoint for status information with interface assignments"""
    try:
        ssid, password = read_config()
        system_info = get_system_info()
        service_status = get_service_status()
        interface_assignments = get_interface_assignments()
        interface_capabilities = get_interface_capabilities()
        
        # Get recent logs from INTEGRATED services only - NO separate traffic services
        logs = {
            'main':       read_log_file('main.log', 50),
            'wired':      read_log_file('wired.log', 50),
            'wifi-good':  read_log_file('wifi-good.log', 50),
            'wifi-bad':   read_log_file('wifi-bad.log', 50),
        }  
        
        # Get log file information for integrated services only
        log_info = {}
        for log_name in logs.keys():
            log_info[log_name] = get_log_file_info(f'{log_name}.log')
        
        return jsonify({
            "ssid": ssid,
            "password_masked": "*" * len(password) if password else "",
            "system_info": system_info,
            "service_status": service_status,
            "interface_assignments": interface_assignments,
            "interface_capabilities": interface_capabilities,
            "logs": logs,
            "log_info": log_info,
            "log_labels": build_log_labels(interface_assignments),
            "success": True
        })

    except Exception as e:
        logger.error(f"Error in status endpoint: {e}")
        return jsonify({"success": False, "error": str(e)}), 500

@app.route("/api/logs/<log_name>")
def api_logs(log_name):
    """API endpoint for getting log content with integrated service mapping"""
    try:
        # Map friendly names & adapter names to integrated service logs
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
        if gi: alias_map[gi] = "wifi-good"
        if bi: alias_map[bi] = "wifi-bad"
        log_name = alias_map.get(log_name, log_name)

        # Only expose integrated service logs
        valid_logs = ["main", "wired", "wifi-good", "wifi-bad"]
        if log_name not in valid_logs:
            return jsonify({"success": False, "error": "Invalid log name"}), 400

        lines    = int(request.args.get("lines", 200))
        offset   = int(request.args.get("offset", 0))
        all_lines = request.args.get("all", "false").lower() == "true"

        log_content = read_log_file(f"{log_name}.log", -1 if all_lines else lines, offset)
        log_info    = get_log_file_info(f"{log_name}.log")

        return jsonify({
            "success": True,
            "log_name": log_name,
            "content": log_content,
            "info": log_info,
            "lines_returned": len(log_content),
            "offset": offset
        })
    except Exception as e:
        logger.error(f"Error in logs API endpoint: {e}")
        return jsonify({"success": False, "error": str(e)}), 500


# --- /api/throughput (full block starts) ---
@app.route("/api/throughput")
def api_throughput():
    """
    Returns current per-interface throughput (Mbps) and cumulative totals (MB)
    """
    try:
        # Call calculate_throughput ONCE - it returns ALL interfaces
        throughput_data = calculate_throughput()
        
        a = get_interface_assignments()
        candidates = set(["eth0", a.get("good_interface", "wlan0"), a.get("bad_interface", "wlan1")])
        candidates = {i for i in candidates if i}  # drop blanks

        out = {}

        for iface in candidates:
            if iface in throughput_data:
                # Use the data from calculate_throughput()
                data = throughput_data[iface]
                
                # Convert bytes/sec to Mbps
                download_mbps = round((data['download'] * 8) / 1_000_000, 2)
                upload_mbps = round((data['upload'] * 8) / 1_000_000, 2)
                
                # Convert bytes to MB for totals
                total_download_mb = round(data['total_download'] / (1024 * 1024), 1)
                total_upload_mb = round(data['total_upload'] / (1024 * 1024), 1)
                
                out[iface] = {
                    "download": download_mbps,
                    "upload": upload_mbps,
                    "active": data['active'],
                    "rx_packets": data.get('rx_packets', 0),
                    "tx_packets": data.get('tx_packets', 0),
                    "total_download": total_download_mb,
                    "total_upload": total_upload_mb,
                }
            else:
                # Interface not in throughput data
                out[iface] = {
                    "download": 0.0,
                    "upload": 0.0,
                    "active": False,
                    "rx_packets": 0,
                    "tx_packets": 0,
                    "total_download": 0.0,
                    "total_upload": 0.0,
                }

        return jsonify({"success": True, "throughput": out, "timestamp": datetime.now().isoformat()})
    except Exception as e:
        logger.exception("throughput endpoint failed")
        return jsonify({"success": False, "error": str(e), "throughput": {}, "timestamp": datetime.now().isoformat()}), 500

@app.route("/api/interfaces")
def api_interfaces():
    """API endpoint for detailed interface information"""
    try:
        interface_assignments = get_interface_assignments()
        interface_capabilities = get_interface_capabilities()
        
        # Combine assignment and capability data
        interface_data = {}
        
        # Add assignment info
        if interface_assignments['good_interface']:
            good_iface = interface_assignments['good_interface']
            interface_data[good_iface] = interface_capabilities.get(good_iface, {})
            interface_data[good_iface].update({
                'assignment': 'good_client',
                'assignment_type': interface_assignments['good_type'],
                'description': 'Wi-Fi Good Client (Successful Authentication)'
            })
        
        if interface_assignments['bad_interface']:
            bad_iface = interface_assignments['bad_interface']
            interface_data[bad_iface] = interface_capabilities.get(bad_iface, {})
            interface_data[bad_iface].update({
                'assignment': 'bad_client', 
                'assignment_type': interface_assignments['bad_type'],
                'description': 'Wi-Fi Bad Client (Authentication Failures)'
            })
        
        # Add ethernet
        if 'eth0' in interface_capabilities:
            interface_data['eth0'] = interface_capabilities['eth0']
            interface_data['eth0'].update({
                'assignment': 'wired_client',
                'assignment_type': 'ethernet',
                'description': 'Wired Ethernet Client'
            })
        
        # Add any unassigned interfaces
        for iface, data in interface_capabilities.items():
            if iface not in interface_data:
                interface_data[iface] = data
                interface_data[iface].update({
                    'assignment': 'unassigned',
                    'assignment_type': 'none',
                    'description': 'Unassigned Interface'
                })
        
        return jsonify({
            "success": True,
            "auto_detected": interface_assignments['auto_detected'],
            "interfaces": interface_data,
            "timestamp": datetime.now().isoformat()
        })
        
    except Exception as e:
        logger.error(f"Error in interfaces endpoint: {e}")
        return jsonify({"success": False, "error": str(e)}), 500

@app.route("/traffic_control")
def traffic_control():
    """Traffic control management page"""
    return render_template("traffic_control.html")

@app.route("/traffic_status")
def traffic_status():
    """API endpoint for traffic generation status (integrated services)."""
    try:
        a = get_interface_assignments()
        # Build (service, iface, description, log_file)
        items = [
            ('wired-test', a.get('wired_interface', 'eth0'),
             'Wired Client with Integrated Heavy Traffic', 'wired.log'),
            ('wifi-good',  a.get('good_interface',  'wlan0'),
             'Wi-Fi Good Client with Integrated Medium Traffic', 'wifi-good.log'),
        ]
        if a.get('bad_interface'):
            items.append(
                ('wifi-bad', a['bad_interface'],
                 'Wi-Fi Bad Client (Auth Failures for Mist PCAP)', 'wifi-bad.log')
            )

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
                    # naive parse: first 'inet ' line
                    for ln in ip_result.stdout.splitlines():
                        ln = ln.strip()
                        if ln.startswith('inet '):
                            ip_info = ln.split()[1]  # e.g., "192.168.1.111/24"
                            break

                # Recent logs (last 20 lines) + file info
                recent = read_log_file(log_file, lines=20)
                info = get_log_file_info(log_file)
                exists = bool(info.get('exists'))

                # Get persistent traffic stats
                persistent_stats = read_persistent_stats(interface)

                traffic_status_data[interface] = {
                    'service_name': service_name,
                    'service_status': status,
                    'description': description,
                    'ip_address': ip_info,
                    'recent_logs': recent,
                    'log_file_exists': exists,
                    'total_download_mb': round(persistent_stats['download'] / (1024 * 1024), 1),
                    'total_upload_mb': round(persistent_stats['upload'] / (1024 * 1024), 1),
                    'stats_timestamp': persistent_stats['timestamp']
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
                    'stats_timestamp': 0
                }

        return jsonify({"interfaces": traffic_status_data, "success": True})
    except Exception as e:
        logger.error(f"Error in traffic_status endpoint: {e}")
        return jsonify({"success": False, "error": str(e)}), 500

@app.route("/traffic_action", methods=["POST"])
def traffic_action():
    """Start/stop/restart integrated traffic/client services based on assigned interfaces."""
    try:
        interface = request.form.get("interface")
        action = request.form.get("action")

        if not interface or not action:
            return jsonify({"success": False, "error": "Missing interface or action"}), 400
        if action not in ['start', 'stop', 'restart']:
            return jsonify({"success": False, "error": "Invalid action"}), 400

        # Build valid iface set + iface->service map from assignments
        a = get_interface_assignments()
        valid_ifaces = {a.get('wired_interface', 'eth0'), a.get('good_interface', 'wlan0')}
        if a.get('bad_interface'):
            valid_ifaces.add(a['bad_interface'])

        if interface not in valid_ifaces:
            return jsonify({"success": False, "error": "Invalid interface"}), 400

        service_map = {
            a.get('wired_interface', 'eth0'): 'wired-test',
            a.get('good_interface',  'wlan0'): 'wifi-good',
        }
        if a.get('bad_interface'):
            service_map[a['bad_interface']] = 'wifi-bad'

        service_name = service_map.get(interface)
        if not service_name:
            return jsonify({"success": False, "error": "No service mapped for interface"}), 400

        # Non-blocking control so UI stays responsive if service has ExecStartPre waits
        result = subprocess.run(
            ['sudo', 'systemctl', action, '--no-block', f'{service_name}.service'],
            capture_output=True, text=True, timeout=10
        )

        if result.returncode == 0:
            log_action(f"Service {service_name} {action} via UI (iface={interface})")
            return jsonify({"success": True, "message": f"{service_name} {action} issued"})
        else:
            logger.error(f"Failed to {action} {service_name}: {result.stderr}")
            return jsonify({"success": False, "error": f"Failed to {action} {service_name}: {result.stderr}"}), 500

    except Exception as e:
        logger.error(f"Error with traffic_action: {e}")
        return jsonify({"success": False, "error": str(e)}), 500

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

            # Non-blocking restarts so the UI won't time out on ExecStartPre waits
            try:
                subprocess.run(['sudo', 'systemctl', 'restart', '--no-block', 'wifi-good.service'])
                subprocess.run(['sudo', 'systemctl', 'restart', '--no-block', 'wifi-bad.service'])
                flash("Wi-Fi services restarting in the background…", "info")

                # Run hostname verification script
                subprocess.Popen(
                    ["/home/pi/wifi_test_dashboard/scripts/verify-hostnames.sh"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL
                )

            except Exception as e:
                logger.error(f"Error restarting services: {e}")
                flash("Configuration saved but failed to restart services", "warning")
        else:
            flash("Failed to update configuration", "error")

    except Exception as e:
        logger.error(f"Error updating Wi-Fi config: {e}")
        flash(f"Error updating configuration: {e}", "error")

    return redirect("/")

@app.route("/set_netem", methods=["POST"])
def set_netem():
    """Configure network emulation on the GOOD client interface"""
    try:
        a = get_interface_assignments()
        good_iface = a.get('good_interface') or 'wlan0'

        latency = request.form.get("latency", "0")
        loss = request.form.get("loss", "0")

        # Remove existing netem safely
        subprocess.run(["sudo", "tc", "qdisc", "del", "dev", good_iface, "root"],
                       stderr=subprocess.DEVNULL, timeout=10)

        cmd = ["sudo", "tc", "qdisc", "add", "dev", good_iface, "root", "netem"]
        if int(latency) > 0:
            cmd.extend(["delay", f"{latency}ms"])
        if float(loss) > 0:
            cmd.extend(["loss", f"{loss}%"])

        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        if result.returncode == 0:
            log_action(f"Applied netem on {good_iface}: latency={latency}ms, loss={loss}%")
            flash(f"Network emulation applied on {good_iface}: {latency}ms latency, {loss}% loss", "success")
        else:
            flash(f"Failed to apply network emulation: {result.stderr}", "error")

    except Exception as e:
        logger.error(f"Error setting netem: {e}")
        flash(f"Error configuring network emulation: {e}", "error")

    return redirect("/")

@app.route("/service_action", methods=["POST"])
def service_action():
    """Start/stop/restart services"""
    try:
        service = request.form.get("service")
        action = request.form.get("action")
        
        if service not in ['wired-test', 'wifi-good', 'wifi-bad']:
            flash("Invalid service", "error")
            return redirect("/")
        
        if action not in ['start', 'stop', 'restart']:
            flash("Invalid action", "error")
            return redirect("/")
        
        result = subprocess.run(['sudo', 'systemctl', action, f'{service}.service'], 
                              capture_output=True, text=True, timeout=15)
        
        if result.returncode == 0:
            log_action(f"Service {service} {action}ed via UI")
            flash(f"Service {service} {action}ed successfully", "success")
        else:
            flash(f"Failed to {action} service {service}: {result.stderr}", "error")
            
    except Exception as e:
        logger.error(f"Error with service action: {e}")
        flash(f"Error performing service action: {e}", "error")
    
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

if __name__ == "__main__":
    log_action("Wi-Fi Test Dashboard v5.0 starting with persistent throughput tracking")
    app.run(host="0.0.0.0", port=5000, debug=False)