#!/usr/bin/env bash
set -uo pipefail

# =============================================================================
# WI-FI BAD CLIENT - OPTIMIZED AUTH FAILURE GENERATOR
# =============================================================================
# Purpose: Generate intentional auth failures for Mist PCAP analysis
# Features:
#   - Simplified code (no locks)
#   - Persistent stats tracking
#   - Configurable failure interval
# =============================================================================

export PATH="$PATH:/usr/local/bin:/usr/sbin:/sbin:/home/pi/.local/bin"
DASHBOARD_DIR="/home/pi/wifi_test_dashboard"
LOG_DIR="$DASHBOARD_DIR/logs"
LOG_FILE="$LOG_DIR/wifi-bad.log"
CONFIG_FILE="$DASHBOARD_DIR/configs/ssid.conf"
SETTINGS="$DASHBOARD_DIR/configs/settings.conf"

INTERFACE="${INTERFACE:-wlan1}"
HOSTNAME="${WIFI_BAD_HOSTNAME:-CNXNMist-WiFiBad}"
REFRESH_INTERVAL="${WIFI_BAD_REFRESH_INTERVAL:-45}"

mkdir -p "$LOG_DIR" 2>/dev/null || true
mkdir -p "$DASHBOARD_DIR/stats" 2>/dev/null || true

set +e  # Keep service alive on errors
trap 'log_msg "Service stopping gracefully..."; save_stats' EXIT

# Privilege helper
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then SUDO="sudo"; else SUDO=""; fi

# =============================================================================
# LOGGING
# =============================================================================
log_msg() {
  echo "[$(date '+%F %T')] WIFI-BAD: $1" | tee -a "$LOG_FILE"
}

# =============================================================================
# PERSISTENT STATS TRACKING
# =============================================================================
load_stats() {
  if [[ -f "$STATS_FILE" ]]; then
    local j
    j=$(cat "$STATS_FILE" 2>/dev/null || echo '{"download":0,"upload":0}')
    TOTAL_DOWN=$(echo "$j" | jq -r '.download // 0' 2>/dev/null || echo 0)
    TOTAL_UP=$(echo "$j" | jq -r '.upload // 0' 2>/dev/null || echo 0)
  else
    TOTAL_DOWN=0
    TOTAL_UP=0
  fi
  log_msg "📊 Loaded stats: down=${TOTAL_DOWN}B up=${TOTAL_UP}B"
}

save_stats() {
  local f="$STATS_FILE"
  local now="$(date +%s)"
  local prev_down=0 prev_up=0

  if [[ -f "$f" ]]; then
    prev_down=$(sed -n 's/.*"download":[[:space:]]*\([0-9]\+\).*/\1/p' "$f" | head -n1)
    prev_up=$(sed -n 's/.*"upload":[[:space:]]*\([0-9]\+\).*/\1/p' "$f" | head -n1)
    prev_down=${prev_down:-0}
    prev_up=${prev_up:-0}
  fi

  [[ "$TOTAL_DOWN" =~ ^[0-9]+$ ]] || TOTAL_DOWN=0
  [[ "$TOTAL_UP"   =~ ^[0-9]+$ ]] || TOTAL_UP=0
  (( TOTAL_DOWN < prev_down )) && TOTAL_DOWN="$prev_down"
  (( TOTAL_UP   < prev_up   )) && TOTAL_UP="$prev_up"

  printf '{"download": %d, "upload": %d, "timestamp": %d}\n' \
    "$TOTAL_DOWN" "$TOTAL_UP" "$now" > "$f.tmp" && mv "$f.tmp" "$f"
}

# =============================================================================
# CONFIGURATION
# =============================================================================
[[ -f "$SETTINGS" ]] && source "$SETTINGS" || true

INTERFACE="${WIFI_BAD_INTERFACE:-$INTERFACE}"
HOSTNAME="${WIFI_BAD_HOSTNAME:-$HOSTNAME}"
REFRESH_INTERVAL="${WIFI_BAD_REFRESH_INTERVAL:-$REFRESH_INTERVAL}"

