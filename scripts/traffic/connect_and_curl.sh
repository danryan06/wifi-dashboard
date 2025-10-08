#!/usr/bin/env bash
# Wi-Fi Good Client: Auth + Roaming + Realistic Traffic (FIXED VERSION)
# Fixes for roaming BSSID locking and persistent throughput tracking

set -uo pipefail

# --- Paths & defaults ---
export PATH="$PATH:/usr/local/bin:/usr/sbin:/sbin:/home/pi/.local/bin"
DASHBOARD_DIR="/home/pi/wifi_test_dashboard"
LOG_DIR="$DASHBOARD_DIR/logs"
LOG_FILE="$LOG_DIR/wifi-good.log"
CONFIG_FILE="$DASHBOARD_DIR/configs/ssid.conf"
SETTINGS="$DASHBOARD_DIR/configs/settings.conf"
ROTATE_UTIL="$DASHBOARD_DIR/scripts/log_rotation_utils.sh"
mkdir -p "$DASHBOARD_DIR/stats"

INTERFACE="${INTERFACE:-wlan0}"
HOSTNAME="${WIFI_GOOD_HOSTNAME:-${HOSTNAME:-CNXNMist-WiFiGood}}"
LOG_MAX_SIZE_BYTES="${LOG_MAX_SIZE_BYTES:-10485760}"   # 10MB default

# HOSTNAME LOCK SYSTEM
HOSTNAME_LOCK_DIR="/var/run/wifi-dashboard"
HOSTNAME_LOCK_FILE="$HOSTNAME_LOCK_DIR/hostname-${INTERFACE}.lock"

# Trap errors but DO NOT exit service
trap 'ec=$?; echo "[$(date "+%F %T")] TRAP-ERR: cmd=\"$BASH_COMMAND\" ec=$ec line=$LINENO" | tee -a "$LOG_FILE"' ERR

# --- Privilege helper for nmcli ---
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  SUDO="sudo"
else
  SUDO=""
fi

# --- Rotation helpers ---
[[ -f "$ROTATE_UTIL" ]] && source "$ROTATE_UTIL" || true
rotate_basic() {
  if command -v rotate_log >/dev/null 2>&1; then
    rotate_log "$LOG_FILE" "${LOG_MAX_SIZE_MB:-5}"
    return 0
  fi
  local max="${LOG_MAX_SIZE_BYTES:-10485760}"
  if [[ -f "$LOG_FILE" ]]; then
    local size
    size=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
    (( size >= max )) && { mv -f "$LOG_FILE" "$LOG_FILE.$(date +%s).1" 2>/dev/null || true; : > "$LOG_FILE"; }
  fi
}

log_msg() {
  local msg="[$(date '+%F %T')] WIFI-GOOD: $1"
  if declare -F log_msg_with_rotation >/dev/null; then
    echo "$msg"
    log_msg_with_rotation "$LOG_FILE" "$msg" "WIFI-GOOD"
  else
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    rotate_basic
    echo "$msg" | tee -a "$LOG_FILE"
  fi
}

# =============================================================================
# HOSTNAME LOCK SYSTEM
# =============================================================================

acquire_hostname_lock() {
    local interface="$1"
    local desired_hostname="$2"
    local max_wait=30
    local wait_count=0
    
    log_msg "🔒 Acquiring hostname lock for $interface -> $desired_hostname"
    $SUDO mkdir -p "$HOSTNAME_LOCK_DIR"
    
    while [[ -f "$HOSTNAME_LOCK_FILE" && $wait_count -lt $max_wait ]]; do
        local existing_lock
        existing_lock=$(cat "$HOSTNAME_LOCK_FILE" 2>/dev/null || echo "")
        if [[ "$existing_lock" == "${interface}:${desired_hostname}"* ]]; then
            log_msg "✅ Lock already held by this service"
            return 0
        fi
        log_msg "⏳ Waiting for hostname lock to clear: $existing_lock"
        sleep 2
        ((wait_count += 2))
    done
    
    echo "${interface}:${desired_hostname}:$(date +%s):$$" | $SUDO tee "$HOSTNAME_LOCK_FILE" >/dev/null
    local lock_content
    lock_content=$(cat "$HOSTNAME_LOCK_FILE" 2>/dev/null || echo "")
    if [[ "$lock_content" == "${interface}:${desired_hostname}:"* ]]; then
        log_msg "✅ Hostname lock acquired successfully"
        return 0
    else
        log_msg "❌ Failed to acquire hostname lock"
        return 1
    fi
}

release_hostname_lock() {
    local interface="$1"
    if [[ -f "$HOSTNAME_LOCK_FILE" ]]; then
        local lock_content
        lock_content=$(cat "$HOSTNAME_LOCK_FILE" 2>/dev/null || echo "")
        if [[ "$lock_content" == "${interface}:"* ]]; then
            $SUDO rm -f "$HOSTNAME_LOCK_FILE"
            log_msg "🔓 Released hostname lock for $interface"
        fi
    fi
}

# =============================================================================
# ENHANCED HOSTNAME MANAGEMENT WITH LOCKS
# =============================================================================

