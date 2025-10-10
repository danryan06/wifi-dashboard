#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# WIRED CLIENT - OPTIMIZED HEAVY TRAFFIC GENERATOR
# =============================================================================
# Purpose: Generate sustained, configurable heavy traffic for Mist PoC demos
# Features: 
#   - Configurable intensity (light/medium/heavy)
#   - Persistent stats tracking (never-decreasing totals)
#   - Simplified hostname management (no locks)
#   - Automatic netem configuration support
#   - Clean, maintainable code
# =============================================================================

INTERFACE="eth0"
HOSTNAME="CNXNMist-Wired"
DASHBOARD_DIR="/home/pi/wifi_test_dashboard"
LOG_FILE="$DASHBOARD_DIR/logs/wired.log"
SETTINGS="$DASHBOARD_DIR/configs/settings.conf"

set +e  # Keep service alive on errors
trap 'log_msg "Service stopping gracefully..."' EXIT

# =============================================================================
# LOGGING
# =============================================================================
log_msg() {
    local msg="[$(date '+%F %T')] WIRED: $1"
    echo "$msg" | tee -a "$LOG_FILE"
}

# =============================================================================
# CONFIGURATION LOADING
# =============================================================================
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
mkdir -p "$DASHBOARD_DIR/stats"

# Load settings
[[ -f "$SETTINGS" ]] && source "$SETTINGS" || true

# Apply overrides from settings.conf
INTERFACE="${WIRED_INTERFACE:-$INTERFACE}"
HOSTNAME="${WIRED_HOSTNAME:-$HOSTNAME}"
REFRESH_INTERVAL="${WIRED_REFRESH_INTERVAL:-30}"
TRAFFIC_INTENSITY="${ETH0_TRAFFIC_INTENSITY:-heavy}"

# Stats file (based on final interface)
STATS_FILE="$DASHBOARD_DIR/stats/stats_${INTERFACE}.json"

# =============================================================================
# TRAFFIC INTENSITY PRESETS
# =============================================================================
case "$TRAFFIC_INTENSITY" in
  heavy)
    DOWNLOAD_SIZE=104857600      # 100MB per download
    CONCURRENT_DOWNLOADS=5       # 5 simultaneous downloads
    UPLOAD_SIZE=10485760         # 10MB uploads
    CONCURRENT_UPLOADS=3         # 3 simultaneous uploads
    DOWNLOAD_INTERVAL=60         # Download every 60s
    CYCLE_SLEEP=30               # 30s between cycles
    ;;
  medium)
    DOWNLOAD_SIZE=52428800       # 50MB per download
    CONCURRENT_DOWNLOADS=3       # 3 simultaneous downloads
    UPLOAD_SIZE=5242880          # 5MB uploads
    CONCURRENT_UPLOADS=2         # 2 simultaneous uploads
    DOWNLOAD_INTERVAL=120        # Download every 120s
    CYCLE_SLEEP=60               # 60s between cycles
    ;;
  light|*)
    DOWNLOAD_SIZE=10485760       # 10MB per download
    CONCURRENT_DOWNLOADS=2       # 2 simultaneous downloads
    UPLOAD_SIZE=1048576          # 1MB uploads
    CONCURRENT_UPLOADS=1         # 1 simultaneous upload
    DOWNLOAD_INTERVAL=300        # Download every 300s
    CYCLE_SLEEP=120              # 120s between cycles
    ;;
esac

# =============================================================================
# DOWNLOAD SOURCES (Fast, reliable mirrors)
# =============================================================================
DOWNLOAD_URLS=(
    "https://ash-speed.hetzner.com/100MB.bin"
    "https://proof.ovh.net/files/100Mb.dat"
    "http://ipv4.download.thinkbroadband.com/100MB.zip"
    "https://speed.hetzner.de/100MB.bin"
    "https://fra-speed.hetzner.com/100MB.bin"
)

# =============================================================================
# PERSISTENT STATS TRACKING (Never-Decreasing Totals)
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
  log_msg "📊 Loaded persistent stats: Down=${TOTAL_DOWN}B ($(( TOTAL_DOWN / 1048576 ))MB), Up=${TOTAL_UP}B ($(( TOTAL_UP / 1048576 ))MB)"
}

