#!/usr/bin/env bash
# Enhanced 01-dependencies.sh with NetworkManager fixes for fresh Pi installations
# This ensures NetworkManager works properly out of the box

set -euo pipefail

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; }

log_info "Installing system dependencies with NetworkManager configuration..."

# Set environment variables to prevent interactive prompts
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# Update package lists
log_info "Updating package lists..."
apt-get update -y

# CRITICAL: Fix NetworkManager conflicts on fresh Pi installations
log_info "Configuring NetworkManager for fresh Pi installation..."

# 1. Remove/disable conflicting services that interfere with NetworkManager
log_info "Removing dhcpcd conflicts..."
if systemctl is-enabled dhcpcd >/dev/null 2>&1; then
    log_info "Disabling dhcpcd to prevent NetworkManager conflicts..."
    systemctl disable dhcpcd || true
    systemctl stop dhcpcd || true
fi

# 2. Remove openresolv if present (causes DNS conflicts)
log_info "Removing openresolv conflicts..."
apt-get remove --purge -y openresolv dhcpcd5 2>/dev/null || true

# 3. Install NetworkManager and essential packages
log_info "Installing NetworkManager and core packages..."
apt-get install -y \
    network-manager \
    network-manager-gnome \
    python3 \
    python3-pip \
    python3-psutil \
    curl \
    wget \
    jq \
    iproute2 \
    wireless-tools \
    wpasupplicant \
    dos2unix \
    dnsutils \
    net-tools \
    git \
    nano \
    htop \
    iftop \
    nethogs

# 4. Configure NetworkManager properly for fresh installations
log_info "Configuring NetworkManager for optimal Wi-Fi performance..."
cat > /etc/NetworkManager/NetworkManager.conf <<EOF
[main]
plugins=ifupdown,keyfile
dhcp=dhclient
dns=default

[ifupdown]
managed=true

[device]
wifi.scan-rand-mac-address=no
wifi.powersave=2

[connectivity]
enabled=true
uri=http://connectivity-check.ubuntu.com/

[logging]
level=INFO
domains=WIFI:INFO,WIFI_SCAN:INFO
EOF

# 5. Ensure /etc/network/interfaces doesn't conflict
log_info "Cleaning up /etc/network/interfaces conflicts..."
if [[ -f "/etc/network/interfaces" ]]; then
    # Backup original
    cp /etc/network/interfaces /etc/network/interfaces.backup.$(date +%s)
    
    # Remove any wlan0 configurations that would conflict
    sed -i '/^auto wlan0/d' /etc/network/interfaces
    sed -i '/^iface wlan0/d' /etc/network/interfaces
    sed -i '/wpa-ssid/d' /etc/network/interfaces
    sed -i '/wpa-psk/d' /etc/network/interfaces
    
    log_info "Cleaned conflicting Wi-Fi configs from /etc/network/interfaces"
fi

# 6. Remove any existing wpa_supplicant configs that might conflict
log_info "Cleaning up legacy wpa_supplicant configurations..."
if [[ -f "/etc/wpa_supplicant/wpa_supplicant.conf" ]]; then
    mv /etc/wpa_supplicant/wpa_supplicant.conf /etc/wpa_supplicant/wpa_supplicant.conf.backup.$(date +%s)
    log_info "Backed up existing wpa_supplicant.conf"
fi

# 7. Install traffic generation tools
log_info "Installing traffic generation tools..."

# Install YouTube tools
log_info "Installing yt-dlp..."
if ! command -v yt-dlp >/dev/null 2>&1; then
    pip3 install yt-dlp --break-system-packages >/dev/null 2>&1 || {
        log_warn "Failed to install yt-dlp with --break-system-packages, trying without..."
        pip3 install yt-dlp >/dev/null 2>&1 || log_warn "Failed to install yt-dlp"
    }
else
    log_info "yt-dlp already installed"
fi

