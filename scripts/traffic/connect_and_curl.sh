#!/usr/bin/env bash
set -uo pipefail

# =============================================================================
# WI-FI GOOD CLIENT - OPTIMIZED WITH ROAMING & TRAFFIC GENERATION
# =============================================================================
# Purpose: Successful auth + intelligent roaming + configurable traffic
# Features:
#   - Configurable intensity (light/medium/heavy)
#   - Intelligent BSSID roaming with demo mode
#   - Simplified hostname management (no locks)
#   - Persistent stats tracking
#   - Support for netem (latency/packet loss)
# =============================================================================

export PATH="$PATH:/usr/local/bin:/usr/sbin:/sbin:/home/pi/.local/bin"
DASHBOARD_DIR="/home/pi/wifi_test_dashboard"
LOG_DIR="$DASHBOARD_DIR/logs"
LOG_FILE="$LOG_DIR/wifi-good.log"
CONFIG_FILE="$DASHBOARD_DIR/configs/ssid.conf"
SETTINGS="$DASHBOARD_DIR/configs/settings.conf"

INTERFACE="${INTERFACE:-wlan0}"
HOSTNAME="${WIFI_GOOD_HOSTNAME:-CNXNMist-WiFiGood}"

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
  local msg="[$(date '+%F %T')] WIFI-GOOD: $1"
  echo "$msg" | tee -a "$LOG_FILE"
}

# =============================================================================
# PERSISTENT STATS TRACKING
# =============================================================================
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
  log_msg "📊 Loaded stats: Down=${TOTAL_DOWN}B ($(( TOTAL_DOWN / 1048576 ))MB), Up=${TOTAL_UP}B ($(( TOTAL_UP / 1048576 ))MB)"
}

save_stats() {
  local f="$STATS_FILE"
  local now="$(date +%s)"
  local prev_down=0 prev_up=0

  if [[ -f "$f" ]]; then
    prev_down=$(sed -n 's/.*"download":[[:space:]]*\([0-9]\+\).*/\1/p' "$f" | head -n1)
    prev_up=$(sed -n 's/.*"upload":[[:space:]]*\([0-9]\+\).*/\1/p' "$f" | head -n1)
    prev_down=${prev_down:-0}; prev_up=${prev_up:-0}
  fi

  [[ "$TOTAL_DOWN" =~ ^[0-9]+$ ]] || TOTAL_DOWN=0
  [[ "$TOTAL_UP"   =~ ^[0-9]+$ ]] || TOTAL_UP=0
  (( TOTAL_DOWN < prev_down )) && TOTAL_DOWN="$prev_down"
  (( TOTAL_UP   < prev_up   )) && TOTAL_UP="$prev_up"

  printf '{"download": %d, "upload": %d, "timestamp": %d}\n' \
    "$TOTAL_DOWN" "$TOTAL_UP" "$now" > "$f.tmp" && mv "$f.tmp" "$f"
}

# =============================================================================
# CONFIGURATION LOADING
# =============================================================================
[[ -f "$SETTINGS" ]] && source "$SETTINGS" || true

# Interface & hostname
INTERFACE="${WIFI_GOOD_INTERFACE:-$INTERFACE}"
HOSTNAME="${WIFI_GOOD_HOSTNAME:-$HOSTNAME}"
REFRESH_INTERVAL="${WIFI_GOOD_REFRESH_INTERVAL:-60}"

# Roaming configuration
DEMO_MODE="${DEMO_MODE:-true}"
ROAMING_ENABLED="${WIFI_ROAMING_ENABLED:-true}"
ROAMING_INTERVAL="${WIFI_ROAMING_INTERVAL:-60}"
OPPORTUNISTIC_ROAMING_INTERVAL="${OPPORTUNISTIC_ROAMING_INTERVAL:-180}"
MIN_SIGNAL_THRESHOLD="${WIFI_MIN_SIGNAL_THRESHOLD:--75}"
ROAMING_SIGNAL_DIFF="${WIFI_ROAMING_SIGNAL_DIFF:-5}"

