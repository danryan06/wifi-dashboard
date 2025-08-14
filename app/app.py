from flask import Flask, render_template, request, redirect, jsonify, flash
import os
import subprocess
import logging
from datetime import datetime

app = Flask(__name__)
app.secret_key = 'wifi-test-dashboard-secret-key'

# Configuration
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = os.path.join(BASE_DIR, "configs", "ssid.conf")
SETTINGS_FILE = os.path.join(BASE_DIR, "configs", "settings.conf")
LOG_DIR = os.path.join(BASE_DIR, "logs")

# Setup logging
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

def read_config():
    """Read SSID configuration"""
    ssid, password = "", ""
    try:
        if os.path.exists(CONFIG_FILE):
            with open(CONFIG_FILE, 'r') as f:
                lines = [line.strip() for line in f.readlines()]
                if len(lines) >= 2:
                    ssid, password = lines[0], lines[1]
    except Exception as e:
        logger.error(f"Error reading config: {e}")
    return ssid, password

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

def read_log_file(log_file, lines=20):
    """Read last N lines from log file"""
    log_path = os.path.join(LOG_DIR, log_file)
    try:
        if os.path.exists(log_path):
            with open(log_path, 'r') as f:
                return f.readlines()[-lines:]
        return []
    except Exception as e:
        logger.error(f"Error reading log file {log_file}: {e}")
        return [f"Error reading log: {e}"]

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
    services = ['wifi-dashboard', 'wired-test', 'wifi-good', 'wifi-bad', 
               'traffic-eth0', 'traffic-wlan0', 'traffic-wlan1']
    status = {}
    
    for service in services:
        try:
            result = subprocess.run(['systemctl', 'is-active', f'{service}.service'], 
                                  capture_output=True, text=True, timeout=5)
            status[service] = result.stdout.strip()
        except Exception as e:
            status[service] = f"Error: {e}"
    
    return status

@app.route("/")
def index():
    """Main dashboard page"""
    ssid, _ = read_config()
    return render_template("dashboard.html", ssid=ssid)

@app.route("/status")
def status():
    """API endpoint for status information"""
    try:
        ssid, password = read_config()
        system_info = get_system_info()
        service_status = get_service_status()
        
        # Get recent logs from all services
        logs = {
            'main': read_log_file('main.log', 10),
            'wired': read_log_file('wired.log', 10),
            'wifi-good': read_log_file('wifi-good.log', 10),
            'wifi-bad': read_log_file('wifi-bad.log', 10),
            'traffic-eth0': read_log_file('traffic-eth0.log', 10),
            'traffic-wlan0': read_log_file('traffic-wlan0.log', 10),
            'traffic-wlan1': read_log_file('traffic-wlan1.log', 10)
        }
        
        return jsonify({
            "ssid": ssid,
            "password_masked": "*" * len(password) if password else "",
            "system_info": system_info,
            "service_status": service_status,
            "logs": logs,
            "success": True
        })
    except Exception as e:
        logger.error(f"Error in status endpoint: {e}")
        return jsonify({"success": False, "error": str(e)}), 500

@app.route("/traffic_control")
def traffic_control():
    """Traffic control management page"""
    return render_template("traffic_control.html")

@app.route("/traffic_status")
def traffic_status():
    """API endpoint for traffic generation status"""
    try:
        interfaces = ['eth0', 'wlan0', 'wlan1']
        traffic_status = {}
        
        for interface in interfaces:
            service_name = f"traffic-{interface}"
            try:
                # Check service status
                result = subprocess.run(['systemctl', 'is-active', f'{service_name}.service'], 
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
                
                # Get recent log entries
                log_file = os.path.join(LOG_DIR, f"traffic-{interface}.log")
                recent_logs = read_log_file(f"traffic-{interface}.log", 5) if os.path.exists(log_file) else []
                
                traffic_status[interface] = {
                    'service_status': status,
                    'ip_address': ip_info,
                    'recent_logs': recent_logs,
                    'log_file_exists': os.path.exists(log_file)
                }
                
            except Exception as e:
                traffic_status[interface] = {
                    'service_status': f'error: {e}',
                    'ip_address': 'unknown',
                    'recent_logs': [],
                    'log_file_exists': False
                }
        
        return jsonify({