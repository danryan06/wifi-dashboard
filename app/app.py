from flask import Flask, render_template, request, redirect, jsonify, flash
import os
import subprocess
import logging
import time
import re
from datetime import datetime

app = Flask(__name__)
app.secret_key = 'wifi-test-dashboard-secret-key'

# Configuration
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = os.path.join(BASE_DIR, "configs", "ssid.conf")
SETTINGS_FILE = os.path.join(BASE_DIR, "configs", "settings.conf")
LOG_DIR = os.path.join(BASE_DIR, "logs")

# Throughput monitoring
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

def calculate_throughput():
    """Calculate throughput based on network stats"""
    global last_stats, last_stats_time
    
    current_stats = get_network_stats()
    current_time = time.time()
    
    throughput = {}
    
    if last_stats and (current_time - last_stats_time) > 0:
        time_diff = current_time - last_stats_time
        
        for iface in current_stats:
            if iface in last_stats:
                current = current_stats[iface]
                previous = last_stats[iface]
                
                # Calculate bytes per second
                rx_rate = max(0, (current['rx_bytes'] - previous['rx_bytes']) / time_diff)
                tx_rate = max(0, (current['tx_bytes'] - previous['tx_bytes']) / time_diff)
                
                # Check if traffic service is active
                try:
                    result = subprocess.run(['systemctl', 'is-active', f'traffic-{iface}.service'], 
                                          capture_output=True, text=True, timeout=2)
                    is_active = result.stdout.strip() == 'active'
                except:
                    is_active = False
                
                throughput[iface] = {
                    'download': rx_rate,
                    'upload': tx_rate,
                    'active': is_active,
                    'rx_packets': current['rx_packets'] - previous['rx_packets'],
                    'tx_packets': current['tx_packets'] - previous['tx_packets']
                }
    
    # Update last stats
    last_stats = current_stats
    last_stats_time = current_time
    
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
        netem_result = subprocess.run(['tc', 'qdisc', 'show', 'dev', 'wlan0'], 
                                    capture_output=True, text=True, timeout=5)
        netem_status = netem_result.stdout.strip() if netem_result.returncode == 0 else "No netem configured"
        
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
    """Get status of all services"""
    services = ['wifi-dashboard', 'wired-test', 'wifi-good', 'wifi-bad']  # Remove traffic-eth0
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
    """Read and return interface assignment information"""
    assignments_file = os.path.join(BASE_DIR, "configs", "interface-assignments.conf")
    assignments = {
        'good_interface': 'wlan0',
        'good_type': 'unknown',
        'bad_interface': 'wlan1', 
        'bad_type': 'unknown',
        'auto_detected': False
    }
    
    try:
        if os.path.exists(assignments_file):
            with open(assignments_file, 'r') as f:
                for line in f:
                    line = line.strip()
                    if line.startswith('#') or '=' not in line:
                        continue
                    
                    key, value = line.split('=', 1)
                    key = key.strip()
                    value = value.strip()
                    
                    if key == 'WIFI_GOOD_INTERFACE':
                        assignments['good_interface'] = value
                    elif key == 'WIFI_GOOD_INTERFACE_TYPE':
                        assignments['good_type'] = value
                    elif key == 'WIFI_BAD_INTERFACE':
                        assignments['bad_interface'] = value if value != 'none' else None
                    elif key == 'WIFI_BAD_INTERFACE_TYPE':
                        assignments['bad_type'] = value
            
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
        "wired":       "Wired Client (eth0)",  # Updated description
        "wifi-good":   f"Wi-Fi Good ({good_iface})",
        "wifi-bad":    f"Wi-Fi Bad ({bad_iface})",
        # Removed traffic-eth0 entry
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
        
        # Get recent logs from all services - increased to 50 lines
        logs = {
            'main':       read_log_file('main.log', 50),
            'wired':      read_log_file('wired.log', 50),
            'wifi-good':  read_log_file('wifi-good.log', 50),
            'wifi-bad':   read_log_file('wifi-bad.log', 50),
            # 'traffic-eth0': read_log_file('traffic-eth0.log', 50),  # keep wired traffic if you use it
            # intentionally omit 'traffic-wlan0' and 'traffic-wlan1'
    }  
        
        # Get log file information
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
    """API endpoint for getting more log content with pagination"""
    try:
        # Map friendly names & adapter names to canonical logs
        assignments = get_interface_assignments()
        alias_map = {
            "good": "wifi-good",
            "good-client": "wifi-good",
            "bad": "wifi-bad",
            "bad-client": "wifi-bad",
        }
        gi = assignments.get("good_interface")
        bi = assignments.get("bad_interface")
        if gi: alias_map[gi] = "wifi-good"
        if bi: alias_map[bi] = "wifi-bad"
        log_name = alias_map.get(log_name, log_name)

        # Only expose what the UI should show
        valid_logs = ["main", "wired", "wifi-good", "wifi-bad", "traffic-eth0"]
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


