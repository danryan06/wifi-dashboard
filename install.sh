#!/usr/bin/env bash
# Simplified Wi-Fi Dashboard Installer
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }

# Configuration
REPO_URL="${REPO_URL:-https://raw.githubusercontent.com/danryan06/wifi-dashboard/main}"
PI_USER="${PI_USER:-pi}"
PI_HOME="/home/$PI_USER"
DASHBOARD_DIR="$PI_HOME/wifi_test_dashboard"

print_banner() {
    echo -e "${BLUE}"
    cat << 'EOF'
╔══════════════════════════════════════════╗
║   Wi-Fi Test Dashboard - Simplified      ║
║        One-Command Installation          ║
╚══════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

# Check prerequisites
check_prereqs() {
    log_step "Checking prerequisites..."
    
    if [[ $EUID -ne 0 ]]; then
        log_error "Must be run as root (use: sudo bash install.sh)"
        exit 1
    fi
    
    if ! curl -fsSL --max-time 10 https://google.com >/dev/null 2>&1; then
        log_error "Internet connection required"
        exit 1
    fi
    
    log_info "✓ Prerequisites OK"
}

# Install system dependencies
install_dependencies() {
    log_step "Installing system dependencies..."
    
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    
    apt-get install -y \
        network-manager \
        python3 \
        python3-pip \
        python3-psutil \
        curl \
        wget \
        jq
    
    # Install Python packages
    pip3 install --break-system-packages flask requests 2>/dev/null || \
        pip3 install flask requests
    
    log_info "✓ Dependencies installed"
}

# Setup NetworkManager
setup_network() {
    log_step "Configuring NetworkManager..."
    
    # Basic NetworkManager config
    cat > /etc/NetworkManager/NetworkManager.conf <<EOF
[main]
plugins=keyfile
dhcp=dhclient

[device]
wifi.scan-rand-mac-address=no
wifi.powersave=2
EOF
    
    # Ensure wireless interfaces are managed
    for iface in wlan0 wlan1; do
        if ip link show "$iface" >/dev/null 2>&1; then
            nmcli device set "$iface" managed yes 2>/dev/null || true
        fi
    done
    
    systemctl restart NetworkManager
    sleep 3
    
    log_info "✓ NetworkManager configured"
}

# Create directory structure
create_directories() {
    log_step "Creating directory structure..."
    
    mkdir -p "$DASHBOARD_DIR"/{scripts,configs,logs,templates}
    chown -R "$PI_USER:$PI_USER" "$DASHBOARD_DIR"
    
    log_info "✓ Directories created"
}

# Download core files
download_files() {
    log_step "Downloading application files..."
    
    # Download main app
    curl -fsSL "$REPO_URL/app/app.py" -o "$DASHBOARD_DIR/app.py"
    
    # Download scripts
    mkdir -p "$DASHBOARD_DIR/scripts"
    curl -fsSL "$REPO_URL/scripts/traffic/connect_and_curl.sh" \
        -o "$DASHBOARD_DIR/scripts/connect_and_curl.sh"
    curl -fsSL "$REPO_URL/scripts/traffic/fail_auth_loop.sh" \
        -o "$DASHBOARD_DIR/scripts/fail_auth_loop.sh"
    curl -fsSL "$REPO_URL/scripts/traffic/wired_simulation.sh" \
        -o "$DASHBOARD_DIR/scripts/wired_simulation.sh"
    
    # Make scripts executable
    chmod +x "$DASHBOARD_DIR"/scripts/*.sh
    
    # Download templates
    curl -fsSL "$REPO_URL/templates/dashboard.html" \
        -o "$DASHBOARD_DIR/templates/dashboard.html" 2>/dev/null || \
        log_warn "Could not download dashboard.html template"
    
    chown -R "$PI_USER:$PI_USER" "$DASHBOARD_DIR"
    
    log_info "✓ Files downloaded"
}

# Create default configs
create_configs() {
    log_step "Creating default configuration..."
    
    # SSID config
    cat > "$DASHBOARD_DIR/configs/ssid.conf" <<EOF
YourSSID
YourPassword
EOF
    
    # Interface assignments
    cat > "$DASHBOARD_DIR/configs/interface-assignments.conf" <<EOF
good_interface=wlan0
bad_interface=wlan1
wired_interface=eth0
EOF
    
    chmod 600 "$DASHBOARD_DIR/configs/ssid.conf"
    chown -R "$PI_USER:$PI_USER" "$DASHBOARD_DIR/configs"
    
    log_info "✓ Configs created"
}

# Install systemd services
install_services() {
    log_step "Installing systemd services..."
    
    # Dashboard service
    cat > /etc/systemd/system/wifi-dashboard.service <<EOF
[Unit]
Description=Wi-Fi Test Dashboard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$PI_USER
WorkingDirectory=$DASHBOARD_DIR
ExecStart=/usr/bin/python3 $DASHBOARD_DIR/app.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    # Wired client service
    cat > /etc/systemd/system/wired-test.service <<EOF
[Unit]
Description=Wired Client
After=network-online.target NetworkManager.service

[Service]
Type=simple
User=$PI_USER
WorkingDirectory=$DASHBOARD_DIR
Environment=INTERFACE=eth0
ExecStart=/usr/bin/env bash $DASHBOARD_DIR/scripts/wired_simulation.sh
Restart=always
RestartSec=15

[Install]
WantedBy=multi-user.target
EOF

    # Wi-Fi good client service
    cat > /etc/systemd/system/wifi-good.service <<EOF
[Unit]
Description=Wi-Fi Good Client
After=network-online.target NetworkManager.service

[Service]
Type=simple
User=$PI_USER
WorkingDirectory=$DASHBOARD_DIR
Environment=INTERFACE=wlan0
ExecStart=/usr/bin/env bash $DASHBOARD_DIR/scripts/connect_and_curl.sh
Restart=always
RestartSec=20

[Install]
WantedBy=multi-user.target
EOF

    # Wi-Fi bad client service
    cat > /etc/systemd/system/wifi-bad.service <<EOF
[Unit]
Description=Wi-Fi Bad Client
After=network-online.target NetworkManager.service

[Service]
Type=simple
User=$PI_USER
WorkingDirectory=$DASHBOARD_DIR
Environment=INTERFACE=wlan1
ExecStart=/usr/bin/env bash $DASHBOARD_DIR/scripts/fail_auth_loop.sh
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    
    # Enable services
    systemctl enable wifi-dashboard.service
    systemctl enable wired-test.service
    systemctl enable wifi-good.service
    systemctl enable wifi-bad.service
    
    log_info "✓ Services installed and enabled"
}

# Start services
start_services() {
    log_step "Starting services..."
    
    # Start dashboard immediately
    systemctl start wifi-dashboard.service
    
    log_info "✓ Dashboard started"
    log_info "Other services will start after SSID is configured"
}

# Print completion message
show_completion() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "")
    
    echo
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║     🎉 Installation Complete!         ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    echo
    
    if [[ -n "$ip" ]]; then
        log_info "🌐 Dashboard: http://${ip}:5000"
    fi
    
    echo
    log_info "📋 Next Steps:"
    log_info "  1. Open dashboard in browser"
    log_info "  2. Enter your SSID and password"
    log_info "  3. Services will auto-start"
    echo
    log_info "🔧 Service Commands:"
    log_info "  Status:  systemctl status wifi-good"
    log_info "  Logs:    journalctl -u wifi-good -f"
    log_info "  Restart: systemctl restart wifi-good"
    echo
    log_info "✨ Simplified architecture:"
    log_info "  • Single stats source (kernel counters)"
    log_info "  • Forced roaming with round-robin BSSID selection"
    log_info "  • No locks or artificial delays"
    log_info "  • Clean systemd service ordering"
}

# Main installation flow
main() {
    print_banner
    check_prereqs
    install_dependencies
    setup_network
    create_directories
    download_files
    create_configs
    install_services
    start_services
    show_completion
}

main "$@"