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

# --- Log rotation setup (installer-friendly) ---
ROTATE_UTIL="/home/pi/wifi_test_dashboard/scripts/log_rotation_utils.sh"
# shellcheck source=/dev/null
[[ -f "$ROTATE_UTIL" ]] && source "$ROTATE_UTIL" || true
: "${LOG_MAX_SIZE_BYTES:=10485760}"   # 10MB default if not set
: "${LOG_BACKUPS:=5}"                 # keep 5 rotated logs by default

rotate_basic() {
    local file="$LOG_FILE"
    local max="${LOG_MAX_SIZE_BYTES:-10485760}"
    local backups="${LOG_BACKUPS:-5}"
    # Only rotate if file exists and exceeds max
    if [[ -f "$file" ]]; then
        local size
        size="$(stat -c%s "$file" 2>/dev/null || wc -c < "$file" 2>/dev/null || echo 0)"
        if [[ "$size" =~ ^[0-9]+$ ]] && (( size > max )); then
            # Drop the oldest backup
            [[ -f "$file.$backups" ]] && rm -f "$file.$backups" || true
            # Shift others
            for ((i=backups-1; i>=1; i--)); do
                [[ -f "$file.$i" ]] && mv -f "$file.$i" "$file.$((i+1))" || true
            done
            mv -f "$file" "$file.1" || true
            : > "$file" || true
        fi
    fi
}

log_msg() {
    local msg="[$(date '+%F %T')] WIFI-GOOD: $1"
    # Prefer centralized util if present
    if declare -F log_msg_with_rotation >/dev/null; then
        # Write to journal/stdout
        echo "$msg"
        # Write to file with rotation handled by util
        log_msg_with_rotation "$LOG_FILE" "$msg" "WIFI-GOOD"
    else
        # Fallback: rotate locally then append
        rotate_basic
        # Ensure log directory exists
        mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
        echo "$msg" | tee -a "$LOG_FILE"
    fi
}

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

    # State 30 = disconnected but managed (good)
    # State 70 = connected (good)
    # State 20 = unavailable (bad)
    # State 10 = unmanaged (bad)
    if [[ "$state" == "20" || "$state" == "10" ]]; then
        log_msg "⚠ Interface state indicates issues - attempting to fix..."
        sudo nmcli device set "$INTERFACE" managed no || true
        sleep 2
        sudo nmcli device set "$INTERFACE" managed yes || true
        sleep 3
        state="$(nmcli -t -f GENERAL.STATE device show "$INTERFACE" 2>/dev/null | cut -d: -f2 | awk '{print $1}')"
        log_msg "Interface $INTERFACE state after reset: $state"
    fi

    return 0
}