# Install speedtest tools
log_info "Installing speedtest tools..."
# Try official Ookla first
if curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash; then
    apt-get update >/dev/null 2>&1
    if apt-get install -y speedtest; then
        log_info "✓ Official Ookla Speedtest CLI installed"
        # Accept license automatically
        timeout 10 speedtest --accept-license --accept-gdpr >/dev/null 2>&1 || true
    else
        log_warn "Official speedtest failed, installing Python version..."
        pip3 install speedtest-cli --break-system-packages >/dev/null 2>&1 || pip3 install speedtest-cli || true
    fi
else
    log_warn "Ookla repository failed, installing Python speedtest-cli..."
    pip3 install speedtest-cli --break-system-packages >/dev/null 2>&1 || pip3 install speedtest-cli || true
fi

# Install additional tools
apt-get install -y \
    youtube-dl \
    ffmpeg \
    iperf3 \
    tcpdump \
    bmon \
    nload \
    vnstat \
    mtr-tiny \
    traceroute \
    nmap \
    ethtool 2>/dev/null || log_warn "Some optional tools failed to install"

# 8. Install Python dependencies
log_info "Installing Python dependencies..."
pip3 install flask requests --break-system-packages >/dev/null 2>&1 || {
    log_warn "Failed to install Python packages with --break-system-packages, trying without..."
    pip3 install flask requests >/dev/null 2>&1 || log_error "Failed to install Python packages"
}

# 9. Configure Wi-Fi country and hardware (Raspberry Pi specific)
if grep -q "Raspberry Pi" /proc/cpuinfo 2>/dev/null; then
    log_info "Configuring Raspberry Pi Wi-Fi settings..."
    
    # Set Wi-Fi country
    raspi-config nonint do_wifi_country US || log_warn "Failed to set Wi-Fi country"
    
    # Unblock Wi-Fi devices
    rfkill unblock wifi || log_warn "Failed to unblock Wi-Fi"
    
    # Handle Pi Zero 2W specific issues
    if grep -q "Pi Zero 2" /proc/cpuinfo; then
        log_info "Applying Pi Zero 2W Wi-Fi fixes..."
        echo 'options brcmfmac feature_disable=0x2000' > /etc/modprobe.d/02w-wifi-fix.conf
    fi
else
    log_info "Non-Raspberry Pi detected, skipping Pi-specific Wi-Fi configuration"
fi

# 10. Create NetworkManager dispatcher script for better interface management
log_info "Creating NetworkManager dispatcher script..."
mkdir -p /etc/NetworkManager/dispatcher.d
cat > /etc/NetworkManager/dispatcher.d/99-wifi-dashboard <<'EOF'
#!/bin/bash
# NetworkManager dispatcher script for Wi-Fi dashboard
# Ensures interfaces are properly managed

case "$2" in
    up|dhcp4-change|dhcp6-change)
        # Ensure all wireless interfaces are managed and available
        for iface in wlan0 wlan1 wlan2; do
            if [ -d "/sys/class/net/$iface" ]; then
                # Set interface to managed mode
                nmcli device set "$iface" managed yes 2>/dev/null || true
                
                # Bring interface up if it's down
                ip link set "$iface" up 2>/dev/null || true
            fi
        done
        ;;
    pre-down)
        # Don't interfere with disconnection
        ;;
esac
EOF
chmod +x /etc/NetworkManager/dispatcher.d/99-wifi-dashboard

# 11. Configure system optimizations for network performance
log_info "Configuring system optimizations..."
cat >> /etc/sysctl.conf <<EOF
# Wi-Fi Dashboard network optimizations
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 65536 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_congestion_control = bbr
EOF

# 12. Configure system limits for traffic generation
cat >> /etc/security/limits.conf <<EOF
# Wi-Fi Dashboard traffic generation limits
$PI_USER soft nofile 65536
$PI_USER hard nofile 65536
$PI_USER soft nproc 32768
$PI_USER hard nproc 32768
EOF

