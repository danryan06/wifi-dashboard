#!/usr/bin/env bash
set -euo pipefail

# Wi-Fi Good Client Simulation
# Connects to Wi-Fi network successfully and generates normal traffic

INTERFACE="wlan0"
HOSTNAME="CNXNMist-WiFiGood"
LOG_FILE="$HOME/wifi_test_dashboard/logs/wifi-good.log"
CONFIG_FILE="$HOME/wifi_test_dashboard/configs/ssid.conf"
SETTINGS="$HOME/wifi_test_dashboard/configs/settings.conf"

# Source settings if available
[[ -f "$SETTINGS" ]] && source "$SETTINGS" || true

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

# Check if Wi-Fi interface exists and is managed
check_wifi_interface() {
    if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
        log_msg "✗ Wi-Fi interface $INTERFACE not found"
        return 1
    fi
    
    # Ensure NetworkManager manages this interface
    if ! nmcli device show "$INTERFACE" >/dev/null 2>&1; then
        log_msg "Setting $INTERFACE to managed mode"
        sudo nmcli device set "$INTERFACE" managed yes || true
        sleep 2
    fi
    
    local state=$(nmcli device show "$INTERFACE" | grep 'GENERAL.STATE' | awk '{print $2}')
    log_msg "Interface $INTERFACE state: $state"
    
    return 0
}

# Connect to Wi-Fi network
connect_to_wifi() {
    local ssid="$1"
    local password="$2"
    local connection_name="wifi-good-$ssid"
    
    log_msg "Attempting to connect to Wi-Fi: $ssid"
    
    # Remove any existing connection with the same name
    nmcli connection delete "$connection_name" 2>/dev/null || true
    
    # Create new Wi-Fi connection
    if nmcli connection add \
        type wifi \
        con-name "$connection_name" \
        ifname "$INTERFACE" \
        ssid "$ssid" \
        wifi-sec.key-mgmt wpa-psk \
        wifi-sec.psk "$password" \
        ipv4.method auto \
        ipv6.method auto; then
        
        log_msg "✓ Created Wi-Fi connection: $connection_name"
    else
        log_msg "✗ Failed to create Wi-Fi connection"
        return 1
    fi
    
    # Set hostname for DHCP identification
    if command -v hostnamectl >/dev/null 2>&1; then
        sudo hostnamectl set-hostname "$HOSTNAME" 2>/dev/null || true
    fi
    
    # Attempt to connect with timeout
    log_msg "Connecting to $ssid (timeout: ${CONNECTION_TIMEOUT}s)..."
    
    if timeout "$CONNECTION_TIMEOUT" nmcli connection up "$connection_name"; then
        log_msg "✓ Successfully connected to $ssid"
        
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
        log_msg "✗ Failed to connect to $ssid"
        nmcli connection delete "$connection_name" 2>/dev/null || true
        return 1
    fi
}

# Test connectivity and generate traffic
test_connectivity_and_traffic() {
    local success_count=0
    local total_tests=${#TEST_URLS[@]}
    
    log_msg "Testing connectivity and generating traffic..."
    
    for url in "${TEST_URLS[@]}"; do
        if curl --interface "$INTERFACE" \
               --max-time 10 \
               --silent \
               --location \
               --output /dev/null \
               "$url" 2>/dev/null; then
            log_msg "✓ Traffic test passed: $url"
            ((success_count++))
        else
            log_msg "✗ Traffic test failed: $url"
        fi
        
        # Small delay between tests
        sleep 1
    done
    
    log_msg "Traffic test results: $success_count/$total_tests passed"
    
    # Additional traffic patterns for good client
    generate_good_client_traffic
    
    return $([[ $success_count -gt 0 ]] && echo 0 || echo 1)
}

# Generate typical "good client" traffic patterns
generate_good_client_traffic() {
    # Background ping to maintain connection
    {
        ping -I "$INTERFACE" -c 5 -i 0.5 8.8.8.8 >/dev/null 2>&1 && \
        log_msg "✓ Background ping successful"
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
                log_msg "✓ Web traffic: $(basename "$web_url")"
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
            fi
        done
    } &
    
    wait  # Wait for all background traffic to complete
}

# Get detailed connection information
get_connection_info() {
    local ip_addr=$(ip addr show "$INTERFACE" | grep 'inet ' | awk '{print $2}' | head -n1)
    local mac_addr=$(ip link show "$INTERFACE" | grep 'link/ether' | awk '{print $2}')
    
    # Get Wi-Fi specific info
    local wifi_info=""
    if command -v iwconfig >/dev/null 2>&1; then
        wifi_info=$(iwconfig "$INTERFACE" 2>/dev/null | grep -E "(ESSID|Frequency|Signal)" | tr '\n' ' ')
    fi
    
    log_msg "Connection Info - IP: ${ip_addr:-none}, MAC: ${mac_addr:-none}"
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

# Main monitoring and connection loop
main_loop() {
    log_msg "Starting Wi-Fi good client simulation (interface: $INTERFACE, hostname: $HOSTNAME)"
    
    local retry_count=0
    local last_config_check=0
    
    while true; do
        local current_time=$(date +%s)
        
        # Re-read config periodically (every 5 minutes)
        if [[ $((current_time - last_config_check)) -gt 300 ]]; then
            if read_wifi_config; then
                last_config_check=$current_time
                log_msg "Config refreshed"
            else
                log_msg "⚠ Config read failed, using previous values"
            fi
        fi
        
        if ! check_wifi_interface; then
            log_msg "✗ Wi-Fi interface check failed"
            sleep $REFRESH_INTERVAL
            continue
        fi
        
        # Check if we're connected to the right network
        if is_connected_to_ssid "$SSID"; then
            log_msg "✓ Connected to target SSID: $SSID"
            get_connection_info
            
            # Test connectivity and generate traffic
            if test_connectivity_and_traffic; then
                retry_count=0
                log_msg "✓ Wi-Fi good client operating normally"
            else
                ((retry_count++))
                log_msg "✗ Connectivity issues detected (attempt $retry_count/$MAX_RETRIES)"
                
                if [[ $retry_count -ge $MAX_RETRIES ]]; then
                    log_msg "Max retries reached, forcing reconnection"
                    # Disconnect and reconnect
                    nmcli device disconnect "$INTERFACE" 2>/dev/null || true
                    sleep 5
                    retry_count=0
                fi
            fi
        else
            log_msg "Not connected to target SSID, attempting connection..."
            
            if connect_to_wifi "$SSID" "$PASSWORD"; then
                retry_count=0
                log_msg "✓ Successfully established Wi-Fi connection"
                sleep 10  # Allow connection to stabilize
            else
                ((retry_count++))
                log_msg "✗ Wi-Fi connection failed (attempt $retry_count/$MAX_RETRIES)"
                
                if [[ $retry_count -ge $MAX_RETRIES ]]; then
                    log_msg "Max connection retries reached, waiting longer before retry"
                    retry_count=0
                    sleep $((REFRESH_INTERVAL * 2))
                fi
            fi
        fi
        
        sleep $REFRESH_INTERVAL
    done
}

# Cleanup function
cleanup_and_exit() {
    log_msg "Cleaning up Wi-Fi good client simulation..."
    
    # Disconnect from Wi-Fi
    nmcli device disconnect "$INTERFACE" 2>/dev/null || true
    
    log_msg "Wi-Fi good client simulation stopped"
    exit 0
}

# Signal handlers
trap cleanup_and_exit SIGTERM SIGINT EXIT

# Initial config read
if ! read_wifi_config; then
    log_msg "✗ Failed to read initial configuration, exiting"
    exit 1
fi

# Start main loop
main_loop