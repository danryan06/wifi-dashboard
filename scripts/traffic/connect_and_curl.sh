#!/usr/bin/env bash
# Wi-Fi Good Client: Auth + Roaming + Realistic Traffic (CRITICAL FIXES)
# Fixes for SSID variable scope and scanning issues

set -uo pipefail

# --- Paths & defaults ---
export PATH="$PATH:/usr/local/bin:/usr/sbin:/sbin:/home/pi/.local/bin"
DASHBOARD_DIR="/home/pi/wifi_test_dashboard"
LOG_DIR="$DASHBOARD_DIR/logs"
LOG_FILE="$LOG_DIR/wifi-good.log"
CONFIG_FILE="$DASHBOARD_DIR/configs/ssid.conf"
SETTINGS="$DASHBOARD_DIR/configs/settings.conf"
ROTATE_UTIL="$DASHBOARD_DIR/scripts/log_rotation_utils.sh"

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

# --- Settings ---
[[ -f "$SETTINGS" ]] && source "$SETTINGS" || true
INTERFACE="${WIFI_GOOD_INTERFACE:-$INTERFACE}"
REFRESH_INTERVAL="${WIFI_GOOD_REFRESH_INTERVAL:-60}"
CONNECTION_TIMEOUT="${WIFI_CONNECTION_TIMEOUT:-30}"
MAX_RETRIES="${WIFI_MAX_RETRY_ATTEMPTS:-3}"

# Roaming config
ROAMING_ENABLED="${WIFI_ROAMING_ENABLED:-true}"
ROAMING_INTERVAL="${WIFI_ROAMING_INTERVAL:-120}"
ROAMING_SCAN_INTERVAL="${WIFI_ROAMING_SCAN_INTERVAL:-10}"  # Scan more frequently
MIN_SIGNAL_THRESHOLD="${WIFI_MIN_SIGNAL_THRESHOLD:--75}"
ROAMING_SIGNAL_DIFF="${WIFI_ROAMING_SIGNAL_DIFF:-10}"
WIFI_BAND_PREFERENCE="${WIFI_BAND_PREFERENCE:-both}"

# Traffic config
TRAFFIC_INTENSITY="${WLAN0_TRAFFIC_INTENSITY:-medium}"
ENABLE_INTEGRATED_TRAFFIC="${WIFI_GOOD_INTEGRATED_TRAFFIC:-true}"

# Optional heavy features (opt-in)
ENABLE_SPEEDTEST="${ENABLE_SPEEDTEST:-false}"
SPEEDTEST_INTERVAL="${SPEEDTEST_INTERVAL:-900}"

ENABLE_YOUTUBE="${ENABLE_YOUTUBE:-false}"
YOUTUBE_INTERVAL="${YOUTUBE_INTERVAL:-900}"
YOUTUBE_URL="${YOUTUBE_URL:-https://www.youtube.com/watch?v=dQw4w9WgXcQ}"

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

# Global SSID/PASSWORD variables (CRITICAL: make these global and persistent)
SSID=""
PASSWORD=""

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