# Connect to Wi-Fi network with interface validation and hostname fix
connect_to_wifi() {
    local ssid="$1"
    local password="$2"
    local connection_name="wifi-good-$ssid"

    log_msg "Attempting to connect to Wi-Fi: $ssid (interface: $INTERFACE, hostname: $HOSTNAME)"

    # Pre-connection checks for fresh installations
    log_msg "Performing pre-connection checks..."
    local state
    state="$(nmcli -t -f GENERAL.STATE device show "$INTERFACE" 2>/dev/null | cut -d: -f2 | awk '{print $1}')"
    if [[ "$state" == "20" ]]; then  # unavailable
        log_msg "Interface unavailable, waiting for it to become ready..."
        sleep 5
        nmcli device wifi rescan ifname "$INTERFACE" 2>/dev/null || true
        sleep 3
    fi

    # Scan for SSID
    log_msg "Scanning for target SSID: $ssid"
    nmcli device wifi rescan ifname "$INTERFACE" 2>/dev/null || true
    sleep 3
    if ! nmcli -t -f SSID device wifi list ifname "$INTERFACE" 2>/dev/null | grep -Fxq "$ssid"; then
        log_msg "⚠ Target SSID '$ssid' not visible in scan, but continuing anyway..."
    else
        log_msg "✓ Target SSID '$ssid' is visible"
    fi

    # Clean up any existing connection profiles for this SSID
    log_msg "Cleaning up any existing connection profiles for $ssid..."
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
    log_msg "Creating new Wi-Fi connection profile 'wifi-good-$ssid'..."
    nmcli connection add \
        type wifi \
        con-name "$connection_name" \
        ifname "$INTERFACE" \
        ssid "$ssid" \
        wifi-sec.key-mgmt wpa-psk \
        wifi-sec.psk "$password" \
        ipv4.method auto \
        ipv6.method auto >/dev/null 2>&1 || true
    log_msg "✓ Created Wi-Fi connection: $connection_name (interface: $INTERFACE, hostname: $HOSTNAME)"
    log_msg "Using connection-specific hostname: $HOSTNAME (not changing system hostname)"

    # Ensure clean connection state on this interface
    log_msg "Ensuring clean connection state on $INTERFACE..."
    nmcli device disconnect "$INTERFACE" 2>/dev/null || true
    sleep 3

    # Attempt to connect
    log_msg "Connecting to $ssid on $INTERFACE (timeout: ${CONNECTION_TIMEOUT}s)..."
    if timeout "$CONNECTION_TIMEOUT" nmcli connection up "$connection_name" >/dev/null 2>&1; then
        log_msg "✓ Successfully connected to $ssid on $INTERFACE"
        return 0
    else
        log_msg "✗ Failed to connect to $ssid on $INTERFACE"
        log_msg "Checking connection failure details..."
        local status
        status="$(nmcli -t -f GENERAL.STATE device show "$INTERFACE" 2>/dev/null | cut -d: -f2 | awk '{print $1}')"
        log_msg "Connection status: ${status:-unknown}"
        log_msg "Cleaning up failed connection profile"
        nmcli connection delete "$connection_name" 2>/dev/null || true
        return 1
    fi
}

wifi_info_snapshot() {
    local ip_addr
    ip_addr="$(ip -o -4 addr show "$INTERFACE" 2>/dev/null | awk '{print $4}' | head -n1)"
    local mac
    mac="$(cat /sys/class/net/"$INTERFACE"/address 2>/dev/null || echo "unknown")"
    log_msg "Connection Info - Interface: $INTERFACE, IP: ${ip_addr:-unknown}, MAC: $mac"

    if command -v iwconfig >/dev/null 2>&1; then
        local wi
        wi="$(iwconfig "$INTERFACE" 2>/dev/null | tr -s ' ' | sed 's/[[:space:]]\{1,\}/ /g')"
        log_msg "Wi-Fi Info: ${wi}"
    fi
}

basic_connectivity_tests() {
    log_msg "Testing connectivity through $INTERFACE..."
    local ok=0
    for url in "${TEST_URLS[@]}"; do
        if curl --interface "$INTERFACE" --max-time "${CURL_TIMEOUT:-10}" -fsSL -o /dev/null "$url"; then
            log_msg "✓ Traffic test passed: $url (via $INTERFACE)"
            ((ok++))
        fi
        sleep 1
    done
    log_msg "Traffic test results: $ok/${#TEST_URLS[@]} passed on $INTERFACE"

    # A few small web patterns
    curl --interface "$INTERFACE" --max-time 10 -fsSL "https://httpbin.org/bytes/1024" -o /dev/null && \
        log_msg "✓ Web traffic: 1024 on $INTERFACE" || true

    ping -I "$INTERFACE" -c 2 1.1.1.1 >/dev/null 2>&1 && \
        log_msg "✓ Background ping successful on $INTERFACE" || true

    curl --interface "$INTERFACE" --max-time 10 -fsSL "https://httpbin.org/json" -o /dev/null && \
        log_msg "✓ Web traffic: json on $INTERFACE" || true

    curl --interface "$INTERFACE" --max-time 10 -I "https://example.com" >/dev/null 2>&1 && \
        log_msg "✓ Web traffic: headers on $INTERFACE" || true
}

