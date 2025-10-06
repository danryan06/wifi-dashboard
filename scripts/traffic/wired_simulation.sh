#!/usr/bin/env bash
set -euo pipefail

# Wired Client Simulation - IMPROVED hostname claiming

INTERFACE="eth0"
HOSTNAME="CNXNMist-Wired"
LOG_FILE="/home/pi/wifi_test_dashboard/logs/wired.log"
SETTINGS="/home/pi/wifi_test_dashboard/configs/settings.conf"
DASHBOARD_DIR="/home/pi/wifi_test_dashboard"
mkdir -p "$DASHBOARD_DIR/stats"
STATS_FILE="$DASHBOARD_DIR/stats/stats_${INTERFACE:-eth0}.json"

set +e  # Keep service alive on errors

log_msg() {
    local msg="[$(date '+%F %T')] WIRED: $1"
    echo "$msg" | tee -a "$LOG_FILE"
}

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

[[ -f "$SETTINGS" ]] && source "$SETTINGS" || true

INTERFACE="${WIRED_INTERFACE:-$INTERFACE}"
HOSTNAME="${WIRED_HOSTNAME:-$HOSTNAME}"
REFRESH_INTERVAL="${WIRED_REFRESH_INTERVAL:-30}"

# IMPROVED: Aggressively claim DHCP hostname on startup
claim_dhcp_hostname() {
    log_msg "🏷️ Claiming DHCP hostname: $HOSTNAME for $INTERFACE"
    
    # Create dhclient config with SUPERSEDE (most aggressive)
    local dhcp_conf="/etc/dhcp/dhclient-${INTERFACE}.conf"
    sudo bash -c "cat > $dhcp_conf" << EOF
# DHCP hostname for ${INTERFACE} - WIRED CLIENT
send host-name "$HOSTNAME";
supersede host-name "$HOSTNAME";

request subnet-mask, broadcast-address, time-offset, routers,
        domain-name, domain-name-servers, domain-search, host-name,
        dhcp6.name-servers, dhcp6.domain-search, dhcp6.fqdn,
        netbios-name-servers, netbios-scope, interface-mtu,
        rfc3442-classless-static-routes, ntp-servers;
EOF
    
    # Also create NetworkManager config
    local nm_conf="/etc/NetworkManager/conf.d/dhcp-hostname-${INTERFACE}.conf"
    sudo bash -c "cat > $nm_conf" << EOF
[connection-${INTERFACE}]
match-device=interface-name:${INTERFACE}

[ipv4]
dhcp-hostname=${HOSTNAME}
dhcp-send-hostname=yes

[ipv6]
dhcp-hostname=${HOSTNAME}
dhcp-send-hostname=yes
EOF
    
    # Force NetworkManager reload
    sudo nmcli general reload 2>/dev/null || true
    sleep 2
    
    log_msg "✅ DHCP hostname claimed: $HOSTNAME"
}

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

get_ip_address() {
    ip -4 addr show dev "$INTERFACE" 2>/dev/null | grep 'inet ' | awk '{print $2}' | head -n1
}

test_connectivity() {
    log_msg "Testing connectivity on $INTERFACE"
    local success_count=0
    local total_tests=0
    
    for target in "${PING_TARGETS[@]}"; do
        total_tests=$((total_tests + 1))
        if timeout 10 ping -I "$INTERFACE" -c 3 -W 2 "$target" >/dev/null 2>&1; then
            log_msg "✓ Ping successful: $target"
            success_count=$((success_count + 1))
        else
            log_msg "✗ Ping failed: $target"
        fi
    done
    
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
        local url="${DOWNLOAD_URLS[0]}"
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

request_dhcp_if_needed() {
    local current_ip
    current_ip=$(get_ip_address)
    
    if [[ -z "$current_ip" ]]; then
        log_msg "No IP address, requesting DHCP..."
        # Use dhclient with our config
        sudo dhclient -1 -cf "/etc/dhcp/dhclient-${INTERFACE}.conf" "$INTERFACE" >/dev/null 2>&1 || true
        sleep 5
        current_ip=$(get_ip_address)
        if [[ -n "$current_ip" ]]; then
            log_msg "✓ DHCP successful: $current_ip"
        else
            log_msg "✗ DHCP failed"
        fi
    fi
}

main_loop() {
    log_msg "Starting wired client simulation with hostname: $HOSTNAME"
    log_msg "Interface: $INTERFACE"
    
    # CRITICAL: Claim hostname FIRST before any network activity
    claim_dhcp_hostname
    
    while true; do
        if ! check_interface; then
            log_msg "Waiting for $INTERFACE to become available..."
            sleep "$REFRESH_INTERVAL"
            continue
        fi

        request_dhcp_if_needed
        local ip_addr
        ip_addr=$(get_ip_address)

        if [[ -n "$ip_addr" ]]; then
            log_msg "✓ $INTERFACE has IP: $ip_addr (hostname: $HOSTNAME)"
            
            if test_connectivity; then
                generate_heavy_traffic
                log_msg "✓ Wired client cycle completed"
            else
                log_msg "✗ Connectivity issues detected"
            fi
        else
            log_msg "✗ No IP address on $INTERFACE"
        fi

        sleep "$REFRESH_INTERVAL"
    done
}

cleanup_and_exit() {
    log_msg "Cleaning up wired client simulation..."
    # Clean up DHCP hostname lock
    sudo rm -f "/var/run/wifi-dashboard/hostname-${INTERFACE}.lock" 2>/dev/null || true
    log_msg "Wired client simulation stopped"
    exit 0
}

trap cleanup_and_exit SIGTERM SIGINT EXIT

log_msg "Wired Client Starting with IMPROVED hostname claiming..."
log_msg "Target interface: $INTERFACE"
log_msg "Expected hostname: $HOSTNAME"

main_loop