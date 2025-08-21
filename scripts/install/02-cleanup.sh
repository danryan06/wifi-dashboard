#!/usr/bin/env bash
# Fixed: Comprehensive cleanup of previous installations and conflicting services
set -euo pipefail

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; }

log_info "Starting comprehensive cleanup of previous installations..."

DASHBOARD_DIR="$PI_HOME/wifi_test_dashboard"

# Function to safely stop and disable a service
cleanup_service() {
    local service_name="$1"
    local service_file="/etc/systemd/system/${service_name}.service"
    
    if systemctl list-unit-files | grep -q "^${service_name}.service"; then
        log_info "Cleaning up service: $service_name"
        
        # Stop the service
        if systemctl is-active --quiet "$service_name"; then
            systemctl stop "$service_name" || log_warn "Could not stop $service_name"
        fi
        
        # Disable the service
        if systemctl is-enabled --quiet "$service_name" >/dev/null 2>&1; then
            systemctl disable "$service_name" || log_warn "Could not disable $service_name"
        fi
        
        # Remove service file
        if [[ -f "$service_file" ]]; then
            rm -f "$service_file"
            log_info "Removed service file: $service_file"
        fi
    fi
}

# Clean up all dashboard-related services
log_info "Stopping and removing existing dashboard services..."

# Current services
cleanup_service "wifi-dashboard"
cleanup_service "wired-test"
cleanup_service "wifi-good"
cleanup_service "wifi-bad"

# Legacy traffic services that may conflict
cleanup_service "traffic-eth0"
cleanup_service "traffic-wlan0" 
cleanup_service "traffic-wlan1"
cleanup_service "traffic-lo"

# Other possible variations
cleanup_service "wifi-test-dashboard"
cleanup_service "wifi_dashboard"

# Clean up any orphaned network configurations  
log_info "Cleaning up orphaned network configurations..."

# Remove old NetworkManager connections that might conflict
if command -v nmcli >/dev/null 2>&1; then
    log_info "Performing NetworkManager connection cleanup..."
    
    # FIXED: Simple but comprehensive approach without pipes/subshells
    cleanup_count=0
    
    # Save all connection names to a temporary file to avoid pipe issues
    temp_connections="/tmp/nm_connections_$$"
    nmcli -t -f NAME,UUID connection show 2>/dev/null > "$temp_connections" || true
    
    if [[ -s "$temp_connections" ]]; then
        log_info "Found NetworkManager connections, checking for dashboard-related ones..."
        
        # Process each connection safely
        while IFS=':' read -r conn_name conn_uuid; do
            # Skip empty lines and headers
            [[ -z "$conn_name" || "$conn_name" == "NAME" ]] && continue
            
            # Check if this connection matches our dashboard patterns
            should_delete=false
            
            # Pattern matching for dashboard connections (replaces hardcoded TestSSID)
            if [[ "$conn_name" =~ (wifi-good-|wifi-bad-|wired-cnxn|CNXNMist|dashboard|wifi-roam-) ]]; then
                should_delete=true
            fi
            
            # Also check for connections that might be from testing
            if [[ "$conn_name" =~ (test.*wifi|demo.*wifi|poc.*wifi|simulation) ]]; then
                should_delete=true
            fi
            
            if [[ "$should_delete" == "true" ]]; then
                log_info "Removing dashboard connection: $conn_name"
                if nmcli connection delete "$conn_uuid" >/dev/null 2>&1; then
                    log_info "✓ Successfully removed: $conn_name"
                    ((cleanup_count++))
                else
                    log_warn "Could not remove: $conn_name"
                fi
            fi
            
        done < "$temp_connections"
        
        # Clean up temp file
        rm -f "$temp_connections"
        
        log_info "✓ NetworkManager cleanup completed ($cleanup_count connections removed)"
    else
        log_info "No NetworkManager connections found"
    fi
    
    # Ensure interfaces are properly managed
    log_info "Ensuring Wi-Fi interfaces are managed by NetworkManager..."
    nmcli device set wlan0 managed yes 2>/dev/null || true
    nmcli device set wlan1 managed yes 2>/dev/null || true
    
else
    log_info "NetworkManager not available, skipping connection cleanup"
fi

# Clean up old wpa_supplicant configurations
log_info "Cleaning up legacy wpa_supplicant configurations..."

if [[ -f /etc/wpa_supplicant/wpa_supplicant.conf ]]; then
    # Back up original if not already backed up
    if [[ ! -f /etc/wpa_supplicant/wpa_supplicant.conf.orig ]]; then
        cp /etc/wpa_supplicant/wpa_supplicant.conf /etc/wpa_supplicant/wpa_supplicant.conf.orig
        log_info "Backed up original wpa_supplicant.conf"
    fi
    
    # Remove any dashboard-specific entries
    if grep -q "CNXNMist\|dashboard\|test" /etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null; then
        log_info "Removing dashboard entries from wpa_supplicant.conf"
        sed -i '/CNXNMist\|dashboard\|test/,+10d' /etc/wpa_supplicant/wpa_supplicant.conf || true
    fi
fi

# Clean up old cron jobs related to dashboard
log_info "Removing old cron jobs..."
if crontab -l 2>/dev/null | grep -q "wifi.*dashboard\|traffic.*generator"; then
    log_info "Found dashboard-related cron jobs, removing..."
    crontab -l 2>/dev/null | grep -v "wifi.*dashboard\|traffic.*generator" | crontab - || log_warn "Could not update crontab"