save_stats() {
  local f="$STATS_FILE"
  local now="$(date +%s)"
  local prev_down=0 prev_up=0

  # Load previous values to prevent decreases
  if [[ -f "$f" ]]; then
    prev_down=$(sed -n 's/.*"download":[[:space:]]*\([0-9]\+\).*/\1/p' "$f" | head -n1)
    prev_up=$(sed -n 's/.*"upload":[[:space:]]*\([0-9]\+\).*/\1/p' "$f" | head -n1)
    prev_down=${prev_down:-0}; prev_up=${prev_up:-0}
  fi

  # Validate and never decrease
  [[ "$TOTAL_DOWN" =~ ^[0-9]+$ ]] || TOTAL_DOWN=0
  [[ "$TOTAL_UP"   =~ ^[0-9]+$ ]] || TOTAL_UP=0
  (( TOTAL_DOWN < prev_down )) && TOTAL_DOWN="$prev_down"
  (( TOTAL_UP   < prev_up   )) && TOTAL_UP="$prev_up"

  # Atomic write
  printf '{"download": %d, "upload": %d, "timestamp": %d}\n' \
    "$TOTAL_DOWN" "$TOTAL_UP" "$now" > "$f.tmp" && mv "$f.tmp" "$f"
}

# =============================================================================
# SIMPLIFIED DHCP HOSTNAME (No Locks - Systemd Ordering Handles Conflicts)
# =============================================================================
configure_dhcp_hostname() {
    log_msg "🏷️ Configuring DHCP hostname: $HOSTNAME for $INTERFACE"
    
    # dhclient config
    local dhcp_conf="/etc/dhcp/dhclient-${INTERFACE}.conf"
    sudo bash -c "cat > $dhcp_conf" << EOF
# DHCP hostname for ${INTERFACE}
send host-name "$HOSTNAME";
supersede host-name "$HOSTNAME";
EOF
    
    # NetworkManager config
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
    
    sudo nmcli general reload 2>/dev/null || true
    log_msg "✅ DHCP hostname configured: $HOSTNAME"
}

# =============================================================================
# INTERFACE MANAGEMENT
# =============================================================================
ensure_interface_up() {
    if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
        log_msg "❌ Interface $INTERFACE not found"
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
    ip -4 addr show dev "$INTERFACE" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | head -n1
}

request_dhcp_if_needed() {
    local current_ip
    current_ip=$(get_ip_address)
    
    if [[ -z "$current_ip" ]]; then
        log_msg "No IP address, requesting DHCP..."
        sudo dhclient -1 -cf "/etc/dhcp/dhclient-${INTERFACE}.conf" "$INTERFACE" >/dev/null 2>&1 || true
        sleep 5
        current_ip=$(get_ip_address)
        if [[ -n "$current_ip" ]]; then
            log_msg "✅ DHCP successful: $current_ip"
        else
            log_msg "⚠️ DHCP failed"
            return 1
        fi
    fi
    return 0
}

