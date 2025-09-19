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
STATS_FILE="$DASHBOARD_DIR/stats_${INTERFACE:-wlan0}.json"

INTERFACE="${INTERFACE:-wlan0}"
HOSTNAME="${WIFI_GOOD_HOSTNAME:-${HOSTNAME:-CNXNMist-WiFiGood}}"
LOG_MAX_SIZE_BYTES="${LOG_MAX_SIZE_BYTES:-10485760}"   # 10MB default

# Ensure system hostname is set correctly
if command -v hostnamectl >/dev/null 2>&1; then
  sudo hostnamectl set-hostname "$HOSTNAME" 2>/dev/null || true
fi

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

set_device_hostname() {
    local desired_hostname="$1"
    local interface="$2"
    
    log_msg "🏷️ Setting device hostname to: $desired_hostname for interface $interface"
    
    # Get the MAC address for this interface for logging
    local mac_addr=$(ip link show "$interface" 2>/dev/null | awk '/link\/ether/ {print $2}' || echo "unknown")
    log_msg "📱 Interface $interface MAC address: $mac_addr"
    
    # Method 1: Set system hostname
    if command -v hostnamectl >/dev/null 2>&1; then
        if $SUDO hostnamectl set-hostname "$desired_hostname" 2>/dev/null; then
            log_msg "✅ System hostname set via hostnamectl: $desired_hostname"
        else
            log_msg "❌ Failed to set hostname via hostnamectl"
        fi
    fi
    
    # Method 2: Update /etc/hostname
    if echo "$desired_hostname" | $SUDO tee /etc/hostname >/dev/null 2>&1; then
        log_msg "✅ Updated /etc/hostname: $desired_hostname"
    else
        log_msg "❌ Failed to update /etc/hostname"
    fi
    
    # Method 3: Update /etc/hosts
    $SUDO sed -i.bak "/127.0.1.1/d" /etc/hosts 2>/dev/null || true
    echo "127.0.1.1    $desired_hostname" | $SUDO tee -a /etc/hosts >/dev/null
    log_msg "✅ Updated /etc/hosts with: $desired_hostname"
    
    # Method 4: Set NetworkManager hostname for this connection
    local current_connection
    current_connection=$($SUDO nmcli -t -f NAME connection show --active 2>/dev/null | head -1 || echo "")
    
    if [[ -n "$current_connection" ]]; then
        if $SUDO nmcli connection modify "$current_connection" connection.dhcp-hostname "$desired_hostname" 2>/dev/null; then
            log_msg "✅ Set DHCP hostname in NetworkManager connection: $desired_hostname"
        else
            log_msg "⚠️ Could not set DHCP hostname in NetworkManager"
        fi
    fi
    
    # Method 5: Force immediate hostname update
    if command -v hostname >/dev/null 2>&1; then
        $SUDO hostname "$desired_hostname" 2>/dev/null || true
        log_msg "✅ Set immediate hostname: $(hostname)"
    fi
    
    # Verify hostname was set
    local actual_hostname=$(hostname)
    if [[ "$actual_hostname" == "$desired_hostname" ]]; then
        log_msg "✅ Hostname verification successful: $actual_hostname"
    else
        log_msg "⚠️ Hostname verification: expected '$desired_hostname', got '$actual_hostname'"
    fi
    
    return 0
}

# =============================================================================
# 2. Enhanced DHCP Client Configuration
# =============================================================================

configure_dhcp_hostname() {
    local hostname="$1"
    local interface="$2"
    
    log_msg "🌐 Configuring DHCP to send hostname: $hostname for $interface"
    
    # Create dhclient configuration for this interface
    local dhclient_conf="/etc/dhcp/dhclient-${interface}.conf"
    
    $SUDO mkdir -p /etc/dhcp
    
    cat <<EOF | $SUDO tee "$dhclient_conf" >/dev/null
# DHCP client configuration for $interface
# Generated by Wi-Fi Dashboard

# Send hostname in DHCP requests
send host-name "$hostname";

# Request hostname from server
request subnet-mask, broadcast-address, time-offset, routers,
        domain-name, domain-name-servers, domain-search, host-name,
        dhcp6.name-servers, dhcp6.domain-search, dhcp6.fqdn, dhcp6.sntp-servers,
        netbios-name-servers, netbios-scope, interface-mtu,
        rfc3442-classless-static-routes, ntp-servers;

# Override any server-provided hostname
supersede host-name "$hostname";
EOF
    
    log_msg "✅ Created DHCP client config: $dhclient_conf"
    
    # Also configure NetworkManager to use this dhclient config
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
    
    # Reload NetworkManager configuration
    $SUDO nmcli general reload || true
    
    return 0
}

