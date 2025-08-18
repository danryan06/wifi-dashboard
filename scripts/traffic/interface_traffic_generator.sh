#!/usr/bin/env bash
set -euo pipefail

# Universal traffic generator that can target specific interfaces
# Usage: ./interface_traffic_generator.sh <interface> <traffic_type> [intensity]

INTERFACE="${1:-eth0}"
TRAFFIC_TYPE="${2:-all}"
INTENSITY="${3:-medium}"

LOG_FILE="/home/pi/wifi_test_dashboard/logs/traffic-${INTERFACE}.log"
SETTINGS="/home/pi/wifi_test_dashboard/configs/settings.conf"
LOG_ROTATION_UTILS="/home/pi/wifi_test_dashboard/scripts/log_rotation_utils.sh"

# Source settings if available
[[ -f "$SETTINGS" ]] && source "$SETTINGS"

# Source log rotation utilities if available
[[ -f "$LOG_ROTATION_UTILS" ]] && source "$LOG_ROTATION_UTILS"

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

# YouTube playlists for traffic generation
YOUTUBE_PLAYLISTS=(
    "https://www.youtube.com/playlist?list=PLrAXtmRdnEQy5tts6p-v1URsm7wOSM-M0"  # Music
    "https://www.youtube.com/watch?v=dQw4w9WgXcQ"  # Single video
    "https://www.youtube.com/watch?v=jNQXAC9IVRw"  # Another single video
)

# Test URLs for downloads
DOWNLOAD_URLS=(
    "https://proof.ovh.net/files/100Mb.dat"
    "https://speed.hetzner.de/100MB.bin"
    "https://ash-speed.hetzner.com/100MB.bin"
    "http://ipv4.download.thinkbroadband.com/50MB.zip"
    "https://releases.ubuntu.com/20.04/ubuntu-20.04.6-desktop-amd64.iso"
)

# Enhanced logging function with automatic rotation
log_msg() {
    local message="$1"
    local component="TRAFFIC-${INTERFACE^^}"
    
    # Use log rotation utility if available, otherwise fall back to simple logging
    if command -v log_msg_with_rotation >/dev/null 2>&1; then
        log_msg_with_rotation "$LOG_FILE" "$message" "$component"
    else
        # Fallback to basic logging with manual rotation check
        echo "[$(date '+%F %T')] $component: $message" | tee -a "$LOG_FILE"
        
        # Basic size check - rotate if over 10MB
        if [[ -f "$LOG_FILE" ]]; then
            local size_mb=$(du -m "$LOG_FILE" 2>/dev/null | cut -f1 || echo "0")
            if [[ $size_mb -gt 10 ]]; then
                mv "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
                touch "$LOG_FILE"
                echo "[$(date '+%F %T')] $component: Log rotated (was ${size_mb}MB)" | tee -a "$LOG_FILE"
            fi
        fi
    fi
}

