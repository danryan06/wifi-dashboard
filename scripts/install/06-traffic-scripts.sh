#!/usr/bin/env bash
# scripts/install/06-traffic-scripts.sh
# Download and install traffic generation scripts

set -euo pipefail

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }

log_info "Installing traffic generation scripts..."

# Create scripts directory
mkdir -p "$PI_HOME/wifi_test_dashboard/scripts"

# Download main traffic generator with fallback
log_info "Installing main traffic generator..."
if curl -sSL --max-time 30 --retry 3 "${REPO_URL}/scripts/traffic/interface_traffic_generator.sh" -o "$PI_HOME/wifi_test_dashboard/scripts/interface_traffic_generator.sh"; then
    log_info "✓ Downloaded interface_traffic_generator.sh"
else
    log_warn "✗ Failed to download interface_traffic_generator.sh, creating locally..."
    
    # Create the complete traffic generator script locally
    cat > "$PI_HOME/wifi_test_dashboard/scripts/interface_traffic_generator.sh" <<'TRAFFIC_GENERATOR_EOF'
#!/usr/bin/env bash
set -euo pipefail

# Universal traffic generator that can target specific interfaces
# Usage: ./interface_traffic_generator.sh <interface> <traffic_type> [intensity]

INTERFACE="${1:-eth0}"
TRAFFIC_TYPE="${2:-all}"
INTENSITY="${3:-medium}"

LOG_FILE="$HOME/wifi_test_dashboard/logs/traffic-${INTERFACE}.log"
SETTINGS="$HOME/wifi_test_dashboard/configs/settings.conf"

# Source settings if available
[[ -f "$SETTINGS" ]] && source "$SETTINGS"

# Traffic intensity settings
case "$INTENSITY" in
    "light")
        SPEEDTEST_INTERVAL=600    # 10 minutes
        DOWNLOAD_INTERVAL=300     # 5 minutes
        CONCURRENT_DOWNLOADS=2
        CHUNK_SIZE=52428800       # 50MB
        YOUTUBE_INTERVAL=900      # 15 minutes
        ;;
    "medium")
        SPEEDTEST_INTERVAL=300    # 5 minutes
        DOWNLOAD_INTERVAL=120     # 2 minutes
        CONCURRENT_DOWNLOADS=3
        CHUNK_SIZE=104857600      # 100MB
        YOUTUBE_INTERVAL=600      # 10 minutes
        ;;
    "heavy")
        SPEEDTEST_INTERVAL=180    # 3 minutes
        DOWNLOAD_INTERVAL=60      # 1 minute
        CONCURRENT_DOWNLOADS=5
        CHUNK_SIZE=209715200      # 200MB
        YOUTUBE_INTERVAL=300      # 5 minutes
        ;;
esac

# Test URLs for downloads
DOWNLOAD_URLS=(
    "https://proof.ovh.net/files/100Mb.dat"
    "https://speed.hetzner.de/100MB.bin"
    "https://ash-speed.hetzner.com/100MB.bin"
    "http://ipv4.download.thinkbroadband.com/50MB.zip"
)

log_msg() {
    echo "[$(date '+%F %T')] TRAFFIC-${INTERFACE^^}: $1" | tee -a "$LOG_FILE"
}

# Check if interface exists and is up
check_interface() {
    if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
        log_msg "✗ Interface $INTERFACE not found"
        return 1
    fi
    
    local ip_addr=$(ip addr show "$INTERFACE" | grep 'inet ' | awk '{print $2}' | head -n1)
    if [[ -n "$ip_addr" ]]; then
        log_msg "✓ Interface $INTERFACE ready with IP: $ip_addr"
    else
        log_msg "⚠ Interface $INTERFACE has no IP address"
        return 1
    fi
    
    return 0
}

