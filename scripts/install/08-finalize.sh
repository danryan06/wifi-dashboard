#!/usr/bin/env bash
# scripts/install/08-finalize.sh
# Finalize installation and start services

set -euo pipefail

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }

log_info "Finalizing installation..."

# Set final permissions
log_info "Setting final permissions..."
chown -R "$PI_USER:$PI_USER" "$PI_HOME/wifi_test_dashboard"
find "$PI_HOME/wifi_test_dashboard" -type f -name "*.sh" -exec chmod +x {} \;
find "$PI_HOME/wifi_test_dashboard" -type f -name "*.conf" -exec chmod 600 {} \;

# Reload systemd
log_info "Reloading systemd daemon..."
systemctl daemon-reload

# Enable services
CORE_SERVICES=("wifi-dashboard" "wired-test" "wifi-good" "wifi-bad")
# TRAFFIC_SERVICES=("traffic-eth0" "traffic-wlan0" "traffic-wlan1")
    #Commented out to try and reduce the duplicates
    
log_info "Enabling core services..."
for service in "${CORE_SERVICES[@]}"; do
    systemctl enable "${service}.service"
    log_info "✓ Enabled $service.service"
done

log_info "Enabling traffic services..."
for service in "${TRAFFIC_SERVICES[@]}"; do
    systemctl enable "${service}.service"
    log_info "✓ Enabled $service.service"
done

# Start services with delays to avoid conflicts
log_info "Starting core services..."
systemctl restart wifi-dashboard.service
sleep 3

systemctl restart wired-test.service
sleep 2
systemctl restart wifi-good.service
sleep 2
systemctl restart wifi-bad.service
sleep 2

log_info "Starting traffic generation services..."
systemctl restart traffic-eth0.service
sleep 2
systemctl restart traffic-wlan0.service  
sleep 2
systemctl restart traffic-wlan1.service

# Verify services are running
log_info "Verifying service status..."
sleep 5

ALL_SERVICES=("${CORE_SERVICES[@]}" "${TRAFFIC_SERVICES[@]}")
for service in "${ALL_SERVICES[@]}"; do
    if systemctl is-active --quiet "$service.service"; then
        log_info "✓ $service.service is running"
    else
        log_warn "✗ $service.service is not running"
    fi
done

log_info "✓ Installation finalized successfully"