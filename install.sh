#!/usr/bin/env bash
set -euo pipefail

# Wi-Fi Test Dashboard Installer with Auto Interface Detection
# Downloads and installs complete dashboard system from GitHub
# Usage: curl -sSL https://raw.githubusercontent.com/danryan06/wifi-dashboard/main/install.sh | sudo bash

VERSION="v5.0.2"
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

# --- NEW: Patch /etc/hosts with dashboard hostnames ---
patch_hosts_for_hostname() {
    local hn="$1"
    [[ -z "$hn" ]] && return 0

    # Remove any existing line for this hostname to avoid duplicates
    sed -i.bak "/[[:space:]]$hn$/d" /etc/hosts

    # Add fresh entry
    log_info "Ensuring /etc/hosts entry for hostname: $hn"
    echo "127.0.1.1    $hn" >> /etc/hosts
}

print_banner() {
    echo -e "${BLUE}"
    echo "███████████████████████████████████████████████████████████████████████████████"
    echo "█                                                                             █"
    echo "█  🌐 Wi-Fi Test Dashboard with Auto Interface Detection ${VERSION}           █"
    echo "█  🚦 Intelligent interface assignment for optimal performance                █"
    echo "█  📡 Speedtest CLI + YouTube Traffic + Smart Configuration                   █"
    echo "█                                                                             █"
    echo "███████████████████████████████████████████████████████████████████████████████"
    echo -e "${NC}"
}

check_requirements() {
    log_step "Checking system requirements..."
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
    
    # Check if running on Raspberry Pi
    if ! grep -q "Raspberry Pi" /proc/cpuinfo 2>/dev/null; then
        log_warn "This script is designed for Raspberry Pi, but will attempt to continue..."
    else
        # Show Pi model for interface detection
        local pi_model=$(grep "Model" /proc/cpuinfo | cut -d: -f2 | xargs 2>/dev/null || echo "Unknown")
        log_info "Detected: $pi_model"
    fi
    
    # Check internet connectivity
    if ! ping -c 1 google.com >/dev/null 2>&1; then
        log_error "Internet connection required for installation"
        exit 1
    fi
    
    # Detect Pi user
    PI_USER=$(getent passwd 1000 | cut -d: -f1 2>/dev/null || echo "pi")
    PI_HOME="/home/$PI_USER"
    export PI_USER PI_HOME
    
    log_info "✓ System requirements met"
    log_info "✓ Target user: $PI_USER ($PI_HOME)"
}

download_file() {
    local url="$1"
    local destination="$2"
    local description="${3:-file}"
    
    log_info "Downloading $description..."
    
    # Create destination directory if it doesn't exist
    mkdir -p "$(dirname "$destination")"
    
    # Download with error handling
    if curl -sSL --max-time 30 --retry 3 "$url" -o "$destination"; then
        log_info "✓ Downloaded $description"
        return 0
    else
        log_error "✗ Failed to download $description from $url"
        return 1
    fi
}

download_and_execute() {
    local script_path="$1"
    local description="$2"
    local temp_file="${INSTALL_DIR}/$(basename "$script_path")"
    
    log_step "$description"
    
    # Download the script
    if download_file "${REPO_URL}/${script_path}" "$temp_file" "$description"; then
        # Make executable and run
        chmod +x "$temp_file"
        if bash "$temp_file"; then
            log_success "✓ $description completed successfully"
        else
            log_error "✗ $description failed"
            return 1
        fi
    else
        log_error "✗ Could not download $description"
        return 1
    fi
}

create_install_directory() {
    log_step "Setting up installation environment..."
    
    # Clean up any previous installation attempts
    rm -rf "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    
    # Export variables for sub-scripts
    export INSTALL_DIR PI_USER PI_HOME VERSION REPO_URL
    
    log_info "✓ Installation directory created: $INSTALL_DIR"
}

