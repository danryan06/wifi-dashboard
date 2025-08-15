#!/usr/bin/env bash
set -euo pipefail

# Wi-Fi Good Client Simulation
# Connects to Wi-Fi network successfully and generates normal traffic

INTERFACE="wlan0"
HOSTNAME="CNXNMist-WiFiGood"
LOG_FILE="/home/pi/wifi_test_dashboard/logs/wifi-good.log"
CONFIG_FILE="/home/pi/wifi_test_dashboard/configs/ssid.conf"
SETTINGS="/home/pi/wifi_test_dashboard/configs/settings.conf"

# Source settings if available
[[ -f "$SETTINGS" ]] && source "$SETTINGS" || true

# Make sure tools installed in user space are on PATH when run via systemd
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# Override with environment variables if set
INTERFACE="${WIFI_GOOD_INTERFACE:-$INTERFACE}"
HOSTNAME="${WIFI_GOOD_HOSTNAME:-$HOSTNAME}"
REFRESH_INTERVAL="${WIFI_GOOD_REFRESH_INTERVAL:-60}"
CONNECTION_TIMEOUT="${WIFI_CONNECTION_TIMEOUT:-30}"
MAX_RETRIES="${WIFI_MAX_RETRY_ATTEMPTS:-3}"

# Test URLs for connectivity testing
TEST_URLS=(
    "https://www.google.com"
    "https://www.cloudflare.com"
    "https://httpbin.org/ip"
    "https://www.github.com"
)

log_msg() {
    echo "[$(date '+%F %T')] WIFI-GOOD: $1" | tee -a "$LOG_FILE"
}

# Read Wi-Fi credentials from config file
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

# Decide if it's time to run a YouTube-like pull
_should_run_youtube_now() {
  # falls back to 600s if not set
  local interval="${YOUTUBE_TRAFFIC_INTERVAL:-600}"
  # disabled if flag isn't true
  [[ "${ENABLE_YOUTUBE_TRAFFIC:-false}" == "true" ]] || return 1

  local stamp="/tmp/.wifi_good_youtube_last"
  local now ts
  now="$(date +%s)"
  if [[ ! -f "$stamp" ]]; then
    echo "$now" > "$stamp"
    return 0
  fi
  ts="$(cat "$stamp" 2>/dev/null || echo 0)"
  if (( now - ts >= interval )); then
    echo "$now" > "$stamp"
    return 0
  fi
  return 1
}

# One-shot stream-like traffic: resolve a direct media URL, then pull bytes via curl
run_youtube_probe_once() {
  local iface="${1:-wlan0}"
  local max_secs="${YOUTUBE_MAX_DURATION:-300}"

  # preflight
  [[ "${ENABLE_YOUTUBE_TRAFFIC:-false}" == "true" ]] || return 0
  command -v yt-dlp >/dev/null 2>&1 || { log_msg "YouTube: yt-dlp not found; skipping"; return 0; }
  [[ -n "${YOUTUBE_PLAYLIST_URL:-}" ]] || { log_msg "YouTube: playlist URL empty; skipping"; return 0; }

  # get a direct media URL (best quality)
  local media_url
  if ! media_url="$(yt-dlp -f best -g "$YOUTUBE_PLAYLIST_URL" 2>/dev/null | head -n1)"; then
    log_msg "YouTube: failed to resolve media URL"
    return 0
  fi
  [[ -n "$media_url" ]] || { log_msg "YouTube: empty media URL"; return 0; }

  log_msg "Starting YouTube-like pull on $iface for ~${max_secs}s"
  timeout "$max_secs" curl -L --interface "$iface" --max-time "$max_secs" \
    --silent --output /dev/null "$media_url" \
    && log_msg "YouTube-like pull completed" \
    || log_msg "YouTube-like pull ended (timeout/err)"
}


# Check if Wi-Fi interface exists and is managed
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
        
        # Trigger a scan to wake up the interface
        nmcli device wifi rescan ifname "$INTERFACE" 2>/dev/null || true
        sleep 2
    fi
    
    local state=$(nmcli device show "$INTERFACE" | grep 'GENERAL.STATE' | awk '{print $2}')
    log_msg "Interface $INTERFACE state: $state"
    
    # State 30 = disconnected but managed (good)
    # State 70 = connected (good)
    # State 20 = unavailable (bad)
    # State 10 = unmanaged (bad)
    if [[ "$state" == "20" || "$state" == "10" ]]; then
        log_msg "⚠ Interface state indicates issues - attempting to fix..."
        
        # Try to reset the interface
        sudo nmcli device set "$INTERFACE" managed no || true
        sleep 2
        sudo nmcli device set "$INTERFACE" managed yes || true
        sleep 3
        
        # Check state again
        state=$(nmcli device show "$INTERFACE" | grep 'GENERAL.STATE' | awk '{print $2}')
        log_msg "Interface $INTERFACE state after reset: $state"
    fi
    
    return 0
}

