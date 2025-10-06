#!/usr/bin/env bash
# 08-finalize.sh - Enhanced with DHCP config pre-creation
set -euo pipefail

: "${PI_USER:=pi}"
: "${PI_HOME:=/home/${PI_USER}}"
: "${VERSION:=v5.1.0}"

export PATH="/usr/sbin:/sbin:/usr/bin:/bin:/usr/local/bin"

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; }

log_info "Finalizing installation..."

DASHBOARD_DIR="${PI_HOME}/wifi_test_dashboard"
LOG_DIR="${DASHBOARD_DIR}/logs"
CONFIGS_DIR="${DASHBOARD_DIR}/configs"

mkdir -p "$LOG_DIR" "$CONFIGS_DIR" "${DASHBOARD_DIR}/scripts" "${DASHBOARD_DIR}/stats"
chown -R "$PI_USER:$PI_USER" "$DASHBOARD_DIR"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Install/upgrade to ${VERSION}" >> "${LOG_DIR}/main.log"
chown "$PI_USER:$PI_USER" "${LOG_DIR}/main.log"

find "${DASHBOARD_DIR}/scripts" -type f -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

systemctl daemon-reload

setup_system_hostname() {
    local system_hostname="CNXNMist-Dashboard"
    local current_hostname
    current_hostname=$(hostname)

    if [[ "$current_hostname" == "localhost" || "$current_hostname" == "raspberrypi" || "$current_hostname" == "raspberry" ]]; then
        log_info "Setting system hostname to $system_hostname"

        if command -v hostnamectl >/dev/null 2>&1; then
            hostnamectl set-hostname "$system_hostname" || log_warn "Failed to set hostname via hostnamectl"
        fi

        echo "$system_hostname" > /etc/hostname || log_warn "Failed to update /etc/hostname"
        cp /etc/hosts /etc/hosts.backup.$(date +%s) 2>/dev/null || true
        sed -i '/^127\.0\.1\.1/d' /etc/hosts 2>/dev/null || true
        echo "127.0.1.1    $system_hostname" >> /etc/hosts

        log_info "✓ System hostname configured"
    else
        log_info "System hostname already set ($current_hostname), leaving as-is"
    fi
}

