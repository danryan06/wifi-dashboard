#!/usr/bin/env bash
# scripts/install/01-dependencies.sh
# Install system dependencies and configure system

set -euo pipefail

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; }

log_info "Installing system dependencies..."

# Set environment variables to prevent interactive prompts
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# Update package lists
log_info "Updating package lists..."
apt-get update -y

# Install core system packages (without speedtest packages)
log_info "Installing core system packages..."
apt-get install -y \
    network-manager \
    python3 \
    python3-pip \
    curl \
    wget \
    jq \
    iproute2 \
    wireless-tools \
    wpasupplicant \
    dos2unix \
    dnsutils \
    net-tools \
    youtube-dl \
    ffmpeg \
    git \
    nano \
    htop \
    iftop \
    nethogs

# Install potentially interactive packages separately with forced non-interactive mode
log_info "Installing network testing tools..."
echo 'iperf3 iperf3/start_daemon boolean false' | debconf-set-selections
apt-get install -y iperf3 tcpdump

# Install Official Ookla Speedtest CLI (the better, official version)
log_info "Installing official Ookla Speedtest CLI..."
if ! command -v speedtest >/dev/null 2>&1; then
    # Add Ookla repository and install official speedtest
    curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash
    apt-get update >/dev/null 2>&1
    if apt-get install -y speedtest; then
        log_info "✓ Official Ookla Speedtest CLI installed"
    else
        log_warn "✗ Failed to install official speedtest, installing Python version as fallback"
        pip3 install speedtest-cli --break-system-packages || pip3 install speedtest-cli || log_warn "Failed to install any speedtest tool"
    fi
else
    log_info "✓ Speedtest CLI already available"
fi
log_info "Installing yt-dlp..."
if ! command -v yt-dlp >/dev/null 2>&1; then
    pip3 install yt-dlp --break-system-packages >/dev/null 2>&1 || {
        log_warn "Failed to install yt-dlp with --break-system-packages, trying without..."
        pip3 install yt-dlp >/dev/null 2>&1 || log_warn "Failed to install yt-dlp"
    }
else
    log_info "yt-dlp already installed"
fi

# Install Python dependencies
log_info "Installing Python dependencies..."
pip3 install flask requests --break-system-packages >/dev/null 2>&1 || {
    log_warn "Failed to install Python packages with --break-system-packages, trying without..."
    pip3 install flask requests >/dev/null 2>&1 || log_error "Failed to install Python packages"
}

# Configure Wi-Fi country and unblock (Raspberry Pi specific)
if grep -q "Raspberry Pi" /proc/cpuinfo 2>/dev/null; then
    log_info "Configuring Wi-Fi settings for Raspberry Pi..."
    raspi-config nonint do_wifi_country US || log_warn "Failed to set Wi-Fi country"
    rfkill unblock wifi || log_warn "Failed to unblock Wi-Fi"
else
    log_info "Non-Raspberry Pi detected, skipping Pi-specific Wi-Fi configuration"
fi

# Configure NetworkManager
log_info "Configuring NetworkManager..."
cat > /etc/NetworkManager/NetworkManager.conf <<EOF
[main]
plugins=ifupdown,keyfile
dhcp=dhclient

[ifupdown]
managed=true

[device]
wifi.scan-rand-mac-address=no
wifi.powersave=2
EOF

# Create NetworkManager dispatcher script for interface management
log_info "Creating NetworkManager dispatcher script..."
mkdir -p /etc/NetworkManager/dispatcher.d
cat > /etc/NetworkManager/dispatcher.d/99-wifi-dashboard <<'EOF'
#!/bin/bash
# NetworkManager dispatcher script for Wi-Fi dashboard

case "$2" in
    up|dhcp4-change|dhcp6-change)
        # Ensure all wireless interfaces are managed
        for iface in wlan0 wlan1 wlan2; do
            if [ -d "/sys/class/net/$iface" ]; then
                nmcli device set "$iface" managed yes 2>/dev/null || true
            fi
        done
        ;;
esac
EOF
chmod +x /etc/NetworkManager/dispatcher.d/99-wifi-dashboard

