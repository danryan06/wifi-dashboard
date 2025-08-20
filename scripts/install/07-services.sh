#!/usr/bin/env bash
# scripts/install/07-services.sh
# Configure system services

set -euo pipefail

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }

log_info "Configuring system services..."

# Configure sudoers
log_info "Setting up sudo permissions..."
cat > /etc/sudoers.d/wifi_test_dashboard <<EOF
$PI_USER ALL=(ALL) NOPASSWD: /usr/bin/nmcli, /usr/sbin/tc, /sbin/reboot, /sbin/poweroff, /usr/bin/systemctl restart NetworkManager, /sbin/ip
EOF
chmod 440 /etc/sudoers.d/wifi_test_dashboard

# Create main dashboard service
log_info "Creating dashboard service..."
cat > /etc/systemd/system/wifi-dashboard.service <<EOF
[Unit]
Description=Wi-Fi Test Dashboard $VERSION
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $PI_HOME/wifi_test_dashboard/app.py
User=$PI_USER
Group=$PI_USER
WorkingDirectory=$PI_HOME/wifi_test_dashboard
Restart=always
RestartSec=10
Environment=PYTHONUNBUFFERED=1
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Create wired test service
log_info "Creating wired test service..."
cat > /etc/systemd/system/wired-test.service <<EOF
[Unit]
Description=Wired Network Test Client
After=network-online.target NetworkManager.service
Wants=network-online.target
Requires=NetworkManager.service

[Service]
Type=simple
ExecStart=/usr/bin/env bash $PI_HOME/wifi_test_dashboard/scripts/wired_simulation.sh
User=$PI_USER
Group=$PI_USER
WorkingDirectory=$PI_HOME/wifi_test_dashboard
Restart=always
RestartSec=15
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Create Wi-Fi good client service
log_info "Creating Wi-Fi good client service..."
cat > /etc/systemd/system/wifi-good.service <<EOF
[Unit]
Description=Wi-Fi Good Client Test
After=network-online.target NetworkManager.service
Wants=network-online.target
Requires=NetworkManager.service

[Service]
Type=simple
ExecStart=/usr/bin/env bash $PI_HOME/wifi_test_dashboard/scripts/connect_and_curl.sh
User=$PI_USER
Group=$PI_USER
WorkingDirectory=$PI_HOME/wifi_test_dashboard
Restart=always
RestartSec=20
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Create Wi-Fi bad client service
log_info "Creating Wi-Fi bad client service..."
cat > /etc/systemd/system/wifi-bad.service <<EOF
[Unit]
Description=Wi-Fi Bad Client Test (Authentication Failures)
After=network-online.target NetworkManager.service
Wants=network-online.target
Requires=NetworkManager.service

[Service]
Type=simple
ExecStart=/usr/bin/env bash $PI_HOME/wifi_test_dashboard/scripts/fail_auth_loop.sh
User=$PI_USER
Group=$PI_USER
WorkingDirectory=$PI_HOME/wifi_test_dashboard
Restart=always
RestartSec=25
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Function to create traffic generation services
create_traffic_service() {
    local interface="$1"
    local traffic_type="$2"
    local intensity="$3"
    
    log_info "Creating traffic service for $interface..."
    cat > "/etc/systemd/system/traffic-${interface}.service" <<EOF
[Unit]
Description=Traffic Generator for ${interface} (${traffic_type}, ${intensity})
After=network-online.target NetworkManager.service
Wants=network-online.target
Requires=NetworkManager.service

[Service]
Type=simple
ExecStart=/usr/bin/env bash $PI_HOME/wifi_test_dashboard/scripts/interface_traffic_generator.sh ${interface} ${traffic_type} ${intensity}
User=$PI_USER
Group=$PI_USER
WorkingDirectory=$PI_HOME/wifi_test_dashboard
Restart=always
RestartSec=30
StandardOutput=journal
StandardError=journal

# Resource limits based on intensity
$(case "$intensity" in
    "light") echo "LimitNOFILE=1024" ; echo "MemoryMax=128M" ;;
    "medium") echo "LimitNOFILE=2048" ; echo "MemoryMax=256M" ;;
    "heavy") echo "LimitNOFILE=4096" ; echo "MemoryMax=512M" ;;
esac)

[Install]
WantedBy=multi-user.target
EOF
}

# Create traffic generation services for each interface
# create_traffic_service "eth0" "all" "heavy"
    #commented out because it was duplicate
create_traffic_service "wlan0" "all" "medium" 
create_traffic_service "wlan1" "ping" "light"

log_info "✓ System services configured"