# --- Config (FIXED to maintain global variables) ---
read_wifi_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then 
    log_msg "Config file not found: $CONFIG_FILE"; return 1; 
  fi
  
  mapfile -t lines < "$CONFIG_FILE"
  if [[ ${#lines[@]} -lt 2 ]]; then 
    log_msg "Config incomplete (need SSID + password)"; return 1; 
  fi
  
  # FIXED: Assign to global variables and validate before assignment
  local temp_ssid="${lines[0]}"
  local temp_password="${lines[1]}"
  
  # Trim whitespace and validate
  temp_ssid=$(echo "$temp_ssid" | xargs)
  temp_password=$(echo "$temp_password" | xargs)
  
  if [[ -z "$temp_ssid" || -z "$temp_password" ]]; then 
    log_msg "SSID or password empty after parsing"; return 1; 
  fi
  
  # Only update globals if validation passes
  SSID="$temp_ssid"
  PASSWORD="$temp_password"
  export SSID PASSWORD
  
  log_msg "Wi-Fi config loaded (SSID: '$SSID')"
  return 0
}

# --- Interface mgmt (ENHANCED) ---
check_wifi_interface() {
  if ! ip link show "$INTERFACE" >/dev/null 2>&1; then 
    log_msg "Interface $INTERFACE not found"; return 1; 
  fi
  
  # Force interface up and managed
  log_msg "Ensuring $INTERFACE is up and managed..."
  $SUDO ip link set "$INTERFACE" up || true
  sleep 2
  
  # Force NetworkManager to manage this interface
  $SUDO nmcli device set "$INTERFACE" managed yes || true
  sleep 2
  
  # Force a rescan to refresh available networks
  log_msg "Forcing Wi-Fi rescan..."
  $SUDO nmcli device wifi rescan ifname "$INTERFACE" || true
  sleep 3
  
  local st; st="$(nm_state)"; 
  log_msg "Interface $INTERFACE state: ${st:-unknown}"
  return 0
}

# --- Band helper (ENHANCED) ---
freqs_for_band() {
  case "${1:-both}" in
    2.4) echo "2412 2417 2422 2427 2432 2437 2442 2447 2452 2457 2462" ;;
    5)   echo "5180 5200 5220 5240 5500 5520 5540 5745 5765 5785" ;;
    both|*) echo "" ;;  # Let nmcli scan all bands
  esac
}

