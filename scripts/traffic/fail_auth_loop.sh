#!/usr/bin/env bash
# Wi-Fi Bad Client: repeated auth failures to generate association/auth logs
set -uo pipefail

# --- Paths & defaults ---
export PATH="$PATH:/usr/local/bin:/usr/sbin:/sbin:/home/pi/.local/bin"
DASHBOARD_DIR="/home/pi/wifi_test_dashboard"
LOG_DIR="$DASHBOARD_DIR/logs"
LOG_FILE="$LOG_DIR/wifi-bad.log"
CONFIG_FILE="$DASHBOARD_DIR/configs/ssid.conf"
SETTINGS="$DASHBOARD_DIR/configs/settings.conf"

INTERFACE="${INTERFACE:-wlan1}"
HOSTNAME="${WIFI_BAD_HOSTNAME:-${HOSTNAME:-CNXNMist-WiFiBad}}"
REFRESH_INTERVAL="${WIFI_BAD_REFRESH_INTERVAL:-45}"

mkdir -p "$LOG_DIR" 2>/dev/null || true
mkdir -p "$DASHBOARD_DIR/stats" 2>/dev/null || true

# Privilege helper
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then SUDO="sudo"; else SUDO=""; fi

log_msg() {
  echo "[$(date '+%F %T')] WIFI-BAD: $1" | tee -a "$LOG_FILE"
}

# --- Hostname lock helpers (lightweight) ---
LOCK_DIR="/var/run/wifi-dashboard"
LOCK_FILE="$LOCK_DIR/hostname-${INTERFACE}.lock"
acquire_hostname_lock() {
  $SUDO mkdir -p "$LOCK_DIR"
  echo "${INTERFACE}:${HOSTNAME}:$(date +%s):$$" | $SUDO tee "$LOCK_FILE" >/dev/null
}
release_hostname_lock() {
  [[ -f "$LOCK_FILE" ]] && $SUDO rm -f "$LOCK_FILE" || true
}

# --- Persistent totals (bytes) ---
TOTAL_DOWN=0
TOTAL_UP=0

load_stats() {
  local fn="$STATS_FILE"
  if [[ -f "$fn" ]]; then
    local j; j=$(cat "$fn" 2>/dev/null || echo '{"download":0,"upload":0}')
    TOTAL_DOWN=$(echo "$j" | jq -r '.download // 0' 2>/dev/null || echo 0)
    TOTAL_UP=$(echo "$j" | jq -r '.upload // 0' 2>/dev/null || echo 0)
  else
    TOTAL_DOWN=0; TOTAL_UP=0
  fi
  log_msg "📊 Loaded stats: down=${TOTAL_DOWN}B up=${TOTAL_UP}B"
}
save_stats() {
  local f="$STATS_FILE"
  local now="$(date +%s)"
  local prev_down=0 prev_up=0

  if [[ -f "$f" ]]; then
    # best-effort parse without jq to avoid zeroing
    prev_down=$(sed -n 's/.*"download":[[:space:]]*\([0-9]\+\).*/\1/p' "$f" | head -n1)
    prev_up=$(sed -n 's/.*"upload":[[:space:]]*\([0-9]\+\).*/\1/p' "$f" | head -n1)
    prev_down=${prev_down:-0}; prev_up=${prev_up:-0}
  fi

  # Never decrease totals
  [[ "$TOTAL_DOWN" =~ ^[0-9]+$ ]] || TOTAL_DOWN=0
  [[ "$TOTAL_UP"   =~ ^[0-9]+$ ]] || TOTAL_UP=0
  (( TOTAL_DOWN < prev_down )) && TOTAL_DOWN="$prev_down"
  (( TOTAL_UP   < prev_up   )) && TOTAL_UP="$prev_up"

  printf '{"download": %d, "upload": %d, "timestamp": %d}\n' \
    "$TOTAL_DOWN" "$TOTAL_UP" "$now" > "$f.tmp" && mv "$f.tmp" "$f"
}
LAST_SAVE_TS=0
maybe_save_stats() {  # [UPDATED] debounced to limit writes
  local now; now=$(date +%s)
  if (( LAST_SAVE_TS == 0 || (now - LAST_SAVE_TS) >= 5 )); then
    save_stats
    LAST_SAVE_TS=$now
  fi
}

# --- Read settings and finalize interface ---
[[ -f "$SETTINGS" ]] && source "$SETTINGS" || true
INTERFACE="${WIFI_BAD_INTERFACE:-$INTERFACE}"
HOSTNAME="${WIFI_BAD_HOSTNAME:-$HOSTNAME}"
REFRESH_INTERVAL="${WIFI_BAD_REFRESH_INTERVAL:-$REFRESH_INTERVAL}"

# Recompute STATS_FILE once the interface is FINAL  # [UPDATED]
STATS_FILE="$DASHBOARD_DIR/stats/stats_${INTERFACE}.json"  # [UPDATED]
load_stats
trap 'save_stats; release_hostname_lock' EXIT

# --- Utilities ---
read_ssid() {
  if [[ -f "$CONFIG_FILE" ]]; then
    head -n1 "$CONFIG_FILE" | xargs
  else
    echo ""
  fi
}

configure_dhcp_hostname() {
  local hn="$1" ifn="$2"
  local dhc="/etc/dhcp/dhclient-${ifn}.conf"
  $SUDO mkdir -p /etc/dhcp
  cat <<EOF | $SUDO tee "$dhc" >/dev/null
send host-name "$hn";
supersede host-name "$hn";
EOF
  local nm="/etc/NetworkManager/conf.d/dhcp-hostname-${ifn}.conf"
  cat <<EOF | $SUDO tee "$nm" >/dev/null
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
}

# --- Main bad-auth loop ---
log_msg "🚀 Starting Wi-Fi bad client on $INTERFACE (hostname: $HOSTNAME)"
acquire_hostname_lock
configure_dhcp_hostname "$HOSTNAME" "$INTERFACE"

while true; do
  SSID="$(read_ssid)"
  if [[ -z "$SSID" ]]; then
    log_msg "⚠️ No SSID configured in $CONFIG_FILE; sleeping ${REFRESH_INTERVAL}s"
    sleep "$REFRESH_INTERVAL"; continue
  fi

  # Create a temporary bad password attempt to trigger auth failures
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

  # (Optional) light traffic to keep interface visible (very small)
  if timeout 5 ping -I "$INTERFACE" -c 2 1.1.1.1 >/dev/null 2>&1; then
    # Count a tiny amount for ping overhead as down/up “noise”
    TOTAL_DOWN=$((TOTAL_DOWN + 256))
    TOTAL_UP=$((TOTAL_UP + 256))
    maybe_save_stats   # [UPDATED]
    log_msg "📶 Light probe traffic accounted (+256B each dir)"
  fi

  # End-of-iteration persist
  save_stats
  log_msg "⏳ Sleeping ${REFRESH_INTERVAL}s (stats D=${TOTAL_DOWN} U=${TOTAL_UP})"
  sleep "$REFRESH_INTERVAL"
done