# Force NetworkManager to manage wireless interfaces
log_info "Configuring wireless interface management..."
for IF in wlan0 wlan1 wlan2; do
    if ip link show "$IF" >/dev/null 2>&1; then
        log_info "Setting $IF to managed mode"
        nmcli device set "$IF" managed yes >/dev/null 2>&1 || true
    fi
done

# Restart NetworkManager with new configuration
log_info "Restarting NetworkManager..."
systemctl restart NetworkManager
sleep 5

# Install Speedtest CLI (official version)
log_info "Installing official Speedtest CLI..."
if ! command -v speedtest >/dev/null 2>&1; then
    # Install Speedtest CLI repository and package
    curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash || log_warn "Failed to add Speedtest repository"
    apt-get update >/dev/null 2>&1 || true
    apt-get install -y speedtest || log_warn "Failed to install official Speedtest CLI, will use speedtest-cli"
fi

# Configure speedtest
if command -v speedtest >/dev/null 2>&1; then
    log_info "Accepting Speedtest CLI license..."
    speedtest --accept-license --accept-gdpr >/dev/null 2>&1 || log_warn "Failed to accept Speedtest license"
fi

# Install traffic control tools
log_info "Installing traffic control tools..."
apt-get install -y iproute2-dev || true

# Configure system limits for traffic generation
log_info "Configuring system limits..."
cat >> /etc/security/limits.conf <<EOF
# Wi-Fi Dashboard traffic generation limits
$PI_USER soft nofile 65536
$PI_USER hard nofile 65536
$PI_USER soft nproc 32768
$PI_USER hard nproc 32768
EOF

# Configure kernel parameters for network performance
log_info "Configuring kernel network parameters..."
cat >> /etc/sysctl.conf <<EOF
# Wi-Fi Dashboard network optimizations
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 65536 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_congestion_control = bbr
EOF

# Apply kernel parameters
sysctl -p >/dev/null 2>&1 || true

# Create systemd override directory for service tweaks
log_info "Creating systemd service overrides..."
mkdir -p /etc/systemd/system/NetworkManager.service.d
cat > /etc/systemd/system/NetworkManager.service.d/wifi-dashboard.conf <<EOF
[Service]
# Restart NetworkManager if it crashes
Restart=always
RestartSec=5
EOF

# Install additional monitoring tools if available
log_info "Installing additional monitoring tools..."
apt-get install -y \
    bmon \
    nload \
    vnstat \
    mtr-tiny \
    traceroute \
    nmap \
    ethtool 2>/dev/null || log_warn "Some monitoring tools failed to install"

# Clean up package cache
log_info "Cleaning up package cache..."
apt-get autoremove -y >/dev/null 2>&1 || true
apt-get autoclean >/dev/null 2>&1 || true

# Verify critical dependencies
log_info "Verifying critical dependencies..."
REQUIRED_COMMANDS=(
    "python3"
    "pip3"
    "curl"
    "nmcli"
    "ip"
    "systemctl"
)

MISSING_COMMANDS=()
for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING_COMMANDS+=("$cmd")
    fi
done

if [ ${#MISSING_COMMANDS[@]} -ne 0 ]; then
    log_error "Missing required commands: ${MISSING_COMMANDS[*]}"
    exit 1
fi

# Check optional dependencies
OPTIONAL_COMMANDS=(
    "speedtest"
    "speedtest-cli"
    "yt-dlp"
    "youtube-dl"
    "iperf3"
)

log_info "Checking optional dependencies..."
for cmd in "${OPTIONAL_COMMANDS[@]}"; do
    if command -v "$cmd" >/dev/null 2>&1; then
        log_info "✓ $cmd available"
    else
        log_warn "✗ $cmd not available (some features may be limited)"
    fi
done

# Test NetworkManager connectivity
log_info "Testing NetworkManager connectivity..."
if nmcli general status >/dev/null 2>&1; then
    log_info "✓ NetworkManager is responding"
else
    log_warn "✗ NetworkManager connectivity issues detected"
fi

# Test interface detection
log_info "Detecting network interfaces..."
for iface in eth0 wlan0 wlan1; do
    if ip link show "$iface" >/dev/null 2>&1; then
        log_info "✓ Interface $iface detected"
    else
        log_warn "✗ Interface $iface not found"
    fi
done

log_info "✓ System dependencies installation completed successfully"