set_device_hostname() {
    local desired_hostname="$1"
    local interface="$2"
    if ! acquire_hostname_lock "$interface" "$desired_hostname"; then
        log_msg "❌ Cannot set hostname - failed to acquire lock"
        return 1
    fi
    
    log_msg "🏷️ Setting DHCP hostname to: $desired_hostname for interface $interface (NOT changing system hostname)"
    local mac_addr=$(ip link show "$interface" 2>/dev/null | awk '/link\/ether/ {print $2}' || echo "unknown")
    log_msg "📱 Interface $interface MAC address: $mac_addr"
    
    local existing_connections
    existing_connections=$($SUDO nmcli -t -f NAME,DEVICE connection show --active | grep ":$interface$" | cut -d: -f1)
    if [[ -n "$existing_connections" ]]; then
        while read -r connection_name; do
            [[ -n "$connection_name" ]] || continue
            log_msg "🔧 Updating connection '$connection_name' DHCP hostname to '$desired_hostname'"
            $SUDO nmcli connection modify "$connection_name" \
                connection.dhcp-hostname "$desired_hostname" \
                ipv4.dhcp-hostname "$desired_hostname" \
                ipv4.dhcp-send-hostname yes \
                ipv6.dhcp-hostname "$desired_hostname" \
                ipv6.dhcp-send-hostname yes 2>/dev/null && \
                log_msg "✅ Updated connection '$connection_name'" || \
                log_msg "⚠️ Failed to update connection '$connection_name'"
        done <<< "$existing_connections"
    fi
    
    configure_dhcp_hostname "$desired_hostname" "$interface"
    log_msg "✅ Interface $interface configured to send DHCP hostname: $desired_hostname"
    return 0
}

setup_system_hostname() {
    local system_hostname="${1:-CNXNMist-Dashboard}"
    log_msg "🏠 Setting up system hostname (one-time): $system_hostname"
    if command -v hostnamectl >/dev/null 2>&1; then
        $SUDO hostnamectl set-hostname "$system_hostname" 2>/dev/null && \
        log_msg "✅ System hostname set via hostnamectl: $system_hostname" || \
        log_msg "❌ Failed to set hostname via hostnamectl"
    fi
    echo "$system_hostname" | $SUDO tee /etc/hostname >/dev/null 2>&1 && log_msg "✅ Updated /etc/hostname: $system_hostname" || log_msg "❌ Failed to update /etc/hostname"
    $SUDO cp /etc/hosts /etc/hosts.backup.$(date +%s) 2>/dev/null || true
    $SUDO sed -i '/^127\.0\.1\.1/d' /etc/hosts 2>/dev/null || true
    echo "127.0.1.1    $system_hostname" | $SUDO tee -a /etc/hosts >/dev/null
    local actual_hostname=$(hostname)
    [[ "$actual_hostname" == "$system_hostname" ]] && log_msg "✅ System hostname verification successful: $actual_hostname" || log_msg "⚠️ System hostname verification: expected '$system_hostname', got '$actual_hostname'"
    return 0
}

# =============================================================================
# DHCP Client Configuration
# =============================================================================

configure_dhcp_hostname() {
    local hostname="$1"
    local interface="$2"
    log_msg "🌐 Configuring DHCP to send hostname: $hostname for $interface"
    local dhclient_conf="/etc/dhcp/dhclient-${interface}.conf"
    $SUDO mkdir -p /etc/dhcp
    cat <<EOF | $SUDO tee "$dhclient_conf" >/dev/null
# DHCP client configuration for $interface
# Generated by Wi-Fi Dashboard
send host-name "$hostname";
request subnet-mask, broadcast-address, time-offset, routers,
        domain-name, domain-name-servers, domain-search, host-name,
        dhcp6.name-servers, dhcp6.domain-search, dhcp6.fqdn, dhcp6.sntp-servers,
        netbios-name-servers, netbios-scope, interface-mtu,
        rfc3442-classless-static-routes, ntp-servers;
supersede host-name "$hostname";
EOF
    log_msg "✅ Created DHCP client config: $dhclient_conf"
    local nm_conf="/etc/NetworkManager/conf.d/dhcp-hostname-${interface}.conf"
    cat <<EOF | $SUDO tee "$nm_conf" >/dev/null
[connection-dhcp-${interface}]
match-device=interface-name:${interface}
[ipv4]
dhcp-hostname=${hostname}
dhcp-send-hostname=yes
[ipv6]
dhcp-hostname=${hostname}
dhcp-send-hostname=yes
EOF
    log_msg "✅ Created NetworkManager DHCP config: $nm_conf"
    $SUDO nmcli general reload || true
    return 0
}

# =============================================================================
# Identity & helpers
# =============================================================================

verify_device_identity() {
    local interface="$1"
    local expected_hostname="$2"
    log_msg "🔍 Verifying device identity for $interface"
    local mac_addr=$(ip link show "$interface" 2>/dev/null | awk '/link\/ether/ {print $2}' || echo "unknown")
    local ip_addr=$(ip -4 addr show "$interface" 2>/dev/null | awk '/inet / {print $2; exit}' || echo "none")
    local current_hostname=$(hostname)
    log_msg "📊 Device Identity Report:"
    log_msg "   Interface: $interface"
    log_msg "   MAC Address: $mac_addr"
    log_msg "   IP Address: $ip_addr"
    log_msg "   Current Hostname: $current_hostname"
    log_msg "   Expected Hostname: $expected_hostname"
    local bssid="" ssid=""
    if $SUDO nmcli device show "$interface" 2>/dev/null | grep -q "connected"; then
        bssid=$($SUDO nmcli -t -f active,bssid dev wifi 2>/dev/null | awk -F: '$1=="yes"{print $2; exit}' || echo "unknown")
        ssid=$($SUDO nmcli -t -f active,ssid dev wifi 2>/dev/null | awk -F: '$1=="yes"{print $2; exit}' || echo "unknown")
        log_msg "   Connected SSID: $ssid"
        log_msg "   Connected BSSID: $bssid"
    else
        log_msg "   Connection Status: Not connected"
    fi
    local identity_file="/home/pi/wifi_test_dashboard/identity_${interface}.json"
    cat > "$identity_file" << EOF
{
  "interface": "$interface",
  "mac_address": "$mac_addr",
  "ip_address": "$ip_addr",
  "hostname": "$current_hostname",
  "expected_hostname": "$expected_hostname",
  "ssid": "$ssid",
  "bssid": "$bssid",
  "timestamp": "$(date -Iseconds)"
}
EOF
    log_msg "✅ Identity information saved to: $identity_file"
    return 0
}

