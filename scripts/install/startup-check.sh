#!/usr/bin/env bash
# scripts/utils/startup-check.sh - Verify hostname separation after service start
# This should be run automatically on boot and can be run manually

set -euo pipefail

DASHBOARD_DIR="/home/pi/wifi_test_dashboard"
CLIENTS_CONF="$DASHBOARD_DIR/configs/clients.conf"
LOG_FILE="$DASHBOARD_DIR/logs/main.log"

log_msg() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] STARTUP-CHECK: $1"
    echo "$msg" | tee -a "$LOG_FILE"
}

# All Wi-Fi client interfaces from clients.conf (falls back to wlan0/wlan1)
wifi_client_ifaces() {
    if [[ -f "$CLIENTS_CONF" ]]; then
        grep -Ev '^\s*(#|$)' "$CLIENTS_CONF" | cut -d: -f1
    else
        printf '%s\n' wlan0 wlan1
    fi
}

# Expected hostname for an interface, from clients.conf
expected_hostname_for() {
    local iface="$1"
    if [[ -f "$CLIENTS_CONF" ]]; then
        grep -E "^${iface}:" "$CLIENTS_CONF" | head -n1 | cut -d: -f3
    fi
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

    # Check each Wi-Fi client
    local iface expected
    while read -r iface; do
        [[ -n "$iface" ]] || continue
        expected="$(expected_hostname_for "$iface")"
        if [[ -f "/etc/dhcp/dhclient-${iface}.conf" ]]; then
            if [[ -n "$expected" ]] && grep -q "$expected" "/etc/dhcp/dhclient-${iface}.conf"; then
                log_msg "✓ $iface DHCP config present: $expected"
            elif [[ -z "$expected" ]]; then
                log_msg "✓ $iface DHCP config present"
            else
                log_msg "✗ $iface DHCP config incorrect (expected $expected)"
                all_good=false
            fi
        else
            log_msg "⚠ $iface DHCP config missing (normal until first connection)"
        fi
    done < <(wifi_client_ifaces)

    return $([[ "$all_good" == "true" ]] && echo 0 || echo 1)
}

check_service_startup() {
    log_msg "🔍 Checking service startup..."

    local services=("wired-test" "wifi-bad" "wifi-good")
    local unit
    while read -r unit _rest; do
        [[ -n "$unit" ]] && services+=("${unit%.service}")
    done < <(systemctl list-units --all --plain --no-legend 'wifi-client@*' 2>/dev/null)

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

check_interface_states() {
    log_msg "🔍 Checking interface states..."

    local ifaces=(eth0)
    while read -r iface; do
        [[ -n "$iface" ]] && ifaces+=("$iface")
    done < <(wifi_client_ifaces)

    for iface in "${ifaces[@]}"; do
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
    check_dhcp_configs
    check_interface_states
    check_service_startup

    log_msg "=========================================="
    log_msg "✅ Startup check complete"
    log_msg "=========================================="
    log_msg ""
    log_msg "💡 Next steps:"
    log_msg "  1. Check service status: systemctl status wired-test wifi-bad wifi-good 'wifi-client@*'"
    log_msg "  2. View logs: journalctl -u wifi-good -f"
    log_msg "  3. Verify hostnames after connection: sudo bash $DASHBOARD_DIR/scripts/verify-hostnames.sh"
}

main "$@"
