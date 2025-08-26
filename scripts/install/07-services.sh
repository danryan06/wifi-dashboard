#!/usr/bin/env bash
# 07-services.sh — Create/enable systemd services with proper deps and interface assignments
set -euo pipefail

# ---------- logging helpers ----------
log_info()  { echo -e "\033[0;32m[INFO]\033[0m $*"; }
log_warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }

# ---------- defaults (safe under set -u) ----------
: "${PI_USER:=pi}"
: "${PI_HOME:=/home/${PI_USER}}"
DASHBOARD_DIR="${PI_HOME}/wifi_test_dashboard"

# Optional settings (hostnames, etc.)
if [[ -f "$DASHBOARD_DIR/configs/settings.conf" ]]; then
  # shellcheck disable=SC1090
  source "$DASHBOARD_DIR/configs/settings.conf"
fi
: "${WIRED_HOSTNAME:=CNXNMist-Wired}"
: "${WIFI_GOOD_HOSTNAME:=CNXNMist-WiFiGood}"
: "${WIFI_BAD_HOSTNAME:=CNXNMist-WiFiBad}"

# ---------- ensure interface assignments exist ----------
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

# Load once and normalize
# shellcheck disable=SC1090
source "$CONF"
GOOD_IFACE="${good_interface:-wlan0}"
BAD_IFACE="${bad_interface:-wlan1}"
WIRED_IFACE="${wired_interface:-eth0}"

log_info "Creating systemd services with enhanced network dependencies..."
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
# Prefer gunicorn if available; otherwise fall back to python app.py
ExecStart=/bin/bash -lc 'if command -v gunicorn >/dev/null 2>&1; then exec /usr/bin/python3 -m gunicorn -w 2 -b 0.0.0.0:5000 app:app; else exec /usr/bin/python3 ${DASHBOARD_DIR}/app.py; fi'
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# ---------- wired-test.service ----------
log_info "Creating wired-test.service..."
cat > /etc/systemd/system/wired-test.service <<EOF
[Unit]
Description=Wired Network Test Client
After=network-online.target NetworkManager.service
Wants=network-online.target
Requires=NetworkManager.service

[Service]
Type=simple
User=${PI_USER}
Group=${PI_USER}
WorkingDirectory=${DASHBOARD_DIR}
Environment=HOSTNAME=${WIRED_HOSTNAME}
Environment=INTERFACE=${WIRED_IFACE}
ExecStart=/usr/bin/env bash ${DASHBOARD_DIR}/scripts/traffic/wired_simulation.sh
Restart=always
RestartSec=15
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# ---------- wifi-good.service ----------
log_info "Creating wifi-good.service for interface: ${GOOD_IFACE}..."
cat > /etc/systemd/system/wifi-good.service <<EOF
[Unit]
Description=Wi-Fi Good Client (auth + integrated traffic) on ${GOOD_IFACE}
After=network-online.target NetworkManager.service
Wants=network-online.target
Requires=NetworkManager.service

[Service]
Type=simple
User=${PI_USER}
Group=${PI_USER}
WorkingDirectory=${DASHBOARD_DIR}
Environment=HOSTNAME=${WIFI_GOOD_HOSTNAME}
Environment=INTERFACE=${GOOD_IFACE}
# Wait for the device to be connected + have an IPv4 address
ExecStartPre=/bin/bash -lc "timeout 90 bash -c 'until nmcli -t -f DEVICE,STATE dev status | grep -q \"^${GOOD_IFACE}:connected\$\"; do echo \"Waiting for ${GOOD_IFACE} connection...\"; sleep 5; done'"
ExecStartPre=/bin/bash -lc "timeout 60 bash -c 'until ip -4 addr show ${GOOD_IFACE} | grep -q \"inet \"; do echo \"Waiting for ${GOOD_IFACE} IP address...\"; sleep 3; done'"
ExecStart=/usr/bin/env bash ${DASHBOARD_DIR}/scripts/traffic/connect_and_curl.sh
Restart=always
RestartSec=15
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# ---------- wifi-bad.service (optional) ----------
if [[ -n "${BAD_IFACE:-}" && "${BAD_IFACE}" != "disabled" ]]; then
  log_info "Creating wifi-bad.service for interface: ${BAD_IFACE}..."
  cat > /etc/systemd/system/wifi-bad.service <<EOF
[Unit]
Description=Wi-Fi Bad Client (auth failures + minimal traffic) on ${BAD_IFACE}
After=network-online.target NetworkManager.service
Wants=network-online.target
Requires=NetworkManager.service

[Service]
Type=simple
User=${PI_USER}
Group=${PI_USER}
WorkingDirectory=${DASHBOARD_DIR}
Environment=HOSTNAME=${WIFI_BAD_HOSTNAME}
Environment=INTERFACE=${BAD_IFACE}
# Just ensure the interface exists; bad client intentionally fails auth
ExecStartPre=/bin/bash -lc "timeout 30 bash -c 'until ip link show ${BAD_IFACE} >/dev/null 2>&1; do echo \"Waiting for ${BAD_IFACE} interface...\"; sleep 2; done'"
ExecStart=/usr/bin/env bash ${DASHBOARD_DIR}/scripts/traffic/fail_auth_loop.sh
Restart=always
RestartSec=25
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
else
  log_warn "BAD_IFACE is empty or 'disabled' — skipping wifi-bad.service creation."
fi

# ---------- enable services (do not force-start Wi-Fi clients here) ----------
log_info "Enabling services (but not starting until conditions are met)..."
systemctl daemon-reload

systemctl enable wifi-dashboard >/dev/null 2>&1 && log_info "✓ Enabled wifi-dashboard.service" || log_warn "wifi-dashboard.service enable skipped/failed"
systemctl enable wired-test     >/dev/null 2>&1 && log_info "✓ Enabled wired-test.service"     || log_warn "wired-test.service enable skipped/failed"
systemctl enable wifi-good      >/dev/null 2>&1 && log_info "✓ Enabled wifi-good.service"      || log_warn "wifi-good.service enable skipped/failed"

if [[ -f /etc/systemd/system/wifi-bad.service ]]; then
  systemctl enable wifi-bad    >/dev/null 2>&1 && log_info "✓ Enabled wifi-bad.service"       || log_warn "wifi-bad.service enable skipped/failed"
fi

log_info "Service creation complete."
