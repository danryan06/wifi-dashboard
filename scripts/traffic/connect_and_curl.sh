#!/usr/bin/env bash
set -euo pipefail

# Enhanced Wi-Fi Good Client Simulation
# Complete good client behavior: Authentication + Connection + Realistic Traffic Generation
# This represents a real user's device that successfully connects and uses the network

INTERFACE="wlan0"
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

TRAFFIC_GEN="/home/pi/wifi_test_dashboard/scripts/traffic/interface_traffic_generator.sh"


# Basic rotation function if utils not available
rotate_basic() {
    if command -v rotate_log >/dev/null 2>&1; then
        rotate_log "$LOG_FILE" "${LOG_MAX_BYTES:-5}"
        return 0
    fi

    local max_mb="${LOG_MAX_BYTES:-5}"
    local size_bytes=0

    if [[ -f "$LOG_FILE" ]]; then
        size_bytes=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE")
        if (( size_bytes >= max_mb * 1024 * 1024 )); then
            mv -f "$LOG_FILE" "$LOG_FILE.$(date +%s).1"
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

# --- Load settings and overrides ---
[[ -f "$SETTINGS" ]] && source "$SETTINGS" || true

INTERFACE="${WIFI_GOOD_INTERFACE:-$INTERFACE}"
HOSTNAME="${WIFI_GOOD_HOSTNAME:-$HOSTNAME}"
REFRESH_INTERVAL="${WIFI_GOOD_REFRESH_INTERVAL:-60}"
CONNECTION_TIMEOUT="${WIFI_CONNECTION_TIMEOUT:-30}"
MAX_RETRIES="${WIFI_MAX_RETRY_ATTEMPTS:-3}"

# Traffic generation settings
TRAFFIC_INTENSITY="${WLAN0_TRAFFIC_INTENSITY:-medium}"
ENABLE_INTEGRATED_TRAFFIC="${WIFI_GOOD_INTEGRATED_TRAFFIC:-true}"

# Traffic intensity configurations
case "$TRAFFIC_INTENSITY" in
    heavy)   
        DL_SIZE=104857600    # 100MB downloads
        PING_COUNT=20        # 20 pings per test
        SPEEDTEST_INTERVAL=300   # Every 5 minutes
        DOWNLOAD_INTERVAL=60     # Every minute
        YOUTUBE_INTERVAL=300     # Every 5 minutes
        CONCURRENT_DOWNLOADS=5   # 5 simultaneous downloads
        ;;
    medium)  
        DL_SIZE=52428800     # 50MB downloads
        PING_COUNT=10        # 10 pings per test
        SPEEDTEST_INTERVAL=600   # Every 10 minutes
        DOWNLOAD_INTERVAL=120    # Every 2 minutes
        YOUTUBE_INTERVAL=600     # Every 10 minutes
        CONCURRENT_DOWNLOADS=3   # 3 simultaneous downloads
        ;;
    light|*) 
        DL_SIZE=10485760     # 10MB downloads
        PING_COUNT=5         # 5 pings per test
        SPEEDTEST_INTERVAL=1200  # Every 20 minutes
        DOWNLOAD_INTERVAL=300    # Every 5 minutes
        YOUTUBE_INTERVAL=900     # Every 15 minutes
        CONCURRENT_DOWNLOADS=2   # 2 simultaneous downloads
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
    "https://proof.ovh.net/files/1Gb.dat"
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
    state="$(nmcli -t -f GENERAL.STATE device show "$INTERFACE" 2>/dev/null | cut -d: -f2 | awk '{print $1}')"
    state="${state:-unknown}"
    log_msg "Interface $INTERFACE state: $state"

    return 0
}

