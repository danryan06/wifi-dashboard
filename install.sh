#!/usr/bin/env bash
# Fresh Raspberry Pi Wi-Fi Dashboard Installer
# Designed for clean Pi installations with automatic NetworkManager setup

set -euo pipefail

VERSION="v5.0.1-fresh"
REPO_URL="https://raw.githubusercontent.com/danryan06/wifi-dashboard/main"
INSTALL_DIR="/tmp/wifi-dashboard-install"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
log_success() { echo -e "${PURPLE}[SUCCESS]${NC} $1"; }

print_banner() {
    echo -e "${BLUE}"
    echo "███████████████████████████████████████████████████████████████████████████████"
    echo "█                                                                             █"
    echo "█  🌐 Wi-Fi Test Dashboard - Fresh Pi Installer ${VERSION}                   █"
    echo "█  🔧 Automatic NetworkManager Configuration                                 █"
    echo "█  📡 Optimized for Fresh Raspberry Pi Installations                        █"
    echo "█                                                                             █"
    echo "███████████████████████████████████████████████████████████████████████████████"
    echo -e "${NC}"
}

check_fresh_installation() {
    log_step "Checking system state..."
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
    
    # Detect Pi user
    PI_USER=$(getent passwd 1000 | cut -d: -f1 2>/dev/null || echo "pi")
    PI_HOME="/home/$PI_USER"
    export PI_USER PI_HOME
    
    # Check if this is a Raspberry Pi
    if ! grep -q "Raspberry Pi" /proc/cpuinfo 2>/dev/null; then
        log_warn "This script is designed for Raspberry Pi, but will attempt to continue..."
    else
        local pi_model=$(grep "Model" /proc/cpuinfo | cut -d: -f2 | xargs 2>/dev/null || echo "Unknown")
        log_info "Detected: $pi_model"
    fi
    
    # Check internet connectivity
    if ! ping -c 1 google.com >/dev/null 2>&1; then
        log_error "Internet connection required for installation"
        exit 1
    fi
    
    log_info "✓ System checks passed"
    log_info "✓ Target user: $PI_USER ($PI_HOME)"
}

install_enhanced_dependencies() {
    log_step "Installing enhanced dependencies with NetworkManager fixes..."
    
    # Use the enhanced dependencies script that handles NetworkManager properly
    cat > "${INSTALL_DIR}/01-dependencies-enhanced.sh" << 'ENHANCED_DEPS_EOF'
#!/usr/bin/env bash
# Enhanced dependencies installer with NetworkManager configuration
set -euo pipefail

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }

log_info "Installing enhanced dependencies with NetworkManager fixes..."

# Set environment variables to prevent interactive prompts
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# Update package lists
apt-get update -y

# Remove conflicting services
log_info "Removing dhcpcd conflicts..."
if systemctl is-enabled dhcpcd >/dev/null 2>&1; then
    systemctl disable dhcpcd || true
    systemctl stop dhcpcd || true
fi

# Remove problematic packages
apt-get remove --purge -y openresolv dhcpcd5 2>/dev/null || true

# Install core packages
apt-get install -y \
    network-manager \
    python3 \
    python3-pip \
    curl \
    wget \
    wireless-tools \
    wpasupplicant \
    git \
    nano

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

    # Clean up conflicting configs
if [[ -f "/etc/network/interfaces" ]]; then
    cp /etc/network/interfaces /etc/network/interfaces.backup
    sed -i '/^auto wlan0/d' /etc/network/interfaces
    sed -i '/^iface wlan0/d' /etc/network/interfaces
    sed -i '/wpa-ssid/d' /etc/network/interfaces
    sed -i '/wpa-psk/d' /etc/network/interfaces
fi

# Install Python packages
pip3 install flask requests --break-system-packages >/dev/null 2>&1 || \
pip3 install flask requests >/dev/null 2>&1

# Install traffic tools
pip3 install yt-dlp speedtest-cli --break-system-packages >/dev/null 2>&1 || \
pip3 install yt-dlp speedtest-cli >/dev/null 2>&1

# Configure Pi-specific settings
if grep -q "Raspberry Pi" /proc/cpuinfo 2>/dev/null; then
    raspi-config nonint do_wifi_country US || true
    rfkill unblock wifi || true
fi

# Force interface management
for iface in wlan0 wlan1; do
    if ip link show "$iface" >/dev/null 2>&1; then
        nmcli device set "$iface" managed yes >/dev/null 2>&1 || true
        ip link set "$iface" up 2>/dev/null || true
    fi
