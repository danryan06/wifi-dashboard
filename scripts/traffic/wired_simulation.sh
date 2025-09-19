#!/usr/bin/env bash
set -euo pipefail

# Wired Client Simulation - Simplified and Fixed
# Generates steady traffic on Ethernet interface

INTERFACE="eth0"
HOSTNAME="CNXNMist-Wired"
LOG_FILE="/home/pi/wifi_test_dashboard/logs/wired.log"
SETTINGS="/home/pi/wifi_test_dashboard/configs/settings.conf"
mkdir -p "$DASHBOARD_DIR/stats"
STATS_FILE="$DASHBOARD_DIR/stats/stats_eth0.json"

# Keep service alive on errors
set +e

log_msg() {
    local msg="[$(date '+%F %T')] WIRED: $1"
    echo "$msg" | tee -a "$LOG_FILE"
}

# Create log directory
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

# Load settings
[[ -f "$SETTINGS" ]] && source "$SETTINGS" || true

INTERFACE="${WIRED_INTERFACE:-$INTERFACE}"
HOSTNAME="${WIRED_HOSTNAME:-$HOSTNAME}"
REFRESH_INTERVAL="${WIRED_REFRESH_INTERVAL:-30}"

# Test URLs
TEST_URLS=(
    "https://www.google.com"
    "https://www.cloudflare.com"
    "https://httpbin.org/ip"
    "https://www.github.com"
)

DOWNLOAD_URLS=(
    "https://proof.ovh.net/files/10Mb.dat"
    "https://ash-speed.hetzner.com/10MB.bin"
    "http://ipv4.download.thinkbroadband.com/5MB.zip"
)

PING_TARGETS=("8.8.8.8" "1.1.1.1" "208.67.222.222")

# Check interface
check_interface() {
    if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
        log_msg "✗ Interface $INTERFACE not found"
        return 1
    fi
    
    if ! ip link show "$INTERFACE" | grep -q "state UP"; then
        log_msg "Bringing $INTERFACE up..."
        sudo ip link set "$INTERFACE" up 2>/dev/null || true
        sleep 2
    fi
    
    return 0
}

# Get IP address
get_ip_address() {
    ip -4 addr show dev "$INTERFACE" 2>/dev/null | grep 'inet ' | awk '{print $2}' | head -n1
}

# Basic connectivity tests
test_connectivity() {
    log_msg "Testing connectivity on $INTERFACE"
    local success_count=0
    local total_tests=0
    
    # Ping tests
    for target in "${PING_TARGETS[@]}"; do
        total_tests=$((total_tests + 1))
        if timeout 10 ping -I "$INTERFACE" -c 3 -W 2 "$target" >/dev/null 2>&1; then
            log_msg "✓ Ping successful: $target"
            success_count=$((success_count + 1))
        else
            log_msg "✗ Ping failed: $target"
        fi
    done
    
    # HTTP tests
    for url in "${TEST_URLS[@]}"; do
        total_tests=$((total_tests + 1))
        if timeout 15 curl --interface "$INTERFACE" --max-time 10 -fsSL -o /dev/null "$url" 2>/dev/null; then
            log_msg "✓ HTTP test passed: $url"
            success_count=$((success_count + 1))
        else
            log_msg "✗ HTTP test failed: $url"
        fi
    done
    
    log_msg "Basic connectivity: $success_count/$total_tests tests passed"
    return $([[ $success_count -gt 0 ]] && echo 0 || echo 1)
}

# Generate heavy traffic
generate_heavy_traffic() {
    log_msg "Starting heavy traffic generation"
    
    # Background ping traffic
    {
        for target in "${PING_TARGETS[@]}"; do
            timeout 30 ping -I "$INTERFACE" -c 10 -i 0.5 "$target" >/dev/null 2>&1 && \
            log_msg "✓ Heavy ping completed: $target" || log_msg "✗ Heavy ping failed: $target"
        done
    } &
    
    # Download traffic
    {
        local url="${DOWNLOAD_URLS[0]}"  # Use first URL
        log_msg "Starting download: $(basename "$url")"
        if timeout 120 curl --interface "$INTERFACE" \
               --max-time 90 \
               --silent \
               --location \
               --output /dev/null \
               "$url" 2>/dev/null; then
            log_msg "✓ Download completed: $(basename "$url")"
        else
            log_msg "✗ Download failed: $(basename "$url")"
        fi
    } &
    
    # HTTP traffic
    {
        for url in "${TEST_URLS[@]}"; do
            for i in {1..3}; do
                timeout 15 curl --interface "$INTERFACE" --max-time 10 -s "$url" >/dev/null 2>&1 && \
                log_msg "✓ HTTP traffic $i: $(basename "$url")" || log_msg "✗ HTTP traffic $i failed: $(basename "$url")"
                sleep 1
            done
        done
    } &
    
    # DNS traffic
    {
        local domains=("google.com" "cloudflare.com" "github.com" "juniper.net")
        for domain in "${domains[@]}"; do
            nslookup "$domain" >/dev/null 2>&1 && \
            log_msg "✓ DNS query: $domain" || log_msg "✗ DNS query failed: $domain"
        done
    } &
    
    wait
    log_msg "✓ Heavy traffic generation cycle completed"
}

# Request DHCP if needed
request_dhcp_if_needed() {
    local current_ip
    current_ip=$(get_ip_address)
    
    if [[ -z "$current_ip" ]]; then
        log_msg "No IP address, requesting DHCP..."
        sudo dhclient -1 "$INTERFACE" >/dev/null 2>&1 || true
        sleep 5
        current_ip=$(get_ip_address)
        if [[ -n "$current_ip" ]]; then
            log_msg "✓ DHCP successful: $current_ip"
        else
            log_msg "✗ DHCP failed"
        fi
    fi
}

# Main loop
main_loop() {
    log_msg "Starting wired client simulation with heavy traffic generation"
    log_msg "Interface: $INTERFACE, Hostname: $HOSTNAME"

    # Set hostname if possible
    if command -v hostnamectl >/dev/null 2>&1; then
        sudo hostnamectl set-hostname "$HOSTNAME" 2>/dev/null || true
    fi

    while true; do
        # Check interface
        if ! check_interface; then
            log_msg "Waiting for $INTERFACE to become available..."
            sleep "$REFRESH_INTERVAL"
            continue
        fi

        # Check/request IP
        request_dhcp_if_needed
        local ip_addr
        ip_addr=$(get_ip_address)

        if [[ -n "$ip_addr" ]]; then
            log_msg "✓ $INTERFACE has IP: $ip_addr"
            
            # Test connectivity
            if test_connectivity; then
                # Generate heavy traffic
                generate_heavy_traffic
                log_msg "✓ Wired client cycle completed - heavy traffic generated"
            else
                log_msg "✗ Connectivity issues detected"
            fi
        else
            log_msg "✗ No IP address on $INTERFACE"
        fi

        sleep "$REFRESH_INTERVAL"
    done
}

# Cleanup
cleanup_and_exit() {
    log_msg "Cleaning up wired client simulation..."
    log_msg "Wired client simulation stopped"
    exit 0
}

trap cleanup_and_exit SIGTERM SIGINT EXIT

# Initialize
log_msg "Wired Client Starting..."
log_msg "Target interface: $INTERFACE"
log_msg "Expected hostname: $HOSTNAME"

# Start main loop
main_loop