#!/usr/bin/env bash
# scripts/install/02-cleanup.sh
# Clean up previous installations

set -euo pipefail

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }

log_info "Cleaning up previous installations..."

# Stop and disable all related services
SERVICES=(
    "wifi-dashboard" "wired-test" "wifi-good" "wifi-bad"
    "wired-test-heavy" "traffic-eth0" "traffic-wlan0" "traffic-wlan1"
)

log_info "Stopping and disabling services..."
for service in "${SERVICES[@]}"; do
    if systemctl is-active --quiet "${service}.service" 2>/dev/null; then
        log_info "Stopping ${service}.service"
        systemctl stop "${service}.service" || true
    fi
    
    if systemctl is-enabled --quiet "${service}.service" 2>/dev/null; then
        log_info "Disabling ${service}.service"
        systemctl disable "${service}.service" || true
    fi
    
    if [[ -f "/etc/systemd/system/${service}.service" ]]; then
        log_info "Removing ${service}.service file"
        rm -f "/etc/systemd/system/${service}.service"
    fi
done

# Remove installation directory
if [[ -d "$PI_HOME/wifi_test_dashboard" ]]; then
    log_info "Removing previous installation directory"
    rm -rf "$PI_HOME/wifi_test_dashboard"
fi

# Remove sudoers configuration
if [[ -f "/etc/sudoers.d/wifi_test_dashboard" ]]; then
    log_info "Removing sudoers configuration"
    rm -f /etc/sudoers.d/wifi_test_dashboard
fi

# Reload systemd after cleanup
log_info "Reloading systemd daemon"
systemctl daemon-reload

log_info "✓ Cleanup completed successfully"