# =============================================================================
# TRAFFIC GENERATION - HEAVY DOWNLOADS
# =============================================================================
generate_download_traffic() {
    log_msg "📥 Starting download traffic (intensity: $TRAFFIC_INTENSITY, size: $(( DOWNLOAD_SIZE / 1048576 ))MB, concurrent: $CONCURRENT_DOWNLOADS)"
    
    local pids=()
    local total_downloaded=0
    
    for i in $(seq 1 $CONCURRENT_DOWNLOADS); do
        (
            local url="${DOWNLOAD_URLS[$((RANDOM % ${#DOWNLOAD_URLS[@]}))]}"
            local tmp_file="/tmp/wired_download_${i}_$$"
            log_msg "↓ Download $i: $url (target ${DOWNLOAD_SIZE} bytes)"
            
            if timeout 180 curl --interface "$INTERFACE" \
                   --connect-timeout 15 \
                   --max-time 150 \
                   --range 0-$DOWNLOAD_SIZE \
                   --silent --location \
                   --output "$tmp_file" \
                   "$url" 2>/dev/null; then
                
                if [[ -f "$tmp_file" ]]; then
                    local bytes
                    bytes=$(stat -c%s "$tmp_file" 2>/dev/null || stat -f%z "$tmp_file" 2>/dev/null || echo 0)
                    log_msg "✓ Download $i complete: ${bytes} bytes"
                    echo "$bytes"  # Return bytes to parent
                    rm -f "$tmp_file"
                else
                    log_msg "✗ Download $i produced no file"
                    echo "0"
                fi
            else
                rm -f "$tmp_file"
                log_msg "✗ Download $i failed"
                echo "0"
            fi
        ) &
        pids+=($!)
    done
    
    # Wait for all downloads and sum bytes
    for pid in "${pids[@]}"; do
        if wait "$pid" 2>/dev/null; then
            local result
            result=$(jobs -p | grep -q "$pid" && echo "0" || echo "0")
        fi
    done
    
    # Collect results from job output (this is approximate - actual tracking is via kernel counters)
    # The real tracking happens in kernel via /sys/class/net statistics
    
    log_msg "✅ Download cycle completed"
}

# =============================================================================
# TRAFFIC GENERATION - HEAVY UPLOADS
# =============================================================================
generate_upload_traffic() {
    log_msg "📤 Starting upload traffic (size: $(( UPLOAD_SIZE / 1048576 ))MB, concurrent: $CONCURRENT_UPLOADS)"
    
    local pids=()
    
    for i in $(seq 1 $CONCURRENT_UPLOADS); do
        (
            local upload_url="https://httpbin.org/post"
            local upload_data="/tmp/wired_upload_${i}_$$"
            
            # Create upload data
            dd if=/dev/urandom of="$upload_data" bs=1M count=$(( UPLOAD_SIZE / 1048576 )) 2>/dev/null
            log_msg "↑ Upload $i: ${UPLOAD_SIZE} bytes to httpbin"
            
            if timeout 120 curl --interface "$INTERFACE" \
                    --connect-timeout 15 \
                    --max-time 90 \
                    --silent \
                    -X POST \
                    -o /dev/null \
                    "$upload_url" \
                    --data-binary "@$upload_data" 2>/dev/null; then
                log_msg "✅ Upload $i completed"
            else
                log_msg "✗ Upload $i failed"
            fi
            
            rm -f "$upload_data"
        ) &
        pids+=($!)
    done
    
    # Wait for all uploads
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    
    log_msg "✅ Upload cycle completed"
}

# =============================================================================
# TRAFFIC GENERATION - CONTINUOUS BACKGROUND HTTP
# =============================================================================
generate_background_http() {
    log_msg "🌐 Generating background HTTP traffic..."
    
    local urls=(
        "https://www.google.com"
        "https://www.cloudflare.com" 
        "https://httpbin.org/ip"
        "https://www.github.com"
    )
    
    for url in "${urls[@]}"; do
        timeout 10 curl --interface "$INTERFACE" \
               --max-time 8 \
               --silent \
               --output /dev/null \
               "$url" 2>/dev/null && \
        log_msg "✓ HTTP: $(basename "$url")" || \
        log_msg "✗ HTTP: $(basename "$url")"
        
        sleep 1
    done
}

# =============================================================================
# KERNEL COUNTER STATS UPDATE
# =============================================================================
update_stats_from_kernel() {
    # Read current kernel counters
    local rx_path="/sys/class/net/${INTERFACE}/statistics/rx_bytes"
    local tx_path="/sys/class/net/${INTERFACE}/statistics/tx_bytes"
    
    if [[ -f "$rx_path" && -f "$tx_path" ]]; then
        local current_rx=$(cat "$rx_path" 2>/dev/null || echo 0)
        local current_tx=$(cat "$tx_path" 2>/dev/null || echo 0)
        
        # On first run, just store baseline
        if [[ ! -f "$STATS_FILE.baseline" ]]; then
            echo "$current_rx $current_tx" > "$STATS_FILE.baseline"
            return
        fi
        
        # Calculate delta from baseline
        local baseline
        baseline=$(cat "$STATS_FILE.baseline" 2>/dev/null || echo "0 0")
        local baseline_rx=$(echo "$baseline" | awk '{print $1}')
        local baseline_tx=$(echo "$baseline" | awk '{print $2}')
        
        TOTAL_DOWN=$(( current_rx - baseline_rx ))
        TOTAL_UP=$(( current_tx - baseline_tx ))
        
        # Ensure non-negative
        [[ $TOTAL_DOWN -lt 0 ]] && TOTAL_DOWN=0
        [[ $TOTAL_UP -lt 0 ]] && TOTAL_UP=0
        
        save_stats
    fi
}

