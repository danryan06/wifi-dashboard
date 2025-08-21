#!/usr/bin/env bash
# Fixed: Smart service enablement that waits for proper network configuration
set -euo pipefail

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; }

log_info "Finalizing installation with smart service enablement..."

DASHBOARD_DIR="$PI_HOME/wifi_test_dashboard"

# Create log directories
mkdir -p "$DASHBOARD_DIR/logs"
mkdir -p "$DASHBOARD_DIR/pids"
chown -R "$PI_USER:$PI_USER" "$DASHBOARD_DIR/logs" "$DASHBOARD_DIR/pids"

# Create installation log entry
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Install/upgrade to $VERSION" >> "$DASHBOARD_DIR/logs/dashboard.log"
chown "$PI_USER:$PI_USER" "$DASHBOARD_DIR/logs/dashboard.log"

# Load interface assignments
if [[ -f "$DASHBOARD_DIR/configs/interface-assignments.conf" ]]; then
    source "$DASHBOARD_DIR/configs/interface-assignments.conf"
    log_info "Loaded interface assignments"
else
    log_warn "Interface assignments not found, using defaults"
    WIFI_GOOD_INTERFACE="wlan0"
    WIFI_BAD_INTERFACE="wlan1"
fi

# Function to check if Wi-Fi is configured
check_wifi_config() {
    local config_file="$DASHBOARD_DIR/configs/ssid.conf"
    
    if [[ ! -f "$config_file" ]]; then
        return 1
    fi
    
    if ! source "$config_file" 2>/dev/null; then
        return 1
    fi
    
    if [[ -z "${SSID:-}" || -z "${PASSWORD:-}" ]]; then
        return 1
    fi
    
    return 0
}

# Create startup condition checker
create_startup_checker() {
    log_info "Creating startup condition checker..."
    
    cat > "$DASHBOARD_DIR/scripts/check_startup_conditions.sh" << 'EOF'
#!/bin/bash
# Startup condition checker for Wi-Fi services

DASHBOARD_DIR="/home/$(whoami)/wifi_test_dashboard"
CONFIG_FILE="$DASHBOARD_DIR/configs/ssid.conf"

# Check if Wi-Fi is configured
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "WAIT: Wi-Fi not configured - $CONFIG_FILE missing"
    exit 1
fi

source "$CONFIG_FILE" 2>/dev/null || {
    echo "WAIT: Wi-Fi config file corrupted"
    exit 1
}

if [[ -z "${SSID:-}" || -z "${PASSWORD:-}" ]]; then
    echo "WAIT: SSID or PASSWORD not configured"
    exit 1
fi

# Check if NetworkManager is ready
if ! systemctl is-active --quiet NetworkManager; then
    echo "WAIT: NetworkManager not active"
    exit 1
fi

# Check if interface is available
INTERFACE="${INTERFACE:-wlan0}"
if ! nmcli device status | grep -q "$INTERFACE"; then
    echo "WAIT: Interface $INTERFACE not available to NetworkManager"
    exit 1
fi

echo "OK: All startup conditions met"
exit 0
EOF

    chmod +x "$DASHBOARD_DIR/scripts/check_startup_conditions.sh"
    chown "$PI_USER:$PI_USER" "$DASHBOARD_DIR/scripts/check_startup_conditions.sh"
}