detect_network_interfaces() {
    log_step "Detecting network interfaces for optimal assignment..."
    
    # Show available interfaces
    log_info "Available network interfaces:"
    ip link show | grep -E "^[0-9]+: (eth|wlan)[0-9].*:" | while read -r line; do
        iface=$(echo "$line" | cut -d: -f2 | tr -d ' ')
        state=$(echo "$line" | grep -o "state [A-Z]*" | awk '{print $2}' || echo "UNKNOWN")
        log_info "  $iface: $state"
    done
    
    # Count Wi-Fi interfaces
    wifi_count=$(ip link show | grep -c "wlan" || echo "0")
    log_info "Wi-Fi interfaces detected: $wifi_count"
    
    if [[ $wifi_count -eq 0 ]]; then
        log_warn "No Wi-Fi interfaces detected - you may need USB Wi-Fi adapters"
        log_warn "The system will still install but Wi-Fi testing will be limited"
    elif [[ $wifi_count -eq 1 ]]; then
        log_warn "Only 1 Wi-Fi interface detected - bad client simulation will be disabled"
        log_warn "For full functionality, consider adding a USB Wi-Fi adapter"
    else
        log_success "Multiple Wi-Fi interfaces detected - full functionality available"
    fi
}

# FIXED: Comprehensive network manager setup with proper conflict resolution
setup_network_manager() {
    log_step "Setting up NetworkManager as primary network manager..."

    # Stop and disable conflicting services first
    log_info "Disabling conflicting network services..."
    
    # Disable dhcpcd (common on Raspbian)
    if systemctl is-enabled dhcpcd >/dev/null 2>&1; then
        systemctl disable dhcpcd
        systemctl stop dhcpcd
        log_info "Disabled dhcpcd"
    fi
    
    # Disable wpa_supplicant service (NetworkManager will manage it)
    if systemctl is-enabled wpa_supplicant >/dev/null 2>&1; then
        systemctl disable wpa_supplicant
        systemctl stop wpa_supplicant || true
        log_info "Disabled standalone wpa_supplicant"
    fi
    
    # Kill any running wpa_supplicant processes
    pkill -f "wpa_supplicant" || true
    
    # Install NetworkManager if not present
    if ! command -v nmcli >/dev/null 2>&1; then
        log_info "Installing NetworkManager..."
        apt-get update
        apt-get install -y network-manager
    fi
    
    # Enable and start NetworkManager
    systemctl enable NetworkManager
    systemctl start NetworkManager
    
    # Wait for NetworkManager to initialize
    sleep 5
    
    log_info "✓ NetworkManager is now the primary network manager"
}

# FIXED: Better Wi-Fi configuration with proper dependencies
configure_wifi_settings() {
    log_step "Configuring Wi-Fi settings for Mist PoC environment..."

    # Set regulatory domain in multiple places for reliability
    log_info "Setting Wi-Fi regulatory domain to US..."
    
    # Kernel command line (persistent across reboots)
    if ! grep -q 'cfg80211.ieee80211_regdom=US' /boot/cmdline.txt 2>/dev/null; then
        sed -i 's/$/ cfg80211.ieee80211_regdom=US/' /boot/cmdline.txt
        log_info "Added regulatory domain to kernel cmdline"
    fi
    
    # Runtime setting
    iw reg set US 2>/dev/null || true
    
    # Create comprehensive NetworkManager configuration
    mkdir -p /etc/NetworkManager/conf.d
    
    # Main NetworkManager configuration for Wi-Fi dashboard
    cat > /etc/NetworkManager/conf.d/99-wifi-dashboard.conf << 'EOF'
[main]
# Ensure NetworkManager manages all devices
no-auto-default=*
plugins=ifupdown,keyfile

[device]
# Disable MAC randomization for stable DHCP/analytics
wifi.scan-rand-mac-address=no
wifi.cloned-mac-address=preserve

[connection]
# Optimize for demo environment
ipv6.method=ignore
connection.autoconnect-retries=5
connection.autoconnect-priority=10

# Faster DHCP timeouts for demo
ipv4.dhcp-timeout=30
ipv4.may-fail=false

[logging]
level=INFO
domains=WIFI:INFO,DHCP:INFO,DEVICE:INFO
EOF

    # Disable MAC randomization specifically (important for Mist analytics)
    cat > /etc/NetworkManager/conf.d/10-wifi-stable-mac.conf << 'EOF'
[device]
wifi.scan-rand-mac-address=no

[connection]
wifi.cloned-mac-address=preserve
ethernet.cloned-mac-address=preserve
EOF

    # Restart NetworkManager with new configuration
    systemctl restart NetworkManager
    
    # Wait for restart and ensure interfaces are managed
    sleep 8
    
    # Ensure all Wi-Fi interfaces are managed by NetworkManager
    for iface in $(ip link show | grep -o "wlan[0-9]" || true); do
        nmcli device set "$iface" managed yes 2>/dev/null || true
        log_info "Set $iface managed by NetworkManager"
    done
    
    log_info "✓ Wi-Fi settings optimized for Mist PoC environment"
}