get_current_bssid() {
  local b; b=$(iwconfig "$INTERFACE" 2>/dev/null | awk '/Access Point:/ {print $6; exit}')
  b=$(echo "$b" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
  [[ "$b" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] && echo "$b" || echo ""
}

# CRITICAL FIX: Enhanced BSSID discovery with proper error handling
discover_bssids_for_ssid() {
  local target_ssid="$1" 
  local now; now=$(date +%s)
  
  # Check rate limiting
  if (( now - LAST_SCAN_TIME < ROAMING_SCAN_INTERVAL )); then 
    return 0; 
  fi
  
  # CRITICAL: Validate input
  if [[ -z "$target_ssid" ]]; then
    log_msg "❌ discover_bssids_for_ssid called with empty SSID"
    return 1
  fi
  
  log_msg "🔍 Scanning (${WIFI_BAND_PREFERENCE}) for BSSIDs broadcasting SSID: '$target_ssid'"

  # Clear previous results
  DISCOVERED_BSSIDS=(); BSSID_SIGNALS=()

  # ENHANCED: Force fresh scan with longer wait
  log_msg "🔄 Forcing fresh Wi-Fi scan..."
  $SUDO nmcli device wifi rescan ifname "$INTERFACE" >/dev/null 2>&1 || true
  sleep 5  # Longer wait for scan to complete

  # ENHANCED: Primary discovery with detailed logging
  log_msg "📋 Listing available networks..."
  local scan_output
  scan_output=$($SUDO nmcli -t -f BSSID,SSID,SIGNAL device wifi list ifname "$INTERFACE" 2>/dev/null || echo "")
  
  if [[ -z "$scan_output" ]]; then
    log_msg "❌ nmcli wifi list returned no results"
  else
    log_msg "📊 Processing scan results..."
  fi

  # CRITICAL FIX: Process scan results with escaped colon handling
  # nmcli -t output format: XX\:XX\:XX\:XX\:XX\:XX:SSID:SIGNAL (note escaped colons in BSSID)
  while IFS= read -r line; do
    # Skip empty lines
    [[ -n "$line" ]] || continue
    
    # FIXED: Parse nmcli format with escaped colons in BSSID
    # Format: XX\:XX\:XX\:XX\:XX\:XX:SSID:SIGNAL
    if [[ "$line" =~ ^([0-9A-Fa-f]{2}\\:[0-9A-Fa-f]{2}\\:[0-9A-Fa-f]{2}\\:[0-9A-Fa-f]{2}\\:[0-9A-Fa-f]{2}\\:[0-9A-Fa-f]{2}):(.+):([0-9]+)$ ]]; then
      local bssid_escaped="${BASH_REMATCH[1]}"
      local ssid="${BASH_REMATCH[2]}"
      local signal="${BASH_REMATCH[3]}"
      
      # Convert escaped BSSID to normal format
      local bssid="${bssid_escaped//\\:/:}"
      
      log_msg "✅ Parsed: BSSID=$bssid SSID='$ssid' SIGNAL=$signal vs target='$target_ssid'"
      
      # CRITICAL: Exact SSID match
      if [[ "$ssid" == "$target_ssid" ]]; then
        # Convert signal percentage to dBm
        local signal_dbm=$(( signal / 2 - 100 ))
        if (( signal_dbm >= MIN_SIGNAL_THRESHOLD )); then
          DISCOVERED_BSSIDS["$bssid"]="$ssid"
          BSSID_SIGNALS["$bssid"]="$signal_dbm"
          log_msg "🎯 Found matching BSSID: $bssid (Signal: ${signal_dbm} dBm, ${signal}%)"
        else
          log_msg "🔸 Found weak BSSID: $bssid (Signal: ${signal_dbm} dBm, too weak)"
        fi
      fi
    else
      log_msg "⚠️ Could not parse line: $line"
    fi
  done <<< "$scan_output"

  # ENHANCED: Fallback with iw scan if nmcli failed
  if (( ${#DISCOVERED_BSSIDS[@]} == 0 )); then
    log_msg "⚠️ nmcli found no matches, trying iw scan fallback..."
    
    local iw_output
    if iw_output=$($SUDO iw dev "$INTERFACE" scan 2>/dev/null); then
      local current_bssid="" current_ssid="" current_signal=""
      
      while IFS= read -r line; do
        if [[ "$line" =~ ^BSS\ ([0-9a-f:]+) ]]; then
          current_bssid="${BASH_REMATCH[1]}"
          current_ssid=""
          current_signal=""
        elif [[ "$line" =~ SSID:\ (.+)$ ]]; then
          current_ssid="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ signal:\ (-?[0-9]+\.[0-9]+)\ dBm ]]; then
          current_signal="${BASH_REMATCH[1]}"
          current_signal="${current_signal%.*}"  # Remove decimal part
          
          # If we have all components and SSID matches
          if [[ -n "$current_bssid" && "$current_ssid" == "$target_ssid" && -n "$current_signal" ]]; then
            if (( current_signal >= MIN_SIGNAL_THRESHOLD )); then
              DISCOVERED_BSSIDS["$current_bssid"]="$current_ssid"
              BSSID_SIGNALS["$current_bssid"]="$current_signal"
              log_msg "✅ iw found: $current_bssid (Signal: ${current_signal} dBm)"
            fi
          fi
        fi
      done <<< "$iw_output"
    else
      log_msg "❌ Both nmcli and iw scans failed"
    fi
  fi

  LAST_SCAN_TIME="$now"
  local count=${#DISCOVERED_BSSIDS[@]}

  if (( count == 0 )); then
    log_msg "❌ No BSSIDs found for SSID: '$target_ssid'"
    
    # DIAGNOSTIC: Show what SSIDs we DID find
    log_msg "📋 Available SSIDs in area:"
    $SUDO nmcli -t -f SSID device wifi list ifname "$INTERFACE" 2>/dev/null | sort -u | head -10 | while read -r found_ssid; do
      [[ -n "$found_ssid" ]] && log_msg "   - '$found_ssid'"
    done
    
    return 1
  elif (( count == 1 )); then
    log_msg "ℹ️ Single BSSID found - roaming not possible"
  else
    log_msg "✅ Multiple BSSIDs found ($count) - roaming enabled!"
    for b in "${!DISCOVERED_BSSIDS[@]}"; do
      log_msg "   Available: $b (${BSSID_SIGNALS[$b]} dBm)"
    done
  fi
  return 0
}

# Remove any existing NM connections for this SSID to avoid conflicts
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

# CRITICAL FIX: BSSID connect with proper variable handling
connect_locked_bssid() {
  local bssid="$1" 
  local ssid="$2" 
  local psk="$3"
  
  # CRITICAL: Validate all inputs
  if [[ -z "$bssid" ]]; then
    log_msg "❌ connect_locked_bssid: missing BSSID parameter"
    return 1
  fi
  if [[ -z "$ssid" ]]; then
    log_msg "❌ connect_locked_bssid: missing SSID parameter"
    return 1
  fi
  if [[ -z "$psk" ]]; then
    log_msg "❌ connect_locked_bssid: missing password parameter"
    return 1
  fi
  
  log_msg "🔗 Connecting to BSSID $bssid (SSID: '$ssid')"
  
  prune_same_ssid_profiles "$ssid"
  $SUDO nmcli dev disconnect "$INTERFACE" 2>/dev/null || true
  sleep 2
  
  local OUT
  # CRITICAL FIX: Use proper variable substitution and quotes
  if OUT="$($SUDO nmcli --wait 45 device wifi connect "${ssid}" password "${psk}" ifname "$INTERFACE" bssid "${bssid}" 2>&1)"; then
    log_msg "✅ BSSID connect success: ${OUT}"
  else
    log_msg "❌ BSSID connect failed: ${OUT}"
    return 1
  fi
  
  sleep 3
  local new_bssid
  new_bssid="$(iw dev "$INTERFACE" link 2>/dev/null | awk '/Connected to/{print tolower($3)}')"
  if [[ "$new_bssid" == "${bssid,,}" ]]; then
    log_msg "✅ BSSID verified: $new_bssid"
    return 0
  else
    log_msg "❌ BSSID verify mismatch (got: ${new_bssid:-unknown}, expected: $bssid)"
    return 1
  fi
}

select_roaming_target() {
  local cur="$1" best="" best_sig=-100
  local current_sig="${BSSID_SIGNALS[$cur]:-$MIN_SIGNAL_THRESHOLD}"
  
  for b in "${!DISCOVERED_BSSIDS[@]}"; do
    [[ "$b" == "$cur" ]] && continue
    local s="${BSSID_SIGNALS[$b]}"
    
    # Only consider BSSIDs above threshold AND significantly better than current
    (( s > MIN_SIGNAL_THRESHOLD )) || continue
    (( s > current_sig + ROAMING_SIGNAL_DIFF )) || continue
    
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

  # Fresh scan to ensure BSSID visibility
  $SUDO nmcli device wifi rescan ifname "$INTERFACE" >/dev/null 2>&1
  sleep 3

  # Verify target BSSID is visible
  if ! $SUDO nmcli device wifi list ifname "$INTERFACE" | grep -qi "$target_bssid"; then
    log_msg "❌ Target BSSID $target_bssid not currently visible"
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

# CRITICAL FIX: Connection function with proper variable scope
connect_to_wifi_with_roaming() {
  local local_ssid="$1" 
  local local_password="$2"
  
  # CRITICAL: Validate inputs before proceeding  
  if [[ -z "$local_ssid" ]]; then
    log_msg "❌ connect_to_wifi_with_roaming called with empty SSID"
    return 1
  fi
  if [[ -z "$local_password" ]]; then
    log_msg "❌ connect_to_wifi_with_roaming called with empty password"
    return 1
  fi
  
  log_msg "🔗 Connecting to Wi-Fi (roaming enabled=${ROAMING_ENABLED}) for SSID '$local_ssid'"

  # Discover candidates
  discover_bssids_for_ssid "$local_ssid" || true

  # Pick strongest if we have any
  local target_bssid="" best_signal=-100
  for b in "${!DISCOVERED_BSSIDS[@]}"; do
    local s="${BSSID_SIGNALS[$b]}"
    [[ -n "$s" && "$s" -gt "$best_signal" ]] && best_signal="$s" && target_bssid="$b"
  done

  # Try BSSID-locked first if we have one
  if [[ -n "$target_bssid" ]]; then
    log_msg "🎯 Connecting via specific BSSID $target_bssid ($best_signal dBm)"
    if connect_locked_bssid "$target_bssid" "$local_ssid" "$local_password"; then
      log_msg "✅ BSSID-locked connection successful"
      return 0
    else
      log_msg "⚠️ Locked connect failed; falling back to direct connect"
    fi
  fi

  # CRITICAL FIX: Fallback direct connect with proper variable handling
  local state
  state="$($SUDO nmcli -t -f GENERAL.STATE device show "$INTERFACE" 2>/dev/null | cut -d: -f2 | awk '{print $1}' || echo "0")"
  if [[ "$state" != "100" ]]; then
    log_msg "🔄 Attempting direct connection to SSID '$local_ssid'"
    $SUDO nmcli dev disconnect "$INTERFACE" 2>/dev/null || true
    sleep 2
    
    local OUT
    # CRITICAL FIX: Use local variables with proper quotes
    if OUT="$($SUDO nmcli --wait 45 device wifi connect "${local_ssid}" password "${local_password}" ifname "$INTERFACE" 2>&1)"; then
      log_msg "✅ Direct connect success: ${OUT}"
    else
      log_msg "❌ Direct connect failed: ${OUT}"
      log_msg "🔍 Debug: SSID='${local_ssid}' (length: ${#local_ssid})"
      return 1
    fi
  fi

  # Verify IP
  log_msg "⏳ Waiting for IP address..."
  for i in {1..20}; do
    local ip
    ip="$(ip addr show "$INTERFACE" | awk '/inet /{print $2; exit}')"
    if [[ -n "$ip" ]]; then
      log_msg "✅ IP address acquired: $ip"
      break
    fi
    log_msg "⏳ Waiting for IP... ($i/20)"
    sleep 2
  done

  # Record current BSSID
  CURRENT_BSSID="$(iw dev "$INTERFACE" link 2>/dev/null | awk '/Connected to/{print tolower($3)}')"
  if [[ -n "$CURRENT_BSSID" && -z "${BSSID_SIGNALS[$CURRENT_BSSID]:-}" ]]; then
    local sig="$(iw dev "$INTERFACE" link 2>/dev/null | awk '/signal:/{print $2}')"
    [[ -n "$sig" ]] && BSSID_SIGNALS["$CURRENT_BSSID"]="$sig"
  fi

  log_msg "✅ Successfully connected to '$local_ssid' (BSSID=${CURRENT_BSSID:-unknown})"
  
  # ENHANCED: Immediately discover other BSSIDs for roaming after successful connection
  log_msg "🔍 Performing initial BSSID discovery for roaming..."
  discover_bssids_for_ssid "$local_ssid" || true
  
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

  # ALWAYS keep the candidate list fresh - not just when roaming
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
        log_msg "❌ Roaming attempt failed"
      fi
      sleep 5
    else
      log_msg "📍 No better BSSID found; staying on $CURRENT_BSSID"
    fi
  fi
}

# --- Traffic functions ---
test_basic_connectivity() {
  log_msg "🧪 Testing connectivity on $INTERFACE..."
  local success_count=0

  # DNS test
  if getent hosts google.com >/dev/null 2>&1; then
    log_msg "✅ DNS resolution OK"
    ((success_count++))
  else
    log_msg "❌ DNS resolution failed"
  fi

  # HTTPS test
  if timeout 15 curl --interface "$INTERFACE" --max-time 10 -fsSL -o /dev/null "https://www.google.com" 2>/dev/null; then
    log_msg "✅ HTTPS connectivity test passed"
    ((success_count++))
  else
    log_msg "❌ HTTPS connectivity test failed"
  fi

  # Ping test
  if timeout 10 ping -I "$INTERFACE" -c 3 -W 2 8.8.8.8 >/dev/null 2>&1; then
    log_msg "✅ Ping connectivity test passed"
    ((success_count++))
  else
    log_msg "❌ Ping connectivity test failed"
  fi

  log_msg "📊 Connectivity: $success_count/3 tests passed"
  return $([[ $success_count -gt 0 ]] && echo 0 || echo 1)
}

generate_realistic_traffic() {
  if [[ "$ENABLE_INTEGRATED_TRAFFIC" != "true" ]]; then
    return 0
  fi

  # Health gate: only run traffic if properly connected
  local st ip ss
  st="$(nm_state)"
  ip="$(current_ip)"
  ss="$(current_ssid)"
  
  if [[ "$st" != "100" || -z "$ip" || "$ss" != "$SSID" ]]; then
    log_msg "⚠️ Traffic suppressed: link not healthy (state=$st, ip=${ip:-none}, ssid=${ss:-none})"
    return 1
  fi

  log_msg "🚀 Starting realistic traffic generation (intensity: $TRAFFIC_INTENSITY)..."

  if ! test_basic_connectivity; then
    log_msg "❌ Basic connectivity failed; skipping traffic"
    return 1
  fi

  # Light ping traffic
  timeout 30 ping -I "$INTERFACE" -c "$PING_COUNT" -i 0.5 8.8.8.8 >/dev/null 2>&1 && \
    log_msg "✅ Ping traffic successful" || log_msg "❌ Ping traffic failed"

  log_msg "✅ Realistic traffic generation completed"
  return 0
}

# CRITICAL FIX: Main loop with enhanced error handling
main_loop() {
  log_msg "🚀 Starting enhanced good client"
  local last_cfg=0 last_traffic=0
  
  while true; do
    local now=$(date +%s)
    
    # Re-read config periodically (every 10 minutes)
    if (( now - last_cfg > 600 )); then
      if read_wifi_config; then
        log_msg "✅ Config refreshed (SSID: '$SSID')"
        last_cfg=$now
      else
        log_msg "⚠️ Config read failed, using previous values (SSID: '${SSID:-unset}')"
      fi
    fi
    
    # CRITICAL: Validate we have config before proceeding
    if [[ -z "$SSID" || -z "$PASSWORD" ]]; then
      log_msg "❌ No valid SSID/password configuration, retrying in $REFRESH_INTERVAL seconds"
      sleep "$REFRESH_INTERVAL"
      continue
    fi
    
    # Check interface with enhanced validation
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
      
      # CRITICAL FIX: Pass validated non-empty variables with explicit validation
      if [[ -n "$SSID" && -n "$PASSWORD" ]]; then
        log_msg "🔄 Attempting to (re)connect with SSID='$SSID' (length: ${#SSID})"
        if connect_to_wifi_with_roaming "$SSID" "$PASSWORD"; then
          log_msg "✅ Wi-Fi connection (re)established"
          sleep 5
        else
          log_msg "❌ Reconnect failed; retrying later"
          sleep "$REFRESH_INTERVAL"
          continue
        fi
      else
        log_msg "❌ Cannot reconnect: missing SSID (${#SSID}) or password (${#PASSWORD})"
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
      log_msg "📍 Current: BSSID $CURRENT_BSSID (${BSSID_SIGNALS[$CURRENT_BSSID]:-unknown} dBm) | Available BSSIDs: ${#DISCOVERED_BSSIDS[@]}"
    fi

    log_msg "✅ Good client operating normally"
    sleep "$REFRESH_INTERVAL"
  done
}

cleanup_and_exit() {
  log_msg "🧹 Cleaning up good client..."
  $SUDO nmcli device disconnect "$INTERFACE" 2>/dev/null || true
  log_msg "✅ Stopped"
  exit 0
}
trap cleanup_and_exit SIGTERM SIGINT

# --- Init ---
mkdir -p "$LOG_DIR" 2>/dev/null || true
log_msg "🚀 Enhanced Wi-Fi Good Client Starting..."
log_msg "Interface: $INTERFACE | Hostname: $HOSTNAME"
log_msg "Roaming: ${ROAMING_ENABLED} (interval ${ROAMING_INTERVAL}s; scan ${ROAMING_SCAN_INTERVAL}s; min ${MIN_SIGNAL_THRESHOLD}dBm)"

# Initial config read with validation
if ! read_wifi_config; then
  log_msg "❌ Failed to read initial configuration"
  log_msg "⚠️ Will retry reading config in main loop"
fi

# CRITICAL: Debug the initial config state
log_msg "🔍 Debug: Initial SSID='${SSID}' (length: ${#SSID}), PASSWORD length: ${#PASSWORD}"

# Start main loop
main_loop