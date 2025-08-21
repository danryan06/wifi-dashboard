#!/usr/bin/env bash
# Fixed: Service creation with proper network dependencies and interface assignment
set -euo pipefail

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; }

log_info "Creating systemd services with enhanced network dependencies..."

# Source interface assignments (created in early assignment phase)
DASHBOARD_DIR="$PI_HOME/wifi_test_dashboard"
if [[ -f "$DASHBOARD_DIR/configs/interface-assignments.conf" ]]; then
    source "$DASHBOARD_DIR/configs/interface-assignments.conf"
    log_info "Loaded interface assignments: good=$WIFI_GOOD_INTERFACE, bad=$WIFI_BAD_INTERFACE"
else
    log_warn "Interface assignments not found, using defaults"
    WIFI_GOOD_INTERFACE="wlan0"
    WIFI_BAD_INTERFACE="wlan1"
fi

# 1. Wi-Fi Dashboard Service
log_info "Creating wifi-dashboard.service..."
cat > /etc/systemd/system/wifi-dashboard.service << EOF
[Unit]
Description=Wi-Fi Test Dashboard Web Interface
After=multi-user.target NetworkManager.service
Wants=NetworkManager.service
StartLimitIntervalSec=300
StartLimitBurst=3

[Service]
Type=simple
User=$PI_USER
WorkingDirectory=$DASHBOARD_DIR
Environment=PYTHONPATH=$DASHBOARD_DIR
Environment=FLASK_APP=app.py
ExecStart=/usr/bin/python3 $DASHBOARD_DIR/app.py
Restart=on-failure
RestartSec=10
StandardOutput=append:$DASHBOARD_DIR/logs/dashboard.log
StandardError=append:$DASHBOARD_DIR/logs/dashboard.log

# Security settings
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

# 2. Wired Test Service (eth0)
log_info "Creating wired-test.service..."
cat > /etc/systemd/system/wired-test.service << EOF
[Unit]
Description=Wired Network Client Simulation (eth0)
After=NetworkManager.service network-online.target
Wants=NetworkManager.service network-online.target
Requires=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=3

[Service]
Type=simple
User=$PI_USER
WorkingDirectory=$DASHBOARD_DIR
Environment=INTERFACE=eth0
Environment=HOSTNAME=$WIRED_HOSTNAME
ExecStart=/bin/bash $DASHBOARD_DIR/scripts/traffic/wired_simulation.sh
Restart=on-failure
RestartSec=15
StandardOutput=append:$DASHBOARD_DIR/logs/wired.log
StandardError=append:$DASHBOARD_DIR/logs/wired.log

# Wait for network to be truly ready
ExecStartPre=/bin/bash -c 'timeout 60 bash -c "until ip route | grep -q default; do sleep 2; done"'

[Install]
WantedBy=multi-user.target
EOF

# 3. Wi-Fi Good Client Service
log_info "Creating wifi-good.service for interface: $WIFI_GOOD_INTERFACE..."
cat > /etc/systemd/system/wifi-good.service << EOF
[Unit]
Description=Wi-Fi Good Client Simulation ($WIFI_GOOD_INTERFACE)
After=NetworkManager.service network-online.target wifi-dashboard.service
Wants=NetworkManager.service network-online.target
Requires=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=3

[Service]
Type=simple
User=$PI_USER
WorkingDirectory=$DASHBOARD_DIR
Environment=INTERFACE=$WIFI_GOOD_INTERFACE
Environment=HOSTNAME=$WIFI_GOOD_HOSTNAME
ExecStart=/bin/bash $DASHBOARD_DIR/scripts/traffic/connect_and_curl.sh
Restart=on-failure
RestartSec=20
StandardOutput=append:$DASHBOARD_DIR/logs/wifi-good.log
StandardError=append:$DASHBOARD_DIR/logs/wifi-good.log

# Enhanced pre-start checks for Wi-Fi
ExecStartPre=/bin/bash -c 'timeout 90 bash -c "until nmcli device status | grep -q \"$WIFI_GOOD_INTERFACE.*connected\"; do echo \"Waiting for $WIFI_GOOD_INTERFACE connection...\"; sleep 5; done"'
ExecStartPre=/bin/bash -c 'timeout 60 bash -c "until ip addr show $WIFI_GOOD_INTERFACE | grep -q \"inet \"; do echo \"Waiting for $WIFI_GOOD_INTERFACE IP address...\"; sleep 3; done"'