# Create smart service starter
create_service_starter() {
    log_info "Creating smart service starter..."
    
    cat > "$DASHBOARD_DIR/scripts/start_when_ready.sh" << 'EOF'
#!/bin/bash
# Smart service starter that waits for proper conditions

DASHBOARD_DIR="/home/$(whoami)/wifi_test_dashboard"
CHECKER="$DASHBOARD_DIR/scripts/check_startup_conditions.sh"

log_info() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $1"; }
log_warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $1"; }

# Function to check and start a service
start_service_when_ready() {
    local service="$1"
    local max_wait="${2:-300}"  # 5 minutes default
    local wait_time=0
    
    log_info "Checking startup conditions for $service..."
    
    while [[ $wait_time -lt $max_wait ]]; do
        # For Wi-Fi services, check if Wi-Fi is configured
        if [[ "$service" =~ wifi ]]; then
            if bash "$CHECKER" >/dev/null 2>&1; then
                log_info "Starting $service (conditions met)"
                sudo systemctl start "$service" && return 0
                log_warn "$service failed to start"
                return 1
            else
                if [[ $((wait_time % 30)) -eq 0 ]]; then
                    local reason=$(bash "$CHECKER" 2>&1 | head -1)
                    log_info "$service waiting: $reason"
                fi
            fi
        else
            # Non-Wi-Fi services can start immediately
            log_info "Starting $service (no special conditions)"
            sudo systemctl start "$service" && return 0
            log_warn "$service failed to start"
            return 1
        fi
        
        sleep 10
        wait_time=$((wait_time + 10))
    done
    
    log_warn "$service startup timeout after ${max_wait}s"
    return 1
}

# Start services in order
log_info "=== Smart Service Startup ==="

# Always start dashboard first (no Wi-Fi dependency)
start_service_when_ready "wifi-dashboard.service"

# Start wired service (no Wi-Fi dependency)  
start_service_when_ready "wired-test.service"

# Start Wi-Fi services only when ready
start_service_when_ready "wifi-good.service" 300

# Start bad client if available
if systemctl list-unit-files | grep -q "wifi-bad.service"; then
    start_service_when_ready "wifi-bad.service" 300
fi

log_info "Smart service startup completed"
EOF

    chmod +x "$DASHBOARD_DIR/scripts/start_when_ready.sh"
    chown "$PI_USER:$PI_USER" "$DASHBOARD_DIR/scripts/start_when_ready.sh"
}

# Enable services but don't start them yet
log_info "Enabling services (but not starting until conditions are met)..."

# Always enable the dashboard service
systemctl enable wifi-dashboard.service
log_info "✓ Enabled wifi-dashboard.service"

# Enable wired service
systemctl enable wired-test.service  
log_info "✓ Enabled wired-test.service"

# Enable Wi-Fi services
systemctl enable wifi-good.service
log_info "✓ Enabled wifi-good.service"

if [[ "$WIFI_BAD_INTERFACE" != "disabled" && -n "$WIFI_BAD_INTERFACE" ]]; then
    systemctl enable wifi-bad.service
    log_info "✓ Enabled wifi-bad.service"
fi

# Create startup components
create_startup_checker
create_service_starter

# Start dashboard service immediately (it doesn't require Wi-Fi config)
log_info "Starting dashboard service..."
systemctl start wifi-dashboard.service
sleep 2

if systemctl is-active --quiet wifi-dashboard.service; then
    log_info "✓ Dashboard service started successfully"
else
    log_warn "⚠ Dashboard service failed to start, checking logs..."
    systemctl status wifi-dashboard.service --no-pager -l || true
fi

# Start wired service immediately (doesn't require Wi-Fi config)
log_info "Starting wired test service..."
systemctl start wired-test.service
sleep 2

if systemctl is-active --quiet wired-test.service; then
    log_info "✓ Wired test service started successfully"  
else
    log_warn "⚠ Wired test service failed to start, checking logs..."
    systemctl status wired-test.service --no-pager -l || true
fi

# Check if Wi-Fi is already configured
if check_wifi_config; then
    log_info "Wi-Fi is already configured, starting Wi-Fi services..."
    
    # Start Wi-Fi good service
    systemctl start wifi-good.service
    sleep 3
    
    if systemctl is-active --quiet wifi-good.service; then
        log_info "✓ Wi-Fi good service started successfully"
    else
        log_warn "⚠ Wi-Fi good service failed to start"
        systemctl status wifi-good.service --no-pager -l || true
    fi
    
    # Start Wi-Fi bad service if available
    if [[ "$WIFI_BAD_INTERFACE" != "disabled" && -n "$WIFI_BAD_INTERFACE" ]]; then
        systemctl start wifi-bad.service
        sleep 2
        
        if systemctl is-active --quiet wifi-bad.service; then
            log_info "✓ Wi-Fi bad service started successfully"
        else
            log_warn "⚠ Wi-Fi bad service failed to start"
            systemctl status wifi-bad.service --no-pager -l || true
        fi
    fi