# Connection with explicit hostname
connect_with_hostname() {
    local ssid="$1" password="$2" interface="$3" desired_hostname="$4"
    log_msg "🔗 Connecting $interface to '$ssid' with hostname '$desired_hostname'"
    set_device_hostname "$desired_hostname" "$interface"
    configure_dhcp_hostname "$desired_hostname" "$interface"
    $SUDO nmcli device disconnect "$interface" 2>/dev/null || true
    sleep 2
    local connection_name="${desired_hostname}-wifi-$$"
    if $SUDO nmcli connection add \
        type wifi con-name "$connection_name" ifname "$interface" ssid "$ssid" \
        wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$password" \
        connection.dhcp-hostname "$desired_hostname" \
        ipv4.dhcp-hostname "$desired_hostname" ipv4.dhcp-send-hostname yes \
        ipv6.dhcp-hostname "$desired_hostname" ipv6.dhcp-send-hostname yes \
        connection.autoconnect no 2>/dev/null; then
        log_msg "✅ Created connection profile with hostname: $desired_hostname"
        if $SUDO nmcli --wait 45 connection up "$connection_name" 2>/dev/null; then
            log_msg "✅ Connection activated successfully"
            sleep 10
            verify_device_identity "$interface" "$desired_hostname"
            # $SUDO nmcli connection delete "$connection_name" 2>/dev/null || true
            return 0
        else
            log_msg "❌ Failed to activate connection"
            $SUDO nmcli connection delete "$connection_name" 2>/dev/null || true
            return 1
        fi
    else
        log_msg "❌ Failed to create connection profile"
        return 1
    fi
}

# Persistent stats
load_stats() {
  if [[ -f "$STATS_FILE" ]]; then
    local stats_content
    stats_content=$(cat "$STATS_FILE" 2>/dev/null || echo '{"download": 0, "upload": 0}')
    TOTAL_DOWN=$(echo "$stats_content" | jq -r '.download // 0' 2>/dev/null || echo 0)
    TOTAL_UP=$(echo "$stats_content" | jq -r '.upload // 0' 2>/dev/null || echo 0)
  else
    TOTAL_DOWN=0
    TOTAL_UP=0
  fi
  log_msg "📊 Loaded stats: Down=${TOTAL_DOWN}B, Up=${TOTAL_UP}B"
}
save_stats() {
  echo "{\"download\": $TOTAL_DOWN, \"upload\": $TOTAL_UP, \"timestamp\": $(date +%s)}" > "$STATS_FILE"
}

# Debounced saver (avoid excessive writes mid-cycle)
LAST_SAVE_TS=0
maybe_save_stats() {
  local now
  now=$(date +%s)
  if (( LAST_SAVE_TS == 0 || (now - LAST_SAVE_TS) >= 5 )); then
    save_stats
    LAST_SAVE_TS=$now
  fi
}

# --- Settings (FINALIZE INTERFACE BEFORE STATS FILE) ---
[[ -f "$SETTINGS" ]] && source "$SETTINGS" || true
DEMO_MODE="${DEMO_MODE:-true}"
OPPORTUNISTIC_ROAMING_INTERVAL="${OPPORTUNISTIC_ROAMING_INTERVAL:-180}"
LAST_ROAM_TIME="${LAST_ROAM_TIME:-0}"  # Initialize roaming timer
INTERFACE="${WIFI_GOOD_INTERFACE:-$INTERFACE}"
REFRESH_INTERVAL="${WIFI_GOOD_REFRESH_INTERVAL:-60}"
CONNECTION_TIMEOUT="${WIFI_CONNECTION_TIMEOUT:-30}"
MAX_RETRIES="${WIFI_MAX_RETRY_ATTEMPTS:-3}"

# Roaming config
ROAMING_ENABLED="${WIFI_ROAMING_ENABLED:-true}"
ROAMING_INTERVAL="${WIFI_ROAMING_INTERVAL:-60}"
ROAMING_SCAN_INTERVAL="${WIFI_ROAMING_SCAN_INTERVAL:-10}"
MIN_SIGNAL_THRESHOLD="${WIFI_MIN_SIGNAL_THRESHOLD:--75}"
ROAMING_SIGNAL_DIFF="${WIFI_ROAMING_SIGNAL_DIFF:-5}"
WIFI_BAND_PREFERENCE="${WIFI_BAND_PREFERENCE:-both}"

# Traffic config
TRAFFIC_INTENSITY="${WLAN0_TRAFFIC_INTENSITY:-medium}"
ENABLE_INTEGRATED_TRAFFIC="${WIFI_GOOD_INTEGRATED_TRAFFIC:-true}"

# Ensure stats dir and compute STATS_FILE based on the final INTERFACE
mkdir -p "$DASHBOARD_DIR/stats"
STATS_FILE="$DASHBOARD_DIR/stats/stats_${INTERFACE}.json"