# Optional: scheduled YouTube-like pull (uses yt-dlp if enabled)
maybe_youtube_pull() {
    [[ "${ENABLE_YOUTUBE_TRAFFIC:-false}" == "true" ]] || return 0

    # Run at most once per YOUTUBE_TRAFFIC_INTERVAL
    local stamp="/tmp/wifi_good_youtube.last"
    local now epoch_last
    now="$(date +%s)"
    epoch_last=0
    [[ -f "$stamp" ]] && epoch_last="$(cat "$stamp" 2>/dev/null || echo 0)"
    local interval="${YOUTUBE_TRAFFIC_INTERVAL:-600}"
    if (( now - epoch_last < interval )); then
        return 0
    fi
    echo "$now" > "$stamp"

    log_msg "YouTube-like pull: starting scheduled run on $INTERFACE"
    local playlist="${YOUTUBE_PLAYLIST_URL:-}"
    if [[ -z "$playlist" ]]; then
        log_msg "YouTube: playlist URL not set; skipping"
        return 0
    fi

    # Resolve one video URL (best <=360p) using yt-dlp
    local media_v video_url audio_url
    if ! command -v yt-dlp >/dev/null 2>&1; then
        log_msg "YouTube: yt-dlp not installed; skipping"
        return 0
    fi

    # Pick first video item URL from playlist
    local first_video
    first_video="$(yt-dlp --flat-playlist -J "$playlist" 2>/dev/null | python3 - <<'PY'
import sys, json
d=json.load(sys.stdin)
e=d.get("entries") or []
if e:
    vid=e[0]
    # Return a canonical watch URL if possible
    if "url" in vid:
        print("https://www.youtube.com/watch?v="+vid["url"])
PY
)"
    if [[ -z "$first_video" ]]; then
        log_msg "YouTube: failed to pick a video from playlist"
        return 0
    fi

    # Get direct media URLs: video (<=360p) and audio
    read -r video_url audio_url <<<"$(
        yt-dlp -4 --no-playlist -f 'bv*[height<=360]+ba/b[height<=360]' -g "$first_video" 2>/dev/null | sed -n '1p;2p'
    )"

    if [[ -z "$video_url" ]]; then
        log_msg "YouTube: failed to resolve media URL"
        return 0
    fi

    # Stream ~YOUTUBE_MAX_DURATION seconds worth of bytes (not storing)
    local seconds="${YOUTUBE_MAX_DURATION:-300}"
    local tmp_fifo="/tmp/yt_stream.$$"
    mkfifo "$tmp_fifo" 2>/dev/null || true
    # Stream using curl; we don't need to *play*, only generate traffic
    timeout "$seconds" curl --interface "$INTERFACE" --max-time "$((seconds+5))" -fsSL "$video_url" -o "$tmp_fifo" 2>/dev/null || true
    rm -f "$tmp_fifo" || true
    log_msg "YouTube-like pull: completed (~${seconds}s)"
}

main_loop() {
    log_msg "Starting Wi-Fi good client simulation (interface: $INTERFACE, hostname: $HOSTNAME)"

    local last_config_check=0

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

        # Verify connectivity; if not, connect
        local state
        state="$(nmcli -t -f GENERAL.STATE device show "$INTERFACE" 2>/dev/null | cut -d: -f2 | awk '{print $1}')"
        if [[ "$state" != "100" ]]; then
            log_msg "Not connected to target SSID, attempting connection on $INTERFACE..."
            if connect_to_wifi "$SSID" "$PASSWORD"; then
                :
            else
                sleep "${REFRESH_INTERVAL}"
                continue
            fi
        fi

        log_msg "✓ Connected to target SSID: $SSID on $INTERFACE"
        wifi_info_snapshot
        log_msg "Testing connectivity through $INTERFACE..."
        # Make sure we have an IP
        if ip -o -4 addr show "$INTERFACE" | grep -q 'inet '; then
            log_msg "Interface $INTERFACE has IP: $(ip -o -4 addr show "$INTERFACE" | awk '{print $4}' | head -n1) - proceeding with traffic tests"
            # Connectivity & patterns
            basic_connectivity_tests
            # Maybe scheduled YouTube-like traffic
            maybe_youtube_pull
        else
            log_msg "No IP on $INTERFACE; skipping traffic checks"
        fi

        log_msg "✓ Wi-Fi good client operating normally on $INTERFACE"
        sleep "${REFRESH_INTERVAL}"
    done
}

# Ensure log dir exists from the start
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
log_msg "Using interface: $INTERFACE for good client simulation"
log_msg "Target hostname: $HOSTNAME"

# Initial config & start
read_wifi_config || true
main_loop