# FIXED: Connect to Wi-Fi network with interface validation and hostname fix
connect_to_wifi() {
    local ssid="$1"
    local password="$2"
    local connection_name="wifi-good-$ssid"
    
    log_msg "Attempting to connect to Wi-Fi: $ssid (interface: $INTERFACE, hostname: $HOSTNAME)"
    
    # Pre-connection checks for fresh installations
    log_msg "Performing pre-connection checks..."
    
    # Ensure interface is ready
    local state=$(nmcli device show "$INTERFACE" | grep 'GENERAL.STATE' | awk '{print $2}')
    if [[ "$state" == "20" ]]; then  # unavailable
        log_msg "Interface unavailable, waiting for it to become ready..."
        sleep 5
        nmcli device wifi rescan ifname "$INTERFACE" 2>/dev/null || true
        sleep 3
    fi
    
    # Check if target SSID is visible
    log_msg "Scanning for target SSID: $ssid"
    nmcli device wifi rescan ifname "$INTERFACE" 2>/dev/null || true
    sleep 3
    
    if ! nmcli device wifi list ifname "$INTERFACE" | grep -q "$ssid"; then
        log_msg "⚠ Target SSID '$ssid' not visible in scan, but continuing anyway..."
    else
        log_msg "✓ Target SSID '$ssid' is visible"
    fi
    
    # CRITICAL FIX: Clean up any existing connections to avoid interface conflicts
    log_msg "Cleaning up any existing connection profiles for $ssid..."
    nmcli connection delete "$connection_name" 2>/dev/null || true
    
    # CRITICAL FIX: Ensure we're creating a WiFi connection with explicit interface binding
    log_msg "Creating new Wi-Fi connection profile '$connection_name'..."
    if nmcli connection add \
        type wifi \
        con-name "$connection_name" \
        ifname "$INTERFACE" \
        ssid "$ssid" \
        wifi-sec.key-mgmt wpa-psk \
        wifi-sec.psk "$password" \
        ipv4.method auto \
        ipv6.method auto \
        ipv4.dhcp-hostname "$HOSTNAME" \
        ipv6.dhcp-hostname "$HOSTNAME" \
        connection.autoconnect yes \
        wifi.powersave 2; then
        
        log_msg "✓ Created Wi-Fi connection: $connection_name (interface: $INTERFACE, hostname: $HOSTNAME)"
    else
        log_msg "✗ Failed to create Wi-Fi connection for interface $INTERFACE"
        return 1
    fi
    
    # FIXED: DO NOT change system hostname - use connection-specific hostname only
    # This prevents hostname conflicts between good and bad clients
    log_msg "Using connection-specific hostname: $HOSTNAME (not changing system hostname)"
    
    # Disconnect any existing connections on this interface first
    log_msg "Ensuring clean connection state on $INTERFACE..."
    nmcli device disconnect "$INTERFACE" 2>/dev/null || true
    sleep 2
    
    # Attempt to connect with timeout and explicit interface specification
    log_msg "Connecting to $ssid on $INTERFACE (timeout: ${CONNECTION_TIMEOUT}s)..."
    
    if timeout "$CONNECTION_TIMEOUT" nmcli connection up "$connection_name" ifname "$INTERFACE"; then
        log_msg "✓ Successfully connected to $ssid on $INTERFACE"
        
        # Wait for IP assignment with better error handling
        local wait_count=0
        while [[ $wait_count -lt 15 ]]; do  # Increased wait time
            local ip_addr=$(ip addr show "$INTERFACE" | grep 'inet ' | awk '{print $2}' | head -n1)
            if [[ -n "$ip_addr" ]]; then
                log_msg "✓ IP address assigned: $ip_addr (hostname: $HOSTNAME)"
                
                # Test basic connectivity
                if ping -I "$INTERFACE" -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
                    log_msg "✓ Internet connectivity confirmed on $INTERFACE"
                else
                    log_msg "⚠ No internet connectivity, but connection established on $INTERFACE"
                fi
                
                return 0
            fi
            sleep 2
            ((wait_count++))
        done
        
        log_msg "⚠ Connected but no IP address assigned after 30 seconds"
        return 1
    else
        log_msg "✗ Failed to connect to $ssid on $INTERFACE"
        
        # Check for common error reasons
        log_msg "Checking connection failure details..."
        local connection_status=$(nmcli connection show "$connection_name" 2>/dev/null | grep "GENERAL.STATE" | awk '{print $2}' || echo "unknown")
        log_msg "Connection status: $connection_status"
        
        # CRITICAL: Clean up failed connection to prevent interface conflicts
        log_msg "Cleaning up failed connection profile"
        nmcli connection delete "$connection_name" 2>/dev/null || true
        return 1
    fi
}