else
    log_info "Wi-Fi not yet configured - Wi-Fi services will start automatically after configuration"
fi

# Create a service startup hook for the web interface
log_info "Creating web interface startup hook..."

cat > "$DASHBOARD_DIR/scripts/web_hook_start_services.py" << 'EOF'
#!/usr/bin/env python3
"""
Web hook to start Wi-Fi services when configuration is saved
Called by the Flask application after Wi-Fi config is updated
"""

import subprocess
import sys
import time

def start_wifi_services():
    """Start Wi-Fi services using the smart starter"""
    try:
        result = subprocess.run([
            '/bin/bash',
            '/home/pi/wifi_test_dashboard/scripts/start_when_ready.sh'
        ], capture_output=True, text=True, timeout=60)
        
        if result.returncode == 0:
            print("Wi-Fi services started successfully")
            return True
        else:
            print(f"Failed to start Wi-Fi services: {result.stderr}")
            return False
            
    except subprocess.TimeoutExpired:
        print("Timeout starting Wi-Fi services")
        return False
    except Exception as e:
        print(f"Error starting Wi-Fi services: {e}")
        return False

if __name__ == "__main__":
    success = start_wifi_services()
    sys.exit(0 if success else 1)
EOF

chmod +x "$DASHBOARD_DIR/scripts/web_hook_start_services.py"
chown "$PI_USER:$PI_USER" "$DASHBOARD_DIR/scripts/web_hook_start_services.py"

# Create status check script for debugging
cat > "$DASHBOARD_DIR/scripts/check_status.sh" << 'EOF'
#!/bin/bash
# System status checker for troubleshooting

echo "=== Wi-Fi Dashboard System Status ==="
echo

echo "--- Service Status ---"
for service in wifi-dashboard wired-test wifi-good wifi-bad; do
    if systemctl list-unit-files | grep -q "${service}.service"; then
        status=$(systemctl is-active "${service}.service" 2>/dev/null || echo "inactive")
        enabled=$(systemctl is-enabled "${service}.service" 2>/dev/null || echo "disabled")
        echo "$service: $status ($enabled)"
    fi
done
echo

echo "--- Network Interface Status ---"
nmcli device status
echo

echo "--- Wi-Fi Configuration Status ---"
config_file="/home/$(whoami)/wifi_test_dashboard/configs/ssid.conf"
if [[ -f "$config_file" ]]; then
    echo "Wi-Fi config file exists"
    if source "$config_file" 2>/dev/null && [[ -n "${SSID:-}" ]]; then
        echo "SSID configured: $SSID"
    else
        echo "Wi-Fi config file invalid or incomplete"
    fi
else
    echo "Wi-Fi config file missing"
fi
echo

echo "--- Recent Logs ---"
log_dir="/home/$(whoami)/wifi_test_dashboard/logs"
if [[ -d "$log_dir" ]]; then
    echo "Dashboard logs:"
    tail -5 "$log_dir/dashboard.log" 2>/dev/null || echo "No dashboard logs"
    echo
    echo "Wi-Fi good logs:"
    tail -5 "$log_dir/wifi-good.log" 2>/dev/null || echo "No wifi-good logs"
fi
EOF

chmod +x "$DASHBOARD_DIR/scripts/check_status.sh"
chown "$PI_USER:$PI_USER" "$DASHBOARD_DIR/scripts/check_status.sh"

# Final permissions fix
chown -R "$PI_USER:$PI_USER" "$DASHBOARD_DIR"

log_info "✓ Installation finalized successfully"
log_info "✓ Dashboard accessible at: http://$(hostname -I | awk '{print $1}'):5000"
log_info "✓ Wi-Fi services will auto-start after configuration"
log_info "✓ Use $DASHBOARD_DIR/scripts/check_status.sh for troubleshooting"