# =============================================================================
# 3. MAC Address Verification and Logging
# =============================================================================

verify_device_identity() {
    local interface="$1"
    local expected_hostname="$2"
    
    log_msg "🔍 Verifying device identity for $interface"
    
    # Get interface details
    local mac_addr=$(ip link show "$interface" 2>/dev/null | awk '/link\/ether/ {print $2}' || echo "unknown")
    local ip_addr=$(ip -4 addr show "$interface" 2>/dev/null | awk '/inet / {print $2}' | head -1 || echo "none")
    local current_hostname=$(hostname)
    
    # Log all identity information
    log_msg "📊 Device Identity Report:"
    log_msg "   Interface: $interface"
    log_msg "   MAC Address: $mac_addr"
    log_msg "   IP Address: $ip_addr"
    log_msg "   Current Hostname: $current_hostname"
    log_msg "   Expected Hostname: $expected_hostname"
    
    # Check if we're connected and get BSSID info
    local bssid=""
    local ssid=""
    
    if $SUDO nmcli device show "$interface" 2>/dev/null | grep -q "connected"; then
        bssid=$($SUDO nmcli -t -f active,bssid dev wifi 2>/dev/null | awk -F: '$1=="yes"{print $2; exit}' || echo "unknown")
        ssid=$($SUDO nmcli -t -f active,ssid dev wifi 2>/dev/null | awk -F: '$1=="yes"{print $2; exit}' || echo "unknown")
        
        log_msg "   Connected SSID: $ssid"
        log_msg "   Connected BSSID: $bssid"
    else
        log_msg "   Connection Status: Not connected"
    fi
    
    # Create identity file for debugging
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

# =============================================================================
# 4. Connection Setup with Proper Hostname Assignment
# =============================================================================

connect_with_hostname() {
    local ssid="$1"
    local password="$2"
    local interface="$3"
    local desired_hostname="$4"
    
    log_msg "🔗 Connecting $interface to '$ssid' with hostname '$desired_hostname'"
    
    # Step 1: Set hostname BEFORE connection
    set_device_hostname "$desired_hostname" "$interface"
    
    # Step 2: Configure DHCP to send our hostname
    configure_dhcp_hostname "$desired_hostname" "$interface"
    
    # Step 3: Ensure clean connection state
    $SUDO nmcli device disconnect "$interface" 2>/dev/null || true
    sleep 2
    
    # Step 4: Connect with explicit hostname setting
    local connection_name="${desired_hostname}-wifi-$$"
    
    if $SUDO nmcli connection add \
        type wifi \
        con-name "$connection_name" \
        ifname "$interface" \
        ssid "$ssid" \
        wifi-sec.key-mgmt wpa-psk \
        wifi-sec.psk "$password" \
        connection.dhcp-hostname "$desired_hostname" \
        ipv4.dhcp-hostname "$desired_hostname" \
        ipv4.dhcp-send-hostname yes \
        ipv6.dhcp-hostname "$desired_hostname" \
        ipv6.dhcp-send-hostname yes \
        connection.autoconnect no 2>/dev/null; then
        
        log_msg "✅ Created connection profile with hostname: $desired_hostname"
        
        # Activate the connection
        if $SUDO nmcli connection up "$connection_name" 2>/dev/null; then
            log_msg "✅ Connection activated successfully"
            
            # Wait for DHCP and verify identity
            sleep 10
            verify_device_identity "$interface" "$desired_hostname"
            
            # Clean up connection profile (optional - or keep for reuse)
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

# --- Load persistent stats ---
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

# --- Settings ---
[[ -f "$SETTINGS" ]] && source "$SETTINGS" || true
INTERFACE="${WIFI_GOOD_INTERFACE:-$INTERFACE}"
REFRESH_INTERVAL="${WIFI_GOOD_REFRESH_INTERVAL:-60}"
CONNECTION_TIMEOUT="${WIFI_CONNECTION_TIMEOUT:-30}"
MAX_RETRIES="${WIFI_MAX_RETRY_ATTEMPTS:-3}"

# Roaming config (AGGRESSIVE FOR DEMO)
ROAMING_ENABLED="${WIFI_ROAMING_ENABLED:-true}"
ROAMING_INTERVAL="${WIFI_ROAMING_INTERVAL:-60}"  # Roam every 60 seconds for active demo
ROAMING_SCAN_INTERVAL="${WIFI_ROAMING_SCAN_INTERVAL:-10}"  # Scan more frequently
MIN_SIGNAL_THRESHOLD="${WIFI_MIN_SIGNAL_THRESHOLD:--75}"
ROAMING_SIGNAL_DIFF="${WIFI_ROAMING_SIGNAL_DIFF:-5}"  # Reduced for more roaming
WIFI_BAND_PREFERENCE="${WIFI_BAND_PREFERENCE:-both}"

# Traffic config
TRAFFIC_INTENSITY="${WLAN0_TRAFFIC_INTENSITY:-medium}"
ENABLE_INTEGRATED_TRAFFIC="${WIFI_GOOD_INTEGRATED_TRAFFIC:-true}"

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

# Load persistent stats
load_stats

# --- Safe getters ---
nm_state() {
  $SUDO nmcli -t -f GENERAL.STATE device show "$INTERFACE" 2>/dev/null | cut -d: -f2 | awk '{print $1}' || echo ""
}
current_ip() {
  ip -o -4 addr show dev "$INTERFACE" 2>/dev/null | awk '{print $4}' | head -n1
}
current_ssid() {
  $SUDO nmcli -t -f active,ssid dev wifi 2>/dev/null | awk -F: '$1=="yes"{print $2; exit}'
}

# --- Config ---
read_wifi_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then 
    log_msg "Config file not found: $CONFIG_FILE"; return 1; 
  fi
  
  mapfile -t lines < "$CONFIG_FILE"
  if [[ ${#lines[@]} -lt 2 ]]; then 
    log_msg "Config incomplete (need SSID + password)"; return 1; 
  fi
  
  local temp_ssid="${lines[0]}"
  local temp_password="${lines[1]}"
  
  temp_ssid=$(echo "$temp_ssid" | xargs)
  temp_password=$(echo "$temp_password" | xargs)
  
  if [[ -z "$temp_ssid" || -z "$temp_password" ]]; then 
    log_msg "SSID or password empty after parsing"; return 1; 
  fi
  
  SSID="$temp_ssid"
  PASSWORD="$temp_password"
  export SSID PASSWORD
  
  log_msg "Wi-Fi config loaded (SSID: '$SSID')"
  return 0
}

# --- Interface mgmt ---
check_wifi_interface() {
  if ! ip link show "$INTERFACE" >/dev/null 2>&1; then 
    log_msg "Interface $INTERFACE not found"; return 1; 
  fi
  
  log_msg "Ensuring $INTERFACE is up and managed..."
  $SUDO ip link set "$INTERFACE" up || true
  sleep 2
  
  $SUDO nmcli device set "$INTERFACE" managed yes || true
  sleep 2
  
  log_msg "Forcing Wi-Fi rescan..."
  $SUDO nmcli device wifi rescan ifname "$INTERFACE" || true
  sleep 3
  
  local st; st="$(nm_state)"; 
  log_msg "Interface $INTERFACE state: ${st:-unknown}"
  return 0
}

get_current_bssid() {
  local b; b=$(iwconfig "$INTERFACE" 2>/dev/null | awk '/Access Point:/ {print $6; exit}')
  b=$(echo "$b" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
  [[ "$b" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] && echo "$b" || echo ""
}

# FIXED: Enhanced BSSID discovery
discover_bssids_for_ssid() {
  local target_ssid="$1" 
  local now; now=$(date +%s)
  
  if (( now - LAST_SCAN_TIME < ROAMING_SCAN_INTERVAL )); then 
    return 0; 
  fi
  
  if [[ -z "$target_ssid" ]]; then
    log_msg "❌ discover_bssids_for_ssid called with empty SSID"
    return 1
  fi
  
  log_msg "🔍 Scanning for BSSIDs broadcasting SSID: '$target_ssid'"

  DISCOVERED_BSSIDS=(); BSSID_SIGNALS=()

  log_msg "🔄 Forcing fresh Wi-Fi scan..."
  $SUDO nmcli device wifi rescan ifname "$INTERFACE" >/dev/null 2>&1 || true
  sleep 5

  log_msg "📋 Listing available networks..."
  local scan_output
  scan_output=$($SUDO nmcli -t -f BSSID,SSID,SIGNAL device wifi list ifname "$INTERFACE" 2>/dev/null || echo "")
  
  if [[ -z "$scan_output" ]]; then
    log_msg "❌ nmcli wifi list returned no results"
    return 1
  fi

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    
    if [[ "$line" =~ ^([0-9A-Fa-f]{2}\\:[0-9A-Fa-f]{2}\\:[0-9A-Fa-f]{2}\\:[0-9A-Fa-f]{2}\\:[0-9A-Fa-f]{2}\\:[0-9A-Fa-f]{2}):([^:]*):([0-9]+)$ ]]; then
      local bssid_escaped="${BASH_REMATCH[1]}"
      local ssid="${BASH_REMATCH[2]}"
      local signal="${BASH_REMATCH[3]}"
      
      local bssid="${bssid_escaped//\\:/:}"
      [[ -n "$ssid" ]] || continue
      
      if [[ "$ssid" == "$target_ssid" ]]; then
        local signal_dbm=$(( signal / 2 - 100 ))
        if (( signal_dbm >= MIN_SIGNAL_THRESHOLD )); then
          DISCOVERED_BSSIDS["$bssid"]="$ssid"
          BSSID_SIGNALS["$bssid"]="$signal_dbm"
          log_msg "🎯 Found matching BSSID: $bssid (Signal: ${signal_dbm} dBm, ${signal}%)"
        fi
      fi
    fi
  done <<< "$scan_output"

  LAST_SCAN_TIME="$now"
  local count=${#DISCOVERED_BSSIDS[@]}

  if (( count == 0 )); then
    log_msg "❌ No BSSIDs found for SSID: '$target_ssid'"
    return 1
  else
    log_msg "✅ Found $count BSSID(s) for '$target_ssid'"
    for b in "${!DISCOVERED_BSSIDS[@]}"; do
      log_msg "   Available: $b (${BSSID_SIGNALS[$b]} dBm)"
    done
  fi
  return 0
}

# Remove existing NM connections for this SSID
prune_same_ssid_profiles() {
  local ssid="$1"
  $SUDO nmcli -t -f NAME,TYPE con show 2>/dev/null \
    | awk -F: '$2=="wifi"{print $1}' \
    | while read -r c; do
        local cs
        cs="$($SUDO nmcli -t -f 802-11-wireless.ssid con show "$c" 2>/dev/null | cut -d: -f2 || true)"
        [[ "$cs" == "$ssid" ]] && $SUDO nmcli con delete "$c" 2>/dev/null || true
      done
}

# FIXED: Enhanced BSSID connection with better verification
connect_locked_bssid() {
  local bssid="$1" 
  local ssid="$2" 
  local psk="$3"

  if [[ -z "$bssid" || -z "$ssid" || -z "$psk" ]]; then
    log_msg "❌ connect_locked_bssid: missing parameter(s)"
    return 1
  fi

  log_msg "🔗 Attempting BSSID-locked connection to $bssid (SSID: '$ssid')"

  # Clean slate
  prune_same_ssid_profiles "$ssid"
  $SUDO nmcli dev disconnect "$INTERFACE" 2>/dev/null || true
  sleep 3

  # First try: Direct nmcli with BSSID
  local OUT
  if OUT="$($SUDO nmcli --wait 45 device wifi connect "$ssid" password "$psk" ifname "$INTERFACE" bssid "$bssid" 2>&1)"; then
    log_msg "✅ nmcli BSSID connect reported success: ${OUT}"
    sleep 5
    
    # Verify the actual BSSID
    local actual_bssid
    actual_bssid="$(get_current_bssid)"
    
    if [[ "$actual_bssid" == "${bssid,,}" ]]; then
      log_msg "✅ BSSID verification successful: connected to $actual_bssid"
      return 0
    else
      log_msg "❌ BSSID mismatch: connected to ${actual_bssid:-unknown}, expected ${bssid,,}"
    fi
  else
    log_msg "❌ nmcli BSSID connect failed: ${OUT}"
  fi

  # Second try: Create temporary profile with BSSID lock
  log_msg "🔄 Trying profile-based BSSID connection..."
  local profile_name="bssid-lock-$$"
  
  if $SUDO nmcli connection add \
      type wifi \
      con-name "$profile_name" \
      ifname "$INTERFACE" \
      ssid "$ssid" \
      802-11-wireless.bssid "$bssid" \
      wifi-sec.key-mgmt wpa-psk \
      wifi-sec.psk "$psk" \
      ipv4.method auto \
      ipv6.method ignore \
      connection.autoconnect no >/dev/null 2>&1; then
    
    log_msg "✅ Created BSSID-locked profile"
    
    if $SUDO nmcli --wait 45 connection up "$profile_name" >/dev/null 2>&1; then
      sleep 5
      local actual_bssid
      actual_bssid="$(get_current_bssid)"
      
      # Clean up profile immediately
      $SUDO nmcli connection delete "$profile_name" 2>/dev/null || true
      
      if [[ "$actual_bssid" == "${bssid,,}" ]]; then
        log_msg "✅ Profile-based BSSID connection successful: $actual_bssid"
        return 0
      else
        log_msg "❌ Profile-based BSSID mismatch: ${actual_bssid:-unknown} vs ${bssid,,}"
      fi
    else
      log_msg "❌ Profile activation failed"
      $SUDO nmcli connection delete "$profile_name" 2>/dev/null || true
    fi
  else
    log_msg "❌ Failed to create BSSID-locked profile"
  fi

  # Third try: iw dev connect (low-level)
  log_msg "🔄 Trying iw dev connect as last resort..."
  $SUDO iw dev "$INTERFACE" disconnect >/dev/null 2>&1 || true
  sleep 2
  
  if $SUDO iw dev "$INTERFACE" connect "$ssid" "$bssid" >/dev/null 2>&1; then
    log_msg "✅ iw dev connect initiated"
    sleep 5
    
    # For iw, we need to handle WPA separately
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
      sleep 8
      
      # Request DHCP
      $SUDO dhclient "$INTERFACE" >/dev/null 2>&1 || true
      sleep 3
      
      local actual_bssid
      actual_bssid="$(get_current_bssid)"
      
      # Clean up
      rm -f "$wpa_conf"
      pkill -f "wpa_supplicant.*$INTERFACE" || true
      
      if [[ "$actual_bssid" == "${bssid,,}" ]]; then
        log_msg "✅ iw+wpa_supplicant BSSID connection successful: $actual_bssid"
        return 0
      else
        log_msg "❌ iw+wpa BSSID mismatch: ${actual_bssid:-unknown}"
      fi
    fi
    
    rm -f "$wpa_conf"
  fi

  log_msg "❌ All BSSID connection methods failed"
  return 1
}

# FIXED: Enhanced traffic generation with persistent stats
generate_realistic_traffic() {
  if [[ "$ENABLE_INTEGRATED_TRAFFIC" != "true" ]]; then return 0; fi

  local st ip ss
  st="$(nm_state)"; ip="$(current_ip)"; ss="$(current_ssid)"
  if [[ "$st" != "100" || -z "$ip" || "$ss" != "$SSID" ]]; then
    log_msg "⚠️ Traffic suppressed: link not healthy"
    return 1
  fi

  log_msg "🚀 Starting realistic traffic generation (intensity: $TRAFFIC_INTENSITY)..."

  if ! test_basic_connectivity; then
    log_msg "❌ Basic connectivity failed; skipping traffic"
    return 1
  fi

  # Download traffic
  local url="${DOWNLOAD_URLS[$((RANDOM % ${#DOWNLOAD_URLS[@]}))]}"
  local tmp_file="/tmp/test_download_$$"
  
  log_msg "📥 Downloading from: $(basename "$url")"
  if timeout 60 curl --interface "$INTERFACE" -fsSL --max-time 45 -o "$tmp_file" "$url" 2>/dev/null; then
    if [[ -f "$tmp_file" ]]; then
      local bytes
      bytes=$(stat -c%s "$tmp_file" 2>/dev/null || stat -f%z "$tmp_file" 2>/dev/null || echo 0)
      TOTAL_DOWN=$((TOTAL_DOWN + bytes))
      log_msg "✅ Downloaded $bytes bytes (Total: ${TOTAL_DOWN})"
      rm -f "$tmp_file"
    fi
  else
    log_msg "❌ Download failed"
  fi

  # Upload traffic
  local upload_url="https://httpbin.org/post"
  local upload_size=102400  # 100KB
  
  log_msg "📤 Uploading test data..."
  if timeout 30 dd if=/dev/zero bs=1024 count=100 2>/dev/null | \
     curl --interface "$INTERFACE" -fsSL --max-time 25 -X POST -o /dev/null "$upload_url" --data-binary @- 2>/dev/null; then
    TOTAL_UP=$((TOTAL_UP + upload_size))
    log_msg "✅ Uploaded $upload_size bytes (Total: ${TOTAL_UP})"
  else
    log_msg "❌ Upload failed"
  fi

  # Ping traffic
  local ping_target="${PING_TARGETS[$((RANDOM % ${#PING_TARGETS[@]}))]}"
  if timeout 30 ping -I "$INTERFACE" -c "$PING_COUNT" -i 0.5 "$ping_target" >/dev/null 2>&1; then
    log_msg "✅ Ping traffic successful ($ping_target)"
  else
    log_msg "❌ Ping traffic failed ($ping_target)"
  fi

  # Save stats persistently
  save_stats

  log_msg "✅ Traffic generation completed (Down: ${TOTAL_DOWN}B, Up: ${TOTAL_UP}B)"
}

select_roaming_target() {
  local cur="$1" best="" best_sig=-100
  
  for b in "${!DISCOVERED_BSSIDS[@]}"; do
    [[ "$b" == "$cur" ]] && continue
    local s="${BSSID_SIGNALS[$b]}"
    
    (( s > MIN_SIGNAL_THRESHOLD )) || continue
    
    # For demo: roam to any available BSSID that's stronger than current
    if (( s > best_sig )); then 
      best_sig=$s
      best="$b"
    fi
  done
  
  [[ -n "$best" ]] && echo "$best" || echo ""
}

perform_roaming() {
  local target_bssid="$1" 
  local target_ssid="$2" 
  local target_password="$3"
  
  log_msg "🔄 Initiating roaming to BSSID: $target_bssid (SSID: $target_ssid)"

  # Fresh scan to ensure target is still available
  $SUDO nmcli device wifi rescan ifname "$INTERFACE" >/dev/null 2>&1
  sleep 3

  # Verify target BSSID is visible
  if ! $SUDO nmcli device wifi list ifname "$INTERFACE" | grep -qi "$target_bssid"; then
    log_msg "❌ Target BSSID $target_bssid no longer visible"
    return 1
  fi

  if connect_locked_bssid "$target_bssid" "$target_ssid" "$target_password"; then
    log_msg "✅ Roaming successful!"
    CURRENT_BSSID="$target_bssid"
    LAST_ROAM_TIME="$(date +%s)"
    return 0
  else
    log_msg "❌ Roaming failed"
    return 1
  fi
}

# FIXED: Connection function with proper fallback
connect_to_wifi_with_roaming() {
  local local_ssid="$1" 
  local local_password="$2"
  
  if [[ -z "$local_ssid" || -z "$local_password" ]]; then
    log_msg "❌ connect_to_wifi_with_roaming called with empty parameters"
    return 1
  fi
  
  log_msg "🔗 Connecting to Wi-Fi (roaming enabled=${ROAMING_ENABLED}) for SSID '$local_ssid'"

  # Discover candidates
  if discover_bssids_for_ssid "$local_ssid"; then
    # Try BSSID-locked connection to strongest signal
    local target_bssid="" best_signal=-100
    for b in "${!DISCOVERED_BSSIDS[@]}"; do
      local s="${BSSID_SIGNALS[$b]}"
      if [[ -n "$s" && "$s" -gt "$best_signal" ]]; then
        best_signal="$s"
        target_bssid="$b"
      fi
    done

    if [[ -n "$target_bssid" ]]; then
      log_msg "🎯 Attempting connection to strongest BSSID $target_bssid ($best_signal dBm)"
      if connect_locked_bssid "$target_bssid" "$local_ssid" "$local_password"; then
        log_msg "✅ BSSID-locked connection successful"
        return 0
      else
        log_msg "⚠️ BSSID-locked connection failed, falling back to regular connect"
      fi
    fi
  fi

  # Fallback to regular connection
  log_msg "🔄 Attempting fallback connection to SSID '$local_ssid'"
  $SUDO nmcli dev disconnect "$INTERFACE" 2>/dev/null || true
  sleep 2
  
  local OUT
  if OUT="$($SUDO nmcli --wait 45 device wifi connect "${local_ssid}" password "${local_password}" ifname "$INTERFACE" 2>&1)"; then
    log_msg "✅ Fallback connection successful: ${OUT}"
  else
    log_msg "❌ Fallback connection failed: ${OUT}"
    return 1
  fi

  # Wait for IP
  log_msg "⏳ Waiting for IP address..."
  for i in {1..20}; do
    local ip
    ip="$(ip addr show "$INTERFACE" | awk '/inet /{print $2; exit}')"
    if [[ -n "$ip" ]]; then
      log_msg "✅ IP address acquired: $ip"
      break
    fi
    sleep 2
  done

  # Record current BSSID
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
  if [[ "$ROAMING_ENABLED" != "true" ]]; then
    return 0
  fi

  # Always keep candidate list fresh
  discover_bssids_for_ssid "$SSID" || return 0

  if should_perform_roaming; then
    log_msg "⏰ Roaming interval reached, evaluating roaming opportunity..."
    CURRENT_BSSID="$(get_current_bssid)"

    local target
    target="$(select_roaming_target "$CURRENT_BSSID")"
    if [[ -n "$target" ]]; then
      local target_signal="${BSSID_SIGNALS[$target]}"
      local current_signal="${BSSID_SIGNALS[$CURRENT_BSSID]:-unknown}"
      log_msg "🔄 Roaming candidate: $target (${target_signal}dBm) vs current $CURRENT_BSSID (${current_signal}dBm)"
      
      if perform_roaming "$target" "$SSID" "$PASSWORD"; then
        log_msg "✅ Roaming completed successfully"
      else
        log_msg "❌ Roaming attempt failed - staying on current BSSID"
      fi
      sleep 5
    else
      log_msg "📍 No suitable roaming target found; staying on $CURRENT_BSSID"
    fi
  fi
}

test_basic_connectivity() {
  log_msg "🧪 Testing connectivity on $INTERFACE..."
  local success_count=0

  # DNS test
  if getent hosts google.com >/dev/null 2>&1; then
    log_msg "✅ DNS resolution OK"
    ((success_count++))
  fi

  # HTTPS test
  if timeout 15 curl --interface "$INTERFACE" --max-time 10 -fsSL -o /dev/null "https://www.google.com" 2>/dev/null; then
    log_msg "✅ HTTPS connectivity test passed"
    ((success_count++))
  fi

  # Ping test
  if timeout 10 ping -I "$INTERFACE" -c 3 -W 2 8.8.8.8 >/dev/null 2>&1; then
    log_msg "✅ Ping connectivity test passed"
    ((success_count++))
  fi

  log_msg "📊 Connectivity: $success_count/3 tests passed"
  return $([[ $success_count -gt 0 ]] && echo 0 || echo 1)
}

# FIXED: Main loop with enhanced error handling and proper identity management
main_loop() {
    log_msg "🚀 Starting enhanced good client with persistent throughput tracking"
    
    # Enhanced setup with proper identity management
    enhanced_good_client_setup
    
    local last_cfg=0 last_traffic=0
    
    while true; do
        local now=$(date +%s)
        
        # Re-read config periodically
        if (( now - last_cfg > 600 )); then
            if read_wifi_config; then
                log_msg "✅ Config refreshed (SSID: '$SSID')"
                last_cfg=$now
            else
                log_msg "⚠️ Config read failed, using previous values (SSID: '${SSID:-unset}')"
            fi
        fi
        
        # Validate config
        if [[ -z "$SSID" || -z "$PASSWORD" ]]; then
            log_msg "❌ No valid SSID/password configuration, retrying in $REFRESH_INTERVAL seconds"
            sleep "$REFRESH_INTERVAL"
            continue
        fi
        
        # Check interface
        if ! check_wifi_interface; then 
            log_msg "❌ Interface check failed, retrying..."
            sleep "$REFRESH_INTERVAL"; 
            continue; 
        fi

        # Check connection health
        local st ip ss
        st="$(nm_state)"
        ip="$(current_ip)"
        ss="$(current_ssid)"
        
        if [[ "$st" == "100" && -n "$ip" && "$ss" == "$SSID" ]]; then
            log_msg "✅ Connection healthy: SSID='$ss', IP=$ip"
        else
            log_msg "⚠️ Connection issue: state=${st:-?} ip=${ip:-none} current='${ss:-none}' expected='$SSID'"
            
            if [[ -n "$SSID" && -n "$PASSWORD" ]]; then
                log_msg "🔄 Attempting to (re)connect with SSID='$SSID'"
                if connect_to_wifi_with_roaming "$SSID" "$PASSWORD"; then
                    log_msg "✅ Wi-Fi connection (re)established"
                    sleep 5
                else
                    log_msg "❌ Reconnect failed; retrying later"
                    sleep "$REFRESH_INTERVAL"
                    continue
                fi
            else
                log_msg "❌ Cannot reconnect: missing SSID or password"
                sleep "$REFRESH_INTERVAL"
                continue
            fi
        fi

        # Roaming and traffic (only if connected)
        manage_roaming
        if (( now - last_traffic > 30 )); then 
            generate_realistic_traffic && last_traffic=$now
        fi

        # Status update with identity verification
        CURRENT_BSSID=$(get_current_bssid)
        if [[ -n "$CURRENT_BSSID" ]]; then
            log_msg "📍 Current: BSSID $CURRENT_BSSID (${BSSID_SIGNALS[$CURRENT_BSSID]:-unknown} dBm) | Available BSSIDs: ${#DISCOVERED_BSSIDS[@]} | Stats: D=${TOTAL_DOWN}B U=${TOTAL_UP}B"
        fi

        # Periodic identity verification (every 5 minutes)
        if (( now % 300 == 0 )); then
            verify_device_identity "$INTERFACE" "$HOSTNAME"
        fi

        log_msg "✅ Good client operating normally"
        sleep "$REFRESH_INTERVAL"
    done
}

# Enhanced setup function (add this before main_loop)
enhanced_good_client_setup() {
    log_msg "🚀 Starting enhanced good client with PROPER identity management"
    
    # Set our identity immediately and persistently
    set_device_hostname "$HOSTNAME" "$INTERFACE"
    configure_dhcp_hostname "$HOSTNAME" "$INTERFACE"
    
    # Verify our identity
    verify_device_identity "$INTERFACE" "$HOSTNAME"
    
    log_msg "Interface: $INTERFACE | Hostname: $HOSTNAME"
    log_msg "Roaming: ${ROAMING_ENABLED} (interval ${ROAMING_INTERVAL}s; scan ${ROAMING_SCAN_INTERVAL}s; min ${MIN_SIGNAL_THRESHOLD}dBm)"
    log_msg "Persistent stats file: $STATS_FILE"
}

cleanup_and_exit() {
  log_msg "🧹 Cleaning up good client..."
  save_stats
  $SUDO nmcli device disconnect "$INTERFACE" 2>/dev/null || true
  log_msg "✅ Stopped (final stats saved: Down=${TOTAL_DOWN}B, Up=${TOTAL_UP}B)"
  exit 0
}
trap cleanup_and_exit SIGTERM SIGINT

# --- Init ---
mkdir -p "$LOG_DIR" 2>/dev/null || true
log_msg "🚀 Enhanced Wi-Fi Good Client Starting..."
log_msg "Interface: $INTERFACE | Hostname: $HOSTNAME"
log_msg "Roaming: ${ROAMING_ENABLED} (interval ${ROAMING_INTERVAL}s; scan ${ROAMING_SCAN_INTERVAL}s; min ${MIN_SIGNAL_THRESHOLD}dBm)"
log_msg "Persistent stats file: $STATS_FILE"

# Initial config read
if ! read_wifi_config; then
  log_msg "❌ Failed to read initial configuration"
fi

# Start main loop
main_loop