# Traffic configuration
TRAFFIC_INTENSITY="${WLAN0_TRAFFIC_INTENSITY:-medium}"
ENABLE_INTEGRATED_TRAFFIC="${WIFI_GOOD_INTEGRATED_TRAFFIC:-true}"

# Stats file (must be set AFTER interface is determined)
STATS_FILE="$DASHBOARD_DIR/stats/stats_${INTERFACE}.json"

# Traffic intensity presets
case "$TRAFFIC_INTENSITY" in
  heavy)
    DOWNLOAD_SIZE=52428800      # 50MB
    UPLOAD_SIZE=5242880         # 5MB
    PING_COUNT=20
    CONCURRENT_DOWNLOADS=3
    ;;
  medium)
    DOWNLOAD_SIZE=26214400      # 25MB
    UPLOAD_SIZE=2621440         # 2.5MB
    PING_COUNT=10
    CONCURRENT_DOWNLOADS=2
    ;;
  light|*)
    DOWNLOAD_SIZE=10485760      # 10MB
    UPLOAD_SIZE=1048576         # 1MB
    PING_COUNT=5
    CONCURRENT_DOWNLOADS=1
    ;;
esac

# Download sources
DOWNLOAD_URLS=(
    "https://ash-speed.hetzner.com/100MB.bin"
    "https://proof.ovh.net/files/100Mb.dat"
    "http://ipv4.download.thinkbroadband.com/50MB.zip"
)

PING_TARGETS=("8.8.8.8" "1.1.1.1" "208.67.222.222")

# Global roaming state
declare -A BSSID_SIGNALS
CURRENT_BSSID=""
LAST_ROAM_TIME=0
SSID=""
PASSWORD=""

# Load persistent stats
load_stats

# =============================================================================
# SIMPLIFIED HOSTNAME CONFIGURATION (No Locks)
# =============================================================================
configure_dhcp_hostname() {
    log_msg "🏷️ Configuring DHCP hostname: $HOSTNAME for $INTERFACE"
    
    # dhclient config
    local dhcp_conf="/etc/dhcp/dhclient-${INTERFACE}.conf"
    $SUDO bash -c "cat > $dhcp_conf" << EOF
send host-name "$HOSTNAME";
supersede host-name "$HOSTNAME";
EOF
    
    # NetworkManager config
    local nm_conf="/etc/NetworkManager/conf.d/dhcp-hostname-${INTERFACE}.conf"
    $SUDO bash -c "cat > $nm_conf" << EOF
[connection-${INTERFACE}]
match-device=interface-name:${INTERFACE}
[ipv4]
dhcp-hostname=${HOSTNAME}
dhcp-send-hostname=yes
[ipv6]
dhcp-hostname=${HOSTNAME}
dhcp-send-hostname=yes
EOF
    
    $SUDO nmcli general reload 2>/dev/null || true
    log_msg "✅ DHCP hostname configured"
}