# --- Connection management ---
connect_to_wifi() {
    local ssid="$1"
    local password="$2"
    local connection_name="wifi-good-$ssid"

    log_msg "Attempting to connect to Wi-Fi: $ssid (interface: $INTERFACE, hostname: $HOSTNAME)"

    # Clean up any existing connection profiles for this SSID
    nmcli -t -f NAME,TYPE connection show 2>/dev/null | \
      awk -F: '$2=="wifi"{print $1}' | \
      while read -r conn; do
        if [[ -n "$conn" ]]; then
            local c_ssid
            c_ssid="$(nmcli -t -f 802-11-wireless.ssid connection show "$conn" 2>/dev/null | cut -d: -f2)"
            [[ "$c_ssid" == "$ssid" ]] && nmcli connection delete "$conn" 2>/dev/null || true
        fi
      done

    # Create connection profile
    if nmcli connection add \
        type wifi \
        con-name "$connection_name" \
        ifname "$INTERFACE" \
        ssid "$ssid" \
        wifi-sec.key-mgmt wpa-psk \
        wifi-sec.psk "$password" \
        ipv4.method auto \
        ipv6.method auto >/dev/null 2>&1; then
        log_msg "✓ Created Wi-Fi connection: $connection_name"
    else
        log_msg "✗ Failed to create connection profile"
        return 1
    fi

    # Ensure clean connection state
    nmcli device disconnect "$INTERFACE" 2>/dev/null || true
    sleep 3

    # Attempt to connect
    if timeout "$CONNECTION_TIMEOUT" nmcli connection up "$connection_name" >/dev/null 2>&1; then
        log_msg "✓ Successfully connected to $ssid on $INTERFACE"
        
        # Wait for IP assignment
        local wait_count=0
        while [[ $wait_count -lt 10 ]]; do
            local ip_addr=$(ip addr show "$INTERFACE" | grep 'inet ' | awk '{print $2}' | head -n1)
            if [[ -n "$ip_addr" ]]; then
                log_msg "✓ IP address assigned: $ip_addr"
                return 0
            fi
            sleep 2
            ((wait_count++))
        done
        
        log_msg "⚠ Connected but no IP address assigned"
        return 1
    else
        log_msg "✗ Failed to connect to $ssid on $INTERFACE"
        nmcli connection delete "$connection_name" 2>/dev/null || true
        return 1
    fi
}

# --- Traffic generation functions ---

# Basic connectivity tests
test_basic_connectivity() {
    log_msg "Testing basic connectivity on $INTERFACE..."
    local success_count=0
    
    for url in "${TEST_URLS[@]}"; do
        if curl --interface "$INTERFACE" --max-time "${CURL_TIMEOUT:-10}" -fsSL -o /dev/null "$url"; then
            log_msg "✓ Connectivity test passed: $url"
            ((success_count++))
        else
            log_msg "✗ Connectivity test failed: $url"
        fi
        sleep 1
    done
    
    log_msg "Basic connectivity: $success_count/${#TEST_URLS[@]} tests passed"
    return $([[ $success_count -gt 0 ]] && echo 0 || echo 1)
}

# Ping traffic generation
generate_ping_traffic() {
    log_msg "Generating ping traffic (${PING_COUNT} pings per target)..."
    
    for target in "${PING_TARGETS[@]}"; do
        if ping -I "$INTERFACE" -c "$PING_COUNT" -i 0.5 "$target" >/dev/null 2>&1; then
            log_msg "✓ Ping successful: $target"
        else
            log_msg "✗ Ping failed: $target"
        fi
    done
}

# HTTP download traffic
generate_download_traffic() {
    log_msg "Starting download traffic (${CONCURRENT_DOWNLOADS} concurrent, ${DL_SIZE} bytes each)..."
    
    local pids=()
    local completed=0
    
    # Start concurrent downloads
    for ((i=0; i<CONCURRENT_DOWNLOADS; i++)); do
        {
            local url="${DOWNLOAD_URLS[$((RANDOM % ${#DOWNLOAD_URLS[@]}))]}"
            local start_time=$(date +%s)
            
            if curl --interface "$INTERFACE" \
                   --max-time 180 \
                   --range "0-$DL_SIZE" \
                   --silent \
                   --location \
                   --output /dev/null \
                   "$url"; then
                local end_time=$(date +%s)
                local duration=$((end_time - start_time))
                log_msg "✓ Download completed: $(basename "$url") (${duration}s)"
            else
                log_msg "✗ Download failed: $(basename "$url")"
            fi
        } &
        pids+=($!)
    done
    
    # Wait for downloads to complete
    for pid in "${pids[@]}"; do
        if wait "$pid"; then
            ((completed++))
        fi
    done
    
    log_msg "Download traffic completed: $completed/$CONCURRENT_DOWNLOADS successful"
}

