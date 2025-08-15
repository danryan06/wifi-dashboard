#!/usr/bin/env bash
set -euo pipefail

# Wired Ethernet Client Simulation
# Simulates a heavy-traffic wired client for network testing

INTERFACE="eth0"
HOSTNAME="CNXNMist-Wired"
CONNECTION_NAME="wired-cnxnmist"
LOG_FILE="/home/pi/wifi_test_dashboard/logs/wired.log"
SETTINGS="/home/pi/wifi_test_dashboard/configs/settings.conf"

# Source settings if available
[[ -f "$SETTINGS" ]] && source "$SETTINGS" || true

# Override with environment variables if set
INTERFACE="${WIRED_INTERFACE:-$INTERFACE}"
HOSTNAME="${WIRED_HOSTNAME:-$HOSTNAME}"
CONNECTION_NAME="${WIRED_CONNECTION_NAME:-$CONNECTION_NAME}"
REFRESH_INTERVAL="${WIRED_REFRESH_INTERVAL:-30}"

# Test URLs for connectivity testing
TEST_URLS=(
    "https://www.google.com"
    "https://www.cloudflare.com" 
    "https://www.github.com"
    "https://www.juniper.net"
    "https://httpbin.org/ip"
)

log_msg() {
    echo "[$(date '+%F %T')] WIRED: $1" | tee -a "$LOG_FILE"
}

# Check if ethernet interface exists and is available
check_ethernet_interface() {
    if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
        log_msg "✗ Ethernet interface $INTERFACE not found"
        return 1
    fi
    
    if ip link show "$INTERFACE" | grep -q "state UP"; then
        log_msg "✓ Ethernet interface $INTERFACE is UP"
        return 0
    else
        log_msg "⚠ Ethernet interface $INTERFACE is DOWN"
        return 1
    fi
}

# Configure ethernet connection with specific hostname
setup_wired_connection() {
    log_msg "Setting up wired connection with hostname: $HOSTNAME"
    
    # Remove existing connection if it exists
    nmcli connection delete "$CONNECTION_NAME" 2>/dev/null || true
    
    # Create new ethernet connection with our hostname
    if nmcli connection add \
        type ethernet \
        con-name "$CONNECTION_NAME" \
        ifname "$INTERFACE" \
        ipv4.method auto \
        ipv6.method auto \
        connection.id "$CONNECTION_NAME" \
        802-3-ethernet.auto-negotiate yes; then
        
        log_msg "✓ Created ethernet connection: $CONNECTION_NAME"
        
        # Set hostname for DHCP
        if command -v hostnamectl >/dev/null 2>&1; then
            sudo hostnamectl set-hostname "$HOSTNAME" || log_msg "⚠ Failed to set system hostname"
        fi
        
        # Activate the connection
        if nmcli connection up "$CONNECTION_NAME"; then
            log_msg "✓ Activated ethernet connection"
            return 0
        else
            log_msg "✗ Failed to activate ethernet connection"
            return 1
        fi
    else
        log_msg "✗ Failed to create ethernet connection"
        return 1
    fi
}

