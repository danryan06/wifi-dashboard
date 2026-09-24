#!/usr/bin/env bash
# 07-services.sh - Create/enable systemd services.
#
# Identity model: each client interface has its own MAC address and a
# per-interface DHCP hostname (NetworkManager per-connection dhcp-hostname +
# conf.d), so services start independently - no lock files, no staggered
# sleeps, no startup ordering between clients.
#
# Services:
#   wifi-dashboard.service      Flask web UI
#   wired-test.service          wired client (eth0)
#   wifi-good.service           primary good Wi-Fi client (roaming)
#   wifi-bad.service            primary bad Wi-Fi client (auth failures)
#   wifi-client@<iface>.service one instance per EXTRA Wi-Fi adapter
#                               (personas defined in configs/clients.conf)
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
CLIENTS_CONF="$DASHBOARD_DIR/configs/clients.conf"

if [[ ! -f "$CONF" ]]; then
  if [[ -x "$DASHBOARD_DIR/scripts/install/04.5-auto-interface-assignment.sh" ]]; then
    bash "$DASHBOARD_DIR/scripts/install/04.5-auto-interface-assignment.sh" || true
  fi
fi

# The assignments file historically used two formats:
#   lowercase: good_interface="wlan0"      (03-directories default)
#   uppercase: WIFI_GOOD_INTERFACE=wlan0   (04.5 auto-assignment)
# Source it and accept either, preferring the uppercase auto-detected keys.
good_interface=""; bad_interface=""; wired_interface=""
WIFI_GOOD_INTERFACE=""; WIFI_BAD_INTERFACE=""; WIRED_INTERFACE=""
if [[ -f "$CONF" ]]; then
  # shellcheck disable=SC1090
  source "$CONF"
fi
GOOD_IFACE="${WIFI_GOOD_INTERFACE:-${good_interface:-wlan0}}"
BAD_IFACE="${WIFI_BAD_INTERFACE:-${bad_interface:-wlan1}}"
WIRED_IFACE="${WIRED_INTERFACE:-${wired_interface:-eth0}}"

log_info "Creating systemd services..."
log_info "Interface assignments: good=${GOOD_IFACE}, bad=${BAD_IFACE}, wired=${WIRED_IFACE}"

# ---------- Multi-NIC sysctls ----------
# With several interfaces on the same subnet the defaults cause ARP flux
# (any NIC answers ARP for any local IP) and strict rp_filter can drop
# legitimate replies. Use per-NIC ARP answers and loose reverse-path filtering.
log_info "Applying multi-NIC ARP/rp_filter sysctls..."
cat > /etc/sysctl.d/99-wifi-dashboard-multinic.conf <<'EOF'
# Wi-Fi Test Dashboard: multiple client NICs on the same subnet
net.ipv4.conf.all.arp_filter = 1
net.ipv4.conf.default.arp_filter = 1
net.ipv4.conf.all.arp_announce = 2
net.ipv4.conf.default.arp_announce = 2
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
EOF
sysctl -p /etc/sysctl.d/99-wifi-dashboard-multinic.conf >/dev/null 2>&1 || \
  log_warn "Failed to apply sysctls now (will apply on next boot)"

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

# ---------- wired-test.service ----------
log_info "Creating wired-test.service..."
cat > /etc/systemd/system/wired-test.service <<EOF
[Unit]
Description=Wired Network Test Client (${WIRED_IFACE} as ${WIRED_HOSTNAME})
After=network-online.target NetworkManager.service
Wants=network-online.target

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
ExecStart=/usr/bin/env bash ${DASHBOARD_DIR}/scripts/wired_simulation.sh
Restart=always
RestartSec=15
TimeoutStartSec=60
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# ---------- wifi-bad.service ----------
log_info "Creating wifi-bad.service for interface: ${BAD_IFACE}..."
if [[ -n "${BAD_IFACE:-}" && "${BAD_IFACE}" != "disabled" && "${BAD_IFACE}" != "none" ]]; then
cat > /etc/systemd/system/wifi-bad.service <<EOF
[Unit]
Description=Wi-Fi Bad Client (${BAD_IFACE} as ${WIFI_BAD_HOSTNAME})
After=network-online.target NetworkManager.service
Wants=network-online.target

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
ExecStart=/usr/bin/env bash ${DASHBOARD_DIR}/scripts/fail_auth_loop.sh
Restart=always
RestartSec=30
TimeoutStartSec=90
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
else
    log_warn "BAD_IFACE is empty or disabled - skipping wifi-bad.service creation."