# NEW: Pre-create DHCP hostname configs for all interfaces
precreate_dhcp_configs() {
    log_info "Pre-creating DHCP hostname configurations..."
    
    # Create dhcp directory
    mkdir -p /etc/dhcp
    mkdir -p /etc/NetworkManager/conf.d
    
    # Wired (eth0) - CNXNMist-Wired
    log_info "Creating DHCP config for eth0 (CNXNMist-Wired)..."
    cat > /etc/dhcp/dhclient-eth0.conf << 'EOF'
# DHCP hostname for eth0 - Wired Client
send host-name "CNXNMist-Wired";
supersede host-name "CNXNMist-Wired";

request subnet-mask, broadcast-address, time-offset, routers,
        domain-name, domain-name-servers, domain-search, host-name,
        dhcp6.name-servers, dhcp6.domain-search, dhcp6.fqdn,
        netbios-name-servers, netbios-scope, interface-mtu,
        rfc3442-classless-static-routes, ntp-servers;
EOF
    
    cat > /etc/NetworkManager/conf.d/dhcp-hostname-eth0.conf << 'EOF'
[connection-eth0]
match-device=interface-name:eth0

[ipv4]
dhcp-hostname=CNXNMist-Wired
dhcp-send-hostname=yes

[ipv6]
dhcp-hostname=CNXNMist-Wired
dhcp-send-hostname=yes
EOF
    
    # Wi-Fi Good (wlan0) - CNXNMist-WiFiGood
    log_info "Creating DHCP config for wlan0 (CNXNMist-WiFiGood)..."
    cat > /etc/dhcp/dhclient-wlan0.conf << 'EOF'
# DHCP hostname for wlan0 - Wi-Fi Good Client
send host-name "CNXNMist-WiFiGood";
supersede host-name "CNXNMist-WiFiGood";

request subnet-mask, broadcast-address, time-offset, routers,
        domain-name, domain-name-servers, domain-search, host-name,
        dhcp6.name-servers, dhcp6.domain-search, dhcp6.fqdn,
        netbios-name-servers, netbios-scope, interface-mtu,
        rfc3442-classless-static-routes, ntp-servers;
EOF
    
    cat > /etc/NetworkManager/conf.d/dhcp-hostname-wlan0.conf << 'EOF'
[connection-wlan0]
match-device=interface-name:wlan0

[ipv4]
dhcp-hostname=CNXNMist-WiFiGood
dhcp-send-hostname=yes

[ipv6]
dhcp-hostname=CNXNMist-WiFiGood
dhcp-send-hostname=yes
EOF
    
    # Wi-Fi Bad (wlan1) - CNXNMist-WiFiBad
    log_info "Creating DHCP config for wlan1 (CNXNMist-WiFiBad)..."
    cat > /etc/dhcp/dhclient-wlan1.conf << 'EOF'
# DHCP hostname for wlan1 - Wi-Fi Bad Client
send host-name "CNXNMist-WiFiBad";
supersede host-name "CNXNMist-WiFiBad";

request subnet-mask, broadcast-address, time-offset, routers,
        domain-name, domain-name-servers, domain-search, host-name,
        dhcp6.name-servers, dhcp6.domain-search, dhcp6.fqdn,
        netbios-name-servers, netbios-scope, interface-mtu,
        rfc3442-classless-static-routes, ntp-servers;
EOF
    
    cat > /etc/NetworkManager/conf.d/dhcp-hostname-wlan1.conf << 'EOF'
[connection-wlan1]
match-device=interface-name:wlan1

[ipv4]
dhcp-hostname=CNXNMist-WiFiBad
dhcp-send-hostname=yes

[ipv6]
dhcp-hostname=CNXNMist-WiFiBad
dhcp-send-hostname=yes
EOF
    
    # Reload NetworkManager to pick up new configs
    log_info "Reloading NetworkManager with new DHCP configs..."
    nmcli general reload || true
    
    log_info "✓ DHCP hostname configs pre-created for all interfaces"
}

create_startup_check_script() {
    log_info "Installing startup check script..."
    
    # The startup-check.sh script should already be in scripts/utils/
    # Make sure it's executable
    if [[ -f "${DASHBOARD_DIR}/scripts/utils/startup-check.sh" ]]; then
        chmod +x "${DASHBOARD_DIR}/scripts/utils/startup-check.sh"
        chown "$PI_USER:$PI_USER" "${DASHBOARD_DIR}/scripts/utils/startup-check.sh"
        log_info "✓ Startup check script ready"
    else
        log_warn "Startup check script not found"
    fi
}

setup_system_hostname
precreate_dhcp_configs
create_startup_check_script

# Start only safe services
log_info "Starting dashboard service..."
systemctl start wifi-dashboard.service || log_warn "Failed to start wifi-dashboard"
log_info "Starting wired test service..."
systemctl start wired-test.service || log_warn "Failed to start wired-test"

# Skip Wi-Fi until SSID is configured
log_info "Skipping Wi-Fi client startup until SSID is configured"

# Run startup check after a delay
log_info "Scheduling startup verification in background..."
(
    sleep 45
    if [[ -x "${DASHBOARD_DIR}/scripts/utils/startup-check.sh" ]]; then
        bash "${DASHBOARD_DIR}/scripts/utils/startup-check.sh" >> "${LOG_DIR}/main.log" 2>&1
    fi
) &

# Final summary
host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
log_info "✓ Installation finalized successfully"
[[ -n "${host_ip:-}" ]] && log_info "✓ Dashboard available at: http://${host_ip}:5000"
log_info "✓ DHCP hostname configs pre-created for all interfaces"
log_info "✓ Services will start with proper hostname separation"

log_warn "Some checks may show as incomplete on fresh install until Wi-Fi is configured."
log_warn "This is expected - DHCP hostnames will be claimed when services connect."
log_info "ℹ️  After configuring SSID, run: sudo bash ${DASHBOARD_DIR}/scripts/utils/startup-check.sh"