# Check if interface exists and is up
check_interface() {
    if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
        log_msg "✗ Interface $INTERFACE not found"
        return 1
    fi
    
    if ! ip route show dev "$INTERFACE" | grep -q .; then
        log_msg "⚠ Interface $INTERFACE has no routes - traffic may not work"
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

# Force traffic through specific interface using routing
setup_interface_routing() {
    local test_ips=("8.8.8.8" "1.1.1.1" "208.67.222.222")
    local gateway
    
    # Get the gateway for this interface
    gateway=$(ip route show dev "$INTERFACE" | grep default | awk '{print $3}' | head -n1)
    
    if [[ -n "$gateway" ]]; then
        # Add specific routes for test traffic through this interface
        for ip in "${test_ips[@]}"; do
            sudo ip route add "$ip/32" via "$gateway" dev "$INTERFACE" 2>/dev/null || true
        done
        log_msg "✓ Routing configured for $INTERFACE via gateway $gateway"
    else
        log_msg "⚠ No gateway found for $INTERFACE"
    fi
}

# Clean up interface-specific routes
cleanup_interface_routing() {
    local test_ips=("8.8.8.8" "1.1.1.1" "208.67.222.222")
    for ip in "${test_ips[@]}"; do
        sudo ip route del "$ip/32" dev "$INTERFACE" 2>/dev/null || true
    done
}

# Interface-specific speedtest
run_interface_speedtest() {
    while true; do
        if check_interface; then
            log_msg "Running speedtest on $INTERFACE (intensity: $INTENSITY)..."
            
            # Bind to specific interface if possible
            local bind_option=""
            local ip_addr=$(ip addr show "$INTERFACE" | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | head -n1)
            [[ -n "$ip_addr" ]] && bind_option="--source=$ip_addr"
            
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
            
            if timeout 120 $speedtest_cmd >/dev/null 2>&1; then
                log_msg "✓ Speedtest completed on $INTERFACE"
            else
                log_msg "✗ Speedtest failed on $INTERFACE"
            fi
            
            # Enable log rotation check after significant operations
            if command -v enable_log_rotation_for_file >/dev/null 2>&1; then
                enable_log_rotation_for_file "$LOG_FILE"
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
                
                # Check for log rotation after bulk operations
                if command -v enable_log_rotation_for_file >/dev/null 2>&1; then
                    enable_log_rotation_for_file "$LOG_FILE"
                fi
            else
                log_msg "No IP address on $INTERFACE for downloads"
            fi
        fi
        sleep $DOWNLOAD_INTERVAL
    done
}

# YouTube traffic generation with enhanced logging
run_youtube_traffic() {
    # Check if yt-dlp or youtube-dl is available
    local youtube_cmd=""
    if command -v yt-dlp >/dev/null 2>&1; then
        youtube_cmd="yt-dlp"
    elif command -v youtube-dl >/dev/null 2>&1; then
        youtube_cmd="youtube-dl"
    else
        log_msg "⚠ No YouTube downloader available, skipping YouTube traffic"
        return
    fi
    
    while true; do
        if check_interface; then
            local ip_addr=$(ip addr show "$INTERFACE" | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | head -n1)
            
            if [[ -n "$ip_addr" ]]; then
                log_msg "Starting YouTube traffic generation on $INTERFACE"
                
                # Select random video/playlist
                local url=${YOUTUBE_PLAYLISTS[$((RANDOM % ${#YOUTUBE_PLAYLISTS[@]}))]}
                
                # Create temporary directory for downloads
                local temp_dir=$(mktemp -d)
                
                {
                    # Download video(s) with interface binding (simulate streaming)
                    # Download only a portion to generate traffic without filling disk
                    if timeout 300 $youtube_cmd \
                        --quiet \
                        --no-warnings \
                        --max-downloads 2 \
                        --format "worst[height<=480]" \
                        --external-downloader curl \
                        --external-downloader-args "--interface $INTERFACE --max-time 180" \
                        --output "$temp_dir/%(title)s.%(ext)s" \
                        "$url" 2>/dev/null; then
                        log_msg "✓ YouTube traffic completed on $INTERFACE"
                    else
                        log_msg "✗ YouTube traffic failed on $INTERFACE"
                    fi
                } || {
                    log_msg "✗ YouTube traffic timed out on $INTERFACE"
                }
                
                # Clean up downloaded files
                rm -rf "$temp_dir"
                
                # Check for log rotation after YouTube operations
                if command -v enable_log_rotation_for_file >/dev/null 2>&1; then
                    enable_log_rotation_for_file "$LOG_FILE"
                fi
            else
                log_msg "No IP address on $INTERFACE for YouTube traffic"
            fi
        fi
        sleep $YOUTUBE_INTERVAL
    done
}

# Interface-specific ping flood (light continuous traffic)
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
    
    # Show log rotation status if available
    if command -v show_log_rotation_status >/dev/null 2>&1; then
        show_log_rotation_status "$LOG_FILE" | while read -r line; do
            log_msg "LOG-INFO: $line"
        done
    fi
    
    # Setup interface-specific routing
    setup_interface_routing
    
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
        "youtube"|"all")
            if [[ "${ENABLE_YOUTUBE_TRAFFIC:-true}" == "true" ]]; then
                run_youtube_traffic &
                YOUTUBE_PID=$!
                pids+=($YOUTUBE_PID)
                log_msg "Started YouTube traffic generator (PID: $YOUTUBE_PID)"
            fi
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
    
    # Monitor and periodic log rotation
    while true; do
        # Check if any process has died
        for pid in "${pids[@]}"; do
            if ! kill -0 "$pid" 2>/dev/null; then
                log_msg "⚠ Traffic generator process $pid has died, restarting main loop"
                cleanup_and_exit
            fi
        done
        
        # Periodic log rotation check (every 5 minutes)
        if command -v enable_log_rotation_for_file >/dev/null 2>&1; then
            enable_log_rotation_for_file "$LOG_FILE"
        fi
        
        sleep 300  # Check every 5 minutes
    done
}

# Cleanup function
cleanup_and_exit() {
    log_msg "Cleaning up traffic generation for $INTERFACE"
    
    # Kill all background processes
    local all_pids=(${SPEEDTEST_PID:-} ${DOWNLOAD_PID:-} ${YOUTUBE_PID:-} ${PING_PID:-})
    for pid in "${all_pids[@]}"; do
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            log_msg "Stopping process $pid"
            kill "$pid" 2>/dev/null || true
        fi
    done
    
    # Clean up routing
    cleanup_interface_routing
    
    # Final log rotation check
    if command -v enable_log_rotation_for_file >/dev/null 2>&1; then
        enable_log_rotation_for_file "$LOG_FILE"
    fi
    
    log_msg "Traffic generation cleanup completed for $INTERFACE"
    exit 0
}

# Signal handlers
trap cleanup_and_exit SIGTERM SIGINT EXIT

# Validate arguments
if [[ ! "$TRAFFIC_TYPE" =~ ^(all|speedtest|downloads|youtube|ping)$ ]]; then
    log_msg "✗ Invalid traffic type: $TRAFFIC_TYPE"
    log_msg "Valid types: all, speedtest, downloads, youtube, ping"
    exit 1
fi

if [[ ! "$INTENSITY" =~ ^(light|medium|heavy)$ ]]; then
    log_msg "✗ Invalid intensity: $INTENSITY"
    log_msg "Valid intensities: light, medium, heavy"
    exit 1
fi

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

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