fi

# ---------- wifi-good.service ----------
log_info "Creating wifi-good.service for interface: ${GOOD_IFACE}..."
cat > /etc/systemd/system/wifi-good.service <<EOF
[Unit]
Description=Wi-Fi Good Client (${GOOD_IFACE} as ${WIFI_GOOD_HOSTNAME})
After=network-online.target NetworkManager.service
Wants=network-online.target

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
ExecStart=/usr/bin/env bash ${DASHBOARD_DIR}/scripts/connect_and_curl.sh
Restart=always
RestartSec=25
TimeoutStartSec=120
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# ---------- wifi-client@.service (template for extra USB adapters) ----------
log_info "Creating wifi-client@.service template..."
cat > /etc/systemd/system/wifi-client@.service <<EOF
[Unit]
Description=Wi-Fi Test Client on %i
After=network-online.target NetworkManager.service
Wants=network-online.target

[Service]
Type=simple
User=${PI_USER}
Group=${PI_USER}
WorkingDirectory=${DASHBOARD_DIR}
Environment=SERVICE_NAME=wifi-client@%i
ExecStart=/usr/bin/env bash ${DASHBOARD_DIR}/scripts/wifi_client.sh %i
Restart=always
RestartSec=25
TimeoutStartSec=120
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# ---------- Enable services ----------
systemctl daemon-reload

systemctl enable wifi-dashboard >/dev/null 2>&1 && log_info "✓ Enabled wifi-dashboard.service" || log_warn "Failed to enable wifi-dashboard.service"
systemctl enable wired-test >/dev/null 2>&1 && log_info "✓ Enabled wired-test.service" || log_warn "Failed to enable wired-test.service"

if [[ -f /etc/systemd/system/wifi-bad.service ]]; then
    systemctl enable wifi-bad >/dev/null 2>&1 && log_info "✓ Enabled wifi-bad.service" || log_warn "Failed to enable wifi-bad.service"
fi

systemctl enable wifi-good >/dev/null 2>&1 && log_info "✓ Enabled wifi-good.service" || log_warn "Failed to enable wifi-good.service"

# ---------- Enable template instances for extra Wi-Fi adapters ----------
# Every clients.conf interface beyond the primary good/bad pair gets a
# wifi-client@<iface> instance. Stale instances are disabled first.
while read -r unit _rest; do
    [[ -n "$unit" ]] || continue
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
done < <(systemctl list-units --all --plain --no-legend 'wifi-client@*' 2>/dev/null)

if [[ -f "$CLIENTS_CONF" ]]; then
    while IFS=: read -r c_iface c_role _rest; do
        [[ -z "$c_iface" || "$c_iface" == \#* ]] && continue
        [[ "$c_iface" == "$GOOD_IFACE" || "$c_iface" == "$BAD_IFACE" ]] && continue
        if systemctl enable "wifi-client@${c_iface}.service" >/dev/null 2>&1; then
            log_info "✓ Enabled wifi-client@${c_iface}.service (role: ${c_role:-good})"
        else
            log_warn "Failed to enable wifi-client@${c_iface}.service"
        fi
    done < "$CLIENTS_CONF"
fi

log_info "✅ Service creation completed."
log_info "Clients start independently; per-interface DHCP hostnames need no serialization."