done

# Restart NetworkManager
systemctl restart NetworkManager
sleep 5

log_info "✓ Enhanced dependencies installation completed"
ENHANCED_DEPS_EOF

    chmod +x "${INSTALL_DIR}/01-dependencies-enhanced.sh"
    
    if bash "${INSTALL_DIR}/01-dependencies-enhanced.sh"; then
        log_success "✓ Enhanced dependencies installed successfully"
    else
        log_error "✗ Enhanced dependencies installation failed"
        return 1
    fi
}

run_main_installer() {
    log_step "Running main Wi-Fi Dashboard installation..."
    
    # Download and run the main installer, but skip dependencies since we already installed them
    if curl -sSL --max-time 30 --retry 3 "${REPO_URL}/install.sh" -o "${INSTALL_DIR}/main-install.sh"; then
        log_info "✓ Downloaded main installer"
        
        # Modify the installer to skip dependencies step
        sed -i '/01-dependencies\.sh/d' "${INSTALL_DIR}/main-install.sh"
        sed -i 's/01-dependencies\.sh:/dependencies (skipped):/' "${INSTALL_DIR}/main-install.sh"
        
        chmod +x "${INSTALL_DIR}/main-install.sh"
        
        if bash "${INSTALL_DIR}/main-install.sh"; then
            log_success "✓ Main installation completed"
        else
            log_error "✗ Main installation failed"
            return 1
        fi
    else
        log_error "✗ Failed to download main installer"
        return 1
    fi
}

verify_fresh_installation() {
    log_step "Verifying fresh installation..."
    
    local verification_passed=true
    
    # Check NetworkManager
    if systemctl is-active --quiet NetworkManager; then
        log_info "✓ NetworkManager: Running"
    else
        log_error "✗ NetworkManager: Not running"
        verification_passed=false
    fi
    
    # Check for dhcpcd conflicts
    if systemctl is-active --quiet dhcpcd; then
        log_warn "⚠ dhcpcd: Still running (may cause conflicts)"
    else
        log_info "✓ dhcpcd: Properly disabled"
    fi
    
    # Check Wi-Fi interfaces
    local wifi_interfaces_found=0
    for iface in wlan0 wlan1; do
        if ip link show "$iface" >/dev/null 2>&1; then
            local state=$(nmcli device show "$iface" 2>/dev/null | grep "GENERAL.STATE" | awk '{print $2}' || echo "unknown")
            log_info "✓ $iface: Detected (state: $state)"
            ((wifi_interfaces_found++))
        fi
    done
    
    if [[ $wifi_interfaces_found -eq 0 ]]; then
        log_warn "⚠ No Wi-Fi interfaces detected - check hardware"
    else
        log_info "✓ Found $wifi_interfaces_found Wi-Fi interface(s)"
    fi
    
    # Check dashboard service
    if systemctl is-enabled --quiet wifi-dashboard.service; then
        log_info "✓ Dashboard service: Enabled"
    else
        log_warn "⚠ Dashboard service: Not enabled"
    fi
    
    # Check Python dependencies
    if python3 -c "import flask, requests" 2>/dev/null; then
        log_info "✓ Python dependencies: Available"
    else
        log_error "✗ Python dependencies: Missing"
        verification_passed=false
    fi
    
    return $([[ "$verification_passed" == "true" ]] && echo 0 || echo 1)
}

post_installation_setup() {
    log_step "Performing post-installation setup..."
    
    # Create a quick start guide
    cat > "$PI_HOME/WIFI_DASHBOARD_QUICK_START.md" << 'QUICKSTART_EOF'
# 🚀 Wi-Fi Dashboard Quick Start Guide

## Fresh Installation Complete!

Your Wi-Fi Test Dashboard has been installed and optimized for this fresh Raspberry Pi.

## 🌐 Access Your Dashboard

Open your web browser and go to:
```
http://YOUR_PI_IP:5000
```

Find your Pi's IP address: `hostname -I`

## 📶 Configure Wi-Fi

1. Click the **Wi-Fi Config** tab
2. Enter your network SSID and password
3. Click **Save Configuration**
4. Services will automatically restart and connect

## 🚦 Monitor Traffic

- **Status Tab**: Real-time system information
- **Traffic Control**: Start/stop traffic generation
- **Logs Tab**: View detailed service logs

## 🔧 Troubleshooting

If you have connection issues:

1. Check NetworkManager status:
   ```bash
   sudo systemctl status NetworkManager
   ```

2. Verify Wi-Fi interfaces:
   ```bash
   nmcli device status
   ```

3. Scan for networks:
   ```bash
   sudo nmcli device wifi list
   ```

4. Check service logs:
   ```bash
   sudo journalctl -u wifi-good.service -f
   ```

## 📋 Fresh Installation Features

✅ **Automatic NetworkManager Setup**: Configured for optimal Wi-Fi performance
✅ **Conflict Resolution**: dhcpcd disabled, interfaces properly managed  
✅ **Password Preservation**: Connection profiles maintained between retries
✅ **Fresh Pi Optimized**: No legacy configuration conflicts

## 🎊 Your system is ready for Wi-Fi testing!
QUICKSTART_EOF

    chown "$PI_USER:$PI_USER" "$PI_HOME/WIFI_DASHBOARD_QUICK_START.md"
    
    log_info "✓ Created quick start guide: $PI_HOME/WIFI_DASHBOARD_QUICK_START.md"
}

