#!/usr/bin/env bash
# 07-services.sh — Create/enable systemd services with IMPROVED hostname identity separation
set -euo pipefail

log_info()  { echo -e "\033[0;32m[INFO]\033[0m $*"; }
log_warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }

: "${PI_USER:=pi}"
: "${PI_HOME:=/home/${PI_USER}}"
DASHBOARD_DIR="${PI_HOME}/wifi_test_dashboard"

if [[ -f "$DASHBOARD_DIR/configs/settings.conf" ]]; then
  source "$DASHBOARD_DIR/configs/settings.conf"
fi
: "${WIRED_HOSTNAME:=CNXNMist-Wired}"
: "${WIFI_GOOD_HOSTNAME:=CNXNMist-WiFiGood}"
: "${WIFI_BAD_HOSTNAME:=CNXNMist-WiFiBad}"

CONF="$DASHBOARD_DIR/configs/interface-assignments.conf"

if [[ ! -f "$CONF" ]]; then
  if [[ -x "$DASHBOARD_DIR/scripts/install/04.5-auto-interface-assignment.sh" ]]; then
    bash "$DASHBOARD_DIR/scripts/install/04.5-auto-interface-assignment.sh" || true
  fi
fi

if [[ ! -f "$CONF" ]]; then
  mkdir -p "$DASHBOARD_DIR/configs"
  cat >"$CONF" <<'EOF'
good_interface="wlan0"
bad_interface="wlan1"
wired_interface="eth0"
EOF
fi

source "$CONF"
GOOD_IFACE="${good_interface:-wlan0}"
BAD_IFACE="${bad_interface:-wlan1}"
WIRED_IFACE="${wired_interface:-eth0}"

log_info "Creating systemd services with IMPROVED hostname identity separation..."
log_info "Interface assignments: good=${GOOD_IFACE}, bad=${BAD_IFACE}, wired=${WIRED_IFACE}"

# ---------- wifi-dashboard.service ----------
log_info "Creating wifi-dashboard.service..."
cat > /etc/systemd/system/wifi-dashboard.service <<EOF
[Unit]
Description=Wi-Fi Test Dashboard Web Interface
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${PI_USER}
Group=${PI_USER}
WorkingDirectory=${DASHBOARD_DIR}
Environment=PYTHONUNBUFFERED=1
Environment=FLASK_ENV=production
ExecStart=/usr/bin/python3 ${DASHBOARD_DIR}/app.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# ---------- wired-test.service - FIRST to claim its hostname ----------
log_info "Creating wired-test.service with priority startup..."
cat > /etc/systemd/system/wired-test.service <<EOF
[Unit]
Description=Wired Network Test Client (${WIRED_IFACE} as ${WIRED_HOSTNAME})
After=network-online.target NetworkManager.service
Wants=network-online.target
# CRITICAL: Start BEFORE Wi-Fi services to establish hostname first
Before=wifi-good.service wifi-bad.service

[Service]
Type=simple
User=${PI_USER}
Group=${PI_USER}
WorkingDirectory=${DASHBOARD_DIR}
Environment=HOSTNAME=${WIRED_HOSTNAME}
Environment=INTERFACE=${WIRED_IFACE}
Environment=WIRED_INTERFACE=${WIRED_IFACE}
Environment=WIRED_HOSTNAME=${WIRED_HOSTNAME}
Environment=SERVICE_NAME=wired-test
# Cleanup stale locks before starting
ExecStartPre=/bin/bash -c 'rm -f /var/run/wifi-dashboard/hostname-${WIRED_IFACE}.lock'
ExecStart=/usr/bin/env bash ${DASHBOARD_DIR}/scripts/wired_simulation.sh
# Cleanup locks on stop
ExecStopPost=/bin/bash -c 'rm -f /var/run/wifi-dashboard/hostname-${WIRED_IFACE}.lock'
Restart=always
RestartSec=15
TimeoutStartSec=60
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# ---------- wifi-bad.service - SECOND to claim its hostname ----------
log_info "Creating wifi-bad.service for interface: ${BAD_IFACE}..."
if [[ -n "${BAD_IFACE:-}" && "${BAD_IFACE}" != "disabled" && "${BAD_IFACE}" != "none" ]]; then
cat > /etc/systemd/system/wifi-bad.service <<EOF
[Unit]
Description=Wi-Fi Bad Client (${BAD_IFACE} as ${WIFI_BAD_HOSTNAME})
After=network-online.target NetworkManager.service wired-test.service
Wants=network-online.target
# Start AFTER wired, BEFORE good
After=wired-test.service
Before=wifi-good.service

