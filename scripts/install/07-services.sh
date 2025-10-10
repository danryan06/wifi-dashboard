#!/usr/bin/env bash
# Simplified service creation with proper systemd ordering
set -euo pipefail

log_info()  { echo -e "\033[0;32m[INFO]\033[0m $*"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }

: "${PI_USER:=pi}"
: "${PI_HOME:=/home/${PI_USER}}"
DASHBOARD_DIR="${PI_HOME}/wifi_test_dashboard"

# Read interface assignments
CONF="$DASHBOARD_DIR/configs/interface-assignments.conf"
if [[ -f "$CONF" ]]; then
    source "$CONF"
fi

GOOD_IFACE="${good_interface:-wlan0}"
BAD_IFACE="${bad_interface:-wlan1}"
WIRED_IFACE="${wired_interface:-eth0}"

log_info "Creating systemd services (simplified)"
log_info "Interfaces: good=$GOOD_IFACE, bad=$BAD_IFACE, wired=$WIRED_IFACE"

# ========================================
# wifi-dashboard.service
# ========================================
log_info "Creating wifi-dashboard.service..."
cat > /etc/systemd/system/wifi-dashboard.service <<EOF
[Unit]
Description=Wi-Fi Test Dashboard Web Interface
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${PI_USER}
WorkingDirectory=${DASHBOARD_DIR}
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/bin/python3 ${DASHBOARD_DIR}/app/app.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# ========================================
# wired-test.service (connection only)
# ========================================
log_info "Creating wired-test.service..."
cat > /etc/systemd/system/wired-test.service <<EOF
[Unit]
Description=Wired Network Client (${WIRED_IFACE})
After=network-online.target NetworkManager.service
Wants=network-online.target
# Start FIRST to establish hostname
Before=wifi-good.service wifi-bad.service

[Service]
Type=simple
User=${PI_USER}
WorkingDirectory=${DASHBOARD_DIR}
Environment=INTERFACE=${WIRED_IFACE}
Environment=HOSTNAME=CNXNMist-Wired
ExecStart=/usr/bin/env bash ${DASHBOARD_DIR}/scripts/traffic/wired_simulation.sh
Restart=always
RestartSec=15
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
EOF

# ========================================
# wifi-good.service (roaming client)
# ========================================
log_info "Creating wifi-good.service..."
cat > /etc/systemd/system/wifi-good.service <<EOF
[Unit]
Description=Wi-Fi Good Client with Roaming (${GOOD_IFACE})
After=network-online.target NetworkManager.service wired-test.service
Wants=network-online.target
# Start AFTER wired to avoid hostname conflicts
After=wired-test.service

[Service]
Type=simple
User=${PI_USER}
WorkingDirectory=${DASHBOARD_DIR}
Environment=INTERFACE=${GOOD_IFACE}
Environment=HOSTNAME=CNXNMist-WiFiGood
Environment=WIFI_GOOD_HOSTNAME=CNXNMist-WiFiGood
# Short delay to ensure wired is established
ExecStartPre=/bin/sleep 10
ExecStart=/usr/bin/env bash ${DASHBOARD_DIR}/scripts/traffic/connect_and_curl.sh
Restart=always
RestartSec=20
TimeoutStartSec=90

[Install]
WantedBy=multi-user.target
EOF

# ========================================
# wifi-bad.service (auth failures)
# ========================================
if [[ -n "${BAD_IFACE}" && "${BAD_IFACE}" != "none" ]]; then
    log_info "Creating wifi-bad.service..."
    cat > /etc/systemd/system/wifi-bad.service <<EOF
[Unit]
Description=Wi-Fi Bad Client - Auth Failures (${BAD_IFACE})
After=network-online.target NetworkManager.service wired-test.service
Wants=network-online.target
# Start AFTER wired to avoid hostname conflicts
After=wired-test.service

[Service]
Type=simple
User=${PI_USER}
WorkingDirectory=${DASHBOARD_DIR}
Environment=INTERFACE=${BAD_IFACE}
Environment=HOSTNAME=CNXNMist-WiFiBad
Environment=WIFI_BAD_HOSTNAME=CNXNMist-WiFiBad
# Short delay to ensure wired is established
ExecStartPre=/bin/sleep 5
ExecStart=/usr/bin/env bash ${DASHBOARD_DIR}/scripts/traffic/fail_auth_loop.sh
Restart=always
RestartSec=30
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
EOF
fi

# Reload and enable services
log_info "Enabling and starting services..."
systemctl daemon-reload

# Enable at boot
systemctl enable wifi-dashboard.service
systemctl enable wired-test.service
systemctl enable wifi-good.service
if [[ -n "${BAD_IFACE}" && "${BAD_IFACE}" != "none" ]]; then
    systemctl enable wifi-bad.service
fi

# Start immediately in the correct order
systemctl start wifi-dashboard.service || true
systemctl start wired-test.service || true
if [[ -n "${BAD_IFACE}" && "${BAD_IFACE}" != "none" ]]; then
    /bin/sleep 5
    systemctl start wifi-bad.service || true
fi
/bin/sleep 5
systemctl start wifi-good.service || true

log_info "✅ Service creation completed and services started"
log_info "Startup order: wired-test → wifi-bad (optional) → wifi-good"