# Intensity presets
case "$TRAFFIC_INTENSITY" in
  heavy)  DL_SIZE=104857600; PING_COUNT=20; DOWNLOAD_INTERVAL=60;  CONCURRENT_DOWNLOADS=5 ;;
  medium) DL_SIZE=52428800;  PING_COUNT=10; DOWNLOAD_INTERVAL=120; CONCURRENT_DOWNLOADS=3 ;;
  *)      DL_SIZE=10485760;  PING_COUNT=5;  DOWNLOAD_INTERVAL=300; CONCURRENT_DOWNLOADS=2 ;;
esac

# Targets
TEST_URLS=("https://www.google.com" "https://www.cloudflare.com" "https://httpbin.org/ip" "https://www.github.com")
DOWNLOAD_URLS=("https://ash-speed.hetzner.com/100MB.bin" "https://proof.ovh.net/files/100Mb.dat" "http://ipv4.download.thinkbroadband.com/50MB.zip" "https://speed.hetzner.de/100MB.bin")
PING_TARGETS=("8.8.8.8" "1.1.1.1" "208.67.222.222" "9.9.9.9")

# Global roaming state
declare -A DISCOVERED_BSSIDS
declare -A BSSID_SIGNALS
CURRENT_BSSID=""
LAST_ROAM_TIME=0
LAST_SCAN_TIME=0

# Global SSID/PASSWORD variables
SSID=""
PASSWORD=""

# Load persistent stats (now that STATS_FILE is finalized)
load_stats
trap 'save_stats' EXIT

# --- Safe getters ---
nm_state() { $SUDO nmcli -t -f GENERAL.STATE device show "$INTERFACE" 2>/dev/null | cut -d: -f2 | awk '{print $1}' || echo ""; }
current_ip() { ip -o -4 addr show dev "$INTERFACE" 2>/dev/null | awk '{print $4}' | head -n1; }
current_ssid() { $SUDO nmcli -t -f active,ssid dev wifi 2>/dev/null | awk -F: '$1=="yes"{print $2; exit}'; }