# Speedtest traffic
generate_speedtest_traffic() {
    log_msg "Running speedtest on $INTERFACE..."
    
    local speedtest_cmd=""
    if command -v speedtest >/dev/null 2>&1; then
        speedtest_cmd="speedtest --accept-license --accept-gdpr --interface-name=$INTERFACE"
    elif command -v speedtest-cli >/dev/null 2>&1; then
        local ip_addr=$(ip addr show "$INTERFACE" | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | head -n1)
        [[ -n "$ip_addr" ]] && speedtest_cmd="speedtest-cli --source $ip_addr"
    fi
    
    if [[ -n "$speedtest_cmd" ]]; then
        if timeout 120 $speedtest_cmd >/dev/null 2>&1; then
            log_msg "✓ Speedtest completed successfully"
        else
            log_msg "✗ Speedtest failed or timed out"
        fi
    else
        log_msg "⚠ No speedtest tool available"
    fi
}

# YouTube-like traffic simulation
generate_youtube_traffic() {
    [[ "${ENABLE_YOUTUBE_TRAFFIC:-false}" == "true" ]] || return 0
    
    local stamp="/tmp/wifi_good_youtube.last"
    local now epoch_last
    now="$(date +%s)"
    epoch_last=0
    [[ -f "$stamp" ]] && epoch_last="$(cat "$stamp" 2>/dev/null || echo 0)"
    
    if (( now - epoch_last < YOUTUBE_INTERVAL )); then
        return 0
    fi
    echo "$now" > "$stamp"
    
    log_msg "Generating YouTube-like traffic on $INTERFACE..."
    
    local playlist="${YOUTUBE_PLAYLIST_URL:-}"
    if [[ -z "$playlist" ]] || ! command -v yt-dlp >/dev/null 2>&1; then
        log_msg "YouTube traffic: playlist URL not set or yt-dlp not available"
        return 0
    fi
    
    # Simulate video streaming by downloading a portion
    local video_url
    video_url="$(yt-dlp --flat-playlist -j "$playlist" 2>/dev/null | head -n1 | python3 -c "
import sys, json
try:
    d=json.load(sys.stdin)
    print('https://www.youtube.com/watch?v=' + d.get('id', ''))
except:
    pass
")"
    
    if [[ -n "$video_url" ]]; then
        # Get media URL and stream some data
        local media_url
        media_url="$(yt-dlp -f 'worst[height<=360]' -g "$video_url" 2>/dev/null | head -n1)"
        
        if [[ -n "$media_url" ]]; then
            local duration="${YOUTUBE_MAX_DURATION:-300}"
            timeout "$duration" curl --interface "$INTERFACE" --max-time "$((duration+5))" -fsSL "$media_url" -o /dev/null 2>/dev/null || true
            log_msg "✓ YouTube-like traffic completed (~${duration}s)"
        fi
    fi
}

# Web browsing simulation
generate_web_browsing_traffic() {
    log_msg "Simulating web browsing patterns..."
    
    local web_patterns=(
        "https://httpbin.org/bytes/1024"
        "https://httpbin.org/json" 
        "https://httpbin.org/headers"
        "https://httpbin.org/user-agent"
        "https://httpbin.org/ip"
    )
    
    for pattern in "${web_patterns[@]}"; do
        if curl --interface "$INTERFACE" --max-time 15 --silent --location --output /dev/null "$pattern" 2>/dev/null; then
            log_msg "✓ Web browsing: $(basename "$pattern")"
        else
            log_msg "✗ Web browsing failed: $(basename "$pattern")"
        fi
        sleep $((RANDOM % 3 + 1))  # Random delay 1-3 seconds
    done
}

# DNS activity simulation
generate_dns_activity() {
    log_msg "Generating DNS queries..."
    
    local dns_targets=("google.com" "cloudflare.com" "github.com" "example.com" "stackoverflow.com")
    for target in "${dns_targets[@]}"; do
        if nslookup "$target" >/dev/null 2>&1; then
            log_msg "✓ DNS query: $target"
        else
            log_msg "✗ DNS query failed: $target"
        fi
    done
}