print_success_summary() {
    local pi_ip
    pi_ip=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "IP_NOT_FOUND")
    
    echo
    echo -e "${GREEN}███████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${GREEN}█                                                                             █${NC}"
    echo -e "${GREEN}█  🎉 FRESH PI INSTALLATION COMPLETE! 🎉                                     █${NC}"
    echo -e "${GREEN}█                                                                             █${NC}"
    echo -e "${GREEN}█  Wi-Fi Test Dashboard ${VERSION} installed successfully!                   █${NC}"
    echo -e "${GREEN}█                                                                             █${NC}"
    echo -e "${GREEN}███████████████████████████████████████████████████████████████████████████████${NC}"
    echo
    log_success "🌐 DASHBOARD ACCESS:"
    log_success "  • Main Dashboard: http://$pi_ip:5000"
    log_success "  • Traffic Control: http://$pi_ip:5000/traffic_control"
    echo
    log_success "🔧 FRESH INSTALLATION OPTIMIZATIONS:"
    log_success "  ✅ NetworkManager properly configured from scratch"
    log_success "  ✅ dhcpcd conflicts automatically resolved"
    log_success "  ✅ Wi-Fi interfaces optimized for connection stability"
    log_success "  ✅ Password preservation implemented"
    log_success "  ✅ No legacy configuration conflicts"
    echo
    log_success "📋 NEXT STEPS:"
    log_success "  1. Open http://$pi_ip:5000 in your web browser"
    log_success "  2. Go to Wi-Fi Config tab and enter your network details"
    log_success "  3. Monitor connections in the Status tab"
    log_success "  4. Start traffic generation in Traffic Control"
    echo
    log_success "📚 DOCUMENTATION:"
    log_success "  • Quick Start: ~/WIFI_DASHBOARD_QUICK_START.md"
    log_success "  • Dashboard logs: /home/$PI_USER/wifi_test_dashboard/logs/"
    echo
    log_success "🎊 Your optimized Wi-Fi testing system is ready!"
    echo
}

main() {
    print_banner
    
    # Check system requirements
    check_fresh_installation
    
    # Create installation directory
    log_step "Setting up installation environment..."
    rm -rf "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    export INSTALL_DIR PI_USER PI_HOME VERSION REPO_URL
    
    # Install enhanced dependencies with NetworkManager fixes
    install_enhanced_dependencies
    
    # Run main installer (skipping dependencies)
    run_main_installer
    
    # Verify installation
    if verify_fresh_installation; then
        log_success "✓ Installation verification passed"
    else
        log_warn "⚠ Some verification checks failed, but installation may still work"
    fi
    
    # Post-installation setup
    post_installation_setup
    
    # Clean up
    rm -rf "$INSTALL_DIR"
    
    # Show success summary
    print_success_summary
}

# Error handling
handle_error() {
    local exit_code=$?
    echo
    log_error "Fresh Pi installation failed with exit code $exit_code"
    log_error "This installer is designed for fresh Raspberry Pi installations"
    echo
    log_info "For troubleshooting:"
    log_info "  • Ensure this is a fresh Pi installation"
    log_info "  • Check internet connectivity"
    log_info "  • Run: sudo systemctl status NetworkManager"
    log_info "  • Visit: https://github.com/danryan06/wifi-dashboard/issues"
    
    rm -rf "$INSTALL_DIR" 2>/dev/null || true
    exit $exit_code
}

trap handle_error ERR

# Run main installation
main "$@"