@app.route("/api/throughput")
def api_throughput():
    """API endpoint for real-time throughput data"""
    try:
        throughput_data = calculate_throughput()
        return jsonify({
            "success": True,
            "throughput": throughput_data,
            "timestamp": datetime.now().isoformat()
        })
    except Exception as e:
        logger.error(f"Error in throughput endpoint: {e}")
        return jsonify({"success": False, "error": str(e)}), 500

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
    """API endpoint for traffic generation status"""
    try:
        # No separate traffic interfaces - all integrated
        interfaces = []  # Remove 'eth0' 
        traffic_status_data = {}
        
        # Show integrated client services instead
        client_services = [
            ('wired-test', 'eth0', 'Wired Client with Integrated Traffic'),
            ('wifi-good', 'wlan0', 'Wi-Fi Good Client with Integrated Traffic'),
            ('wifi-bad', 'wlan1', 'Wi-Fi Bad Client (Auth Failures)')
        ]
        
        for service, interface, description in client_services:
            try:
                # Check service status
                result = subprocess.run(['systemctl', 'is-active', f'{service}.service'], 
                                      capture_output=True, text=True, timeout=5)
                status = result.stdout.strip()
                
                # Get interface info
                ip_result = subprocess.run(['ip', 'addr', 'show', interface], 
                                         capture_output=True, text=True, timeout=5)
                ip_info = "Not available"
                if ip_result.returncode == 0:
                    for line in ip_result.stdout.splitlines():
                        if 'inet ' in line and not '127.0.0.1' in line:
                            ip_info = line.strip().split()[1]
                            break
                
                traffic_status_data[interface] = {
                    'service_status': status,
                    'ip_address': ip_info,
                    'recent_logs': [],
                    'log_file_exists': True,
                    'description': description
                }
                
            except Exception as e:
                traffic_status_data[interface] = {
                    'service_status': f'error: {e}',
                    'ip_address': 'unknown',
                    'recent_logs': [],
                    'log_file_exists': False,
                    'description': description
                }
        
        return jsonify({
            "interfaces": traffic_status_data,
            "success": True
        })
    except Exception as e:
        logger.error(f"Error in traffic_status endpoint: {e}")
        return jsonify({"success": False, "error": str(e)}), 500

@app.route("/traffic_action", methods=["POST"])
def traffic_action():
    """Start/stop/restart traffic generation services"""
    try:
        interface = request.form.get("interface")
        action = request.form.get("action")
        
        if not interface or not action:
            return jsonify({"success": False, "error": "Missing interface or action"}), 400
        
        if interface not in ['eth0', 'wlan0', 'wlan1']:
            return jsonify({"success": False, "error": "Invalid interface"}), 400
        
        if action not in ['start', 'stop', 'restart']:
            return jsonify({"success": False, "error": "Invalid action"}), 400
        
        service_name = f"traffic-{interface}"
        result = subprocess.run(['sudo', 'systemctl', action, f'{service_name}.service'], 
                              capture_output=True, text=True, timeout=15)
        
        if result.returncode == 0:
            log_action(f"Traffic service {service_name} {action}ed via UI")
            return jsonify({"success": True, "message": f"Service {service_name} {action}ed successfully"})
        else:
            logger.error(f"Failed to {action} service {service_name}: {result.stderr}")
            return jsonify({"success": False, "error": f"Failed to {action} service: {result.stderr}"}), 500
            
    except Exception as e:
        logger.error(f"Error with traffic action: {e}")
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
            
            # Restart Wi-Fi services to pick up new config
            try:
                subprocess.run(['sudo', 'systemctl', 'restart', 'wifi-good.service'], timeout=10)
                subprocess.run(['sudo', 'systemctl', 'restart', 'wifi-bad.service'], timeout=10)
                flash("Wi-Fi services restarted", "info")
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
    """Configure network emulation"""
    try:
        latency = request.form.get("latency", "0")
        loss = request.form.get("loss", "0")
        
        # Remove existing netem
        subprocess.run(["sudo", "tc", "qdisc", "del", "dev", "wlan0", "root"], 
                      stderr=subprocess.DEVNULL, timeout=10)
        
        cmd = ["sudo", "tc", "qdisc", "add", "dev", "wlan0", "root", "netem"]
        
        if int(latency) > 0:
            cmd.extend(["delay", f"{latency}ms"])
        if float(loss) > 0:
            cmd.extend(["loss", f"{loss}%"])
        
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        
        if result.returncode == 0:
            log_action(f"Applied netem: latency={latency}ms, loss={loss}%")
            flash(f"Network emulation applied: {latency}ms latency, {loss}% loss", "success")
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
    log_action("Wi-Fi Test Dashboard v5.0 starting")
    app.run(host="0.0.0.0", port=5000, debug=False)