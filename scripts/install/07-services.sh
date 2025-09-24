#!/usr/bin/env bash
# 07-services.sh — Create/enable systemd services with FIXED hostname identity separation
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

log_info "Creating systemd services with FIXED hostname identity separation..."
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

# ---------- wired-test.service - FIXED with proper identity isolation ----------
log_info "Creating wired-test.service with isolated identity..."
cat > /etc/systemd/system/wired-test.service <<EOF
[Unit]
Description=Wired Network Test Client (${WIRED_IFACE} as ${WIRED_HOSTNAME})
After=network-online.target NetworkManager.service
Wants=network-online.target
# FIXED: Run before WiFi services to claim hostname first
Before=wifi-good.service wifi-bad.service

[Service]
Type=simple
User=${PI_USER}
Group=${PI_USER}
WorkingDirectory=${DASHBOARD_DIR}
# FIXED: Explicit hostname and interface isolation
Environment=HOSTNAME=${WIRED_HOSTNAME}
Environment=INTERFACE=${WIRED_IFACE}
Environment=WIRED_INTERFACE=${WIRED_IFACE}
Environment=WIRED_HOSTNAME=${WIRED_HOSTNAME}
Environment=SERVICE_NAME=wired-test
# FIXED: Add lock timeout to prevent hanging
Environment=HOSTNAME_LOCK_TIMEOUT=30
ExecStart=/usr/bin/env bash ${DASHBOARD_DIR}/scripts/wired_simulation.sh
# FIXED: Clean up hostname locks on stop
ExecStopPost=/bin/bash -c 'rm -f /var/run/wifi-dashboard/hostname-${WIRED_IFACE}.lock'
Restart=always
RestartSec=15
TimeoutStartSec=60
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# ---------- wifi-good.service - FIXED with proper identity isolation ---------- 
log_info "Creating wifi-good.service for interface: ${GOOD_IFACE}..."
cat > /etc/systemd/system/wifi-good.service <<EOF
[Unit]
Description=Wi-Fi Good Client (${GOOD_IFACE} as ${WIFI_GOOD_HOSTNAME})
After=network-online.target NetworkManager.service wired-test.service
Wants=network-online.target
# FIXED: Start after wired to avoid hostname conflicts
After=wired-test.service
# FIXED: If bad service exists, coordinate with it
After=wifi-bad.service

[Service]
Type=simple
User=${PI_USER}
Group=${PI_USER}
WorkingDirectory=${DASHBOARD_DIR}
# FIXED: Explicit hostname and interface isolation
Environment=HOSTNAME=${WIFI_GOOD_HOSTNAME}
Environment=INTERFACE=${GOOD_IFACE}
Environment=WIFI_GOOD_INTERFACE=${GOOD_IFACE}
Environment=WIFI_GOOD_HOSTNAME=${WIFI_GOOD_HOSTNAME}
Environment=SERVICE_NAME=wifi-good
# FIXED: Prevent hostname conflicts with other services
Environment=HOSTNAME_LOCK_TIMEOUT=30
Environment=WAIT_FOR_INTERFACE_READY=true
# FIXED: Service startup delay to avoid race conditions
ExecStartPre=/bin/sleep 10
ExecStart=/usr/bin/env bash ${DASHBOARD_DIR}/scripts/connect_and_curl.sh
# FIXED: Clean up hostname locks on stop  
ExecStopPost=/bin/bash -c 'rm -f /var/run/wifi-dashboard/hostname-${GOOD_IFACE}.lock'
Restart=always
RestartSec=25
TimeoutStartSec=90
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# ---------- wifi-bad.service - FIXED with proper identity isolation ----------
if [[ -n "${BAD_IFACE:-}" && "${BAD_IFACE}" != "disabled" && "${BAD_IFACE}" != "none" ]]; then
    log_info "Creating wifi-bad.service for interface: ${BAD_IFACE}..."
    cat > /etc/systemd/system/wifi-bad.service <<EOF
[Unit]
Description=Wi-Fi Bad Client (${BAD_IFACE} as ${WIFI_BAD_HOSTNAME})
After=network-online.target NetworkManager.service wired-test.service
Wants=network-online.target
# FIXED: Start after wired and before good to establish identity
After=wired-test.service
Before=wifi-good.service

[Service]
Type=simple
User=${PI_USER}
Group=${PI_USER}
WorkingDirectory=${DASHBOARD_DIR}
# FIXED: Explicit hostname and interface isolation
Environment=HOSTNAME=${WIFI_BAD_HOSTNAME}
Environment=INTERFACE=${BAD_IFACE}
Environment=WIFI_BAD_INTERFACE=${BAD_IFACE}
Environment=WIFI_BAD_HOSTNAME=${WIFI_BAD_HOSTNAME}
Environment=SERVICE_NAME=wifi-bad
# FIXED: Prevent hostname conflicts
Environment=HOSTNAME_LOCK_TIMEOUT=30
Environment=WAIT_FOR_INTERFACE_READY=true
# FIXED: Service startup delay to avoid conflicts with good service
ExecStartPre=/bin/sleep 5
ExecStart=/usr/bin/env bash ${DASHBOARD_DIR}/scripts/fail_auth_loop.sh
# FIXED: Clean up hostname locks on stop
ExecStopPost=/bin/bash -c 'rm -f /var/run/wifi-dashboard/hostname-${BAD_IFACE}.lock'
Restart=always
RestartSec=30
TimeoutStartSec=75
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
else
    log_warn "BAD_IFACE is empty or disabled — skipping wifi-bad.service creation."
