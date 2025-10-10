#!/usr/bin/env bash
# scripts/install/04-flask-app.sh
# Download and install Flask application

set -euo pipefail

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }

log_info "Installing Flask application..."

# Download the Flask application directly from the repository
mkdir -p "$PI_HOME/wifi_test_dashboard/app"
if curl -sSL --max-time 30 --retry 3 "${REPO_URL}/app/app.py" -o "$PI_HOME/wifi_test_dashboard/app/app.py"; then
    log_info "✓ Downloaded Flask application"
else
    log_info "✗ Failed to download Flask application, creating locally..."
    
    # Fallback: Create the Flask application locally
    cat > "$PI_HOME/wifi_test_dashboard/app/app.py" <<'FLASK_APP_EOF'
from flask import Flask, render_template, request, redirect, jsonify, flash
import os
import subprocess
import logging
from datetime import datetime

app = Flask(__name__)
app.secret_key = 'wifi-test-dashboard-secret-key'

# Configuration
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.abspath(os.path.join(BASE_DIR, ".."))
CONFIG_FILE = os.path.join(ROOT_DIR, "configs", "ssid.conf")
SETTINGS_FILE = os.path.join(ROOT_DIR, "configs", "settings.conf")
LOG_DIR = os.path.join(ROOT_DIR, "logs")

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
        traffic_status_data = {}
        
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
                
                traffic_status_data[interface] = {
                    'service_status': status,
                    'ip_address': ip_info,
                    'recent_logs': recent_logs,
                    'log_file_exists': os.path.exists(log_file)
                }
                
            except Exception as e:
                traffic_status_data[interface] = {
                    'service_status': f'error: {e}',
                    'ip_address': 'unknown',
                    'recent_logs': [],
                    'log_file_exists': False
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
FLASK_APP_EOF
fi

# Ensure proper ownership (be tolerant to older paths)
chown "$PI_USER:$PI_USER" "$PI_HOME/wifi_test_dashboard/app/app.py" 2>/dev/null || true
chown "$PI_USER:$PI_USER" "$PI_HOME/wifi_test_dashboard/app.py" 2>/dev/null || true

# Verify the Flask app can be imported
if sudo -u "$PI_USER" python3 -c "import sys; sys.path.insert(0, '$PI_HOME/wifi_test_dashboard/app'); import app" 2>/dev/null; then
    log_info "✓ Flask application verified successfully"
else
    log_info "⚠ Flask application verification had issues (may still work)"
fi

log_info "✓ Flask application installation completed"