# --- Config ---
read_wifi_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then log_msg "Config file not found: $CONFIG_FILE"; return 1; fi
  mapfile -t lines < "$CONFIG_FILE"
  if [[ ${#lines[@]} -lt 2 ]]; then log_msg "Config incomplete (need SSID + password)"; return 1; fi
  local temp_ssid="${lines[0]}" temp_password="${lines[1]}"
  temp_ssid=$(echo "$temp_ssid" | xargs); temp_password=$(echo "$temp_password" | xargs)
  if [[ -z "$temp_ssid" || -z "$temp_password" ]]; then log_msg "SSID or password empty after parsing"; return 1; fi
  SSID="$temp_ssid"; PASSWORD="$temp_password"; export SSID PASSWORD
  log_msg "Wi-Fi config loaded (SSID: '$SSID')"
  return 0
}

# --- Interface mgmt ---
check_wifi_interface() {
  if ! ip link show "$INTERFACE" >/dev/null 2>&1; then log_msg "Interface $INTERFACE not found"; return 1; fi
  log_msg "Ensuring $INTERFACE is up and managed..."
  $SUDO ip link set "$INTERFACE" up || true; sleep 2
  $SUDO nmcli device set "$INTERFACE" managed yes || true; sleep 2
  log_msg "Forcing Wi-Fi rescan..."; $SUDO nmcli device wifi rescan ifname "$INTERFACE" || true; sleep 3
  local st; st="$(nm_state)"; log_msg "Interface $INTERFACE state: ${st:-unknown}"
  return 0
}

get_current_bssid() {
  # Try nmcli first, then iw
  local bssid=""
  bssid="$(nmcli -t -f ACTIVE,BSSID,SSID dev wifi | awk -F: '$1=="yes"{print $2; exit}')" || true
  if [[ -z "$bssid" || ! "$bssid" =~ : ]]; then
    bssid="$(iw dev "$IFACE" link 2>/dev/null | awk '/Connected to/{print $3; exit}')" || true
  fi
  # Defensive fallback in case some tools format weirdly
  bssid="${bssid//\\n/}"
  bssid="${bssid//\\r/}"
  bssid="${bssid//\\t/}"
  bssid="$(echo "$bssid" | tr 'a-f' 'A-F')"
  echo "$bssid"
}

# BSSID discovery
discover_bssids_for_ssid() {
  declare -gA BSSID_SIGNALS
  BSSID_SIGNALS=()
  nmcli dev wifi rescan >/dev/null 2>&1 || true
  # Pull only the SSID we care about
  while IFS=: read -r active bssid ssid signal; do
    [[ "$ssid" != "$SSID" ]] && continue
    # Normalize and fill map
    bssid="$(echo "$bssid" | tr 'a-f' 'A-F')"
    [[ "$bssid" =~ : ]] || continue
    BSSID_SIGNALS["$bssid"]="$signal"
  done < <(nmcli -t -f ACTIVE,BSSID,SSID,SIGNAL dev wifi 2>/dev/null)
  # Log what we found
  local count="${#BSSID_SIGNALS[@]}"
  if (( count > 0 )); then
    log_msg "✅ Found ${count} BSSID(s) for '$SSID'"
    for k in "${!BSSID_SIGNALS[@]}"; do
      log_msg "   Available: $k ($(( BSSID_SIGNALS[$k] * -1 )) dBm)"
    done
    return 0
  else
    log_msg "⚠️  No BSSIDs discovered for '$SSID'"
    return 1
  fi
}

prune_same_ssid_profiles() {
  local ssid="$1"
  $SUDO nmcli -t -f NAME,TYPE con show 2>/dev/null \
    | awk -F: '$2=="wifi"{print $1}' \
    | while read -r c; do
        local cs; cs="$($SUDO nmcli -t -f 802-11-wireless.ssid con show "$c" 2>/dev/null | cut -d: -f2 || true)"
        [[ "$cs" == "$ssid" ]] && $SUDO nmcli con delete "$c" 2>/dev/null || true
      done
}

connect_locked_bssid() {
  local bssid="$1" ssid="$2" psk="$3"
  [[ -z "$bssid" || -z "$ssid" || -z "$psk" ]] && { log_msg "❌ connect_locked_bssid: missing parameter(s)"; return 1; }
  log_msg "🔗 Attempting BSSID-locked connection to $bssid (SSID: '$ssid')"
  prune_same_ssid_profiles "$ssid"; $SUDO nmcli dev disconnect "$INTERFACE" 2>/dev/null || true; sleep 3

  local OUT
  if OUT="$($SUDO nmcli --wait 45 device wifi connect "$ssid" password "$psk" ifname "$INTERFACE" bssid "$bssid" 2>&1)"; then
    log_msg "✅ nmcli BSSID connect reported success: ${OUT}"
    sleep 5
    local actual_bssid; actual_bssid="$(get_current_bssid)"
    if [[ "$actual_bssid" == "${bssid,,}" ]]; then
      log_msg "✅ BSSID verification successful: connected to $actual_bssid"; return 0
    else
      log_msg "❌ BSSID mismatch: connected to ${actual_bssid:-unknown}, expected ${bssid,,}"
    fi
  else
    log_msg "❌ nmcli BSSID connect failed: ${OUT}"
  fi

  log_msg "🔄 Trying profile-based BSSID connection..."
  local profile_name="bssid-lock-$$"
  if $SUDO nmcli connection add \
      type wifi con-name "$profile_name" ifname "$INTERFACE" ssid "$ssid" \
      802-11-wireless.bssid "$bssid" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$psk" \
      ipv4.method auto ipv6.method ignore connection.autoconnect no >/dev/null 2>&1; then
    log_msg "✅ Created BSSID-locked profile"
    if $SUDO nmcli --wait 45 connection up "$profile_name" >/dev/null 2>&1; then
      sleep 5
      local actual_bssid; actual_bssid="$(get_current_bssid)"
      $SUDO nmcli connection delete "$profile_name" 2>/dev/null || true
      if [[ "$actual_bssid" == "${bssid,,}" ]]; then
        log_msg "✅ Profile-based BSSID connection successful: $actual_bssid"; return 0
      else
        log_msg "❌ Profile-based BSSID mismatch: ${actual_bssid:-unknown} vs ${bssid,,}"
      fi
    else
      log_msg "❌ Profile activation failed"; $SUDO nmcli connection delete "$profile_name" 2>/dev/null || true
    fi
  else
    log_msg "❌ Failed to create BSSID-locked profile"
  fi

  log_msg "🔄 Trying iw dev connect as last resort..."
  $SUDO iw dev "$INTERFACE" disconnect >/dev/null 2>&1 || true; sleep 2
  if $SUDO iw dev "$INTERFACE" connect "$ssid" "$bssid" >/dev/null 2>&1; then
    log_msg "✅ iw dev connect initiated"; sleep 5
    local wpa_conf="/tmp/wpa_roam_$$.conf"
    cat > "$wpa_conf" << EOF
network={
    ssid="$ssid"
    psk="$psk"
    bssid=$bssid
    scan_ssid=1
}
EOF
    if $SUDO wpa_supplicant -i "$INTERFACE" -c "$wpa_conf" -B >/dev/null 2>&1; then
      sleep 8; $SUDO dhclient "$INTERFACE" >/dev/null 2>&1 || true; sleep 3
      local actual_bssid; actual_bssid="$(get_current_bssid)"
      rm -f "$wpa_conf"; pkill -f "wpa_supplicant.*$INTERFACE" || true
      if [[ "$actual_bssid" == "${bssid,,}" ]]; then
        log_msg "✅ iw+wpa_supplicant BSSID connection successful: $actual_bssid"; return 0
      else
        log_msg "❌ iw+wpa BSSID mismatch: ${actual_bssid:-unknown}"
      fi
    fi
    rm -f "$wpa_conf"
  fi

  log_msg "❌ All BSSID connection methods failed"; return 1
}

# Traffic generation (now with debounced mid-cycle saves)
generate_realistic_traffic() {
  [[ "$ENABLE_INTEGRATED_TRAFFIC" != "true" ]] && return 0

  local st ip ss; st="$(nm_state)"; ip="$(current_ip)"; ss="$(current_ssid)"
  if [[ "$st" != "100" && "$st" != "90" && "$st" != "80" ]]; then
      log_msg "⚠️ Traffic suppressed: NetworkManager state not ready (state: $st)"; return 1
  fi
  if [[ -z "$ip" ]]; then log_msg "⚠️ Traffic suppressed: No IP address assigned"; return 1; fi
  if [[ -n "$ss" && -n "$SSID" && "$ss" != "$SSID" ]]; then
      log_msg "ℹ️ Note: Connected to '$ss', expected '$SSID' (may be roaming)"
  fi

  log_msg "🚀 Starting realistic traffic generation (intensity: $TRAFFIC_INTENSITY, IP: $ip)"

  # Quick connectivity test before heavy traffic
  if ! timeout 10 ping -I "$INTERFACE" -c 2 -W 3 8.8.8.8 >/dev/null 2>&1; then
    log_msg "❌ Basic connectivity failed; skipping heavy traffic"; return 1
  fi

  # Download traffic
  local url="${DOWNLOAD_URLS[$((RANDOM % ${#DOWNLOAD_URLS[@]}))]}"
  local tmp_file="/tmp/test_download_$$"
  log_msg "📥 Downloading from: $(basename "$url")"
  if timeout 120 curl --interface "$INTERFACE" --connect-timeout 15 --max-time 90 \
      --retry 2 --retry-delay 5 --silent --location --fail \
      --output "$tmp_file" "$url" 2>/dev/null; then
    if [[ -f "$tmp_file" ]]; then
      local bytes
      bytes=$(stat -c%s "$tmp_file" 2>/dev/null || stat -f%z "$tmp_file" 2>/dev/null || echo 0)
      TOTAL_DOWN=$((TOTAL_DOWN + bytes))
      maybe_save_stats    # <— debounced mid-cycle persist
      log_msg "✅ Downloaded $bytes bytes (Total: ${TOTAL_DOWN})"
      rm -f "$tmp_file"
    fi
  else
    log_msg "❌ Download failed (network may be slow or congested)"
    rm -f "$tmp_file"
  fi

  # Upload traffic
  local upload_url="https://httpbin.org/post"
  local upload_size=102400  # 100KB
  log_msg "📤 Uploading test data..."
  if timeout 60 dd if=/dev/zero bs=1024 count=100 2>/dev/null | \
     curl --interface "$INTERFACE" --connect-timeout 10 --max-time 45 \
          --retry 1 --silent --fail -X POST -o /dev/null \
          "$upload_url" --data-binary @- 2>/dev/null; then
    TOTAL_UP=$((TOTAL_UP + upload_size))
    maybe_save_stats      # <— debounced mid-cycle persist
    log_msg "✅ Uploaded $upload_size bytes (Total: ${TOTAL_UP})"
  else
    log_msg "❌ Upload failed (may be network congestion)"
  fi

  # Multi-target ping summary (no byte accounting)
  local ping_success=0 ping_total=${#PING_TARGETS[@]}
  for ping_target in "${PING_TARGETS[@]}"; do
    if timeout 30 ping -I "$INTERFACE" -c "$PING_COUNT" -i 0.5 "$ping_target" >/dev/null 2>&1; then
      log_msg "✅ Ping successful: $ping_target"; ((ping_success++))
    else
      log_msg "⚠️ Ping failed: $ping_target"
    fi
  done
  log_msg "📊 Ping results: $ping_success/$ping_total targets reachable"

  # Final persist for the cycle
  save_stats
  log_msg "✅ Traffic generation completed (Down: ${TOTAL_DOWN}B, Up: ${TOTAL_UP}B)"
  return 0
}

select_roaming_target() {
  local cur="$1"
  cur="$(echo "$cur" | tr 'a-f' 'A-F')"  # normalize
  local best=""
  local best_sig=-100
  # If your SIGNAL is 0–100, ensure these thresholds are in the same scale
  local current_sig="${BSSID_SIGNALS[$cur]:-$MIN_SIGNAL_THRESHOLD}"
  local now=$(date +%s)

  log_msg "📊 Evaluating roaming from BSSID $cur (SIG ${current_sig})"

  # First, try to find a significantly better signal (normal roaming)
  for b in "${!BSSID_SIGNALS[@]}"; do   # <— iterate over the map you actually use
    [[ "$b" == "$cur" ]] && continue
    local s="${BSSID_SIGNALS[$b]}"

    # Only consider BSSIDs above minimum threshold (0–100 scale if using nmcli SIGNAL)
    if (( s <= MIN_SIGNAL_THRESHOLD )); then
      log_msg "   ⊗ Skipping $b (SIG ${s} - below threshold)"
      continue
    fi

    # Check if significantly better (still 0–100 scale)
    local signal_improvement=$((s - current_sig))
    if (( signal_improvement >= ROAMING_SIGNAL_DIFF )); then
      if (( s > best_sig )); then
        best_sig=$s
        best="$b"
        log_msg "   ✓ Better candidate: $b (SIG ${s}, +${signal_improvement})"
      fi
    else
      log_msg "   → Candidate $b (SIG ${s}, +${signal_improvement}) - below +${ROAMING_SIGNAL_DIFF} threshold"
    fi
  done

  # If we found a significantly better signal, use it
  if [[ -n "$best" ]]; then
    log_msg "🎯 Selected signal-based roaming target: $best (SIG ${best_sig})"
    echo "$best"
    return 0
  fi

  # DEMO MODE: Opportunistic roaming when all signals are similar
  if [[ "$DEMO_MODE" == "true" ]]; then
    local time_since_last_roam=$((now - LAST_ROAM_TIME))

    if (( time_since_last_roam >= OPPORTUNISTIC_ROAMING_INTERVAL )); then
      log_msg "🎪 Demo mode: Opportunistic roaming interval reached (${time_since_last_roam}s)"

      local alternatives=()
      for b in "${!BSSID_SIGNALS[@]}"; do
        [[ "$b" == "$cur" ]] && continue
        local s="${BSSID_SIGNALS[$b]}"
        if (( s > MIN_SIGNAL_THRESHOLD )); then
          alternatives+=("$b")
          log_msg "   • Alternative: $b (SIG ${s})"
        fi
      done

      if (( ${#alternatives[@]} > 0 )); then
        local idx=$((RANDOM % ${#alternatives[@]}))
        best="${alternatives[$idx]}"
        best_sig="${BSSID_SIGNALS[$best]}"
        log_msg "🎯 Selected opportunistic roaming target: $best (SIG ${best_sig}) - demo roaming"
        LAST_ROAM_TIME=$now
        echo "$best"
        return 0
      else
        log_msg "⚠️ No viable alternative BSSIDs available for opportunistic roaming"
      fi
    else
      local remaining=$((OPPORTUNISTIC_ROAMING_INTERVAL - time_since_last_roam))
      log_msg "⏱️  Opportunistic roaming in ${remaining}s (no better signal available)"
    fi
  fi

  # No roaming target found
  log_msg "📍 No suitable roaming target found; staying on $cur (SIG ${current_sig})"
  echo ""
}


perform_roaming() {
  local target_bssid="$1" ssid="$2" password="$3"

  # Be explicit with NM so it doesn't outsmart us
  nmcli con modify "$ssid" 802-11-wireless.bssid "$target_bssid" 2>/dev/null || true
  nmcli con modify "$ssid" 802-11-wireless.mac-address "$WIFI_MAC" 2>/dev/null || true
  nmcli con modify "$ssid" 802-11-wireless.cloned-mac-address "$WIFI_MAC" 2>/dev/null || true
  nmcli con modify "$ssid" 802-11-wireless.powersave 2 2>/dev/null || true      # disable PS
  nmcli set wifi.scan-rand-mac-address no 2>/dev/null || true

  # Tear down cleanly and pin to target
  nmcli dev disconnect "$IFACE" >/dev/null 2>&1 || true
  sleep 2

  # WPA3-Personal (SAE) reconnect pinned to BSSID
  # NOTE: --rescan no keeps the selected BSSID
  nmcli --wait 30 dev wifi connect "$ssid" ifname "$IFACE" bssid "$target_bssid" password "$password" --rescan no
}

connect_to_wifi_with_roaming() {
  local local_ssid="$1" local_password="$2"
  [[ -z "$local_ssid" || -z "$local_password" ]] && { log_msg "❌ connect_to_wifi_with_roaming called with empty parameters"; return 1; }
  log_msg "🔗 Connecting to Wi-Fi (roaming enabled=${ROAMING_ENABLED}) for SSID '$local_ssid'"
  if discover_bssids_for_ssid "$local_ssid"; then
    local target_bssid="" best_signal=-100
    for b in "${!DISCOVERED_BSSIDS[@]}"; do
      local s="${BSSID_SIGNALS[$b]}"; [[ -n "$s" && "$s" -gt "$best_signal" ]] && best_signal="$s" && target_bssid="$b"
    done
    if [[ -n "$target_bssid" ]]; then
      log_msg "🎯 Attempting connection to strongest BSSID $target_bssid ($best_signal dBm)"
      if connect_locked_bssid "$target_bssid" "$local_ssid" "$local_password"; then
        log_msg "✅ BSSID-locked connection successful"; return 0
      else
        log_msg "⚠️ BSSID-locked connection failed, falling back to regular connect"
      fi
    fi
  fi
  log_msg "🔄 Attempting fallback connection to SSID '$local_ssid'"
  $SUDO nmcli dev disconnect "$INTERFACE" 2>/dev/null || true; sleep 2
  local OUT
  if OUT="$($SUDO nmcli --wait 45 device wifi connect "${local_ssid}" password "${local_password}" ifname "$INTERFACE" 2>&1)"; then
    log_msg "✅ Fallback connection successful: ${OUT}"
  else
    log_msg "❌ Fallback connection failed: ${OUT}"; return 1
  fi
  log_msg "⏳ Waiting for IP address..."
  for i in {1..20}; do
    local ip; ip="$(ip addr show "$INTERFACE" | awk '/inet /{print $2; exit}')"
    [[ -n "$ip" ]] && { log_msg "✅ IP address acquired: $ip"; break; }
    sleep 2
  done
  CURRENT_BSSID="$(get_current_bssid)"
  log_msg "✅ Successfully connected to '$local_ssid' (BSSID=${CURRENT_BSSID:-unknown})"
  return 0
}

should_perform_roaming() {
  [[ "$ROAMING_ENABLED" != "true" ]] && return 1
  local now; now=$(date +%s)
  (( now - LAST_ROAM_TIME < ROAMING_INTERVAL )) && return 1
  (( ${#DISCOVERED_BSSIDS[@]} < 2 )) && return 1
  return 0
}

manage_roaming() {
  [[ "$ROAMING_ENABLED" != "true" ]] && return 0
  discover_bssids_for_ssid "$SSID" || return 0

  if should_perform_roaming; then
    log_msg "⏰ Roaming interval reached, evaluating roaming opportunity..."
    local current; current="$(get_current_bssid)"
    current="$(echo "$current" | tr 'a-f' 'A-F')"
    [[ -z "$current" ]] && { log_msg "⚠️  Current BSSID unknown, skipping roam"; return 0; }

    local target; target="$(select_roaming_target "$current")"
    if [[ -n "$target" ]]; then
      local t_sig="${BSSID_SIGNALS[$target]}"
      local c_sig="${BSSID_SIGNALS[$current]:-unknown}"
      log_msg "🔄 Roaming candidate: $target (SIG $t_sig) vs current $current (SIG ${c_sig})"

      set +e
      if timeout 120 perform_roaming "$target" "$SSID" "$PASSWORD" 2>&1; then
        log_msg "✅ Roaming completed successfully"
        LAST_ROAM_TIME=$(date +%s)
      else
        local rc=$?
        if [[ $rc -eq 124 ]]; then
          log_msg "⏱️  Roaming timed out (120s)"
        else
          log_msg "❌ Roaming failed (exit $rc)"
        fi
      fi
      set -e
    else
      log_msg "ℹ️  No better BSSID candidate found; skipping roam"
    fi
  fi
}


# Heuristic for connection health
assess_connection_health() {
  local st ip ss; st="$(nm_state)"; ip="$(current_ip)"; ss="$(current_ssid)"
  if [[ "$st" == "100" || "$st" == "90" || "$st" == "80" ]] && [[ -n "$ip" ]]; then
    if [[ -n "$ss" && -n "$SSID" ]]; then
      if [[ "$ss" == "$SSID" ]]; then
        log_msg "✅ Connection healthy: SSID='$ss', IP=$ip, state=$st"; return 0
      else
        log_msg "ℹ️ Connection active but SSID mismatch: current='$ss', expected='$SSID' (may be roaming)"; return 0
      fi
    else
      log_msg "✅ Connection active: IP=$ip, state=$st"; return 0
    fi
  else
    log_msg "⚠️ Connection unhealthy: state=${st:-?}, IP=${ip:-none}, SSID=${ss:-none}"; return 1
  fi
}

# Main loop
main_loop() {
    log_msg "🚀 Starting enhanced good client with persistent throughput tracking"
    enhanced_good_client_setup
    local last_cfg=0 last_traffic=0
    while true; do
        local now=$(date +%s)
        # Re-read config periodically
        if (( now - last_cfg > 600 )); then
            if read_wifi_config; then log_msg "✅ Config refreshed (SSID: '$SSID')"; last_cfg=$now
            else log_msg "⚠️ Config read failed, using previous values (SSID: '${SSID:-unset}')"; fi
        fi
        # Validate config
        if [[ -z "$SSID" || -z "$PASSWORD" ]]; then
            log_msg "❌ No valid SSID/password configuration, retrying in $REFRESH_INTERVAL seconds"
            sleep "$REFRESH_INTERVAL"; continue
        fi
        # Check interface
        if ! check_wifi_interface; then
            log_msg "❌ Interface check failed, retrying..."; sleep "$REFRESH_INTERVAL"; continue
        fi
        # Health → roam → traffic
        if assess_connection_health; then
            manage_roaming
            if (( now - last_traffic > 30 )); then
                generate_realistic_traffic && last_traffic=$now
            fi
        else
            if [[ -n "$SSID" && -n "$PASSWORD" ]]; then
                log_msg "🔄 Connection needs attention, attempting to reconnect"
                if connect_to_wifi_with_roaming "$SSID" "$PASSWORD"; then
                    log_msg "✅ Wi-Fi connection reestablished"; sleep 5
                else
                    log_msg "❌ Reconnect failed; will retry in $REFRESH_INTERVAL seconds"
                    sleep "$REFRESH_INTERVAL"; continue
                fi
            else
                log_msg "❌ Cannot reconnect: missing SSID or password"
                sleep "$REFRESH_INTERVAL"; continue
            fi
        fi
        CURRENT_BSSID=$(get_current_bssid)
        if [[ -n "$CURRENT_BSSID" ]]; then
            log_msg "📍 Current: BSSID $CURRENT_BSSID (${BSSID_SIGNALS[$CURRENT_BSSID]:-unknown} dBm) | Available BSSIDs: ${#BSSID_SIGNALS[@]} | Stats: D=${TOTAL_DOWN}B U=${TOTAL_UP}B"
        fi
        if (( now % 300 == 0 )); then verify_device_identity "$INTERFACE" "$HOSTNAME"; fi
        log_msg "✅ Good client operating normally"
        save_stats
        sleep "$REFRESH_INTERVAL"
    done
}

enhanced_good_client_setup() {
    log_msg "🚀 Starting enhanced good client with PROPER identity management"
    local current_system_hostname=$(hostname)
    if [[ "$current_system_hostname" == "localhost" ]] || [[ "$current_system_hostname" == "raspberrypi" ]] || [[ -z "$current_system_hostname" ]]; then
        setup_system_hostname "CNXNMist-Dashboard"
    else
        log_msg "🏠 System hostname already set: $current_system_hostname (not changing)"
    fi
    set_device_hostname "$HOSTNAME" "$INTERFACE"
    verify_device_identity "$INTERFACE" "$HOSTNAME"
    log_msg "Interface: $INTERFACE | DHCP Hostname: $HOSTNAME | System Hostname: $(hostname)"
    log_msg "Roaming: ${ROAMING_ENABLED} (interval ${ROAMING_INTERVAL}s; scan ${ROAMING_SCAN_INTERVAL}s; min ${MIN_SIGNAL_THRESHOLD}dBm)"
    log_msg "Persistent stats file: $STATS_FILE"
}

cleanup_and_exit() {
  log_msg "🧹 Cleaning up good client..."
  save_stats
  release_hostname_lock "$INTERFACE"
  $SUDO nmcli device disconnect "$INTERFACE" 2>/dev/null || true
  log_msg "✅ Stopped (final stats saved: Down=${TOTAL_DOWN}B, Up=${TOTAL_UP}B)"
  exit 0
}
trap cleanup_and_exit SIGTERM SIGINT

# --- Init ---
mkdir -p "$LOG_DIR" 2>/dev/null || true
log_msg "🚀 Enhanced Wi-Fi Good Client Starting..."
log_msg "Interface: $INTERFACE | Hostname: $HOSTNAME"

# Initial config read
if ! read_wifi_config; then
  log_msg "❌ Failed to read initial configuration"
fi

# Start main loop
main_loop