# =============================================================================
# MAIN TRAFFIC GENERATION CYCLE
# =============================================================================
traffic_generation_cycle() {
    log_msg "🚀 Starting traffic generation cycle (intensity: $TRAFFIC_INTENSITY)"
    
    # Quick connectivity check
    if ! timeout 10 ping -I "$INTERFACE" -c 2 -W 3 8.8.8.8 >/dev/null 2>&1; then
        log_msg "⚠️ Basic connectivity check failed, skipping heavy traffic"
        return 1
    fi
    
    # Generate heavy download traffic
    generate_download_traffic
    sleep 2
    
    # Generate heavy upload traffic
    generate_upload_traffic
    sleep 2
    
    # Generate background HTTP traffic
    generate_background_http
    
    # Update stats from kernel counters
    update_stats_from_kernel
    
    log_msg "✅ Traffic cycle completed - Stats: Down=$(( TOTAL_DOWN / 1048576 ))MB, Up=$(( TOTAL_UP / 1048576 ))MB"
}

# =============================================================================
# MAIN LOOP
# =============================================================================
main_loop() {
    log_msg "🚀 Starting wired client with hostname: $HOSTNAME"
    log_msg "Interface: $INTERFACE | Intensity: $TRAFFIC_INTENSITY"
    log_msg "Download: $(( DOWNLOAD_SIZE / 1048576 ))MB x$CONCURRENT_DOWNLOADS | Upload: $(( UPLOAD_SIZE / 1048576 ))MB x$CONCURRENT_UPLOADS"
    
    # Configure hostname
    configure_dhcp_hostname
    
    # Initialize stats
    load_stats
    
    # Initialize kernel baseline
    local rx_path="/sys/class/net/${INTERFACE}/statistics/rx_bytes"
    local tx_path="/sys/class/net/${INTERFACE}/statistics/tx_bytes"
    if [[ -f "$rx_path" && -f "$tx_path" ]]; then
        local baseline_rx=$(cat "$rx_path")
        local baseline_tx=$(cat "$tx_path")
        echo "$baseline_rx $baseline_tx" > "$STATS_FILE.baseline"
        log_msg "📊 Initialized kernel counter baseline"
    fi
    
    while true; do
        if ! ensure_interface_up; then
            log_msg "⚠️ Interface check failed, waiting..."
            sleep "$REFRESH_INTERVAL"
            continue
        fi

        if ! request_dhcp_if_needed; then
            log_msg "⚠️ No IP address, waiting..."
            sleep "$REFRESH_INTERVAL"
            continue
        fi

        local ip_addr
        ip_addr=$(get_ip_address)
        log_msg "✅ $INTERFACE operational: IP=$ip_addr, Hostname=$HOSTNAME"

        # Run traffic generation cycle
        if traffic_generation_cycle; then
            log_msg "✅ Cycle successful"
        else
            log_msg "⚠️ Cycle had issues"
        fi

        log_msg "⏳ Sleeping ${CYCLE_SLEEP}s before next cycle..."
        sleep "$CYCLE_SLEEP"
    done
}

# =============================================================================
# STARTUP
# =============================================================================
log_msg "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_msg "🌐 WIRED CLIENT - OPTIMIZED HEAVY TRAFFIC GENERATOR"
log_msg "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_msg "Interface: $INTERFACE"
log_msg "Hostname: $HOSTNAME"
log_msg "Intensity: $TRAFFIC_INTENSITY"
log_msg "Stats file: $STATS_FILE"
log_msg "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

main_loop