fi

# FIXED: Create hostname lock directory with proper permissions
log_info "Creating hostname lock directory with proper permissions..."
mkdir -p /var/run/wifi-dashboard
chown root:root /var/run/wifi-dashboard
chmod 755 /var/run/wifi-dashboard

# FIXED: Create hostname verification script
log_info "Creating hostname verification script..."
cat > ${DASHBOARD_DIR}/scripts/verify-hostnames.sh <<'VERIFY_EOF'
#!/usr/bin/env bash
# verify-hostnames.sh - Verify hostname separation is working
set -euo pipefail

DASHBOARD_DIR="/home/pi/wifi_test_dashboard"
LOG_FILE="$DASHBOARD_DIR/logs/main.log"

log_msg() {
    local level="$1"; shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] VERIFY-HOSTNAMES: $*"
    echo "$msg" | tee -a "$LOG_FILE"
}

log_msg INFO "Starting hostname verification..."

wlan0_file="$DASHBOARD_DIR/identity_wlan0.json"
wlan1_file="$DASHBOARD_DIR/identity_wlan1.json" 
eth0_file="$DASHBOARD_DIR/identity_eth0.json"

get_hostname() {
    local file="$1" field="$2"
    if [[ -f "$file" ]]; then
        if command -v jq >/dev/null 2>&1; then
            jq -r ".$field // \"unknown\"" "$file" 2>/dev/null || echo "unknown"
        else
            grep -o "\"$field\"[^\"]*\"[^\"]*\"" "$file" | cut -d'"' -f4 2>/dev/null || echo "unknown"
        fi
    else
        echo "unknown"
    fi
}

wlan0_expected=$(get_hostname "$wlan0_file" expected_hostname)
wlan0_actual=$(get_hostname "$wlan0_file" hostname)
wlan1_expected=$(get_hostname "$wlan1_file" expected_hostname)  
wlan1_actual=$(get_hostname "$wlan1_file" hostname)
eth0_expected=$(get_hostname "$eth0_file" expected_hostname)
eth0_actual=$(get_hostname "$eth0_file" hostname)

log_msg INFO "wlan0: expected='$wlan0_expected', actual='$wlan0_actual'"
log_msg INFO "wlan1: expected='$wlan1_expected', actual='$wlan1_actual'"
log_msg INFO "eth0: expected='$eth0_expected', actual='$eth0_actual'"

# Check for conflicts
conflicts=0
if [[ "$wlan0_actual" == "$eth0_actual" && "$wlan0_actual" != "unknown" ]]; then
    log_msg ERROR "Hostname conflict: wlan0 and eth0 both report '$wlan0_actual'"
    ((conflicts++))
fi

if [[ "$wlan0_actual" == "$wlan1_actual" && "$wlan0_actual" != "unknown" ]]; then
    log_msg ERROR "Hostname conflict: wlan0 and wlan1 both report '$wlan0_actual'"
    ((conflicts++))
fi

if [[ "$wlan1_actual" == "$eth0_actual" && "$wlan1_actual" != "unknown" ]]; then
    log_msg ERROR "Hostname conflict: wlan1 and eth0 both report '$wlan1_actual'"
    ((conflicts++))
fi

# Verification rules
if [[ "$wlan0_actual" == "CNXNMist-WiFiGood" && 
      "$wlan1_actual" == "CNXNMist-WiFiBad" && 
      "$eth0_actual" == "CNXNMist-Wired" ]]; then
    log_msg INFO "✅ Perfect hostname separation achieved"
    exit 0
elif [[ $conflicts -eq 0 && "$wlan0_actual" != "unknown" && "$eth0_actual" != "unknown" ]]; then
    log_msg INFO "✅ No hostname conflicts detected"
    exit 0
else
    log_msg WARN "❌ Hostname separation issues detected ($conflicts conflicts)"
    log_msg WARN "Services may need time to establish proper identities"
    exit 1
fi
VERIFY_EOF

chmod +x ${DASHBOARD_DIR}/scripts/verify-hostnames.sh
chown ${PI_USER}:${PI_USER} ${DASHBOARD_DIR}/scripts/verify-hostnames.sh

# Enable services with proper error handling
log_info "Enabling services with dependency order..."
systemctl daemon-reload

# Enable in dependency order
systemctl enable wifi-dashboard >/dev/null 2>&1 && log_info "✓ Enabled wifi-dashboard.service" || log_warn "Failed to enable wifi-dashboard.service"
systemctl enable wired-test >/dev/null 2>&1 && log_info "✓ Enabled wired-test.service" || log_warn "Failed to enable wired-test.service"

if [[ -f /etc/systemd/system/wifi-bad.service ]]; then
    systemctl enable wifi-bad >/dev/null 2>&1 && log_info "✓ Enabled wifi-bad.service" || log_warn "Failed to enable wifi-bad.service"
fi

systemctl enable wifi-good >/dev/null 2>&1 && log_info "✓ Enabled wifi-good.service" || log_warn "Failed to enable wifi-good.service"

log_info "✅ Service creation completed with hostname identity separation fixes."
log_info "Services will start with proper delays and identity isolation to prevent hostname conflicts."