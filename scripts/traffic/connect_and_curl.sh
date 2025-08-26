#!/usr/bin/env bash
set -euo pipefail

# Enhanced Wi-Fi Good Client Simulation with BSSID Roaming - FIXED VERSION
# Complete good client behavior: Authentication + Connection + Roaming + Realistic Traffic Generation
# This represents a real user's device that successfully connects and roams between APs

INTERFACE="${INTERFACE:=wlan0}"
HOSTNAME="CNXNMist-WiFiGood"
LOG_FILE="/home/pi/wifi_test_dashboard/logs/wifi-good.log"
CONFIG_FILE="/home/pi/wifi_test_dashboard/configs/ssid.conf"
SETTINGS="/home/pi/wifi_test_dashboard/configs/settings.conf"

# Keep service alive; log failing command instead of exiting
set -E
trap 'ec=$?; echo "[$(date "+%F %T")] TRAP-ERR: cmd=\"$BASH_COMMAND\" ec=$ec line=$LINENO" | tee -a "$LOG_FILE"; ec=0' ERR

# --- Log rotation setup ---
ROTATE_UTIL="/home/pi/wifi_test_dashboard/scripts/log_rotation_utils.sh"
[[ -f "$ROTATE_UTIL" ]] && source "$ROTATE_UTIL" || true
: "${LOG_MAX_SIZE_BYTES:=10485760}"   # 10MB default

# Try to locate the generator in either layout
TRAFFIC_GEN=""
for p in \
  "/home/pi/wifi_test_dashboard/scripts/interface_traffic_generator.sh" \
  "/home/pi/wifi_test_dashboard/scripts/traffic/interface_traffic_generator.sh"
do
  [[ -f "$p" ]] && TRAFFIC_GEN="$p" && break
done

# Basic rotation function if utils not available
rotate_basic() {
    if command -v rotate_log >/dev/null 2>&1; then
        rotate_log "$LOG_FILE" "${LOG_MAX_SIZE_MB:-5}"
        return 0
    fi

    local max_bytes="${LOG_MAX_SIZE_BYTES:-10485760}"
    local size_bytes=0

    if [[ -f "$LOG_FILE" ]]; then
        size_bytes=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo "0")
        if (( size_bytes >= max_bytes )); then
            mv -f "$LOG_FILE" "$LOG_FILE.$(date +%s).1" 2>/dev/null || true
            : > "$LOG_FILE"
        fi
    fi
}

log_msg() {
    local msg="[$(date '+%F %T')] WIFI-GOOD: $1"
    if declare -F log_msg_with_rotation >/dev/null; then
        echo "$msg"
        log_msg_with_rotation "$LOG_FILE" "$msg" "WIFI-GOOD"
    else
        rotate_basic
        mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
        echo "$msg" | tee -a "$LOG_FILE"
    fi
}

# Enhanced logging with network state
log_msg_with_network_info() {
    local msg="$1"
    local timestamp="[$(date '+%F %T')]"
    local ip_info=""
    
    # Add current IP info to critical messages
    if [[ "$msg" =~ (Connected|Failed|IP|DHCP|Error) ]]; then
        local current_ip=$(ip addr show "$INTERFACE" 2>/dev/null | grep 'inet ' | awk '{print $2}' | head -n1 || echo "none")
        ip_info=" [IP:${current_ip}]"
    fi
    
    local full_msg="$timestamp WIFI-GOOD: $msg$ip_info"
    
    if declare -F log_msg_with_rotation >/dev/null; then
        echo "$full_msg"
        log_msg_with_rotation "$LOG_FILE" "$full_msg" "WIFI-GOOD"
    else
        rotate_basic
        mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
        echo "$full_msg" | tee -a "$LOG_FILE"
    fi
}

# --- Load settings and overrides ---
[[ -f "$SETTINGS" ]] && source "$SETTINGS" || true

INTERFACE="${WIFI_GOOD_INTERFACE:-$INTERFACE}"
HOSTNAME="${WIFI_GOOD_HOSTNAME:-$HOSTNAME}"
REFRESH_INTERVAL="${WIFI_GOOD_REFRESH_INTERVAL:-60}"
CONNECTION_TIMEOUT="${WIFI_CONNECTION_TIMEOUT:-30}"
MAX_RETRIES="${WIFI_MAX_RETRY_ATTEMPTS:-3}"

# Roaming-specific settings
ROAMING_ENABLED="${WIFI_ROAMING_ENABLED:-true}"
ROAMING_INTERVAL="${WIFI_ROAMING_INTERVAL:-120}"  # Roam every 2 minutes
ROAMING_SCAN_INTERVAL="${WIFI_ROAMING_SCAN_INTERVAL:-30}"  # Rescan for BSSIDs every 30 seconds
MIN_SIGNAL_THRESHOLD="${WIFI_MIN_SIGNAL_THRESHOLD:--75}"  # Minimum signal strength (dBm)
ROAMING_SIGNAL_DIFF="${WIFI_ROAMING_SIGNAL_DIFF:-10}"     # Signal difference to trigger roaming
# Band preference: 2.4 | 5 | both  (Pi 3 defaults to 2.4)
WIFI_BAND_PREFERENCE="${WIFI_BAND_PREFERENCE:-2.4}"