[Install]
WantedBy=multi-user.target
EOF

# 4. Wi-Fi Bad Client Service (only if second interface available)
if [[ "$WIFI_BAD_INTERFACE" != "disabled" && -n "$WIFI_BAD_INTERFACE" ]]; then
    log_info "Creating wifi-bad.service for interface: $WIFI_BAD_INTERFACE..."
    cat > /etc/systemd/system/wifi-bad.service << EOF
[Unit]
Description=Wi-Fi Bad Client Simulation ($WIFI_BAD_INTERFACE) - Auth Failures
After=NetworkManager.service network-online.target wifi-good.service
Wants=NetworkManager.service network-online.target
StartLimitIntervalSec=300
StartLimitBurst=3

[Service]
Type=simple
User=$PI_USER
WorkingDirectory=$DASHBOARD_DIR
Environment=INTERFACE=$WIFI_BAD_INTERFACE
Environment=HOSTNAME=$WIFI_BAD_HOSTNAME
ExecStart=/bin/bash $DASHBOARD_DIR/scripts/traffic/fail_auth_loop.sh
Restart=on-failure
RestartSec=25
StandardOutput=append:$DASHBOARD_DIR/logs/wifi-bad.log
StandardError=append:$DASHBOARD_DIR/logs/wifi-bad.log

# Wait for interface to be available
ExecStartPre=/bin/bash -c 'timeout 30 bash -c "until ip link show $WIFI_BAD_INTERFACE; do echo \"Waiting for $WIFI_BAD_INTERFACE interface...\"; sleep 2; done"'

[Install]
WantedBy=multi-user.target
EOF
else
    log_warn "Skipping wifi-bad.service - no second Wi-Fi interface available"
fi

# Create service management helper script
log_info "Creating service management helper..."
cat > "$DASHBOARD_DIR/scripts/manage_services.sh" << 'EOF'
#!/bin/bash
# Service management helper for Wi-Fi Dashboard

SERVICES=("wifi-dashboard" "wired-test" "wifi-good")

# Add wifi-bad if it exists
if systemctl list-unit-files | grep -q "wifi-bad.service"; then
    SERVICES+=("wifi-bad")
fi

case "${1:-status}" in
    start)
        echo "Starting Wi-Fi Dashboard services..."
        for service in "${SERVICES[@]}"; do
            echo "Starting $service..."
            sudo systemctl start "$service.service"
        done
        ;;
    stop)
        echo "Stopping Wi-Fi Dashboard services..."
        for service in "${SERVICES[@]}"; do
            echo "Stopping $service..."
            sudo systemctl stop "$service.service"
        done
        ;;
    restart)
        echo "Restarting Wi-Fi Dashboard services..."
        for service in "${SERVICES[@]}"; do
            echo "Restarting $service..."
            sudo systemctl restart "$service.service"
        done
        ;;
    status)
        echo "Wi-Fi Dashboard Service Status:"
        for service in "${SERVICES[@]}"; do
            echo "--- $service ---"
            sudo systemctl status "$service.service" --no-pager -l
        done
        ;;
    logs)
        echo "Viewing logs for all services..."
        sudo journalctl -u wifi-dashboard.service -u wired-test.service -u wifi-good.service ${WIFI_BAD_INTERFACE:+-u wifi-bad.service} -f
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|logs}"
        exit 1
        ;;
esac
EOF

chmod +x "$DASHBOARD_DIR/scripts/manage_services.sh"
chown "$PI_USER:$PI_USER" "$DASHBOARD_DIR/scripts/manage_services.sh"

# Reload systemd to recognize new services
systemctl daemon-reload

log_info "✓ All services created with proper network dependencies"
log_info "✓ Service management helper created: $DASHBOARD_DIR/scripts/manage_services.sh"

# Note: Services are not enabled/started here - that happens in 08-finalize.sh after Wi-Fi config