# Test connectivity through ethernet interface
test_ethernet_connectivity() {
    local success_count=0
    local total_tests=${#TEST_URLS[@]}
    
    log_msg "Testing connectivity through $INTERFACE..."
    
    for url in "${TEST_URLS[@]}"; do
        if curl --interface "$INTERFACE" \
               --max-time 10 \
               --silent \
               --location \
               --output /dev/null \
               "$url" 2>/dev/null; then
            log_msg "✓ Connectivity test passed: $url"
            ((success_count++))
        else
            log_msg "✗ Connectivity test failed: $url"
        fi
    done
    
    log_msg "Connectivity results: $success_count/$total_tests tests passed"
    
    if [[ $success_count -gt 0 ]]; then
        return 0
    else
        return 1
    fi
}

# Generate heavy traffic through ethernet interface
generate_ethernet_traffic() {
    log_msg "Starting heavy traffic generation on $INTERFACE"
    
    # Start background ping to maintain connectivity
    {
        while true; do
            if ping -I "$INTERFACE" -c 5 -i 0.2 8.8.8.8 >/dev/null 2>&1; then
                log_msg "Ping traffic: ✓ Connectivity maintained"
            else
                log_msg "Ping traffic: ✗ Connectivity lost"
            fi
            sleep 30
        done
    } &
    PING_PID=$!
    
    # Start background download traffic
    {
        local download_urls=(
            "https://proof.ovh.net/files/100Mb.dat"
            "https://speed.hetzner.de/100MB.bin"
            "http://ipv4.download.thinkbroadband.com/50MB.zip"
        )
        
        while true; do
            for url in "${download_urls[@]}"; do
                {
                    log_msg "Download traffic: Starting $(basename "$url")"
                    if curl --interface "$INTERFACE" \
                           --max-time 120 \
                           --range "0-52428800" \
                           --silent \
                           --location \
                           --output /dev/null \
                           "$url" 2>/dev/null; then
                        log_msg "Download traffic: ✓ Completed $(basename "$url")"
                    else
                        log_msg "Download traffic: ✗ Failed $(basename "$url")"
                    fi
                } &
            done
            
            # Wait for downloads to complete
            wait
            sleep 60
        done
    } &
    DOWNLOAD_PID=$!
    
    # Start speedtest traffic if available
    if command -v speedtest >/dev/null 2>&1 || command -v speedtest-cli >/dev/null 2>&1; then
        {
            while true; do
                log_msg "Speedtest traffic: Starting test"
                
                local speedtest_cmd=""
                if command -v speedtest >/dev/null 2>&1; then
                    speedtest_cmd="speedtest --accept-license --accept-gdpr --interface-name=$INTERFACE"
                elif command -v speedtest-cli >/dev/null 2>&1; then
                    local ip_addr=$(ip addr show "$INTERFACE" | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | head -n1)
                    [[ -n "$ip_addr" ]] && speedtest_cmd="speedtest-cli --source $ip_addr"
                fi
                
                if [[ -n "$speedtest_cmd" ]] && timeout 120 $speedtest_cmd >/dev/null 2>&1; then
                    log_msg "Speedtest traffic: ✓ Test completed"
                else
                    log_msg "Speedtest traffic: ✗ Test failed"
                fi
                
                sleep 300  # 5 minutes between speedtests
            done
        } &
        SPEEDTEST_PID=$!
    fi
    
    log_msg "✓ Heavy traffic generation started (PIDs: ping=$PING_PID, download=$DOWNLOAD_PID, speedtest=${SPEEDTEST_PID:-none})"
}

# Get interface information
get_interface_info() {
    local ip_addr=$(ip addr show "$INTERFACE" | grep 'inet ' | awk '{print $2}' | head -n1)
    local mac_addr=$(ip link show "$INTERFACE" | grep 'link/ether' | awk '{print $2}')
    local status=$(ip link show "$INTERFACE" | grep -o "state [A-Z]*" | awk '{print $2}')
    
    log_msg "Interface Info - IP: ${ip_addr:-none}, MAC: ${mac_addr:-none}, Status: ${status:-unknown}"
}

# Main monitoring loop
main_loop() {
    log_msg "Starting wired client simulation (interface: $INTERFACE, hostname: $HOSTNAME)"
    
    local consecutive_failures=0
    local traffic_started=false
    
    while true; do
        if check_ethernet_interface; then
            get_interface_info
            
            # Setup connection if needed
            if ! nmcli connection show --active | grep -q "$CONNECTION_NAME"; then
                log_msg "Connection not active, setting up..."
                if setup_wired_connection; then
                    sleep 10  # Wait for DHCP
                else
                    log_msg "✗ Failed to setup connection, retrying in $REFRESH_INTERVAL seconds"
                    sleep $REFRESH_INTERVAL
                    continue
                fi
            fi
            
            # Test connectivity
            if test_ethernet_connectivity; then
                consecutive_failures=0
                
                # Start traffic generation if not already started
                if [[ "$traffic_started" != "true" ]]; then
                    generate_ethernet_traffic
                    traffic_started=true
                fi
                
                log_msg "✓ Wired client running normally"
            else
                ((consecutive_failures++))
                log_msg "✗ Connectivity test failed (failures: $consecutive_failures)"
                
                if [[ $consecutive_failures -ge 3 ]]; then
                    log_msg "Multiple connectivity failures, resetting connection..."
                    nmcli connection down "$CONNECTION_NAME" 2>/dev/null || true
                    sleep 5
                    consecutive_failures=0
                    traffic_started=false
                fi
            fi
        else
            log_msg "✗ Ethernet interface not available"
            traffic_started=false
        fi
        
        sleep $REFRESH_INTERVAL
    done
}

# Cleanup function
cleanup_and_exit() {
    log_msg "Cleaning up wired client simulation..."
    
    # Kill background processes
    [[ -n "${PING_PID:-}" ]] && kill "$PING_PID" 2>/dev/null || true
    [[ -n "${DOWNLOAD_PID:-}" ]] && kill "$DOWNLOAD_PID" 2>/dev/null || true
    [[ -n "${SPEEDTEST_PID:-}" ]] && kill "$SPEEDTEST_PID" 2>/dev/null || true
    
    log_msg "Wired client simulation stopped"
    exit 0
}

# Signal handlers
trap cleanup_and_exit SIGTERM SIGINT EXIT

# Start main loop
main_loop