# IMPROVED: Test connectivity with better error handling and interface validation
test_connectivity_and_traffic() {
    local success_count=0
    local total_tests=${#TEST_URLS[@]}
    
    log_msg "Testing connectivity through $INTERFACE..."
    
    # First check if interface has IP address
    local ip_addr=$(ip addr show "$INTERFACE" | grep 'inet ' | awk '{print $2}' | head -n1)
    if [[ -z "$ip_addr" ]]; then
        log_msg "✗ No IP address on $INTERFACE - skipping traffic tests"
        return 1
    fi
    
    log_msg "Interface $INTERFACE has IP: $ip_addr - proceeding with traffic tests"
    
    for url in "${TEST_URLS[@]}"; do
        if curl --interface "$INTERFACE" \
               --max-time 15 \
               --connect-timeout 10 \
               --silent \
               --location \
               --output /dev/null \
               "$url" 2>/dev/null; then
            log_msg "✓ Traffic test passed: $url (via $INTERFACE)"
            ((success_count++))
        else
            log_msg "✗ Traffic test failed: $url (via $INTERFACE)"
        fi
        
        # Small delay between tests
        sleep 2
    done
    
    log_msg "Traffic test results: $success_count/$total_tests passed on $INTERFACE"
    
    # Generate additional traffic if we have connectivity
    if [[ $success_count -gt 0 ]]; then
        generate_good_client_traffic
    fi
    
    return $([[ $success_count -gt 0 ]] && echo 0 || echo 1)
}

# Generate typical "good client" traffic patterns with interface validation
generate_good_client_traffic() {
    # Background ping to maintain connection
    {
        if ping -I "$INTERFACE" -c 5 -i 0.5 8.8.8.8 >/dev/null 2>&1; then
            log_msg "✓ Background ping successful on $INTERFACE"
        else
            log_msg "✗ Background ping failed on $INTERFACE"
        fi
    } &
    
    # Simulate web browsing traffic
    {
        local web_urls=(
            "https://httpbin.org/bytes/1024"
            "https://httpbin.org/json" 
            "https://httpbin.org/headers"
        )
        
        for web_url in "${web_urls[@]}"; do
            if curl --interface "$INTERFACE" \
                   --max-time 15 \
                   --silent \
                   --location \
                   --output /dev/null \
                   "$web_url" 2>/dev/null; then
                log_msg "✓ Web traffic: $(basename "$web_url") on $INTERFACE"
            else
                log_msg "✗ Web traffic failed: $(basename "$web_url") on $INTERFACE"
            fi
            sleep 2
        done
    } &
    
    # DNS queries
    {
        local dns_targets=("google.com" "cloudflare.com" "github.com")
        for target in "${dns_targets[@]}"; do
            if nslookup "$target" >/dev/null 2>&1; then
                log_msg "✓ DNS query: $target"
            else
                log_msg "✗ DNS query failed: $target"
            fi
        done
    } &
    
    wait  # Wait for all background traffic to complete
}

# Get detailed connection information with interface validation
get_connection_info() {
    local ip_addr=$(ip addr show "$INTERFACE" | grep 'inet ' | awk '{print $2}' | head -n1)
    local mac_addr=$(ip link show "$INTERFACE" | grep 'link/ether' | awk '{print $2}')
    
    # Get Wi-Fi specific info
    local wifi_info=""
    if command -v iwconfig >/dev/null 2>&1; then
        wifi_info=$(iwconfig "$INTERFACE" 2>/dev/null | grep -E "(ESSID|Frequency|Signal)" | tr '\n' ' ')
    fi
    
    log_msg "Connection Info - Interface: $INTERFACE, IP: ${ip_addr:-none}, MAC: ${mac_addr:-none}"
    [[ -n "$wifi_info" ]] && log_msg "Wi-Fi Info: $wifi_info"
}

# Check if currently connected to the target SSID
is_connected_to_ssid() {
    local target_ssid="$1"
    
    # Get current SSID using NetworkManager
    local current_ssid=$(nmcli -t -f active,ssid dev wifi | grep '^yes' | cut -d':' -f2)
    
    if [[ "$current_ssid" == "$target_ssid" ]]; then
        return 0
    else
        return 1
    fi
}

# UPDATED: Main loop with better connection profile management
main_loop() {
    log_msg "Starting Wi-Fi good client simulation (interface: $INTERFACE, hostname: $HOSTNAME)"
    
    local retry_count=0
    local last_config_check=0
    local consecutive_failures=0
    
    while true; do
        local current_time=$(date +%s)
        
        # Re-read config periodically (every 5 minutes)
        if [[ $((current_time - last_config_check)) -gt 300 ]]; then
            local old_password="$PASSWORD"
            if read_wifi_config; then
                last_config_check=$current_time
                log_msg "Config refreshed"
                
                # If password changed, delete old connection to force recreation
                if [[ "$PASSWORD" != "$old_password" && -n "$old_password" ]]; then
                    log_msg "Password changed, recreating connection profile..."
                    nmcli connection delete "wifi-good-$SSID" 2>/dev/null || true
                fi
            else
                log_msg "⚠ Config read failed, using previous values"
            fi
        fi
        
        if ! check_wifi_interface; then
            log_msg "✗ Wi-Fi interface $INTERFACE check failed"
            sleep $REFRESH_INTERVAL
            continue
        fi
        
        # Check if we're connected to the right network
        if is_connected_to_ssid "$SSID"; then
            log_msg "✓ Connected to target SSID: $SSID on $INTERFACE"
            get_connection_info
            
            # Kick off a periodic YouTube-like transfer if due (optionally tie to intensity)
            if [[ "${WLAN0_TRAFFIC_INTENSITY:-medium}" =~ ^(heavy|max)$ \
            || "${WLAN0_TRAFFIC_TYPE:-all}" =~ (^|,)youtube(,|$) \
            || "${WLAN0_TRAFFIC_TYPE:-all}" =~ (^|,)all(,|$) ]]; then
            if _should_run_youtube_now; then
                log_msg "YouTube-like pull: starting scheduled run on $INTERFACE"
                run_youtube_probe_once "$INTERFACE"
            fi
            fi



            # Test connectivity and generate traffic
            if test_connectivity_and_traffic; then
                retry_count=0
                consecutive_failures=0
                log_msg "✓ Wi-Fi good client operating normally on $INTERFACE"
            else
                ((consecutive_failures++))
                log_msg "✗ Connectivity issues detected on $INTERFACE (failures: $consecutive_failures/$MAX_RETRIES)"
                
                # Only disconnect after multiple failures to avoid unnecessary restarts
                if [[ $consecutive_failures -ge $MAX_RETRIES ]]; then
                    log_msg "Multiple connectivity failures, forcing reconnection on $INTERFACE"
                    # Disconnect but keep the connection profile
                    nmcli device disconnect "$INTERFACE" 2>/dev/null || true
                    sleep 5
                    consecutive_failures=0
                fi
            fi
        else
            log_msg "Not connected to target SSID, attempting connection on $INTERFACE..."
            
            if connect_to_wifi "$SSID" "$PASSWORD"; then
                retry_count=0
                consecutive_failures=0
                log_msg "✓ Successfully established Wi-Fi connection on $INTERFACE"
                sleep 10  # Allow connection to stabilize
            else
                ((retry_count++))
                log_msg "✗ Wi-Fi connection failed on $INTERFACE (attempt $retry_count/$MAX_RETRIES)"
                
                if [[ $retry_count -ge $MAX_RETRIES ]]; then
                    log_msg "Max connection retries reached, waiting longer before retry"
                    # After max retries, consider recreating the connection profile
                    log_msg "Recreating connection profile after max retries..."
                    nmcli connection delete "wifi-good-$SSID" 2>/dev/null || true
                    retry_count=0
                    sleep $((REFRESH_INTERVAL * 2))
                fi
            fi
        fi
        
        sleep $REFRESH_INTERVAL
    done
}

# UPDATED: Cleanup function - only delete on intentional exit
cleanup_and_exit() {
    log_msg "Cleaning up Wi-Fi good client simulation..."
    
    # Disconnect from Wi-Fi but preserve connection profile for next restart
    nmcli device disconnect "$INTERFACE" 2>/dev/null || true
    
    log_msg "Wi-Fi good client simulation stopped"
    exit 0
}

# Signal handlers - safer approach
trap cleanup_and_exit SIGTERM SIGINT

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

# Initial config read
if ! read_wifi_config; then
    log_msg "✗ Failed to read initial configuration, exiting"
    exit 1
fi

# Validate interface assignment
log_msg "Using interface: $INTERFACE for good client simulation"
log_msg "Target hostname: $HOSTNAME"

# Start main loop
main_loop