# 13. Force NetworkManager to manage all wireless interfaces
log_info "Forcing NetworkManager to manage wireless interfaces..."
for interface in wlan0 wlan1 wlan2; do
    if ip link show "$interface" >/dev/null 2>&1; then
        log_info "Setting $interface to managed mode"
        nmcli device set "$interface" managed yes >/dev/null 2>&1 || true
        # Ensure interface is up
        ip link set "$interface" up 2>/dev/null || true
    fi
done

# 14. Restart NetworkManager with new configuration
log_info "Restarting NetworkManager with new configuration..."
systemctl daemon-reload
systemctl restart NetworkManager
sleep 5

# 15. Verify NetworkManager is working properly
log_info "Verifying NetworkManager configuration..."
if systemctl is-active --quiet NetworkManager; then
    log_info "✓ NetworkManager is running"
    
    # Wait for interfaces to be detected
    sleep 5
    
    # Check if wlan0 is detected and managed
    if nmcli device status | grep -q "wlan0.*wifi"; then
        log_info "✓ wlan0 detected by NetworkManager"
        
        # Check management state
        if nmcli device show wlan0 | grep -q "GENERAL.STATE.*disconnected"; then
            log_info "✓ wlan0 is managed and ready for connections"
        else
            log_warn "⚠ wlan0 state may need attention"
        fi
    else
        log_warn "⚠ wlan0 not detected - may need hardware troubleshooting"
    fi
else
    log_error "✗ NetworkManager failed to start properly"
fi

# 16. Create a post-installation verification script
log_info "Creating post-installation verification script..."
cat > /usr/local/bin/verify-wifi-dashboard <<'VERIFY_EOF'
#!/usr/bin/env bash
# Post-installation verification for Wi-Fi Dashboard

echo "🔍 Wi-Fi Dashboard Installation Verification"
echo "==========================================="

# Check NetworkManager
if systemctl is-active --quiet NetworkManager; then
    echo "✓ NetworkManager: Running"
else
    echo "✗ NetworkManager: Not running"
fi

# Check dhcpcd conflicts
if systemctl is-active --quiet dhcpcd; then
    echo "⚠ dhcpcd: Running (may conflict)"
else
    echo "✓ dhcpcd: Not running"
fi

# Check Wi-Fi interfaces
for iface in wlan0 wlan1; do
    if ip link show "$iface" >/dev/null 2>&1; then
        state=$(nmcli device show "$iface" 2>/dev/null | grep "GENERAL.STATE" | awk '{print $2}' || echo "unknown")
        echo "✓ $iface: Detected (state: $state)"
    else
        echo "⚠ $iface: Not detected"
    fi
done

# Check Python dependencies
for pkg in flask requests; do
    if python3 -c "import $pkg" 2>/dev/null; then
        echo "✓ Python $pkg: Available"
    else
        echo "✗ Python $pkg: Missing"
    fi
done

# Check traffic tools
for tool in speedtest yt-dlp curl; do
    if command -v "$tool" >/dev/null 2>&1; then
        echo "✓ $tool: Available"
    else
        echo "⚠ $tool: Missing"
    fi
done

echo
echo "🚀 Installation verification complete!"
echo "Run 'sudo nmcli device wifi list' to scan for networks"
VERIFY_EOF

chmod +x /usr/local/bin/verify-wifi-dashboard

# 17. Clean up package cache
log_info "Cleaning up package cache..."
apt-get autoremove -y >/dev/null 2>&1 || true
apt-get autoclean >/dev/null 2>&1 || true

# 18. Final verification
log_info "Running final verification..."
if command -v python3 >/dev/null && command -v nmcli >/dev/null && systemctl is-active --quiet NetworkManager; then
    log_info "✓ Core dependencies installation completed successfully"
    log_info "✓ NetworkManager configured for fresh Pi installation"
    log_info "✓ Run 'verify-wifi-dashboard' to check installation status"
else
    log_error "✗ Some critical dependencies may be missing"
    exit 1
fi

log_info "🎉 Enhanced dependencies installation complete!"
log_info "NetworkManager is now properly configured for Wi-Fi dashboard operation"