# Interface-specific speedtest
run_interface_speedtest() {
    while true; do
        if check_interface; then
            log_msg "Running speedtest on $INTERFACE (intensity: $INTENSITY)..."
            
            local ip_addr=$(ip addr show "$INTERFACE" | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | head -n1)
            
            # Try official speedtest first, fall back to speedtest-cli
            local speedtest_cmd=""
            if command -v speedtest >/dev/null 2>&1; then
                # Official Ookla Speedtest CLI
                speedtest_cmd="speedtest --accept-license --accept-gdpr --format=human-readable"
                [[ -n "$ip_addr" ]] && speedtest_cmd="$speedtest_cmd --interface-name=$INTERFACE"
            elif command -v speedtest-cli >/dev/null 2>&1; then
                # Python-based speedtest-cli
                speedtest_cmd="speedtest-cli"
                [[ -n "$ip_addr" ]] && speedtest_cmd="$speedtest_cmd --source $ip_addr"
            else
                log_msg "✗ No speedtest command available"
                sleep $SPEEDTEST_INTERVAL
                continue
            fi
            
            if timeout 120 $speedtest_cmd 2>&1 | tee -a "$LOG_FILE"; then
                log_msg "✓ Speedtest completed on $INTERFACE"
            else
                log_msg "✗ Speedtest failed on $INTERFACE"
            fi
        else
            log_msg "Interface $INTERFACE not ready for speedtest"
        fi
        sleep $SPEEDTEST_INTERVAL
    done
}

