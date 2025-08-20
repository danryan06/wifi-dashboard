#!/usr/bin/env bash
# scripts/install/08-finalize.sh
# Finalize installation and start services - INTEGRATED TRAFFIC VERSION

set -euo pipefail

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }

log_info "Finalizing installation with integrated traffic generation..."

# Set final permissions
log_info "Setting final permissions..."
chown -R "$PI_USER:$PI_USER" "$PI_HOME/wifi_test_dashboard"
find "$PI_HOME/wifi_test_dashboard" -type f -name "*.sh" -exec chmod +x {} \;
find "$PI_HOME/wifi_test_dashboard" -type f -name "*.conf" -exec chmod 600 {} \;

# Reload systemd
log_info "Reloading systemd daemon..."
systemctl daemon-reload

# INTEGRATED SERVICES ONLY - No separate traffic services
INTEGRATED_SERVICES=("wifi-dashboard" "wired-test" "wifi-good" "wifi-bad")

log_info "Enabling integrated services..."
for service in "${INTEGRATED_SERVICES[@]}"; do
    if systemctl enable "${service}.service"; then
        log_info "✓ Enabled $service.service"
    else
        log_warn "⚠ Failed to enable $service.service"
    fi
done

# Ensure old traffic services are completely disabled and removed
log_info "Ensuring old traffic services are disabled..."
for old_service in traffic-eth0 traffic-wlan0 traffic-wlan1; do
    if systemctl list-unit-files | grep -q "^${old_service}\.service"; then
        log_info "Disabling and removing old service: ${old_service}.service"
        systemctl stop "${old_service}.service" 2>/dev/null || true
        systemctl disable "${old_service}.service" 2>/dev/null || true
        rm -f "/etc/systemd/system/${old_service}.service"
    fi
done

# Reload again after cleanup
systemctl daemon-reload

# Start services with delays to avoid conflicts
log_info "Starting integrated services..."

# Start dashboard first
if systemctl restart wifi-dashboard.service; then
    log_info "✓ Started wifi-dashboard.service"
else
    log_warn "⚠ Failed to start wifi-dashboard.service"
fi
sleep 3

# Start wired client with integrated traffic
if systemctl restart wired-test.service; then
    log_info "✓ Started wired-test.service (with integrated heavy traffic)"
else
    log_warn "⚠ Failed to start wired-test.service"
fi
sleep 2

# Start Wi-Fi good client with integrated traffic
if systemctl restart wifi-good.service; then
    log_info "✓ Started wifi-good.service (with integrated medium traffic)"
else
    log_warn "⚠ Failed to start wifi-good.service"
fi
sleep 2

# Start Wi-Fi bad client for auth failures
if systemctl restart wifi-bad.service; then
    log_info "✓ Started wifi-bad.service (auth failures for Mist PCAP)"
else
    log_warn "⚠ Failed to start wifi-bad.service"
fi
sleep 2

# Verify services are running
log_info "Verifying integrated service status..."
sleep 5

for service in "${INTEGRATED_SERVICES[@]}"; do
  if systemctl is-active --quiet "${service}.service"; then
    log_info "✓ ${service}.service is running with integrated traffic"
  else
    svc_status=$(systemctl is-active "${service}.service" 2>/dev/null || echo "failed")
    log_warn "✗ ${service}.service status: ${svc_status}"

    if [[ "${svc_status}" == "failed" ]]; then
      log_warn "Recent logs for ${service}.service:"
      journalctl -u "${service}.service" --no-pager -n 5 2>/dev/null || true
    fi
  fi
done

# Final verification message
log_info "✓ Installation finalized with integrated traffic generation"
log_info "✓ Architecture Summary:"
log_info "  📊 wifi-dashboard.service - Web interface on port 5000"
log_info "  🔌 wired-test.service - Ethernet client + heavy traffic (eth0)"
log_info "  ✅ wifi-good.service - Wi-Fi client + medium traffic (wlan0)"
log_info "  ❌ wifi-bad.service - Auth failures for Mist PCAP (wlan1)"
log_info "✓ No separate traffic-* services needed - all integrated!"

# Check if any old traffic services are still running and warn
for old_service in traffic-eth0 traffic-wlan0 traffic-wlan1; do
    if systemctl is-active --quiet "${old_service}.service" 2>/dev/null; then
        log_warn "⚠ Old service ${old_service}.service is still running - this may cause conflicts"
        log_warn "   Run: sudo systemctl stop ${old_service}.service"
    fi
done