# Traffic generation settings
TRAFFIC_INTENSITY="${WLAN0_TRAFFIC_INTENSITY:-medium}"
ENABLE_INTEGRATED_TRAFFIC="${WIFI_GOOD_INTEGRATED_TRAFFIC:-true}"

# Global roaming state
declare -A DISCOVERED_BSSIDS
declare -A BSSID_SIGNALS
CURRENT_BSSID=""
LAST_ROAM_TIME=0
LAST_SCAN_TIME=0

# Traffic intensity configurations
case "$TRAFFIC_INTENSITY" in
    heavy)   
        DL_SIZE=104857600; PING_COUNT=20; SPEEDTEST_INTERVAL=300
        DOWNLOAD_INTERVAL=60; YOUTUBE_INTERVAL=300; CONCURRENT_DOWNLOADS=5
        ;;
    medium)  
        DL_SIZE=52428800; PING_COUNT=10; SPEEDTEST_INTERVAL=600
        DOWNLOAD_INTERVAL=120; YOUTUBE_INTERVAL=600; CONCURRENT_DOWNLOADS=3
        ;;
    light|*) 
        DL_SIZE=10485760; PING_COUNT=5; SPEEDTEST_INTERVAL=1200
        DOWNLOAD_INTERVAL=300; YOUTUBE_INTERVAL=900; CONCURRENT_DOWNLOADS=2
        ;;
esac

# --- URLs and targets for traffic generation ---
TEST_URLS=(
    "https://www.google.com"
    "https://www.cloudflare.com"
    "https://httpbin.org/ip"
    "https://www.github.com"
)

DOWNLOAD_URLS=(
    "https://ash-speed.hetzner.com/100MB.bin"
    "https://proof.ovh.net/files/100Mb.dat"
    "http://ipv4.download.thinkbroadband.com/50MB.zip"
    "https://speed.hetzner.de/100MB.bin"
)

PING_TARGETS=("8.8.8.8" "1.1.1.1" "208.67.222.222" "9.9.9.9")

# --- Configuration management ---
read_wifi_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_msg "✗ Config file not found: $CONFIG_FILE"
        return 1
    fi

    local lines=($(cat "$CONFIG_FILE"))
    if [[ ${#lines[@]} -lt 2 ]]; then
        log_msg "✗ Config file incomplete (need SSID and password)"
        return 1
    fi

    SSID="${lines[0]}"
    PASSWORD="${lines[1]}"

    if [[ -z "$SSID" || -z "$PASSWORD" ]]; then
        log_msg "✗ SSID or password is empty"
        return 1
    fi

    log_msg "✓ Wi-Fi config loaded (SSID: $SSID)"
    return 0
}

# --- Interface management ---
check_wifi_interface() {
    if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
        log_msg "✗ Wi-Fi interface $INTERFACE not found"
        return 1
    fi

    # Ensure interface is up
    if ! ip link show "$INTERFACE" | grep -q "state UP"; then
        log_msg "Bringing $INTERFACE up..."
        sudo ip link set "$INTERFACE" up || true
        sleep 2
    fi

    # Ensure NetworkManager manages this interface
    if ! nmcli device show "$INTERFACE" >/dev/null 2>&1; then
        log_msg "Setting $INTERFACE to managed mode"
        sudo nmcli device set "$INTERFACE" managed yes || true
        sleep 3
        nmcli device wifi rescan ifname "$INTERFACE" 2>/dev/null || true
        sleep 2
    fi

    local state
    state="$(nmcli -t -f GENERAL.STATE device show "$INTERFACE" 2>/dev/null | cut -d: -f2 | awk '{print $1}' || echo "unknown")"
    log_msg "Interface $INTERFACE state: $state"

    return 0
}

# Enhanced interface state verification
verify_interface_health() {
    local interface="$1"
    local expected_ssid="$2"
    
    log_msg "🔍 Verifying interface health for $interface..."
    
    # Check 1: Interface exists and is up
    if ! ip link show "$interface" >/dev/null 2>&1; then
        log_msg "❌ Interface $interface not found"
        return 1
    fi
    
    if ! ip link show "$interface" | grep -q "state UP"; then
        log_msg "⚠️ Interface $interface is down, bringing up..."
        sudo ip link set "$interface" up || return 1
        sleep 2
    fi
    
    # Check 2: NetworkManager management
    if ! nmcli device show "$interface" >/dev/null 2>&1; then
        log_msg "⚠️ Interface $interface not managed by NetworkManager"
        sudo nmcli device set "$interface" managed yes || true
        sleep 3
    fi
    
    # Check 3: Connection state
    local nm_state=$(nmcli -t -f GENERAL.STATE device show "$interface" 2>/dev/null | cut -d: -f2 | awk '{print $1}' || echo "unknown")
    local ip_addr=$(ip addr show "$interface" | grep 'inet ' | awk '{print $2}' | head -n1)
    local current_ssid=$(nmcli -t -f active,ssid dev wifi 2>/dev/null | grep '^yes' | cut -d':' -f2 || echo "")
    
    log_msg "📊 Interface Status:"
    log_msg "   - NetworkManager State: $nm_state"
    log_msg "   - IP Address: ${ip_addr:-none}"
    log_msg "   - Current SSID: ${current_ssid:-none}"
    log_msg "   - Expected SSID: ${expected_ssid:-any}"
    
    # Health assessment
    if [[ "$nm_state" == "100" && -n "$ip_addr" ]]; then
        if [[ -n "$expected_ssid" && "$current_ssid" == "$expected_ssid" ]]; then
            log_msg "✅ Interface $interface is healthy"
            return 0
        elif [[ -z "$expected_ssid" ]]; then
            log_msg "✅ Interface $interface is connected (SSID check skipped)"
            return 0
        else
            log_msg "⚠️ Interface $interface connected to wrong SSID"
            return 2  # Connected but wrong SSID
        fi
    else
        log_msg "⚠️ Interface $interface has connectivity issues"
        return 1
    fi
}

freqs_for_band() {
  case "${1:-2.4}" in
    2.4) echo "2412 2417 2422 2427 2432 2437 2442 2447 2452 2457 2462 2467 2472" ;;
    5)   echo "5180 5200 5220 5240 5260 5280 5300 5320 5500 5520 5540 5560 5580 5600 5620 5640 5660 5680 5700 5720 5745 5765 5785 5805 5825" ;;
    both) echo "$(freqs_for_band 2.4) $(freqs_for_band 5)" ;;
    *) echo "$(freqs_for_band 2.4)";;
  esac
}

