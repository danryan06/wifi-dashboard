#!/bin/bash
# Installation script for Wi-Fi Dashboard fixes
# Addresses roaming issues, bad client authentication, and persistent throughput

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}🔧 Installing Wi-Fi Dashboard Fixes${NC}"
echo "=================================="
echo "This will fix:"
echo "1. ✅ Roaming BSSID locking issues"
echo "2. ✅ Bad client authentication attempts"
echo "3. ✅ Persistent throughput tracking"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}❌ This script must be run as root (use sudo)${NC}"
    exit 1
fi

PI_USER=$(getent passwd 1000 | cut -d: -f1 2>/dev/null || echo "pi")
DASHBOARD_DIR="/home/$PI_USER/wifi_test_dashboard"

if [[ ! -d "$DASHBOARD_DIR" ]]; then
    echo -e "${RED}❌ Dashboard directory not found: $DASHBOARD_DIR${NC}"
    echo "Please run the main installer first"
    exit 1
fi

echo -e "${YELLOW}📋 Backing up existing files...${NC}"

# Backup existing files
backup_dir="$DASHBOARD_DIR/backups/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$backup_dir"

for file in app.py scripts/traffic/connect_and_curl.sh scripts/traffic/fail_auth_loop.sh; do
    if [[ -f "$DASHBOARD_DIR/$file" ]]; then
        cp "$DASHBOARD_DIR/$file" "$backup_dir/"
        echo "✓ Backed up $file"
    fi
done

echo -e "${BLUE}🔄 Installing fixed files...${NC}"

# Install fixed Wi-Fi Good Client
echo "📥 Installing enhanced Wi-Fi Good Client..."
cat > "$DASHBOARD_DIR/scripts/traffic/connect_and_curl.sh" << 'EOF'
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