# Stats file (based on final interface)
STATS_FILE="$DASHBOARD_DIR/stats/stats_${INTERFACE}.json"

load_stats

# =============================================================================
# SIMPLIFIED HOSTNAME CONFIGURATION (No Locks)
# =============================================================================
configure_dhcp_hostname() {
  local hn="$1" ifn="$2"
  log_msg "🏷️ Configuring DHCP hostname: $hn for $ifn"
  
  local dhc="/etc/dhcp/dhclient-${ifn}.conf"
  $SUDO mkdir -p /etc/dhcp
  $SUDO bash -c "cat > $dhc" << EOF
send host-name "$hn";
supersede host-name "$hn";
EOF
  
  local nm="/etc/NetworkManager/conf.d/dhcp-hostname-${ifn}.conf"
  $SUDO bash -c "cat > $nm" << EOF
[connection-dhcp-${ifn}]
match-device=interface-name:${ifn}
[ipv4]
dhcp-hostname=${hn}
dhcp-send-hostname=yes
[ipv6]
dhcp-hostname=${hn}
dhcp-send-hostname=yes
EOF
  
  $SUDO nmcli general reload || true
  log_msg "✅ DHCP hostname configured"
}

# =============================================================================
# UTILITIES
# =============================================================================
read_ssid() {
  if [[ -f "$CONFIG_FILE" ]]; then
    head -n1 "$CONFIG_FILE" | xargs
  else
    echo ""
  fi
}

# =============================================================================
# MAIN BAD-AUTH LOOP
# =============================================================================
log_msg "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_msg "🚫 WI-FI BAD CLIENT - OPTIMIZED AUTH FAILURE GENERATOR"
log_msg "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_msg "Interface: $INTERFACE | Hostname: $HOSTNAME"
log_msg "Failure Interval: ${REFRESH_INTERVAL}s"
log_msg "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

configure_dhcp_hostname "$HOSTNAME" "$INTERFACE"

while true; do
  SSID="$(read_ssid)"
  
  if [[ -z "$SSID" ]]; then
    log_msg "⚠️ No SSID configured in $CONFIG_FILE; sleeping ${REFRESH_INTERVAL}s"
    sleep "$REFRESH_INTERVAL"
    continue
  fi

  # Create intentional bad password to trigger auth failures
  BAD_PSK="wrongpassword-$$-$(date +%s)"
  CONN_NAME="wifi-bad-test-$$"
  
  $SUDO nmcli connection delete "$CONN_NAME" >/dev/null 2>&1 || true
  
  if $SUDO nmcli connection add \
      type wifi con-name "$CONN_NAME" ifname "$INTERFACE" ssid "$SSID" \
      wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$BAD_PSK" \
      connection.autoconnect no >/dev/null 2>&1; then
    
    log_msg "🔁 Trying bad auth to SSID '$SSID' (intentionally wrong PSK)"
    
    $SUDO nmcli --wait 20 connection up "$CONN_NAME" >/dev/null 2>&1 && \
      log_msg "⚠️ Unexpected success; network may be open or PSK ignored" || \
      log_msg "✅ Expected failure recorded (auth/logs generated)"
  else
    log_msg "❌ Failed to create test connection profile"
  fi
  
  $SUDO nmcli connection delete "$CONN_NAME" >/dev/null 2>&1 || true

  # Light probe traffic (minimal overhead)
  if timeout 5 ping -I "$INTERFACE" -c 2 1.1.1.1 >/dev/null 2>&1; then
    TOTAL_DOWN=$((TOTAL_DOWN + 256))
    TOTAL_UP=$((TOTAL_UP + 256))
    log_msg "📶 Light probe traffic accounted (+256B each dir)"
  fi

  save_stats
  log_msg "⏳ Sleeping ${REFRESH_INTERVAL}s (stats D=${TOTAL_DOWN} U=${TOTAL_UP})"
  sleep "$REFRESH_INTERVAL"
done