# =============================================================================
# CONFIGURATION & INTERFACE MANAGEMENT
# =============================================================================
read_wifi_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then 
    log_msg "Config file not found: $CONFIG_FILE"
    return 1
  fi
  
  mapfile -t lines < "$CONFIG_FILE"
  if [[ ${#lines[@]} -lt 2 ]]; then
    log_msg "Config incomplete (need SSID + password)"
    return 1
  fi
  
  local temp_ssid="${lines[0]}" temp_password="${lines[1]}"
  temp_ssid=$(echo "$temp_ssid" | xargs)
  temp_password=$(echo "$temp_password" | xargs)
  
  if [[ -z "$temp_ssid" || -z "$temp_password" ]]; then
    log_msg "SSID or password empty"
    return 1
  fi
  
  SSID="$temp_ssid"
  PASSWORD="$temp_password"
  export SSID PASSWORD
  log_msg "Wi-Fi config loaded (SSID: '$SSID')"
  return 0
}

check_wifi_interface() {
  log_msg "🔍 Checking interface $INTERFACE..."
  
  if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
    log_msg "❌ Interface $INTERFACE not found"
    return 1
  fi
  
  # Check current interface state
  local link_state
  link_state="$(ip link show "$INTERFACE" | grep -o 'state [A-Z]*' | cut -d' ' -f2)"
  log_msg "   Link state: $link_state"
  
  # Bring interface up
  $SUDO ip link set "$INTERFACE" up || true
  sleep 2
  
  # Ensure NetworkManager is managing it
  $SUDO nmcli device set "$INTERFACE" managed yes || true
  sleep 2
  
  # Check if interface is now managed
  local managed
  managed="$($SUDO nmcli -t -f DEVICE,STATE device status | grep "^$INTERFACE:" | cut -d: -f2)"
  log_msg "   Managed state: $managed"
  
  # Force a rescan to refresh available networks
  log_msg "   Forcing Wi-Fi rescan..."
  $SUDO nmcli dev wifi rescan >/dev/null 2>&1 || true
  sleep 3
  
  log_msg "✅ Interface $INTERFACE ready (managed: $managed)"
  return 0
}

get_current_bssid() {
  local bssid=""
  bssid="$($SUDO nmcli -t -f ACTIVE,BSSID dev wifi | awk -F: '$1=="yes"{print $2; exit}')" || true
  
  if [[ -z "$bssid" || ! "$bssid" =~ : ]]; then
    bssid="$(iw dev "$INTERFACE" link 2>/dev/null | awk '/Connected to/{print $3; exit}')" || true
  fi
  
  bssid="$(echo "$bssid" | tr 'a-f' 'A-F')"
  echo "$bssid"
}

# =============================================================================
# BSSID DISCOVERY & ROAMING
# =============================================================================
discover_bssids_for_ssid() {
  declare -gA BSSID_SIGNALS
  BSSID_SIGNALS=()
  
  log_msg "🔍 Scanning for BSSIDs for SSID '$SSID'..."
  
  # Force a rescan and wait for results
  $SUDO nmcli dev wifi rescan >/dev/null 2>&1 || true
  sleep 3  # Give time for scan to complete
  
  # Debug: Show all available networks
  log_msg "📡 Available networks:"
  $SUDO nmcli -t -f SSID,BSSID,SIGNAL,SECURITY dev wifi 2>/dev/null | while IFS=: read -r ssid bssid signal security; do
    [[ -n "$ssid" ]] && log_msg "   $ssid ($bssid) - ${signal}dBm - $security"
  done
  
  # Look for our specific SSID
  while IFS=: read -r active bssid ssid signal; do
    [[ "$ssid" != "$SSID" ]] && continue
    bssid="$(echo "$bssid" | tr 'a-f' 'A-F')"
    [[ "$bssid" =~ : ]] || continue
    BSSID_SIGNALS["$bssid"]="$signal"
    log_msg "   Found BSSID: $bssid (signal: ${signal}dBm)"
  done < <($SUDO nmcli -t -f ACTIVE,BSSID,SSID,SIGNAL dev wifi 2>/dev/null)
  
  local count="${#BSSID_SIGNALS[@]}"
  if (( count > 0 )); then
    log_msg "✅ Found ${count} BSSID(s) for '$SSID'"
    for k in "${!BSSID_SIGNALS[@]}"; do
      log_msg "   Available: $k (${BSSID_SIGNALS[$k]} signal)"
    done
    return 0
  else
    log_msg "⚠️ No BSSIDs discovered for '$SSID'"
    log_msg "🔍 Debug: Checking if SSID exists with different case or spacing..."
    
    # Try case-insensitive search
    while IFS=: read -r active bssid ssid signal; do
      if [[ "${ssid,,}" == "${SSID,,}" ]]; then
        log_msg "   Found case-insensitive match: '$ssid' (expected: '$SSID')"
        bssid="$(echo "$bssid" | tr 'a-f' 'A-F')"
        [[ "$bssid" =~ : ]] || continue
        BSSID_SIGNALS["$bssid"]="$signal"
        log_msg "   Added BSSID: $bssid (signal: ${signal}dBm)"
      fi
    done < <($SUDO nmcli -t -f ACTIVE,BSSID,SSID,SIGNAL dev wifi 2>/dev/null)
    
    local final_count="${#BSSID_SIGNALS[@]}"
    if (( final_count > 0 )); then
      log_msg "✅ Found ${final_count} BSSID(s) with case-insensitive search"
      return 0
    fi
    
    return 1
  fi
}

select_roaming_target() {
  local cur="$1"
  cur="$(echo "$cur" | tr 'a-f' 'A-F')"
  
  local best=""
  local best_sig=-100
  local current_sig="${BSSID_SIGNALS[$cur]:-$MIN_SIGNAL_THRESHOLD}"
  local now=$(date +%s)

  log_msg "📊 Evaluating roaming from BSSID $cur (signal ${current_sig})"

  # Try to find significantly better signal
  for b in "${!BSSID_SIGNALS[@]}"; do
    [[ "$b" == "$cur" ]] && continue
    local s="${BSSID_SIGNALS[$b]}"
    
    if (( s <= MIN_SIGNAL_THRESHOLD )); then
      log_msg "   ⊗ Skipping $b (signal ${s} - below threshold)"
      continue
    fi
    
    local signal_improvement=$((s - current_sig))
    if (( signal_improvement >= ROAMING_SIGNAL_DIFF )); then
      if (( s > best_sig )); then
        best_sig=$s
        best="$b"
        log_msg "   ✓ Better candidate: $b (signal ${s}, +${signal_improvement})"
      fi
    fi
  done

  # If found significantly better signal, use it
  if [[ -n "$best" ]]; then
    log_msg "🎯 Selected signal-based roaming target: $best (signal ${best_sig})"
    echo "$best"
    return 0
  fi

  # DEMO MODE: Opportunistic roaming when all signals similar
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
        fi
      done

      if (( ${#alternatives[@]} > 0 )); then
        local idx=$((RANDOM % ${#alternatives[@]}))
        best="${alternatives[$idx]}"
        best_sig="${BSSID_SIGNALS[$best]}"
        log_msg "🎯 Selected opportunistic roaming target: $best (signal ${best_sig}) - demo roaming"
        LAST_ROAM_TIME=$now
        echo "$best"
        return 0
      fi
    fi
  fi

  log_msg "📍 No suitable roaming target found; staying on $cur"
  echo ""
}

connect_locked_bssid() {
  local bssid="$1" ssid="$2" psk="$3"
  
  [[ -z "$bssid" || -z "$ssid" || -z "$psk" ]] && {
    log_msg "❌ connect_locked_bssid: missing parameters"
    return 1
  }
  
  log_msg "🔗 Attempting BSSID-locked connection to $bssid (SSID: '$ssid')"
  
  # Disconnect and clean up
  $SUDO nmcli dev disconnect "$INTERFACE" 2>/dev/null || true
  sleep 3
  
  # Delete any existing connection profiles for this SSID
  $SUDO nmcli connection delete "$ssid" 2>/dev/null || true
  $SUDO nmcli connection delete "wifi-$ssid" 2>/dev/null || true
  sleep 2

  # Try creating connection profile first, then connecting
  log_msg "🔧 Creating connection profile for $ssid..."
  local profile_name="wifi-$ssid"
  
  if $SUDO nmcli connection add type wifi ifname "$INTERFACE" con-name "$profile_name" ssid "$ssid" 2>/dev/null; then
    log_msg "✅ Connection profile created: $profile_name"
    
    # Set security and password
    if $SUDO nmcli connection modify "$profile_name" wifi-sec.key-mgmt wpa-psk 2>/dev/null; then
      $SUDO nmcli connection modify "$profile_name" wifi-sec.psk "$psk" 2>/dev/null
      log_msg "✅ Security configured for profile"
    fi
    
    # Set BSSID if provided
    if [[ -n "$bssid" ]]; then
      $SUDO nmcli connection modify "$profile_name" wifi.bssid "$bssid" 2>/dev/null
      log_msg "✅ BSSID locked to: $bssid"
    fi
    
    # Try to activate the connection
    log_msg "🚀 Activating connection profile..."
    local OUT
    if OUT="$($SUDO nmcli --wait 30 connection up "$profile_name" ifname "$INTERFACE" 2>&1)"; then
      log_msg "✅ Connection profile activation successful"
      sleep 5
      
      local actual_bssid
      actual_bssid="$(get_current_bssid)"
      if [[ -n "$actual_bssid" ]]; then
        log_msg "✅ Connected to BSSID: $actual_bssid"
        return 0
      else
        log_msg "⚠️ Connected but BSSID unknown"
        return 0
      fi
    else
      log_msg "❌ Connection profile activation failed: ${OUT}"
    fi
  else
    log_msg "❌ Failed to create connection profile"
  fi

  # Fallback: Try direct nmcli connect
  log_msg "🔄 Trying direct nmcli connect as fallback..."
  local OUT
  if OUT="$($SUDO nmcli --wait 30 device wifi connect "$ssid" password "$psk" ifname "$INTERFACE" bssid "$bssid" 2>&1)"; then
    log_msg "✅ Direct nmcli connect successful"
    sleep 5
    
    local actual_bssid
    actual_bssid="$(get_current_bssid)"
    if [[ "${actual_bssid,,}" == "${bssid,,}" ]]; then
      log_msg "✅ BSSID verification successful: connected to $actual_bssid"
      return 0
    else
      log_msg "⚠️ BSSID mismatch: connected to ${actual_bssid:-unknown}, expected ${bssid,,}"
      return 0  # Still consider it a success
    fi
  else
    log_msg "❌ Direct nmcli connect failed: ${OUT}"
  fi

  return 1
}

perform_roaming() {
  local target_bssid="$1" ssid="$2" password="$3"
  
  log_msg "🔄 Performing roaming to $target_bssid"
  
  if connect_locked_bssid "$target_bssid" "$ssid" "$password"; then
    log_msg "✅ Roaming successful"
    LAST_ROAM_TIME=$(date +%s)
    return 0
  else
    log_msg "❌ Roaming failed"
    return 1
  fi
}

manage_roaming() {
  [[ "$ROAMING_ENABLED" != "true" ]] && return 0
  
  discover_bssids_for_ssid "$SSID" || return 0

  local now
  now=$(date +%s)
  if (( now - LAST_ROAM_TIME < ROAMING_INTERVAL )); then
    return 0
  fi
  
  if (( ${#BSSID_SIGNALS[@]} < 2 )); then
    return 0
  fi

  log_msg "⏰ Roaming interval reached, evaluating opportunity..."
  
  local current
  current="$(get_current_bssid)"
  current="$(echo "$current" | tr 'a-f' 'A-F')"
  
  [[ -z "$current" ]] && {
    log_msg "⚠️ Current BSSID unknown, skipping roam"
    return 0
  }

  local target
  target="$(select_roaming_target "$current")"
  
  if [[ -n "$target" ]]; then
    log_msg "🔄 Roaming candidate: $target (signal ${BSSID_SIGNALS[$target]}) vs current $current (signal ${BSSID_SIGNALS[$current]:-unknown})"
    
    set +e
    if timeout 120 perform_roaming "$target" "$SSID" "$PASSWORD" 2>&1; then
      log_msg "✅ Roaming completed successfully"
    else
      log_msg "❌ Roaming failed"
    fi
    set -e
  fi
}

# =============================================================================
# CONNECTION MANAGEMENT
# =============================================================================
connect_to_wifi_with_roaming() {
  local local_ssid="$1" local_password="$2"
  
  [[ -z "$local_ssid" || -z "$local_password" ]] && {
    log_msg "❌ connect_to_wifi_with_roaming called with empty parameters"
    return 1
  }
  
  log_msg "🔗 Connecting to Wi-Fi (roaming enabled=${ROAMING_ENABLED}) for SSID '$local_ssid'"
  
  if discover_bssids_for_ssid "$local_ssid"; then
    local target_bssid="" best_signal=-100
    for b in "${!BSSID_SIGNALS[@]}"; do
      local s="${BSSID_SIGNALS[$b]}"
      [[ -n "$s" && "$s" -gt "$best_signal" ]] && best_signal="$s" && target_bssid="$b"
    done
    
    if [[ -n "$target_bssid" ]]; then
      log_msg "🎯 Attempting connection to strongest BSSID $target_bssid (signal $best_signal)"
      if connect_locked_bssid "$target_bssid" "$local_ssid" "$local_password"; then
        log_msg "✅ BSSID-locked connection successful"
        return 0
      fi
    fi
  fi
  
  log_msg "🔄 Attempting fallback connection to SSID '$local_ssid'"
  $SUDO nmcli dev disconnect "$INTERFACE" 2>/dev/null || true
  sleep 3
  
  # Clean up any existing profiles
  $SUDO nmcli connection delete "$local_ssid" 2>/dev/null || true
  $SUDO nmcli connection delete "wifi-$local_ssid" 2>/dev/null || true
  sleep 2
  
  # Try creating a connection profile first
  log_msg "🔧 Creating fallback connection profile..."
  local profile_name="wifi-$local_ssid"
  
  if $SUDO nmcli connection add type wifi ifname "$INTERFACE" con-name "$profile_name" ssid "$local_ssid" 2>/dev/null; then
    log_msg "✅ Fallback profile created: $profile_name"
    
    # Configure security
    $SUDO nmcli connection modify "$profile_name" wifi-sec.key-mgmt wpa-psk 2>/dev/null || true
    $SUDO nmcli connection modify "$profile_name" wifi-sec.psk "$local_password" 2>/dev/null || true
    
    # Try to activate
    local OUT
    if OUT="$($SUDO nmcli --wait 30 connection up "$profile_name" ifname "$INTERFACE" 2>&1)"; then
      log_msg "✅ Fallback profile connection successful"
    else
      log_msg "❌ Fallback profile connection failed: ${OUT}"
      
      # Final fallback: direct connect
      log_msg "🔄 Trying direct nmcli connect as final fallback..."
      if OUT="$($SUDO nmcli --wait 30 device wifi connect "${local_ssid}" password "${local_password}" ifname "$INTERFACE" 2>&1)"; then
        log_msg "✅ Direct fallback connection successful"
      else
        log_msg "❌ All fallback methods failed: ${OUT}"
        return 1
      fi
    fi
  else
    log_msg "❌ Failed to create fallback profile, trying direct connect..."
    local OUT
    if OUT="$($SUDO nmcli --wait 30 device wifi connect "${local_ssid}" password "${local_password}" ifname "$INTERFACE" 2>&1)"; then
      log_msg "✅ Direct fallback connection successful"
    else
      log_msg "❌ Direct fallback connection failed: ${OUT}"
      return 1
    fi
  fi
  
  CURRENT_BSSID="$(get_current_bssid)"
  log_msg "✅ Successfully connected to '$local_ssid' (BSSID=${CURRENT_BSSID:-unknown})"
  return 0
}

assess_connection_health() {
  local state
  state="$($SUDO nmcli -t -f GENERAL.STATE device show "$INTERFACE" 2>/dev/null | cut -d: -f2 | awk '{print $1}' || echo "")"
  
  local ip
  ip="$(ip -o -4 addr show dev "$INTERFACE" 2>/dev/null | awk '{print $4}' | head -n1)"
  
  local ssid
  ssid="$($SUDO nmcli -t -f ACTIVE,SSID dev wifi | awk -F: '$1=="yes"{print $2; exit}' 2>/dev/null || echo "")"
  
  local bssid
  bssid="$(get_current_bssid)"
  
  # More detailed health assessment
  log_msg "🔍 Connection health check:"
  log_msg "   State: ${state:-unknown}"
  log_msg "   IP: ${ip:-none}"
  log_msg "   SSID: ${ssid:-none}"
  log_msg "   BSSID: ${bssid:-none}"
  
  # Check if we have a valid connection state
  if [[ "$state" == "100" || "$state" == "90" || "$state" == "80" ]]; then
    # State looks good, check for IP
    if [[ -n "$ip" ]]; then
      # Test basic connectivity
      if timeout 5 ping -I "$INTERFACE" -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        log_msg "✅ Connection healthy: IP=$ip, state=$state, connectivity=OK"
        return 0
      else
        log_msg "⚠️ Connection has IP but no internet connectivity: IP=$ip, state=$state"
        return 1
      fi
    else
      log_msg "⚠️ Connection state good but no IP assigned: state=$state"
      return 1
    fi
  elif [[ "$state" == "70" ]]; then
    log_msg "⚠️ Connection in progress: state=$state"
    return 1
  elif [[ "$state" == "30" ]]; then
    log_msg "⚠️ Interface disconnected: state=$state"
    return 1
  else
    log_msg "⚠️ Connection unhealthy: state=${state:-?}, IP=${ip:-none}"
    return 1
  fi
}

# =============================================================================
# KERNEL COUNTER STATS UPDATE
# =============================================================================
update_stats_from_kernel() {
    local rx_path="/sys/class/net/${INTERFACE}/statistics/rx_bytes"
    local tx_path="/sys/class/net/${INTERFACE}/statistics/tx_bytes"
    
    if [[ -f "$rx_path" && -f "$tx_path" ]]; then
        local current_rx=$(cat "$rx_path" 2>/dev/null || echo 0)
        local current_tx=$(cat "$tx_path" 2>/dev/null || echo 0)
        
        if [[ ! -f "$STATS_FILE.baseline" ]]; then
            echo "$current_rx $current_tx" > "$STATS_FILE.baseline"
            return
        fi
        
        local baseline
        baseline=$(cat "$STATS_FILE.baseline" 2>/dev/null || echo "0 0")
        local baseline_rx=$(echo "$baseline" | awk '{print $1}')
        local baseline_tx=$(echo "$baseline" | awk '{print $2}')
        
        TOTAL_DOWN=$(( current_rx - baseline_rx ))
        TOTAL_UP=$(( current_tx - baseline_tx ))
        
        [[ $TOTAL_DOWN -lt 0 ]] && TOTAL_DOWN=0
        [[ $TOTAL_UP -lt 0 ]] && TOTAL_UP=0
        
        save_stats
    fi
}

# =============================================================================
# TRAFFIC GENERATION
# =============================================================================
generate_realistic_traffic() {
  [[ "$ENABLE_INTEGRATED_TRAFFIC" != "true" ]] && return 0

  log_msg "🚀 Starting traffic generation (intensity: $TRAFFIC_INTENSITY)"

  # Quick connectivity test
  if ! timeout 10 ping -I "$INTERFACE" -c 2 -W 3 8.8.8.8 >/dev/null 2>&1; then
    log_msg "❌ Basic connectivity failed; skipping traffic"
    return 1
  fi

  # Download traffic
  local url="${DOWNLOAD_URLS[$((RANDOM % ${#DOWNLOAD_URLS[@]}))]}"
  local tmp_file="/tmp/wifi_good_download_$$"
  
  log_msg "📥 Downloading from: $(basename "$url")"
  if timeout 120 curl --interface "$INTERFACE" \
      --connect-timeout 15 --max-time 90 \
      --range 0-$DOWNLOAD_SIZE \
      --silent --location \
      --output "$tmp_file" "$url" 2>/dev/null; then
    log_msg "✅ Download completed"
    rm -f "$tmp_file"
  else
    log_msg "❌ Download failed"
    rm -f "$tmp_file"
  fi

  # Upload traffic
  local upload_data="/tmp/wifi_good_upload_$$"
  dd if=/dev/urandom of="$upload_data" bs=1K count=$(( UPLOAD_SIZE / 1024 )) 2>/dev/null
  
  log_msg "📤 Uploading test data..."
  if timeout 60 curl --interface "$INTERFACE" \
      --connect-timeout 10 --max-time 45 \
      --silent -X POST -o /dev/null \
      "https://httpbin.org/post" \
      --data-binary "@$upload_data" 2>/dev/null; then
    log_msg "✅ Upload completed"
  else
    log_msg "❌ Upload failed"
  fi
  rm -f "$upload_data"

  # Ping tests
  local ping_success=0 ping_total=${#PING_TARGETS[@]}
  for ping_target in "${PING_TARGETS[@]}"; do
    if timeout 30 ping -I "$INTERFACE" -c "$PING_COUNT" -i 0.5 "$ping_target" >/dev/null 2>&1; then
      ((ping_success++))
    fi
  done
  log_msg "📊 Ping results: $ping_success/$ping_total targets reachable"

  # Update stats from kernel
  update_stats_from_kernel
  
  log_msg "✅ Traffic generation completed - Stats: Down=$(( TOTAL_DOWN / 1048576 ))MB, Up=$(( TOTAL_UP / 1048576 ))MB"
  return 0
}

# =============================================================================
# MAIN LOOP
# =============================================================================
main_loop() {
    log_msg "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_msg "🌐 WI-FI GOOD CLIENT - OPTIMIZED"
    log_msg "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_msg "Interface: $INTERFACE | Hostname: $HOSTNAME"
    log_msg "Intensity: $TRAFFIC_INTENSITY | Roaming: $ROAMING_ENABLED"
    log_msg "Demo Mode: $DEMO_MODE | Opportunistic Interval: ${OPPORTUNISTIC_ROAMING_INTERVAL}s"
    log_msg "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Configure hostname
    configure_dhcp_hostname
    
    # Initialize kernel baseline
    local rx_path="/sys/class/net/${INTERFACE}/statistics/rx_bytes"
    local tx_path="/sys/class/net/${INTERFACE}/statistics/tx_bytes"
    if [[ -f "$rx_path" && -f "$tx_path" ]]; then
        local baseline_rx=$(cat "$rx_path")
        local baseline_tx=$(cat "$tx_path")
        echo "$baseline_rx $baseline_tx" > "$STATS_FILE.baseline"
        log_msg "📊 Initialized kernel counter baseline"
    fi
    
    local last_cfg=0 last_traffic=0
    
    while true; do
        local now=$(date +%s)
        
        # Re-read config periodically
        if (( now - last_cfg > 600 )); then
            if read_wifi_config; then
                log_msg "✅ Config refreshed (SSID: '$SSID')"
                last_cfg=$now
            fi
        fi
        
        # Validate config
        if [[ -z "$SSID" || -z "$PASSWORD" ]]; then
            log_msg "❌ No valid SSID/password configuration"
            sleep "$REFRESH_INTERVAL"
            continue
        fi
        
        # Check interface
        if ! check_wifi_interface; then
            log_msg "❌ Interface check failed"
            sleep "$REFRESH_INTERVAL"
            continue
        fi
        
        # Health check → roam → traffic
        if assess_connection_health; then
            manage_roaming
            
            if (( now - last_traffic > 30 )); then
                generate_realistic_traffic && last_traffic=$now
            fi
        else
            log_msg "🔄 Connection needs attention, attempting to reconnect"
            if connect_to_wifi_with_roaming "$SSID" "$PASSWORD"; then
                log_msg "✅ Wi-Fi connection reestablished"
                sleep 5
            else
                log_msg "❌ Reconnect failed; will retry"
                sleep "$REFRESH_INTERVAL"
                continue
            fi
        fi
        
        CURRENT_BSSID=$(get_current_bssid)
        log_msg "📍 Current: BSSID $CURRENT_BSSID | Available BSSIDs: ${#BSSID_SIGNALS[@]} | Stats: D=$(( TOTAL_DOWN / 1048576 ))MB U=$(( TOTAL_UP / 1048576 ))MB"
        
        log_msg "✅ Good client operating normally"
        sleep "$REFRESH_INTERVAL"
    done
}

# Start
log_msg "🚀 Starting enhanced Wi-Fi Good Client..."
main_loop