# Interface-specific downloads with curl binding
run_interface_downloads() {
    while true; do
        if check_interface; then
            local ip_addr=$(ip addr show "$INTERFACE" | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | head -n1)
            
            if [[ -n "$ip_addr" ]]; then
                log_msg "Starting $CONCURRENT_DOWNLOADS concurrent downloads on $INTERFACE"
                
                for ((i=0; i<$CONCURRENT_DOWNLOADS; i++)); do
                    {
                        local url=${DOWNLOAD_URLS[$((RANDOM % ${#DOWNLOAD_URLS[@]}))]}
                        log_msg "Download $((i+1)): $(basename $url) via $INTERFACE"
                        
                        # Use curl with interface binding and limited download size
                        if curl --interface "$INTERFACE" \
                                --max-time 180 \
                                --range "0-$CHUNK_SIZE" \
                                --silent \
                                --location \
                                --output /dev/null \
                                "$url" 2>/dev/null; then
                            log_msg "✓ Download $((i+1)) completed on $INTERFACE"
                        else
                            log_msg "✗ Download $((i+1)) failed on $INTERFACE"
                        fi
                    } &
                done
                
                # Wait for all downloads to complete
                wait
                log_msg "✓ All concurrent downloads completed on $INTERFACE"
            else
                log_msg "No IP address on $INTERFACE for downloads"
            fi
        fi
        sleep $DOWNLOAD_INTERVAL
    done
}

# Interface-specific ping traffic
run_interface_ping_traffic() {
    local targets=("8.8.8.8" "1.1.1.1" "208.67.222.222")
    
    while true; do
        if check_interface; then
            for target in "${targets[@]}"; do
                # Send 10 pings every 30 seconds through specific interface
                if ping -I "$INTERFACE" -c 10 -i 0.2 "$target" >/dev/null 2>&1; then
                    log_msg "✓ Ping traffic to $target via $INTERFACE successful"
                else
                    log_msg "✗ Ping traffic to $target via $INTERFACE failed"
                fi
                sleep 30
            done
        fi
        sleep 60
    done
}

# Main traffic generation controller
main_traffic_loop() {
    log_msg "Starting traffic generation on $INTERFACE (type: $TRAFFIC_TYPE, intensity: $INTENSITY)"
    
    # Start background traffic generators based on type
    local pids=()
    
    case "$TRAFFIC_TYPE" in
        "speedtest"|"all")
            run_interface_speedtest &
            SPEEDTEST_PID=$!
            pids+=($SPEEDTEST_PID)
            log_msg "Started speedtest generator (PID: $SPEEDTEST_PID)"
            ;;
    esac
    
    case "$TRAFFIC_TYPE" in
        "downloads"|"all")
            run_interface_downloads &
            DOWNLOAD_PID=$!
            pids+=($DOWNLOAD_PID)
            log_msg "Started download generator (PID: $DOWNLOAD_PID)"
            ;;
    esac
    
    case "$TRAFFIC_TYPE" in
        "ping"|"all")
            run_interface_ping_traffic &
            PING_PID=$!
            pids+=($PING_PID)
            log_msg "Started ping traffic generator (PID: $PING_PID)"
            ;;
    esac
    
    # If no specific traffic type matched, default to ping
    if [[ ${#pids[@]} -eq 0 ]]; then
        log_msg "No valid traffic type specified, starting ping traffic only"
        run_interface_ping_traffic &
        PING_PID=$!
        pids+=($PING_PID)
    fi
    
    # Wait for any child process to exit (shouldn't happen in normal operation)
    wait -n
    
    # If we get here, something went wrong
    log_msg "⚠ Traffic generator exited unexpectedly, cleaning up..."
    exit 0
}

# Cleanup function
cleanup_and_exit() {
    log_msg "Cleaning up traffic generation for $INTERFACE"
    
    # Kill all background processes
    local all_pids=(${SPEEDTEST_PID:-} ${DOWNLOAD_PID:-} ${PING_PID:-})
    for pid in "${all_pids[@]}"; do
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            log_msg "Stopping process $pid"
            kill "$pid" 2>/dev/null || true
        fi
    done
    
    log_msg "Traffic generation cleanup completed for $INTERFACE"
    exit 0
}

# Signal handlers
trap cleanup_and_exit SIGTERM SIGINT EXIT

# Validate arguments
if [[ ! "$TRAFFIC_TYPE" =~ ^(all|speedtest|downloads|ping)$ ]]; then
    log_msg "✗ Invalid traffic type: $TRAFFIC_TYPE"
    log_msg "Valid types: all, speedtest, downloads, ping"
    exit 1
fi

if [[ ! "$INTENSITY" =~ ^(light|medium|heavy)$ ]]; then
    log_msg "✗ Invalid intensity: $INTENSITY"
    log_msg "Valid intensities: light, medium, heavy"
    exit 1
fi

# Initial interface check
if ! check_interface; then
    log_msg "✗ Interface $INTERFACE is not ready, waiting 30 seconds..."
    sleep 30
    if ! check_interface; then
        log_msg "✗ Interface $INTERFACE still not ready, exiting"
        exit 1
    fi
fi

# Start main traffic generation loop
main_traffic_loop
TRAFFIC_GENERATOR_EOF
fi

# Download wired simulation script with fallback
log_info "Installing wired simulation script..."
if curl -sSL --max-time 30 --retry 3 "${REPO_URL}/scripts/traffic/wired_simulation.sh" -o "$PI_HOME/wifi_test_dashboard/scripts/wired_simulation.sh"; then
    log_info "✓ Downloaded wired_simulation.sh"
else
    log_warn "✗ Failed to download wired_simulation.sh, using existing version or creating basic one..."
    # Note: This file should already exist from the original repository
fi

# Download Wi-Fi good client script with fallback
log_info "Installing Wi-Fi good client script..."
if curl -sSL --max-time 30 --retry 3 "${REPO_URL}/scripts/traffic/wifi_good_client.sh" -o "$PI_HOME/wifi_test_dashboard/scripts/connect_and_curl.sh"; then
    log_info "✓ Downloaded wifi_good_client.sh"
else
    log_warn "✗ Failed to download wifi_good_client.sh, using existing version or creating basic one..."
    # Note: This file should already exist from the original repository
fi

# Download Wi-Fi bad client script with fallback
log_info "Installing Wi-Fi bad client script..."
if curl -sSL --max-time 30 --retry 3 "${REPO_URL}/scripts/traffic/wifi_bad_client.sh" -o "$PI_HOME/wifi_test_dashboard/scripts/fail_auth_loop.sh"; then
    log_info "✓ Downloaded wifi_bad_client.sh"
else
    log_warn "✗ Failed to download wifi_bad_client.sh, using existing version or creating basic one..."
    # Note: This file should already exist from the original repository
fi

# Make scripts executable and fix line endings
chmod +x "$PI_HOME/wifi_test_dashboard/scripts"/*.sh
dos2unix "$PI_HOME/wifi_test_dashboard/scripts"/*.sh 2>/dev/null || true

# Set proper ownership
chown -R "$PI_USER:$PI_USER" "$PI_HOME/wifi_test_dashboard/scripts"

log_info "✓ Traffic generation scripts installed"