[Service]
Type=simple
User=${PI_USER}
Group=${PI_USER}
WorkingDirectory=${DASHBOARD_DIR}
Environment=HOSTNAME=${WIFI_BAD_HOSTNAME}
Environment=INTERFACE=${BAD_IFACE}
Environment=WIFI_BAD_INTERFACE=${BAD_IFACE}
Environment=WIFI_BAD_HOSTNAME=${WIFI_BAD_HOSTNAME}
Environment=SERVICE_NAME=wifi-bad
# LONGER delay to ensure wired is fully established
ExecStartPre=/bin/sleep 15
ExecStartPre=/bin/bash -c 'rm -f /var/run/wifi-dashboard/hostname-${BAD_IFACE}.lock'
ExecStart=/usr/bin/env bash ${DASHBOARD_DIR}/scripts/fail_auth_loop.sh
ExecStopPost=/bin/bash -c 'rm -f /var/run/wifi-dashboard/hostname-${BAD_IFACE}.lock'
Restart=always
RestartSec=30
TimeoutStartSec=90
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
else
    log_warn "BAD_IFACE is empty or disabled — skipping wifi-bad.service creation."
fi

# ---------- wifi-good.service - LAST to claim its hostname ----------
log_info "Creating wifi-good.service for interface: ${GOOD_IFACE}..."
cat > /etc/systemd/system/wifi-good.service <<EOF
[Unit]
Description=Wi-Fi Good Client (${GOOD_IFACE} as ${WIFI_GOOD_HOSTNAME})
After=network-online.target NetworkManager.service wired-test.service wifi-bad.service
Wants=network-online.target
# Start LAST to avoid conflicts
After=wired-test.service wifi-bad.service

[Service]
Type=simple
User=${PI_USER}
Group=${PI_USER}
WorkingDirectory=${DASHBOARD_DIR}
Environment=HOSTNAME=${WIFI_GOOD_HOSTNAME}
Environment=INTERFACE=${GOOD_IFACE}
Environment=WIFI_GOOD_INTERFACE=${GOOD_IFACE}
Environment=WIFI_GOOD_HOSTNAME=${WIFI_GOOD_HOSTNAME}
Environment=SERVICE_NAME=wifi-good
# LONGEST delay to ensure all others are established
ExecStartPre=/bin/sleep 25
ExecStartPre=/bin/bash -c 'rm -f /var/run/wifi-dashboard/hostname-${GOOD_IFACE}.lock'
ExecStart=/usr/bin/env bash ${DASHBOARD_DIR}/scripts/connect_and_curl.sh
ExecStopPost=/bin/bash -c 'rm -f /var/run/wifi-dashboard/hostname-${GOOD_IFACE}.lock'
Restart=always
RestartSec=25
TimeoutStartSec=120
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Create lock directory with proper permissions
log_info "Creating hostname lock directory..."
mkdir -p /var/run/wifi-dashboard
chown root:root /var/run/wifi-dashboard
chmod 1777 /var/run/wifi-dashboard

# Enable services in dependency order
log_info "Enabling services with staggered startup..."
systemctl daemon-reload

systemctl enable wifi-dashboard >/dev/null 2>&1 && log_info "✓ Enabled wifi-dashboard.service" || log_warn "Failed to enable wifi-dashboard.service"
systemctl enable wired-test >/dev/null 2>&1 && log_info "✓ Enabled wired-test.service" || log_warn "Failed to enable wired-test.service"

if [[ -f /etc/systemd/system/wifi-bad.service ]]; then
    systemctl enable wifi-bad >/dev/null 2>&1 && log_info "✓ Enabled wifi-bad.service" || log_warn "Failed to enable wifi-bad.service"
fi

systemctl enable wifi-good >/dev/null 2>&1 && log_info "✓ Enabled wifi-good.service" || log_warn "Failed to enable wifi-good.service"

log_info "✅ Service creation completed with improved hostname separation."
log_info "Startup order: wired-test → (15s delay) → wifi-bad → (10s delay) → wifi-good"
log_info "This ensures each service has time to claim its unique hostname via DHCP."