fi

# Remove old dashboard installations
log_info "Removing old dashboard installations..."

# Common installation directories
OLD_DIRS=(
    "/home/$PI_USER/wifi_dashboard"
    "/home/$PI_USER/wifi-dashboard"
    "/home/$PI_USER/wifi_test"
    "/opt/wifi-dashboard"
    "/usr/local/wifi-dashboard"
)

for old_dir in "${OLD_DIRS[@]}"; do
    if [[ -d "$old_dir" ]]; then
        log_info "Removing old installation directory: $old_dir"
        rm -rf "$old_dir"
    fi
done

# Clean up the current dashboard directory if it exists (for fresh install)
if [[ -d "$DASHBOARD_DIR" ]]; then
    log_info "Removing existing dashboard directory: $DASHBOARD_DIR"
    
    # Stop any running processes first
    pkill -f "$DASHBOARD_DIR" || true
    
    # Remove the directory
    rm -rf "$DASHBOARD_DIR"
fi

# Clean up old log files and temporary data
log_info "Cleaning up old logs and temporary data..."

# Common log locations
LOG_DIRS=(
    "/var/log/wifi-dashboard"
    "/tmp/wifi-dashboard"
    "/tmp/traffic-gen"
)

for log_dir in "${LOG_DIRS[@]}"; do
    if [[ -d "$log_dir" ]]; then
        log_info "Removing old log directory: $log_dir"
        rm -rf "$log_dir"
    fi
done

# Clean up old Python packages that might conflict
log_info "Checking for conflicting Python packages..."

if command -v pip3 >/dev/null 2>&1; then
    # Remove any dashboard-specific packages that might conflict
    pip3 uninstall -y wifi-dashboard wifi-test-dashboard 2>/dev/null || true
fi

# Clean up old systemd timer files
log_info "Cleaning up old systemd timers..."

TIMER_FILES=(
    "/etc/systemd/system/traffic-generator.timer"
    "/etc/systemd/system/wifi-test.timer"
    "/etc/systemd/system/dashboard-update.timer"
)

for timer_file in "${TIMER_FILES[@]}"; do
    if [[ -f "$timer_file" ]]; then
        # Get timer name
        timer_name=$(basename "$timer_file" .timer)
        
        # Stop and disable timer
        systemctl stop "$timer_name.timer" 2>/dev/null || true
        systemctl disable "$timer_name.timer" 2>/dev/null || true
        
        # Remove timer file
        rm -f "$timer_file"
        log_info "Removed old timer: $timer_file"
    fi
done

# Clean up old NetworkManager configuration files that might conflict
log_info "Cleaning up old NetworkManager configuration files..."

OLD_NM_CONFIGS=(
    "/etc/NetworkManager/conf.d/01-dashboard.conf"
    "/etc/NetworkManager/conf.d/wifi-test.conf"
    "/etc/NetworkManager/conf.d/dashboard-wifi.conf"
)

for config_file in "${OLD_NM_CONFIGS[@]}"; do
    if [[ -f "$config_file" ]]; then
        log_info "Removing old NetworkManager config: $config_file"
        rm -f "$config_file"
    fi
done

# Kill any orphaned processes
log_info "Terminating orphaned dashboard processes..."

# Kill processes related to dashboard
pkill -f "wifi.*dashboard" || true
pkill -f "traffic.*generator" || true
pkill -f "connect_and_curl" || true
pkill -f "fail_auth_loop" || true
pkill -f "wired_simulation" || true

# Wait for processes to terminate
sleep 2

# Force kill if still running
pkill -9 -f "wifi.*dashboard" 2>/dev/null || true
pkill -9 -f "traffic.*generator" 2>/dev/null || true

# Clean up old package caches
log_info "Cleaning up package caches..."
apt-get autoremove -y || log_warn "Could not run autoremove"
apt-get autoclean || log_warn "Could not run autoclean"

# Reload systemd after all service cleanup
log_info "Reloading systemd daemon..."
systemctl daemon-reload

# Reset NetworkManager to clean state
if systemctl is-active --quiet NetworkManager; then
    log_info "Restarting NetworkManager for clean state..."
    systemctl restart NetworkManager
    sleep 3
fi

# Clean up any remaining PID files
log_info "Cleaning up old PID files..."
find /tmp -name "*.pid" -path "*wifi*" -delete 2>/dev/null || true
find /var/run -name "*.pid" -path "*wifi*" -delete 2>/dev/null || true

# Final verification
log_info "Verifying cleanup completion..."

# Check for remaining services
remaining_services=$(systemctl list-unit-files | grep -iE "(wifi|traffic|dashboard)" | grep -v NetworkManager || true)
if [[ -n "$remaining_services" ]]; then
    log_warn "Some dashboard-related services may still exist:"
    echo "$remaining_services"
else
    log_info "✓ All dashboard services cleaned up"
fi

# Check for remaining processes
remaining_processes=$(ps aux | grep -iE "(wifi.*dashboard|traffic.*gen)" | grep -v grep || true)
if [[ -n "$remaining_processes" ]]; then
    log_warn "Some dashboard-related processes may still be running:"
    echo "$remaining_processes"
else
    log_info "✓ All dashboard processes terminated"
fi

log_info "✓ Comprehensive cleanup completed successfully"
log_info "System is ready for fresh dashboard installation"