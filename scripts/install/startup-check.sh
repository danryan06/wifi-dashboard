#!/usr/bin/env bash
# scripts/utils/startup-check.sh - Verify hostname separation after service start
# This should be run automatically on boot and can be run manually

set -euo pipefail

DASHBOARD_DIR="/home/pi/wifi_test_dashboard"
LOG_FILE="$DASHBOARD_DIR/logs/main.log"

log_msg() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] STARTUP-CHECK: $1"
    echo "$msg" | tee -a "$LOG_FILE"
}

check_dhcp_configs() {
    log_msg "🔍 Checking DHCP hostname configurations..."
    
    local all_good=true
    
    # Check wired
    if [[ -f "/etc/dhcp/dhclient-eth0.conf" ]]; then
        if grep -q "CNXNMist-Wired" "/etc/dhcp/dhclient-eth0.conf"; then
            log_msg "✓ eth0 DHCP config present: CNXNMist-Wired"
        else
            log_msg "✗ eth0 DHCP config incorrect"
            all_good=false
        fi
    else
        log_msg "⚠ eth0 DHCP config missing"
        all_good=false
    fi
    
    # Check wifi-good
    if [[ -f "/etc/dhcp/dhclient-wlan0.conf" ]]; then
        if grep -q "CNXNMist-WiFiGood" "/etc/dhcp/dhclient-wlan0.conf"; then
            log_msg "✓ wlan0 DHCP config present: CNXNMist-WiFiGood"
        else
            log_msg "✗ wlan0 DHCP config incorrect"
            all_good=false
        fi
    else
        log_msg "⚠ wlan0 DHCP config missing (normal until first connection)"
    fi
    
    # Check wifi-bad
    if [[ -f "/etc/dhcp/dhclient-wlan1.conf" ]]; then
        if grep -q "CNXNMist-WiFiBad" "/etc/dhcp/dhclient-wlan1.conf"; then
            log_msg "✓ wlan1 DHCP config present: CNXNMist-WiFiBad"
        else
            log_msg "✗ wlan1 DHCP config incorrect"
            all_good=false
        fi
    else
        log_msg "⚠ wlan1 DHCP config missing (normal until first connection)"
    fi
    
    return $([[ "$all_good" == "true" ]] && echo 0 || echo 1)
}

check_service_startup() {
    log_msg "🔍 Checking service startup sequence..."
    
    local services=("wired-test" "wifi-bad" "wifi-good")
    
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "${service}.service"; then
            log_msg "✓ ${service} is active"
        elif systemctl is-enabled --quiet "${service}.service"; then
            log_msg "⚠ ${service} is enabled but not yet active (may be starting)"
        else
            log_msg "✗ ${service} is not enabled"
        fi
    done
}

check_lock_directory() {
    log_msg "🔍 Checking lock directory..."
    
    if [[ -d "/var/run/wifi-dashboard" ]]; then
        log_msg "✓ Lock directory exists"
        
        # Check for stale locks
        local lock_count=$(ls -1 /var/run/wifi-dashboard/*.lock 2>/dev/null | wc -l)
        if [[ $lock_count -gt 0 ]]; then
            log_msg "⚠ Found $lock_count lock file(s):"
            ls -la /var/run/wifi-dashboard/*.lock 2>/dev/null | while read -r line; do
                log_msg "  $line"
            done
        else
            log_msg "✓ No lock files (clean state)"
        fi
    else
        log_msg "✗ Lock directory missing - creating..."
        sudo mkdir -p /var/run/wifi-dashboard
        sudo chmod 755 /var/run/wifi-dashboard
    fi
}

check_interface_states() {
    log_msg "🔍 Checking interface states..."
    
    for iface in eth0 wlan0 wlan1; do
        if ip link show "$iface" >/dev/null 2>&1; then
            local state=$(ip link show "$iface" | grep -o "state [A-Z]*" | awk '{print $2}')
            local ip=$(ip -4 addr show "$iface" | grep 'inet ' | awk '{print $2}' | head -1)
            log_msg "  $iface: $state ${ip:+(IP: $ip)}"
        else
            log_msg "  $iface: NOT FOUND"
        fi
    done
}

auto_fix_common_issues() {
    log_msg "🔧 Auto-fixing common issues..."
    
    # Clear any stale locks
    sudo rm -f /var/run/wifi-dashboard/*.lock 2>/dev/null && \
        log_msg "✓ Cleared stale locks" || true
    
    # Ensure lock directory has correct permissions
    sudo chmod 755 /var/run/wifi-dashboard 2>/dev/null && \
        log_msg "✓ Fixed lock directory permissions" || true
    
    # Reload NetworkManager if configs exist but services haven't started
    if [[ -f "/etc/dhcp/dhclient-eth0.conf" ]]; then
        sudo nmcli general reload 2>/dev/null && \
            log_msg "✓ Reloaded NetworkManager configuration" || true
    fi
}

wait_for_services() {
    log_msg "⏳ Waiting for services to stabilize (30 seconds)..."
    
    for i in {1..30}; do
        echo -n "." >&2
        sleep 1
    done
    echo "" >&2
    
    log_msg "✓ Wait complete"
}

main() {
    log_msg "=========================================="
    log_msg "🚀 Wi-Fi Dashboard Startup Check"
    log_msg "=========================================="
    
    # Auto-fix first
    auto_fix_common_issues
    
    # If running soon after boot, wait for services
    local uptime_seconds=$(cat /proc/uptime | cut -d' ' -f1 | cut -d'.' -f1)
    if [[ $uptime_seconds -lt 120 ]]; then
        wait_for_services
    fi
    
    # Run checks
    check_lock_directory
    check_dhcp_configs
    check_interface_states
    check_service_startup
    
    log_msg "=========================================="
    log_msg "✅ Startup check complete"
    log_msg "=========================================="
    log_msg ""
    log_msg "💡 Next steps:"
    log_msg "  1. Check service status: systemctl status wired-test wifi-bad wifi-good"
    log_msg "  2. View logs: journalctl -u wifi-good -f"
    log_msg "  3. Verify hostnames after connection: sudo bash $DASHBOARD_DIR/scripts/verify-hostnames.sh"
}

main "$@"