# FIXED: Main loop with enhanced error handling
main_loop() {
  log_msg "🚀 Starting enhanced good client with persistent throughput tracking"
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

    # Status update
    CURRENT_BSSID=$(get_current_bssid)
    if [[ -n "$CURRENT_BSSID" ]]; then
      log_msg "📍 Current: BSSID $CURRENT_BSSID (${BSSID_SIGNALS[$CURRENT_BSSID]:-unknown} dBm) | Available BSSIDs: ${#DISCOVERED_BSSIDS[@]} | Stats: D=${TOTAL_DOWN}B U=${TOTAL_UP}B"
    fi

    log_msg "✅ Good client operating normally"
    sleep "$REFRESH_INTERVAL"
  done
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
EOF

# Install fixed Wi-Fi Bad Client
echo "📥 Installing enhanced Wi-Fi Bad Client..."
cat > "$DASHBOARD_DIR/scripts/traffic/fail_auth_loop.sh" << 'EOF_BAD'
#!/usr/bin/env bash
set -euo pipefail

# Wi-Fi Bad Client - FIXED to Actually Attempt Associations
# Generates real authentication failures that will show up in Mist logs

INTERFACE="${INTERFACE:-wlan1}"
HOSTNAME="CNXNMist-WiFiBad"
LOG_FILE="/home/pi/wifi_test_dashboard/logs/wifi-bad.log"
CONFIG_FILE="/home/pi/wifi_test_dashboard/configs/ssid.conf"
SETTINGS="/home/pi/wifi_test_dashboard/configs/settings.conf"

# Ensure system hostname is set correctly
if command -v hostnamectl >/dev/null 2>&1; then
  sudo hostnamectl set-hostname "$HOSTNAME" 2>/dev/null || true
fi

# Keep service alive on errors - don't exit on failures
set +e

# --- Privilege helper for nmcli ---
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  SUDO="sudo"
else
  SUDO=""
fi

log_msg() {
    local msg="[$(date '+%F %T')] WIFI-BAD: $1"
    echo "$msg" | tee -a "$LOG_FILE"
}

# Create log directory
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

# Load settings
[[ -f "$SETTINGS" ]] && source "$SETTINGS" || true

INTERFACE="${WIFI_BAD_INTERFACE:-$INTERFACE}"
HOSTNAME="${WIFI_BAD_HOSTNAME:-$HOSTNAME}"
REFRESH_INTERVAL="${WIFI_BAD_REFRESH_INTERVAL:-45}"
CONNECTION_TIMEOUT="${WIFI_CONNECTION_TIMEOUT:-20}"

# Wrong passwords to cycle through
WRONG_PASSWORDS=(
    "wrongpassword123"
    "incorrectpwd"
    "badpassword"
    "admin123"
    "guest123"
    "password123"
    "letmein"
    "12345678"
    "qwerty"
    "hackme"
)

# Read Wi-Fi SSID (but use wrong password)
read_wifi_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_msg "✗ Config file not found: $CONFIG_FILE"
        return 1
    fi

    local lines
    mapfile -t lines < "$CONFIG_FILE"
    if [[ ${#lines[@]} -lt 1 ]]; then
        log_msg "✗ Config file incomplete (need at least SSID)"
        return 1
    fi

    SSID="${lines[0]}"
    # Trim whitespace
    SSID=$(echo "$SSID" | xargs)
    
    if [[ -z "$SSID" ]]; then
        log_msg "✗ SSID is empty after trimming"
        return 1
    fi

    log_msg "✓ Target SSID loaded: '$SSID'"
    return 0
}

# Check interface with enhanced validation
check_wifi_interface() {
    if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
        log_msg "✗ Wi-Fi interface $INTERFACE not found"
        return 1
    fi

    # Force interface up
    log_msg "Ensuring $INTERFACE is up..."
    $SUDO ip link set "$INTERFACE" up 2>/dev/null || true
    sleep 2

    # Ensure NetworkManager manages interface
    log_msg "Setting $INTERFACE to managed mode..."
    $SUDO nmcli device set "$INTERFACE" managed yes 2>/dev/null || true
    sleep 3

    # Check if interface is now managed
    local managed_state
    managed_state=$($SUDO nmcli device show "$INTERFACE" 2>/dev/null | grep "GENERAL.STATE" | awk '{print $2}' || echo "unknown")
    log_msg "Interface $INTERFACE state: $managed_state"

    return 0
}

# Enhanced SSID scanning
scan_for_ssid() {
    local target_ssid="$1"
    log_msg "🔍 Scanning for target SSID: '$target_ssid'"
    
    # Force fresh scan
    log_msg "Triggering Wi-Fi rescan..."
    $SUDO nmcli device wifi rescan ifname "$INTERFACE" 2>/dev/null || true
    sleep 5
    
    # Check if SSID is visible
    local scan_results
    scan_results=$($SUDO nmcli device wifi list ifname "$INTERFACE" 2>/dev/null || echo "")
    
    if [[ -z "$scan_results" ]]; then
        log_msg "✗ No scan results returned"
        return 1
    fi
    
    # Debug: Show first few networks found
    local network_count
    network_count=$(echo "$scan_results" | wc -l)
    log_msg "📋 Scan found $network_count networks"
    
    if echo "$scan_results" | grep -F "$target_ssid" >/dev/null; then
        log_msg "✓ Target SSID '$target_ssid' is visible in scan results"
        return 0
    else
        log_msg "✗ Target SSID '$target_ssid' not found in scan results"
        # Debug: Show what SSIDs we did find (first 5)
        log_msg "Available SSIDs:"
        echo "$scan_results" | awk 'NR>1 {print $2}' | head -5 | while read -r found_ssid; do
            [[ -n "$found_ssid" ]] && log_msg "  - '$found_ssid'"
        done
        return 1
    fi
}

# Force disconnect with cleanup
force_disconnect() {
    log_msg "🔌 Ensuring $INTERFACE is disconnected and clean..."
    
    # Disconnect device
    $SUDO nmcli device disconnect "$INTERFACE" 2>/dev/null || true
    
    # Kill any existing wpa_supplicant for this interface
    pkill -f "wpa_supplicant.*$INTERFACE" 2>/dev/null || true
    
    # Clean up any temporary connection profiles
    local temp_connections
    temp_connections=$($SUDO nmcli -t -f NAME connection show 2>/dev/null | grep -E "^bad-client-|^wifi-bad-|^temp-bad-" || true)
    
    if [[ -n "$temp_connections" ]]; then
        echo "$temp_connections" | while read -r conn; do
            [[ -n "$conn" ]] && $SUDO nmcli connection delete "$conn" 2>/dev/null || true
        done
        log_msg "🧹 Cleaned up temporary connection profiles"
    fi
    
    sleep 2
}

# FIXED: Enhanced bad connection attempt that actually tries to associate
attempt_bad_connection() {
    local ssid="$1"
    local wrong_password="$2"
    local connection_name="bad-client-$(date +%s)-$RANDOM"

    log_msg "🔓 Attempting authentication with wrong password: '***${wrong_password: -3}' for SSID '$ssid'"

    # Ensure clean state
    force_disconnect

    # Method 1: Try nmcli connection profile (enhanced)
    log_msg "📝 Creating connection profile with wrong credentials..."
    
    local profile_created=false
    if $SUDO nmcli connection add \
        type wifi \
        con-name "$connection_name" \
        ifname "$INTERFACE" \
        ssid "$ssid" \
        wifi-sec.key-mgmt wpa-psk \
        wifi-sec.psk "$wrong_password" \
        ipv4.method manual \
        ipv4.addresses "192.168.255.1/24" \
        ipv6.method ignore \
        connection.autoconnect no 2>/dev/null; then
        
        profile_created=true
        log_msg "✓ Created connection profile with wrong password"
        
        # Attempt to activate profile (this should trigger auth failure)
        log_msg "🔌 Attempting activation (expecting auth failure)..."
        if timeout "$CONNECTION_TIMEOUT" $SUDO nmcli connection up "$connection_name" 2>&1; then
            log_msg "🚨 UNEXPECTED: Connection succeeded with wrong password!"
            log_msg "⚠️ This indicates a security issue with the target network"
        else
            log_msg "✓ Authentication failed as expected (profile method)"
        fi
        
        # Clean up profile
        $SUDO nmcli connection delete "$connection_name" 2>/dev/null || true
    else
        log_msg "✗ Failed to create connection profile"
    fi

    # Method 2: Direct nmcli device wifi connect (if profile method failed)
    if [[ "$profile_created" != "true" ]]; then
        log_msg "🔄 Trying direct nmcli device wifi connect..."
        
        local connect_output
        if connect_output=$(timeout "$CONNECTION_TIMEOUT" $SUDO nmcli device wifi connect "$ssid" password "$wrong_password" ifname "$INTERFACE" 2>&1); then
            log_msg "🚨 UNEXPECTED: Direct connect succeeded with wrong password!"
            log_msg "Output: $connect_output"
        else
            log_msg "✓ Direct connect authentication failed as expected"
            log_msg "Error output: $connect_output"
        fi
    fi

    # Method 3: Low-level wpa_supplicant attempt for maximum visibility
    log_msg "🔧 Attempting low-level wpa_supplicant connection..."
    
    local wpa_conf="/tmp/bad_client_$$.conf"
    cat > "$wpa_conf" << EOF
ctrl_interface=/run/wpa_supplicant
ctrl_interface_group=0
ap_scan=1
fast_reauth=1

network={
    ssid="$ssid"
    psk="$wrong_password"
    key_mgmt=WPA-PSK
    scan_ssid=1
    priority=1
}
EOF

    # Kill any existing wpa_supplicant
    pkill -f "wpa_supplicant.*$INTERFACE" 2>/dev/null || true
    sleep 1

    # Start wpa_supplicant with verbose logging
    if timeout "$CONNECTION_TIMEOUT" $SUDO wpa_supplicant -i "$INTERFACE" -c "$wpa_conf" -D nl80211 -d 2>/dev/null; then
        log_msg "🚨 UNEXPECTED: wpa_supplicant succeeded with wrong password!"
    else
        log_msg "✓ wpa_supplicant authentication failed as expected"
    fi

    # Cleanup
    pkill -f "wpa_supplicant.*$INTERFACE" 2>/dev/null || true
    rm -f "$wpa_conf"
    
    # Final cleanup
    force_disconnect
    
    log_msg "✅ Authentication failure cycle completed"
    return 0
}

# Generate additional probe traffic to increase visibility
generate_probe_traffic() {
    log_msg "📡 Generating probe request traffic..."
    
    # Force multiple scans to generate probe requests
    for i in {1..3}; do
        $SUDO nmcli device wifi rescan ifname "$INTERFACE" 2>/dev/null || true
        sleep 2
    done
    
    # List networks to generate more probe activity
    local network_count
    network_count=$($SUDO nmcli device wifi list ifname "$INTERFACE" 2>/dev/null | wc -l || echo "0")
    log_msg "📊 Probe scan cycle $i completed: $network_count networks visible"
    
    # Add some random delay to make traffic more realistic
    sleep $((2 + RANDOM % 3))
}

# Enhanced connection attempts with multiple wrong passwords
attempt_multiple_failures() {
    local ssid="$1"
    local attempts="${2:-3}"
    
    log_msg "🔥 Starting multiple authentication failure attempts for '$ssid'"
    
    for ((i=1; i<=attempts; i++)); do
        local wrong_password="${WRONG_PASSWORDS[$((RANDOM % ${#WRONG_PASSWORDS[@]}))]}"
        log_msg "📢 Attempt $i/$attempts with password variation"
        
        attempt_bad_connection "$ssid" "$wrong_password"
        
        # Add realistic delay between attempts
        if [[ $i -lt $attempts ]]; then
            local delay=$((5 + RANDOM % 10))
            log_msg "⏱️ Waiting ${delay}s before next attempt..."
            sleep "$delay"
        fi
    done
    
    log_msg "✅ Multiple authentication failure cycle completed"
}

# Main loop with enhanced failure generation
main_loop() {
    log_msg "🚀 Starting Wi-Fi bad client for AGGRESSIVE authentication failure testing"
    log_msg "Interface: $INTERFACE, Hostname: $HOSTNAME"
    log_msg "Purpose: Generate visible authentication failures in Mist dashboard"

    local cycle_count=0
    local last_config_check=0
    local password_rotation=0

    while true; do
        local current_time
        current_time=$(date +%s)
        cycle_count=$((cycle_count + 1))

        log_msg "🔴 === Bad Client Cycle $cycle_count ==="

        # Re-read config periodically
        if [[ $((current_time - last_config_check)) -gt 600 ]]; then
            if read_wifi_config; then
                last_config_check=$current_time
                log_msg "✅ Config refreshed"
            else
                log_msg "⚠️ Config read failed, using previous SSID: '${SSID:-TestNetwork}'"
                SSID="${SSID:-TestNetwork}"
            fi
        fi

        # Check interface health
        if ! check_wifi_interface; then
            log_msg "✗ Wi-Fi interface check failed, retrying in $REFRESH_INTERVAL seconds"
            sleep "$REFRESH_INTERVAL"
            continue
        fi

        # Generate initial probe traffic
        generate_probe_traffic

        # Scan for target SSID
        if scan_for_ssid "$SSID"; then
            log_msg "🎯 Target SSID '$SSID' is available for authentication failure testing"
            
            # Determine number of attempts for this cycle (vary for realism)
            local attempt_count=$((2 + RANDOM % 3))  # 2-4 attempts
            log_msg "📋 Planning $attempt_count authentication failure attempts"
            
            # Execute multiple failure attempts
            attempt_multiple_failures "$SSID" "$attempt_count"
            
        else
            log_msg "❌ Target SSID '$SSID' not visible"
            log_msg "🔍 Performing extended scan for SSID discovery..."
            
            # Extended scanning when SSID not found
            for scan_retry in {1..3}; do
                log_msg "🔄 Extended scan attempt $scan_retry/3..."
                generate_probe_traffic
                if scan_for_ssid "$SSID"; then
                    log_msg "✅ Found SSID on retry $scan_retry"
                    break
                fi
                sleep 5
            done
        fi

        # Additional probe traffic at end of cycle
        generate_probe_traffic

        # Ensure complete disconnect and cleanup
        force_disconnect

        # Vary the cycle timing slightly for more realistic behavior
        local actual_interval=$((REFRESH_INTERVAL + RANDOM % 15 - 7))
        log_msg "🔴 Bad client cycle $cycle_count completed, waiting ${actual_interval}s"
        log_msg "📊 Summary: Attempted auth failures against '$SSID'"
        
        sleep "$actual_interval"
    done
}

# Enhanced cleanup
cleanup_and_exit() {
    log_msg "🧹 Cleaning up Wi-Fi bad client simulation..."
    
    # Kill any background processes
    pkill -f "wpa_supplicant.*$INTERFACE" 2>/dev/null || true
    
    # Force disconnect and cleanup
    force_disconnect
    
    # Remove any leftover temp files
    rm -f /tmp/bad_client_*.conf
    
    log_msg "✅ Wi-Fi bad client simulation stopped cleanly"
    exit 0
}

trap cleanup_and_exit SIGTERM SIGINT EXIT

# Initialize
log_msg "🔴 Wi-Fi Bad Client Starting (ENHANCED FOR MIST VISIBILITY)..."
log_msg "Purpose: Generate REAL authentication failures visible in Mist dashboard"
log_msg "Target interface: $INTERFACE"
log_msg "Expected hostname: $HOSTNAME"

# Initial config read
if ! read_wifi_config; then
    log_msg "✗ Failed to read config, using default test SSID"
    SSID="TestNetwork"
fi

# Initial interface setup
check_wifi_interface || true
force_disconnect || true

log_msg "🎯 Target SSID for auth failures: '$SSID'"
log_msg "🔥 Starting aggressive authentication failure generation..."

# Start main loop
main_loop
EOF_BAD

# Set permissions
chmod +x "$DASHBOARD_DIR/scripts/traffic/connect_and_curl.sh"
chmod +x "$DASHBOARD_DIR/scripts/traffic/fail_auth_loop.sh"
chown -R "$PI_USER:$PI_USER" "$DASHBOARD_DIR/scripts/"

echo -e "${GREEN}✅ Fixed scripts installed${NC}"

echo -e "${BLUE}🔄 Installing jq for JSON parsing...${NC}"
apt-get update -qq
apt-get install -y jq

echo -e "${BLUE}🔄 Restarting services...${NC}"

# Restart services to pick up fixes
services=("wifi-good" "wifi-bad")
for service in "${services[@]}"; do
    echo "🔄 Restarting $service..."
    systemctl restart "$service.service" || echo "⚠️ Failed to restart $service"
    sleep 3
done

# Restart dashboard to pick up Flask fixes (will need to manually replace the file)
echo -e "${YELLOW}⚠️ MANUAL STEP REQUIRED:${NC}"
echo "The Flask app.py needs to be updated manually with the persistent throughput fixes."
echo "Please replace the content of $DASHBOARD_DIR/app.py with the fixed version provided."
echo ""

echo -e "${GREEN}✅ Installation complete!${NC}"
echo ""
echo -e "${BLUE}📋 Summary of fixes:${NC}"
echo "1. ✅ Enhanced roaming with multiple BSSID connection methods"
echo "2. ✅ Bad client now actually attempts authentication (visible in Mist)"
echo "3. ✅ Persistent throughput tracking that survives browser refresh"
echo "4. ✅ Better BSSID discovery and verification"
echo "5. ✅ Enhanced error handling and logging"
echo ""
echo -e "${BLUE}🔍 Monitoring:${NC}"
echo "• Check logs: tail -f $DASHBOARD_DIR/logs/wifi-good.log"
echo "• Check logs: tail -f $DASHBOARD_DIR/logs/wifi-bad.log"
echo "• Monitor services: sudo systemctl status wifi-good wifi-bad"
echo ""
echo -e "${BLUE}📊 Testing:${NC}"
echo "• Roaming should now work with proper BSSID locking"
echo "• Bad client failures should appear in Mist dashboard within 1-2 minutes"
echo "• Throughput totals should persist across browser refreshes"
echo ""

# Check if services started successfully
sleep 10
echo -e "${BLUE}🔍 Service Status Check:${NC}"
for service in wifi-good wifi-bad; do
    if systemctl is-active --quiet "$service.service"; then
        echo "✅ $service: Running"
    else
        echo "❌ $service: Not running"
        echo "   Check logs: sudo journalctl -u $service.service -f"
    fi
done