# FIXED: Interface assignment that happens BEFORE service creation
assign_interfaces_early() {
    log_step "Performing early interface assignment (before service creation)..."
    
    # Create configs directory early
    mkdir -p "$PI_HOME/wifi_test_dashboard/configs"
    
    # Get list of all Wi-Fi interfaces
    wifi_interfaces=($(ip link show | grep -E "wlan[0-9]" | cut -d: -f2 | tr -d ' ' || true))
    
    log_info "Detected Wi-Fi interfaces: ${wifi_interfaces[*]:-none}"
    
    # Smart interface assignment
    local good_client_iface="wlan0"
    local bad_client_iface=""
    local capabilities="builtin"
    
    # Assign good client interface
    if [[ ${#wifi_interfaces[@]} -gt 0 ]]; then
        good_client_iface="${wifi_interfaces[0]}"
        
        # Detect capabilities
        if [[ "$good_client_iface" == "wlan0" ]]; then
            if grep -qE "Raspberry Pi (4|3 Model B Plus|Zero 2)" /proc/cpuinfo 2>/dev/null; then
                capabilities="builtin_dualband"
            else
                capabilities="builtin"
            fi
        else
            capabilities="usb"
        fi
        
        log_info "Assigned good client to: $good_client_iface ($capabilities)"
    fi
    
    # Assign bad client interface (if available)
    if [[ ${#wifi_interfaces[@]} -gt 1 ]]; then
        bad_client_iface="${wifi_interfaces[1]}"
        log_info "Assigned bad client to: $bad_client_iface"
    else
        log_warn "Only one Wi-Fi interface - bad client will be disabled"
    fi
    
    # Create early interface assignment file
    cat > "$PI_HOME/wifi_test_dashboard/configs/interface-assignments.conf" << EOF
# Auto-generated interface assignments (Early Assignment)
# Generated: $(date)

WIFI_GOOD_INTERFACE=$good_client_iface
WIFI_GOOD_INTERFACE_TYPE=$capabilities
WIFI_GOOD_HOSTNAME=CNXNMist-WiFiGood

WIFI_BAD_INTERFACE=${bad_client_iface:-disabled}
WIFI_BAD_INTERFACE_TYPE=${bad_client_iface:+usb}
WIFI_BAD_HOSTNAME=CNXNMist-WiFiBad

WIRED_INTERFACE=eth0
WIRED_HOSTNAME=CNXNMist-Wired

# Export for use by installation scripts
export WIFI_GOOD_INTERFACE WIFI_BAD_INTERFACE
EOF

    # Make the assignments available to subsequent scripts
    source "$PI_HOME/wifi_test_dashboard/configs/interface-assignments.conf"
    
    chown -R "$PI_USER:$PI_USER" "$PI_HOME/wifi_test_dashboard/configs/"
    
    log_info "✓ Early interface assignment completed"

    # --- NEW: Ensure hostnames resolve locally ---
    patch_hosts_for_hostname "$WIFI_GOOD_HOSTNAME"
    patch_hosts_for_hostname "$WIFI_BAD_HOSTNAME"
    patch_hosts_for_hostname "$WIRED_HOSTNAME"
}

main_installation() {
    log_step "Starting main installation process..."
    
    # FIXED: Reordered installation steps with better dependencies
    local install_steps=(
        "scripts/install/01-dependencies.sh:Installing system dependencies"
        "scripts/install/02-cleanup.sh:Cleaning up previous installations"  
        "scripts/install/03-directories.sh:Creating directory structure"
        "scripts/install/04-flask-app.sh:Installing Flask application"
        "scripts/install/05-templates.sh:Installing web interface templates"
        "scripts/install/06-traffic-scripts.sh:Installing traffic generation scripts"
        "scripts/install/07-services.sh:Configuring system services"
        "scripts/install/08-finalize.sh:Finalizing installation"
    )
    
    local step_num=1
    local total_steps=${#install_steps[@]}
    
    for step in "${install_steps[@]}"; do
        local script_path="${step%:*}"
        local description="${step#*:}"
        
        echo
        log_step "[$step_num/$total_steps] $description"
        
        if download_and_execute "$script_path" "$description"; then
            log_success "Step $step_num completed successfully"
        else
            log_error "Step $step_num failed. Installation cannot continue."
            exit 1
        fi
        
        ((step_num++))
    done
}

# FIXED: Service hardening with proper network dependencies
harden_services() {
    log_step "Hardening services with proper network dependencies..."
    
    local services=("wifi-dashboard.service" "wired-test.service" "wifi-good.service" "wifi-bad.service")
    
    for service in "${services[@]}"; do
        local unit_file="/etc/systemd/system/$service"
        [[ -f "$unit_file" ]] || continue
        
        log_info "Hardening $service..."
        
        # Ensure proper network dependencies
        if ! grep -q "After=NetworkManager.service" "$unit_file"; then
            sed -i '/^\[Unit\]/a After=NetworkManager.service network-online.target' "$unit_file"
        fi
        
        if ! grep -q "Wants=NetworkManager.service" "$unit_file"; then
            sed -i '/^\[Unit\]/a Wants=NetworkManager.service' "$unit_file"
        fi
        
        # Add restart policies
        if ! grep -q "Restart=on-failure" "$unit_file"; then
            sed -i '/^\[Service\]/a Restart=on-failure' "$unit_file"
            sed -i '/^\[Service\]/a RestartSec=15' "$unit_file"
        fi
        
        # Add rate limiting
        if ! grep -q "StartLimitIntervalSec=" "$unit_file"; then
            sed -i '/^\[Unit\]/a StartLimitIntervalSec=300' "$unit_file"
            sed -i '/^\[Unit\]/a StartLimitBurst=3' "$unit_file"
        fi
    done
    
    # FIXED: Remove any legacy traffic services that conflict
    local legacy_services=("traffic-eth0.service" "traffic-wlan0.service" "traffic-wlan1.service")
    
    for legacy in "${legacy_services[@]}"; do
        if systemctl list-unit-files | grep -q "^${legacy}"; then
            log_info "Removing legacy service: $legacy"
            systemctl disable --now "$legacy" 2>/dev/null || true
            rm -f "/etc/systemd/system/$legacy"
        fi
    done
    
    systemctl daemon-reload
    log_info "✓ Services hardened with proper dependencies"
}

verify_installation() {
    log_step "Verifying installation..."
    
    local checks=(
        "Dashboard directory:/home/$PI_USER/wifi_test_dashboard"
        "Flask application:/home/$PI_USER/wifi_test_dashboard/app.py"
        "Dashboard service:/etc/systemd/system/wifi-dashboard.service"
        "Configuration files:/home/$PI_USER/wifi_test_dashboard/configs"
        "Interface assignments:/home/$PI_USER/wifi_test_dashboard/configs/interface-assignments.conf"
    )
    
    local failed_checks=0
    
    for check in "${checks[@]}"; do
        local description="${check%:*}"
        local path="${check#*:}"
        
        if [[ -e "$path" ]]; then
            log_info "✓ $description: Found"
        else
            log_error "✗ $description: Missing ($path)"
            ((failed_checks++))
        fi
    done
    
    # Check if NetworkManager is managing interfaces
    if nmcli device status | grep -q "wlan0.*connected\|wlan0.*disconnected"; then
        log_info "✓ NetworkManager managing Wi-Fi interfaces"
    else
        log_warn "⚠ NetworkManager may not be managing Wi-Fi properly"
    fi
    
    # Check if dashboard service is running
    if systemctl is-active --quiet wifi-dashboard.service; then
        log_info "✓ Dashboard service: Running"
    else
        log_warn "⚠ Dashboard service: Not running (will be started after configuration)"
    fi
    
    if [[ $failed_checks -eq 0 ]]; then
        log_success "✓ Installation verification passed"
        return 0
    else
        log_error "✗ Installation verification failed ($failed_checks issues)"
        return 1
    fi
}

cleanup_installation() {
    log_step "Cleaning up installation files..."
    rm -rf "$INSTALL_DIR"
    log_info "✓ Installation files cleaned up"
}

print_success_message() {
    local pi_ip
    pi_ip=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "IP_NOT_FOUND")
    
    # Read interface assignments
    local good_iface="wlan0"
    local bad_iface="disabled"
    local interface_summary=""
    
    if [[ -f "/home/$PI_USER/wifi_test_dashboard/configs/interface-assignments.conf" ]]; then
        source "/home/$PI_USER/wifi_test_dashboard/configs/interface-assignments.conf" 2>/dev/null || true
        good_iface="$WIFI_GOOD_INTERFACE"
        bad_iface="${WIFI_BAD_INTERFACE:-disabled}"
        
        interface_summary="
🎯 INTELLIGENT INTERFACE ASSIGNMENT:
  • Good Wi-Fi Client: $good_iface ($WIFI_GOOD_INTERFACE_TYPE)
  • Bad Wi-Fi Client:  $bad_iface
  • Wired Client:      eth0 (ethernet)
  • Hostname Pattern:  $WIFI_GOOD_HOSTNAME / $WIFI_BAD_HOSTNAME"
    fi
    
    echo
    echo -e "${GREEN}███████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${GREEN}█                                                                             █${NC}"
    echo -e "${GREEN}█  🎉 INSTALLATION COMPLETE! 🎉                                               █${NC}"
    echo -e "${GREEN}█                                                                             █${NC}"
    echo -e "${GREEN}█  Wi-Fi Test Dashboard ${VERSION} installed successfully!                    █${NC}"
    echo -e "${GREEN}█                                                                             █${NC}"
    echo -e "${GREEN}███████████████████████████████████████████████████████████████████████████████${NC}"
    echo
    log_success "🌐 DASHBOARD ACCESS:"
    log_success "  • Main Dashboard: http://$pi_ip:5000"
    log_success "  • Traffic Control: http://$pi_ip:5000/traffic_control"
    echo
    if [[ -n "$interface_summary" ]]; then
        echo -e "${GREEN}$interface_summary${NC}"
        echo
    fi
    log_success "🚦 NETWORK IMPROVEMENTS:"
    log_success "  ✅ NetworkManager is the primary network manager"
    log_success "  ✅ Eliminated dhcpcd/wpa_supplicant conflicts"
    log_success "  ✅ Early interface assignment prevents race conditions"
    log_success "  ✅ Proper service dependencies and restart policies"
    log_success "  ✅ Legacy service cleanup completed"
    echo
    log_success "🔧 NEXT STEPS:"
    log_success "  1. Open http://$pi_ip:5000 in your web browser"
    log_success "  2. Configure your SSID and password in the Wi-Fi Config tab"
    log_success "  3. Services will auto-start after Wi-Fi configuration"
    log_success "  4. Check interface assignments in the dashboard"
    echo
    log_success "📊 TROUBLESHOOTING:"
    log_success "  • Network status: sudo nmcli device status"
    log_success "  • Service status: sudo systemctl status wifi-*.service"
    log_success "  • Dashboard logs: sudo journalctl -u wifi-dashboard.service -f"
    echo
    echo -e "${PURPLE}🎊 Your robust Wi-Fi testing system is ready for Mist PoC demos!${NC}"
    echo
}

# Error handling
handle_error() {
    local exit_code=$?
    echo
    log_error "Installation failed with exit code $exit_code"
    log_error "Check the output above for details"
    echo
    log_info "For support:"
    log_info "  • Check logs in $INSTALL_DIR if available"
    log_info "  • Visit: https://github.com/danryan06/wifi-dashboard/issues"
    log_info "  • Include your system info and error messages"
    
    cleanup_installation 2>/dev/null || true
    exit $exit_code
}

# Set error trap
trap handle_error ERR

# FIXED: Main execution with proper order
main() {
    print_banner
    check_requirements
    detect_network_interfaces
    create_install_directory
    
    # FIXED: Critical network setup happens early
    setup_network_manager
    configure_wifi_settings
    assign_interfaces_early
    
    main_installation
    harden_services

    if verify_installation; then
        cleanup_installation
        print_success_message
    else
        log_error "Installation completed but verification failed"
        log_error "The system may not work correctly"
        exit 1
    fi
}

# Run main function
main "$@"