# Main traffic generation orchestrator
generate_realistic_traffic() {
    if [[ "$ENABLE_INTEGRATED_TRAFFIC" != "true" ]]; then
        log_msg "Integrated traffic generation disabled"
        return 0
    fi
    
    log_msg "Starting realistic traffic generation (intensity: $TRAFFIC_INTENSITY)..."
    
    # Always do basic connectivity and web browsing
    test_basic_connectivity
    generate_web_browsing_traffic
    generate_dns_activity
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
    
    # Check if it's time for speedtest
    local speedtest_stamp="/tmp/wifi_good_speedtest.last"
    local last_speedtest=0
    [[ -f "$speedtest_stamp" ]] && last_speedtest="$(cat "$speedtest_stamp" 2>/dev/null || echo 0)"
    
    if (( current_time - last_speedtest >= SPEEDTEST_INTERVAL )); then
        generate_speedtest_traffic
        echo "$current_time" > "$speedtest_stamp"
    fi
    
    # YouTube traffic (if enabled)
    generate_youtube_traffic
    
    log_msg "✓ Realistic traffic generation cycle completed"
}

# --- Connection info display ---
display_connection_info() {
    local ip_addr
    ip_addr="$(ip -o -4 addr show "$INTERFACE" 2>/dev/null | awk '{print $4}' | head -n1)"
    local mac
    mac="$(cat /sys/class/net/"$INTERFACE"/address 2>/dev/null || echo "unknown")"
    log_msg "Connection Info - Interface: $INTERFACE, IP: ${ip_addr:-unknown}, MAC: $mac"

    if command -v iwconfig >/dev/null 2>&1; then
        local wi
        wi="$(iwconfig "$INTERFACE" 2>/dev/null | tr -s ' ' | sed 's/[[:space:]]\{1,\}/ /g')"
        if [[ -n "$wi" ]]; then
            log_msg "Wi-Fi Info: ${wi}"
        fi
    fi
}

# --- Main loop ---
main_loop() {
    log_msg "Starting enhanced Wi-Fi good client simulation"
    log_msg "Interface: $INTERFACE, Hostname: $HOSTNAME, Traffic: $TRAFFIC_INTENSITY"
    log_msg "Integrated traffic generation: $ENABLE_INTEGRATED_TRAFFIC"

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

        # Check connection status
        local state
        state="$(nmcli -t -f GENERAL.STATE device show "$INTERFACE" 2>/dev/null | cut -d: -f2 | awk '{print $1}')"
        
        if [[ "$state" != "100" ]]; then
            log_msg "Not connected to target SSID, attempting connection on $INTERFACE..."
            if connect_to_wifi "$SSID" "$PASSWORD"; then
                display_connection_info
                log_msg "✓ Successfully established Wi-Fi connection"
                sleep 10  # Allow connection to stabilize
            else
                sleep "${REFRESH_INTERVAL}"
                continue
            fi
        fi

        # Verify we're connected to the right SSID
        local current_ssid
        current_ssid="$(nmcli -t -f active,ssid dev wifi | grep '^yes' | cut -d':' -f2 || echo "")"
        
        if [[ "$current_ssid" == "$SSID" ]]; then
            log_msg "✓ Connected to target SSID: $SSID on $INTERFACE"
            
            # Generate realistic traffic
            if [[ $((now - last_traffic_time)) -gt 30 ]]; then  # Traffic every 30 seconds minimum
                generate_realistic_traffic
                last_traffic_time=$now
            fi
            
            log_msg "✓ Good Wi-Fi client operating normally on $INTERFACE"
        else
            log_msg "⚠ Connected to wrong SSID: '$current_ssid', expected: '$SSID'"
        fi
        run_heavy_traffic_once
        
        sleep "${REFRESH_INTERVAL}"
    done
}

run_heavy_traffic_once() {
  # Intensity from installer’s settings (install.sh writes WIFI_GOOD_TRAFFIC_INTENSITY)
  local intensity="${WIFI_GOOD_TRAFFIC_INTENSITY:-medium}"

  if [[ -x "$TRAFFIC_GEN" ]]; then
    # Write the generator’s messages into wifi-good.log (not traffic-wlan0.log)
    TRAFFIC_LOG_FILE="$LOG_FILE" \
    TRAFFIC_INTENSITY_OVERRIDE="$intensity" \
    "$TRAFFIC_GEN" "$INTERFACE" once || true
  else
    log_msg "traffic helper not found at $TRAFFIC_GEN"
  fi
}

# --- Initialization ---
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
log_msg "Enhanced Wi-Fi Good Client starting..."
log_msg "Using interface: $INTERFACE for complete good client simulation"
log_msg "Target hostname: $HOSTNAME"
log_msg "Traffic intensity: $TRAFFIC_INTENSITY"

# Initial config read
read_wifi_config || true

# Start main loop
main_loop