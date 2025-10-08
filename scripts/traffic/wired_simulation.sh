#!/usr/bin/env bash
set -euo pipefail

# Wired Client Simulation - IMPROVED hostname claiming

INTERFACE="eth0"
HOSTNAME="CNXNMist-Wired"
LOG_FILE="/home/pi/wifi_test_dashboard/logs/wired.log"
SETTINGS="/home/pi/wifi_test_dashboard/configs/settings.conf"
DASHBOARD_DIR="/home/pi/wifi_test_dashboard"
mkdir -p "$DASHBOARD_DIR/stats"

set +e  # Keep service alive on errors

# Load persistent stats
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
  local f="$STATS_FILE"
  local now="$(date +%s)"
  local prev_down=0 prev_up=0

  if [[ -f "$f" ]]; then
    # best-effort parse without jq to avoid zeroing
    prev_down=$(sed -n 's/.*"download":[[:space:]]*\([0-9]\+\).*/\1/p' "$f" | head -n1)
    prev_up=$(sed -n 's/.*"upload":[[:space:]]*\([0-9]\+\).*/\1/p' "$f" | head -n1)
    prev_down=${prev_down:-0}; prev_up=${prev_up:-0}
  fi

  # Never decrease totals
  [[ "$TOTAL_DOWN" =~ ^[0-9]+$ ]] || TOTAL_DOWN=0
  [[ "$TOTAL_UP"   =~ ^[0-9]+$ ]] || TOTAL_UP=0
  (( TOTAL_DOWN < prev_down )) && TOTAL_DOWN="$prev_down"
  (( TOTAL_UP   < prev_up   )) && TOTAL_UP="$prev_up"

  printf '{"download": %d, "upload": %d, "timestamp": %d}\n' \
    "$TOTAL_DOWN" "$TOTAL_UP" "$now" > "$f.tmp" && mv "$f.tmp" "$f"
}

log_msg() {
    local msg="[$(date '+%F %T')] WIRED: $1"
    echo "$msg" | tee -a "$LOG_FILE"
}

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

[[ -f "$SETTINGS" ]] && source "$SETTINGS" || true

INTERFACE="${WIRED_INTERFACE:-$INTERFACE}"
HOSTNAME="${WIRED_HOSTNAME:-$HOSTNAME}"
REFRESH_INTERVAL="${WIRED_REFRESH_INTERVAL:-30}"
# Ensure stats dir exists
mkdir -p "$DASHBOARD_DIR/stats"
# Recompute STATS_FILE based on the final INTERFACE
STATS_FILE="$DASHBOARD_DIR/stats/stats_${INTERFACE}.json"

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
    
    # Background ping traffic (no byte tracking needed - minimal overhead)
    {
        for target in "${PING_TARGETS[@]}"; do
            timeout 30 ping -I "$INTERFACE" -c 10 -i 0.5 "$target" >/dev/null 2>&1 && \
            log_msg "✓ Heavy ping completed: $target" || log_msg "✗ Heavy ping failed: $target"
        done
    } &
    
    # Download traffic with byte tracking
    {
        local url="${DOWNLOAD_URLS[0]}"
        local tmp_file="/tmp/wired_download_$$"
        log_msg "Starting download: $(basename "$url")"
        if timeout 120 curl --interface "$INTERFACE" \
               --max-time 90 \
               --silent \
               --location \
               --output "$tmp_file" \
               "$url" 2>/dev/null; then
            # Track the downloaded bytes
            if [[ -f "$tmp_file" ]]; then
                local bytes
                bytes=$(stat -c%s "$tmp_file" 2>/dev/null || stat -f%z "$tmp_file" 2>/dev/null || echo 0)
                TOTAL_DOWN=$((TOTAL_DOWN + bytes))
                log_msg "✓ Download completed: $(basename "$url") - $bytes bytes (Total Down: ${TOTAL_DOWN}B)"
                rm -f "$tmp_file"
            fi
        else
            log_msg "✗ Download failed: $(basename "$url")"
            rm -f "$tmp_file"
        fi
    } &
    
    # HTTP traffic with byte tracking
    {
        for url in "${TEST_URLS[@]}"; do
            for i in {1..3}; do
                local tmp_http="/tmp/wired_http_$$_$i"
                if timeout 15 curl --interface "$INTERFACE" \
                       --max-time 10 \
                       --silent \
                       --output "$tmp_http" \
                       "$url" 2>/dev/null; then
                    # Track HTTP response bytes
                    if [[ -f "$tmp_http" ]]; then
                        local bytes
                        bytes=$(stat -c%s "$tmp_http" 2>/dev/null || stat -f%z "$tmp_http" 2>/dev/null || echo 0)
                        TOTAL_DOWN=$((TOTAL_DOWN + bytes))
                        log_msg "✓ HTTP traffic $i: $(basename "$url") - $bytes bytes"
                        rm -f "$tmp_http"
                    fi
                else
                    log_msg "✗ HTTP traffic $i failed: $(basename "$url")"
                    rm -f "$tmp_http"
                fi
                sleep 1
            done
        done
    } &
    
    # Upload traffic with byte tracking
    {
        local upload_size=102400  # 100KB
        local upload_data="/tmp/wired_upload_$$"
        
        # Create upload data
        dd if=/dev/zero of="$upload_data" bs=1024 count=100 2>/dev/null
        
        if timeout 60 curl --interface "$INTERFACE" \
                --connect-timeout 10 \
                --max-time 45 \
                --silent \
                -X POST \
                -o /dev/null \
                "https://httpbin.org/post" \
                --data-binary "@$upload_data" 2>/dev/null; then
                TOTAL_UP=$((TOTAL_UP + upload_size))
                save_stats     
                log_msg "✓ Upload completed: $upload_size bytes (Total Up: ${TOTAL_UP}B)"
            else
                log_msg "✗ Upload failed"
        fi
        
        rm -f "$upload_data"
    } &
    
    # DNS traffic (minimal bytes, but we can estimate)
    {
        local domains=("google.com" "cloudflare.com" "github.com" "juniper.net")
        local dns_bytes=0
        for domain in "${domains[@]}"; do
            if nslookup "$domain" >/dev/null 2>&1; then
                dns_bytes=$((dns_bytes + 512))  # Estimate ~512 bytes per DNS query (request + response)
                log_msg "✓ DNS query: $domain"
            else
                log_msg "✗ DNS query failed: $domain"
            fi
        done
        if [[ $dns_bytes -gt 0 ]]; then
            TOTAL_DOWN=$((TOTAL_DOWN + dns_bytes))
            TOTAL_UP=$((TOTAL_UP + dns_bytes))
            save_stats
        fi
    } &
    
    # Wait for all background jobs to complete
    wait
    
    # Save stats after all traffic generation is complete
    save_stats
    
    log_msg "✓ Heavy traffic generation cycle completed"
    log_msg "📊 Session totals: Down=${TOTAL_DOWN}B ($(echo "scale=2; $TOTAL_DOWN/1024/1024" | bc 2>/dev/null || echo "?")MB), Up=${TOTAL_UP}B ($(echo "scale=2; $TOTAL_UP/1024/1024" | bc 2>/dev/null || echo "?")MB)"
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
    
    # Initialize stats tracking
    load_stats
    
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