discover_bssids_for_ssid() {
  local target_ssid="$1"
  local now
  now=$(date +%s)
  if [[ $((now - LAST_SCAN_TIME)) -lt $ROAMING_SCAN_INTERVAL ]]; then
    return 0
  fi

  log_msg "🔍 Scanning (${WIFI_BAND_PREFERENCE}) for BSSIDs broadcasting SSID: $target_ssid"
  DISCOVERED_BSSIDS=()
  BSSID_SIGNALS=()

  # --- Primary path: implicit iw scan, filter band in software ---
  # Use process substitution so the while loop runs in the *current* shell (no subshell).
  while read -r bssid sig freq; do
    [[ -z "$bssid" ]] && continue
    DISCOVERED_BSSIDS["$bssid"]="$target_ssid"
    BSSID_SIGNALS["$bssid"]="$sig"
    log_msg "📡 Found BSSID: $bssid (Signal: ${sig} dBm @ ${freq} MHz)"
  done < <(
    sudo iw dev "$INTERFACE" scan 2>/dev/null \
    | awk -v ss="$target_ssid" -v band="$WIFI_BAND_PREFERENCE" '
        /BSS[[:space:]]/     { bssid=$2 }
        /freq:[[:space:]]/   { freq=$2 }
        /signal:[[:space:]]/ { sig=$2 }
        /^[ \t]*SSID:[ \t]*/ {
          sub(/^[ \t]*SSID:[ \t]*/, "", $0);
          curr_ssid=$0;
          gsub(/[ \t]+$/, "", curr_ssid);
          ok_band = (band=="both") || (band=="2.4" && freq<3000) || (band=="5" && freq>5000);
          if (curr_ssid==ss && ok_band && bssid!="" && sig!="") {
            gsub(/\(.*/, "", bssid);         # drop "(on wlanX)" suffix if present
            printf "%s %d %d\n", bssid, int(sig), freq;
          }
        }' \
    | sort -k2,2nr
  )

  # --- Fallback: nmcli if iw yielded nothing (driver busy, etc.) ---
  if [[ ${#DISCOVERED_BSSIDS[@]} -eq 0 ]]; then
    if nmcli -t --separator '|' -f SSID,BSSID,FREQ,SIGNAL dev wifi list ifname "$INTERFACE" >/tmp/.nmwifi 2>/dev/null; then
      while IFS='|' read -r ssid bssid freq sig; do
        [[ "$ssid" == "$target_ssid" ]] || continue
        # Band filter (same logic as above)
        case "$WIFI_BAND_PREFERENCE" in
          2.4) [[ "$freq" -ge 3000 ]] && continue ;;
          5)   [[ "$freq" -le 5000 ]] && continue ;;
        esac
        [[ -n "$bssid" && -n "$sig" ]] || continue
        # Convert nmcli % → rough dBm for thresholding
        local dbm=$(( sig / 2 - 100 ))
        if (( dbm >= MIN_SIGNAL_THRESHOLD )); then
          DISCOVERED_BSSIDS["$bssid"]="$ssid"
          BSSID_SIGNALS["$bssid"]="$dbm"
          log_msg "📡 (nmcli) Found BSSID: $bssid (≈ ${dbm} dBm @ ${freq} MHz)"
        fi
      done < /tmp/.nmwifi
      rm -f /tmp/.nmwifi
    fi
  fi

  LAST_SCAN_TIME="$now"
  local count=${#DISCOVERED_BSSIDS[@]}

  if (( count == 0 )); then
    log_msg "⚠ No BSSIDs found for SSID: $target_ssid"
    return 1
  elif (( count == 1 )); then
    log_msg "📶 Single BSSID found — roaming not possible"
  else
    log_msg "🎯 Multiple BSSIDs found ($count) — roaming enabled!"
    for b in "${!DISCOVERED_BSSIDS[@]}"; do
      log_msg "🏠 Available: $b (${BSSID_SIGNALS[$b]} dBm)"
    done
  fi
  return 0
}

get_current_bssid() {
    # Get currently connected BSSID
    local current_bssid
    current_bssid=$(iwconfig "$INTERFACE" 2>/dev/null | grep "Access Point:" | awk '{print $6}' || echo "")
    
    # Clean up the BSSID (remove any extra characters)
    current_bssid=$(echo "$current_bssid" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
    
    # Validate BSSID format (should be like xx:xx:xx:xx:xx:xx)
    if [[ "$current_bssid" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]; then
        echo "$current_bssid"
    else
        echo ""
    fi
}

select_roaming_target() {
    local current_bssid="$1"
    local best_bssid=""
    local best_signal=-100
    
    log_msg "🎯 Selecting roaming target (current: ${current_bssid:-none})"
    
    # Find the best alternative BSSID
    for bssid in "${!DISCOVERED_BSSIDS[@]}"; do
        local signal="${BSSID_SIGNALS[$bssid]}"
        
        # Skip current BSSID
        if [[ "$bssid" == "$current_bssid" ]]; then
            continue
        fi
        
        # Check signal strength threshold
        if [[ $signal -gt $MIN_SIGNAL_THRESHOLD ]]; then
            if [[ $signal -gt $best_signal ]]; then
                best_signal=$signal
                best_bssid="$bssid"
            fi
        fi
    done
    
    if [[ -n "$best_bssid" ]]; then
        log_msg "📡 Selected roaming target: $best_bssid (${best_signal}dBm)"
        echo "$best_bssid"
    else
        log_msg "⚠ No suitable roaming target found"
        echo ""
    fi
}

should_perform_roaming() {
    local current_time=$(date +%s)
    
    # Check if roaming is enabled
    if [[ "$ROAMING_ENABLED" != "true" ]]; then
        return 1
    fi
    
    # Check if enough time has passed since last roam
    if [[ $((current_time - LAST_ROAM_TIME)) -lt $ROAMING_INTERVAL ]]; then
        return 1
    fi
    
    # Check if we have multiple BSSIDs available
    if [[ ${#DISCOVERED_BSSIDS[@]} -lt 2 ]]; then
        return 1
    fi
    
    return 0
}

perform_roaming() {
    local target_bssid="$1"
    local target_ssid="$2"
    local target_password="$3"
    local roam_connection_name="wifi-roam-$(date +%s)"
    
    log_msg "🔄 Initiating roaming to BSSID: $target_bssid"
    log_msg "📊 Roaming Event: ${CURRENT_BSSID:-unknown} -> $target_bssid (SSID: $target_ssid)"
    
    # Clean up any old roaming connections
    nmcli connection show 2>/dev/null | grep "wifi-roam-" | awk '{print $1}' | \
        while read -r old_conn; do
            [[ -n "$old_conn" ]] && nmcli connection delete "$old_conn" 2>/dev/null || true
        done
    
    # Create connection profile with specific BSSID
    if nmcli connection add \
        type wifi \
        con-name "$roam_connection_name" \
        ifname "$INTERFACE" \
        ssid "$target_ssid" \
        802-11-wireless.bssid "$target_bssid" \
        wifi-sec.key-mgmt wpa-psk \
        wifi-sec.psk "$target_password" \
        wifi.cloned-mac-address preserve \
        ipv4.method auto \
        ipv6.method ignore >/dev/null 2>&1; then

        
        log_msg "✓ Created roaming connection profile"
    else
        log_msg "✗ Failed to create roaming connection profile"
        return 1
    fi
    
    # Disconnect from current network gracefully
    log_msg "📤 Disconnecting from current BSSID..."
    nmcli device disconnect "$INTERFACE" 2>/dev/null || true
    sleep 2
    
    # Connect to target BSSID
    log_msg "📥 Connecting to target BSSID: $target_bssid"
    if timeout "$CONNECTION_TIMEOUT" nmcli connection up "$roam_connection_name" >/dev/null 2>&1; then
        # Verify we connected to the right BSSID
        sleep 3
        local new_bssid
        new_bssid=$(get_current_bssid)
        
        if [[ "$new_bssid" == "$target_bssid" ]]; then
            log_msg "✅ Roaming successful! Connected to: $target_bssid"
            log_msg "🎉 Roaming Event Complete: Signal strength $(echo "${BSSID_SIGNALS[$target_bssid]}")dBm"
            CURRENT_BSSID="$target_bssid"
            LAST_ROAM_TIME=$(date +%s)
            
            # Clean up old connection profile after successful roam
            sleep 2
            nmcli connection delete "$roam_connection_name" 2>/dev/null || true
            
            return 0
        else
            log_msg "⚠ Roaming verification failed - connected to unexpected BSSID: $new_bssid"
            nmcli connection delete "$roam_connection_name" 2>/dev/null || true
            return 1
        fi
    else
        log_msg "✗ Failed to connect to target BSSID: $target_bssid"
        nmcli connection delete "$roam_connection_name" 2>/dev/null || true
        return 1
    fi
}

# --- Enhanced Connection Management with Roaming ---
connect_to_wifi_with_roaming() {
    local ssid="$1"
    local password="$2"
    local connection_name="wifi-good-$ssid"

    log_msg "🔗 Connecting to Wi-Fi with roaming capabilities enabled"
    log_msg "📶 Target SSID: $ssid (Roaming: ${ROAMING_ENABLED})"

    # First, discover all available BSSIDs for this SSID
    if ! discover_bssids_for_ssid "$ssid"; then
        log_msg "⚠ BSSID discovery failed, attempting standard connection"
    fi

    # Clean up any existing connections for this SSID
    nmcli -t -f NAME,TYPE connection show 2>/dev/null | \
      awk -F: '$2=="wifi"{print $1}' | \
      while read -r conn; do
        if [[ -n "$conn" ]]; then
            local c_ssid
            c_ssid="$(nmcli -t -f 802-11-wireless.ssid connection show "$conn" 2>/dev/null | cut -d: -f2 || echo "")"
            [[ "$c_ssid" == "$ssid" ]] && nmcli connection delete "$conn" 2>/dev/null || true
        fi
      done

    # Choose initial BSSID (prefer strongest signal)
    local target_bssid=""
    local best_signal=-100
    
    for bssid in "${!DISCOVERED_BSSIDS[@]}"; do
        local signal="${BSSID_SIGNALS[$bssid]}"
        if [[ $signal -gt $best_signal ]]; then
            best_signal=$signal
            target_bssid="$bssid"
        fi
    done

    # IMPROVED: Try multiple connection methods for reliability
    local connection_success=false
    
    # Method 1: Create connection profile (original method)
    if [[ -n "$target_bssid" ]]; then
        log_msg "🎯 Targeting specific BSSID: $target_bssid (${best_signal}dBm)"
        
        if nmcli connection add \
            type wifi \
            con-name "$connection_name" \
            ifname "$INTERFACE" \
            ssid "$ssid" \
            802-11-wireless.bssid "$target_bssid" \
            wifi-sec.key-mgmt wpa-psk \
            wifi-sec.psk "$password" \
            wifi.cloned-mac-address preserve \
            ipv4.method auto \
            ipv6.method ignore >/dev/null 2>&1; then
            
            log_msg "✓ Created Wi-Fi connection with specific BSSID"
            
            # Ensure clean connection state
            nmcli device disconnect "$INTERFACE" 2>/dev/null || true
            sleep 3

            # Attempt to connect
            if timeout "$CONNECTION_TIMEOUT" nmcli connection up "$connection_name" >/dev/null 2>&1; then
                connection_success=true
            else
                log_msg "⚠ Connection profile method failed, trying direct method"
                nmcli connection delete "$connection_name" 2>/dev/null || true
            fi
        else
            log_msg "⚠ Failed to create connection profile, trying direct method"
        fi
    fi
    
    # Method 2: Direct connection (fallback)
    if [[ "$connection_success" != "true" ]]; then
        log_msg "🔄 Trying direct device connection method"
        
        # Ensure interface is disconnected first
        nmcli device disconnect "$INTERFACE" 2>/dev/null || true
        sleep 2
        
        if timeout "$CONNECTION_TIMEOUT" nmcli device wifi connect "$ssid" password "$password" ifname "$INTERFACE" >/dev/null 2>&1; then
            connection_success=true
            log_msg "✓ Direct connection method succeeded"
        else
            log_msg "✗ Both connection methods failed"
            return 1
        fi
    fi
    
    if [[ "$connection_success" == "true" ]]; then
        log_msg "✓ Successfully connected to $ssid"
        
        # Update current BSSID
        sleep 2
        CURRENT_BSSID=$(get_current_bssid)
        log_msg "📍 Connected to BSSID: ${CURRENT_BSSID:-unknown}"
        
        # Wait for IP assignment with improved checking and NetworkManager integration
        local wait_count=0
        local ip_assigned=false
        log_msg "⏳ Waiting for IP address assignment..."
        
        while [[ $wait_count -lt 20 ]]; do  # Increased from 15 to 20
            local ip_addr
            ip_addr=$(ip addr show "$INTERFACE" | grep 'inet ' | awk '{print $2}' | head -n1)
            if [[ -n "$ip_addr" ]]; then
                log_msg "✅ IP address assigned: $ip_addr"
                ip_assigned=true
                break
            fi
            
            # Enhanced progress reporting
            if [[ $((wait_count % 5)) -eq 0 && $wait_count -gt 0 ]]; then
                log_msg "⏳ Still waiting for IP assignment... (${wait_count}s/40s)"
                
                # Check if NetworkManager shows connected but no IP
                local nm_state=$(nmcli -t -f GENERAL.STATE device show "$INTERFACE" 2>/dev/null | cut -d: -f2 | awk '{print $1}' || echo "unknown")
                if [[ "$nm_state" == "100" ]]; then
                    log_msg "🔧 NetworkManager shows connected but no IP, requesting renewal..."
                    # Use NetworkManager's built-in DHCP renewal instead of direct dhclient
                    nmcli device reapply "$INTERFACE" 2>/dev/null || true
                    sleep 3
                fi
            fi
            
            sleep 2
            wait_count=$((wait_count + 2))
        done
        
        if [[ "$ip_assigned" != "true" ]]; then
            log_msg "⚠️ Connected but no IP address assigned after 40s, attempting recovery..."
            
            # FIXED: Use NetworkManager for DHCP instead of direct dhclient calls
            # This prevents conflicts with NetworkManager's DHCP management
            log_msg "🔄 Attempting NetworkManager DHCP renewal..."
            
            # Method 1: NetworkManager connection restart
            local active_conn=$(nmcli -t -f NAME,DEVICE connection show --active | grep ":$INTERFACE$" | cut -d: -f1)
            if [[ -n "$active_conn" ]]; then
                log_msg "🔄 Restarting connection: $active_conn"
                nmcli connection down "$active_conn" 2>/dev/null || true
                sleep 2
                nmcli connection up "$active_conn" 2>/dev/null || true
                sleep 5
                
                # Check if IP was assigned after restart
                ip_addr=$(ip addr show "$INTERFACE" | grep 'inet ' | awk '{print $2}' | head -n1)
                if [[ -n "$ip_addr" ]]; then
                    log_msg "✅ IP address assigned after connection restart: $ip_addr"
                    ip_assigned=true
                fi
            fi
            
            # Method 2: Device reapply (fallback)
            if [[ "$ip_assigned" != "true" ]]; then
                log_msg "🔄 Attempting device reapply..."
                nmcli device reapply "$INTERFACE" 2>/dev/null || true
                sleep 5
                
                ip_addr=$(ip addr show "$INTERFACE" | grep 'inet ' | awk '{print $2}' | head -n1)
                if [[ -n "$ip_addr" ]]; then
                    log_msg "✅ IP address assigned after device reapply: $ip_addr"
                    ip_assigned=true
                fi
            fi
            
            # Method 3: Last resort - direct dhclient but with NetworkManager awareness
            if [[ "$ip_assigned" != "true" ]]; then
                log_msg "🆘 Last resort: direct DHCP request (may cause NetworkManager conflicts)"
                # First check if NetworkManager is managing DHCP
                if ! nmcli device show "$INTERFACE" | grep -q "IP4.METHOD.*auto"; then
                    sudo dhclient -r "$INTERFACE" 2>/dev/null || true
                    sleep 2
                    sudo dhclient "$INTERFACE" 2>/dev/null || true
                    sleep 5
                    
                    ip_addr=$(ip addr show "$INTERFACE" | grep 'inet ' | awk '{print $2}' | head -n1)
                    if [[ -n "$ip_addr" ]]; then
                        log_msg "✅ IP address assigned via direct DHCP: $ip_addr"
                        ip_assigned=true
                    fi
                else
                    log_msg "⚠️ NetworkManager is managing DHCP - skipping direct dhclient to avoid conflicts"
                fi
            fi
            
            if [[ "$ip_assigned" != "true" ]]; then
                log_msg "❌ Failed to obtain IP address after all recovery attempts"
                return 1
            fi
        
        return 0
    else
        return 1
    fi
}

# --- Roaming Management Function ---
manage_roaming() {
    if [[ "$ROAMING_ENABLED" != "true" ]]; then
        return 0
    fi
    
    # Refresh BSSID list periodically
    discover_bssids_for_ssid "$SSID" || return 0
    
    # Check if we should perform roaming
    if should_perform_roaming; then
        log_msg "⏰ Roaming interval reached, evaluating roaming opportunity..."
        
        # Update current BSSID
        CURRENT_BSSID=$(get_current_bssid)
        
        if [[ -n "$CURRENT_BSSID" ]]; then
            local target_bssid
            target_bssid=$(select_roaming_target "$CURRENT_BSSID")
            
            if [[ -n "$target_bssid" ]]; then
                log_msg "🚀 Initiating roaming sequence..."
                if perform_roaming "$target_bssid" "$SSID" "$PASSWORD"; then
                    log_msg "✅ Roaming completed successfully"
                    
                    # Brief pause after roaming before resuming traffic
                    sleep 5
                else
                    log_msg "❌ Roaming failed, maintaining current connection"
                fi
            else
                log_msg "💤 No suitable roaming target found"
            fi
        else
            log_msg "⚠ Cannot determine current BSSID for roaming"
        fi
    fi
}

# --- Enhanced Traffic Generation (preserving existing functionality) ---
test_basic_connectivity() {
    log_msg "🧪 Testing connectivity on $INTERFACE..."
    local success_count=0
    local test_count=0
    
    # Enhanced connectivity testing with better error handling
    for url in "${TEST_URLS[@]}"; do
        ((test_count++))
        if timeout 15 curl --interface "$INTERFACE" --max-time 10 -fsSL -o /dev/null "$url" 2>/dev/null; then
            log_msg "✓ Connectivity test passed: $url"
            ((success_count++))
        else
            log_msg "✗ Connectivity test failed: $url"
        fi
        sleep 1
    done
    
    # Additional basic tests
    ((test_count++))
    if timeout 10 ping -I "$INTERFACE" -c 3 -W 2 8.8.8.8 >/dev/null 2>&1; then
        log_msg "✓ Ping connectivity test passed"
        ((success_count++))
    else
        log_msg "✗ Ping connectivity test failed"
        
        # Try to fix connectivity issues
        log_msg "🔧 Attempting to fix connectivity..."
        
        # FIXED: Use NetworkManager-based recovery instead of direct dhclient
        log_msg "🔄 Using NetworkManager for connectivity recovery..."
        
        # Check current connection state
        local nm_state=$(nmcli -t -f GENERAL.STATE device show "$INTERFACE" 2>/dev/null | cut -d: -f2 | awk '{print $1}' || echo "unknown")
        local ip_addr=$(ip addr show "$INTERFACE" | grep 'inet ' | awk '{print $2}' | head -n1)
        
        if [[ "$nm_state" == "100" && -n "$ip_addr" ]]; then
            # Connected with IP but ping failing - likely routing/DNS issue
            log_msg "🔍 Have IP ($ip_addr) but ping failing - checking routing..."
            
            # Check if we have a default route through this interface
            if ! ip route | grep -q "default.*dev $INTERFACE"; then
                log_msg "⚠️ No default route via $INTERFACE, this is expected (eth0 likely default)"
                # For Wi-Fi interfaces that aren't the default route, test with source IP
                if timeout 10 ping -I "$ip_addr" -c 3 -W 2 8.8.8.8 >/dev/null 2>&1; then
                    log_msg "✅ Ping successful using source IP"
                    ((success_count++))
                fi
            else
                # Try DNS flush and route refresh
                log_msg "🔄 Refreshing network configuration..."
                nmcli device reapply "$INTERFACE" 2>/dev/null || true
                sleep 3
                
                if timeout 10 ping -I "$INTERFACE" -c 3 -W 2 8.8.8.8 >/dev/null 2>&1; then
                    log_msg "✅ Ping connectivity restored after network refresh"
                    ((success_count++))
                fi
            fi
        else
            # No IP or not connected - need to reestablish connection
            log_msg "🔄 No IP or not connected, attempting connection recovery..."
            
            # Use NetworkManager to refresh the connection
            local active_conn=$(nmcli -t -f NAME,DEVICE connection show --active | grep ":$INTERFACE$" | cut -d: -f1)
            if [[ -n "$active_conn" ]]; then
                nmcli connection down "$active_conn" 2>/dev/null || true
                sleep 2
                nmcli connection up "$active_conn" 2>/dev/null || true
                sleep 5
                
                # Test again after recovery
                if timeout 10 ping -I "$INTERFACE" -c 3 -W 2 8.8.8.8 >/dev/null 2>&1; then
                    log_msg "✅ Ping connectivity restored after connection recovery"
                    ((success_count++))
                fi
            fi
        fi
    
    log_msg "🎯 Connectivity: $success_count/$test_count tests passed"
    return $([[ $success_count -gt 0 ]] && echo 0 || echo 1)
}

generate_ping_traffic() {
    log_msg "Generating ping traffic (${PING_COUNT} pings per target)..."
    
    for target in "${PING_TARGETS[@]}"; do
        if timeout 30 ping -I "$INTERFACE" -c "$PING_COUNT" -i 0.5 "$target" >/dev/null 2>&1; then
            log_msg "✓ Ping successful: $target"
        else
            log_msg "✗ Ping failed: $target"
        fi
    done
}

generate_download_traffic() {
    log_msg "Starting download traffic (${CONCURRENT_DOWNLOADS} concurrent, ${DL_SIZE} bytes each)..."
    
    local pids=()
    local completed=0
    
    for ((i=0; i<CONCURRENT_DOWNLOADS; i++)); do
        {
            local url="${DOWNLOAD_URLS[$((RANDOM % ${#DOWNLOAD_URLS[@]}))]}"
            local start_time=$(date +%s)
            
            if timeout 180 curl --interface "$INTERFACE" \
                   --max-time 120 \
                   --range "0-$DL_SIZE" \
                   --silent \
                   --location \
                   --output /dev/null \
                   "$url" 2>/dev/null; then
                local end_time=$(date +%s)
                local duration=$((end_time - start_time))
                echo "[$(date '+%F %T')] WIFI-GOOD: ✓ Download completed: $(basename "$url") (${duration}s)" >> "$LOG_FILE"
            else
                echo "[$(date '+%F %T')] WIFI-GOOD: ✗ Download failed: $(basename "$url")" >> "$LOG_FILE"
            fi
        } &
        pids+=($!)
    done
    
    for pid in "${pids[@]}"; do
        if wait "$pid" 2>/dev/null; then
            completed=$((completed + 1))
        fi
    done
    
    log_msg "Download traffic completed: $completed/$CONCURRENT_DOWNLOADS successful"
}

generate_realistic_traffic() {
    if [[ "$ENABLE_INTEGRATED_TRAFFIC" != "true" ]]; then
        log_msg "Integrated traffic generation disabled"
        return 0
    fi
    
    log_msg "Starting realistic traffic generation (intensity: $TRAFFIC_INTENSITY)..."
    
    # Always do basic connectivity and traffic
    if ! test_basic_connectivity; then
        log_msg "⚠ Basic connectivity failed, skipping additional traffic"
        return 1
    fi
    
    generate_ping_traffic
    
    # Schedule heavier traffic based on intervals
    local current_time=$(date +%s)
    
    # Check if it's time for downloads
    local download_stamp="/tmp/wifi_good_download.last"
    local last_download=0
    [[ -f "$download_stamp" ]] && last_download="$(cat "$download_stamp" 2>/dev/null || echo 0)"
    
    if (( current_time - last_download >= DOWNLOAD_INTERVAL )); then
        generate_download_traffic
        echo "$current_time" > "$download_stamp"
    fi
    
    log_msg "✓ Realistic traffic generation cycle completed"
    return 0
}

# --- Enhanced Main Loop with Roaming ---
main_loop() {
    log_msg "🚀 Starting enhanced Wi-Fi good client with roaming simulation"
    log_msg "Interface: $INTERFACE, Hostname: $HOSTNAME, Traffic: $TRAFFIC_INTENSITY"
    log_msg "🔄 Roaming: ${ROAMING_ENABLED} (Interval: ${ROAMING_INTERVAL}s)"
    log_msg "📡 BSSID Scan Interval: ${ROAMING_SCAN_INTERVAL}s"

    local last_config_check=0
    local last_traffic_time=0

    while true; do
        local now
        now="$(date +%s)"

        # Periodically refresh config (10 min)
        if [[ $((now - last_config_check)) -gt 600 ]]; then
            if read_wifi_config; then
                last_config_check=$now
                log_msg "Config refreshed"
            fi
        fi

        if ! check_wifi_interface; then
            log_msg "✗ Wi-Fi interface check failed"
            sleep "${REFRESH_INTERVAL}"
            continue
        fi

        # Enhanced connection status checking
        local state
        state="$(nmcli -t -f GENERAL.STATE device show "$INTERFACE" 2>/dev/null | cut -d: -f2 | awk '{print $1}' || echo "unknown")"
        local ip_addr=$(ip addr show "$INTERFACE" | grep 'inet ' | awk '{print $2}' | head -n1)
        local current_ssid
        current_ssid="$(nmcli -t -f active,ssid dev wifi 2>/dev/null | grep '^yes' | cut -d':' -f2 || echo "")"
        
        # Enhanced connection state logic
        local connection_healthy=false
        
        if [[ "$state" == "100" && -n "$ip_addr" && "$current_ssid" == "$SSID" ]]; then
            # All conditions met - connection appears healthy
            connection_healthy=true
            log_msg "✅ Connection healthy: SSID=$SSID, IP=$ip_addr"
        else
            log_msg "⚠️ Connection issue detected:"
            log_msg "   - NetworkManager State: $state (100=connected)"
            log_msg "   - IP Address: ${ip_addr:-none}"
            log_msg "   - Current SSID: ${current_ssid:-none}"
            log_msg "   - Expected SSID: $SSID"
            
            # Determine what needs fixing
            if [[ "$state" != "100" ]]; then
                log_msg "🔧 NetworkManager shows not connected, attempting reconnection..."
                if connect_to_wifi_with_roaming "$SSID" "$PASSWORD"; then
                    log_msg "✅ Successfully re-established Wi-Fi connection"
                    sleep 10
                    continue
                else
                    log_msg "❌ Reconnection failed, will retry in $REFRESH_INTERVAL seconds"
                    sleep "${REFRESH_INTERVAL}"
                    continue
                fi
            elif [[ -z "$ip_addr" ]]; then
                log_msg "🔧 Connected but no IP address, attempting IP recovery..."
                # Use the enhanced IP recovery from Fix 1
                nmcli device reapply "$INTERFACE" 2>/dev/null || true
                sleep 5
                
                # Check if IP was recovered
                ip_addr=$(ip addr show "$INTERFACE" | grep 'inet ' | awk '{print $2}' | head -n1)
                if [[ -n "$ip_addr" ]]; then
                    log_msg "✅ IP address recovered: $ip_addr"
                    connection_healthy=true
                fi
            elif [[ "$current_ssid" != "$SSID" ]]; then
                log_msg "🔧 Connected to wrong SSID, reconnecting..."
                if connect_to_wifi_with_roaming "$SSID" "$PASSWORD"; then
                    log_msg "✅ Successfully connected to correct SSID"
                    sleep 10
                    continue
                fi
            fi
        fi
        
        # Only proceed with normal operations if connection is healthy
        if [[ "$connection_healthy" == "true" ]]; then
            # Manage roaming opportunities
            manage_roaming
            
            # Generate realistic traffic (every 30 seconds minimum)
            if [[ $((now - last_traffic_time)) -gt 30 ]]; then
                if generate_realistic_traffic; then
                    last_traffic_time=$now
                fi
            fi
            
            # Display current connection info
            CURRENT_BSSID=$(get_current_bssid)
            if [[ -n "$CURRENT_BSSID" ]]; then
                local signal="${BSSID_SIGNALS[$CURRENT_BSSID]:-unknown}"
                log_msg "📡 Current: BSSID $CURRENT_BSSID (${signal}dBm) | Available BSSIDs: ${#DISCOVERED_BSSIDS[@]}"
            fi
            
            log_msg "✅ Good Wi-Fi client with roaming operating normally"
        fi

        sleep "${REFRESH_INTERVAL}"
    done
}

# --- Initialization ---
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
log_msg "🌟 Enhanced Wi-Fi Good Client with Roaming Starting..."
log_msg "Interface: $INTERFACE, Hostname: $HOSTNAME"
log_msg "Roaming Configuration:"
log_msg "  - Enabled: $ROAMING_ENABLED"
log_msg "  - Roaming Interval: ${ROAMING_INTERVAL}s"
log_msg "  - BSSID Scan Interval: ${ROAMING_SCAN_INTERVAL}s"
log_msg "  - Min Signal Threshold: ${MIN_SIGNAL_THRESHOLD}dBm"

# Initial config read
read_wifi_config || true

# Start main loop
main_loop