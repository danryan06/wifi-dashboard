#!/usr/bin/env bash
set -euo pipefail

# Simple Wi-Fi Bad Client for Mist PoC
# Just uses wrong password to trigger Mist automatic PCAP capture
# Keeps it simple for demonstration purposes

INTERFACE="wlan1"
HOSTNAME="CNXNMist-WiFiBad"
LOG_FILE="/home/pi/wifi_test_dashboard/logs/wifi-bad.log"
CONFIG_FILE="/home/pi/wifi_test_dashboard/configs/ssid.conf"
SETTINGS="/home/pi/wifi_test_dashboard/configs/settings.conf"

# Keep service alive; log failing command instead of exiting
set -E
trap 'ec=$?; echo "[$(date "+%F %T")] TRAP-ERR: cmd=\"$BASH_COMMAND\" ec=$ec line=$LINENO" | tee -a "$LOG_FILE"; ec=0' ERR

# --- Log rotation setup ---
ROTATE_UTIL="/home/pi/wifi_test_dashboard/scripts/log_rotation_utils.sh"
[[ -f "$ROTATE_UTIL" ]] && source "$ROTATE_UTIL" || true
: "${LOG_MAX_SIZE_BYTES:=5242880}"   # 5MB default for bad client

rotate_basic() {
    if command -v rotate_log >/dev/null 2>&1; then
        rotate_log "$LOG_FILE" "${LOG_MAX_BYTES:-5}"
        return 0
    fi

    local max_mb="${LOG_MAX_BYTES:-5}"
    local size_bytes=0

    if [[ -f "$LOG_FILE" ]]; then
        size_bytes=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE")
        if (( size_bytes >= max_mb * 1024 * 1024 )); then
            mv -f "$LOG_FILE" "$LOG_FILE.$(date +%s).1"
            : > "$LOG_FILE"
        fi
    fi
}

log_msg() {
    local msg="[$(date '+%F %T')] WIFI-BAD: $1"
    if declare -F log_msg_with_rotation >/dev/null; then
        echo "$msg"
        log_msg_with_rotation "$LOG_FILE" "$msg" "WIFI-BAD"
    else
        rotate_basic
        mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
        echo "$msg" | tee -a "$LOG_FILE"
    fi
}

# --- Load settings and overrides ---
[[ -f "$SETTINGS" ]] && source "$SETTINGS" || true

INTERFACE="${WIFI_BAD_INTERFACE:-$INTERFACE}"
HOSTNAME="${WIFI_BAD_HOSTNAME:-$HOSTNAME}"
REFRESH_INTERVAL="${WIFI_BAD_REFRESH_INTERVAL:-45}"
CONNECTION_TIMEOUT="${WIFI_CONNECTION_TIMEOUT:-20}"

# Simple wrong passwords to try
WRONG_PASSWORDS=(
    "wrongpassword123"
    "incorrectpwd"
    "badpassword"
    "admin123" 
    "guest123"
    "password123"
)

# --- Configuration management ---
read_wifi_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_msg "✗ Config file not found: $CONFIG_FILE"
        return 1
    fi

    local lines=($(cat "$CONFIG_FILE"))
    if [[ ${#lines[@]} -lt 1 ]]; then
        log_msg "✗ Config file incomplete (need at least SSID)"
        return 1
    fi

    SSID="${lines[0]}"
    if [[ -z "${SSID:-}" ]]; then
        log_msg "✗ SSID is empty"
        return 1
    fi

    log_msg "✓ Target SSID loaded: $SSID (will use wrong password to trigger Mist PCAP)"
    return 0
}

# --- Interface management ---
check_wifi_interface() {
    if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
        log_msg "✗ Wi-Fi interface $INTERFACE not found"
        return 1
    fi

    # Ensure NetworkManager manages this interface
    if ! nmcli device show "$INTERFACE" >/dev/null 2>&1; then
        log_msg "Setting $INTERFACE to managed mode"
        nmcli device set "$INTERFACE" managed yes 2>/dev/null || true
        sleep 2
    fi

    local state
    state="$(nmcli -t -f GENERAL.STATE device show "$INTERFACE" 2>/dev/null | cut -d: -f2 | awk '{print $1}')"
    state="${state:-unknown}"
    log_msg "Interface $INTERFACE state: $state"
    return 0
}

scan_for_ssid() {
    local target_ssid="$1"
    log_msg "Scanning for target SSID: $target_ssid"
    
    nmcli device wifi rescan ifname "$INTERFACE" 2>/dev/null || true
    sleep 3
    
    if nmcli device wifi list ifname "$INTERFACE" 2>/dev/null | grep -Fq -- "$target_ssid"; then
        log_msg "✓ Target SSID '$target_ssid' is visible"
        return 0
    fi
    log_msg "✗ Target SSID '$target_ssid' not found in scan"
    return 1
}

force_disconnect() {
    log_msg "Ensuring $INTERFACE is disconnected"
    
    nmcli device disconnect "$INTERFACE" 2>/dev/null || true
    sleep 1

    # Check if still connected
    local current_ssid=""
    current_ssid="$(iw dev "$INTERFACE" link 2>/dev/null | sed -n 's/^.*SSID: \(.*\)$/\1/p')"
    
    if [[ -n "$current_ssid" ]]; then
        log_msg "Still connected to: $current_ssid, forcing radio reset"
        nmcli radio wifi off 2>/dev/null || true
        sleep 2
        nmcli radio wifi on 2>/dev/null || true
        sleep 3
    fi
}

# --- Simple authentication failure ---
attempt_connection_with_wrong_password() {
    local ssid="$1"
    local wrong_password="$2"
    local connection_name="mist-bad-client-$RANDOM"

    log_msg "🎯 Attempting connection with wrong password to trigger Mist PCAP"
    log_msg "SSID: $ssid, Wrong Password: ***${wrong_password: -3}"

    force_disconnect
    
    # Create connection with wrong password
    if nmcli connection add \
        type wifi \
        con-name "$connection_name" \
        ifname "$INTERFACE" \
        ssid "$ssid" \
        wifi-sec.key-mgmt wpa-psk \
        wifi-sec.psk "$wrong_password" \
        ipv4.method auto \
        ipv6.method auto >/dev/null 2>&1; then
        log_msg "✓ Created connection profile with wrong password"
    else
        log_msg "✗ Failed to create connection profile"
        return 1
    fi

    # Attempt connection (should fail and trigger Mist PCAP)
    log_msg "Attempting connection (expecting auth failure to trigger Mist PCAP)..."
    local connection_output=""
    if connection_output="$(timeout "$CONNECTION_TIMEOUT" nmcli connection up "$connection_name" 2>&1)"; then
        log_msg "🚨 WARNING: Connection succeeded with wrong password!"
        log_msg "🚨 Either the password is actually correct, or there's a security issue"
        log_msg "🚨 Check your SSID configuration!"
        force_disconnect
    else
        if echo "$connection_output" | grep -qiE "auth|password|key"; then
            log_msg "✓ Authentication failed as expected - Mist should capture this"
        elif echo "$connection_output" | grep -qi "timeout"; then
            log_msg "✓ Connection timed out - Mist should capture this attempt"
        else
            log_msg "✓ Connection failed - Mist should capture this event"
        fi
    fi

    # Clean up
    nmcli connection delete "$connection_name" 2>/dev/null || true
    force_disconnect
    
    log_msg "✓ Authentication failure attempt completed"
    return 0
}

# Generate minimal traffic between attempts
generate_probe_traffic() {
    log_msg "Generating minimal probe traffic..."
    
    # Just scan for networks (generates probe requests)
    nmcli device wifi rescan ifname "$INTERFACE" 2>/dev/null || true
    
    # Count visible networks
    local network_count
    network_count=$(nmcli device wifi list ifname "$INTERFACE" 2>/dev/null | wc -l || echo "0")
    log_msg "📡 Probe scan completed: $network_count networks visible"
}

# --- Main loop ---
main_loop() {
    log_msg "Starting simple Wi-Fi bad client for Mist PoC demonstration"
    log_msg "Interface: $INTERFACE, Hostname: $HOSTNAME"
    log_msg "Purpose: Trigger Mist automatic PCAP capture with authentication failures"

    local cycle_count=0
    local last_config_check=0
    local password_index=0

    while true; do
        local current_time
        current_time="$(date +%s)"
        ((++cycle_count))

        log_msg "=== Bad Client Cycle $cycle_count ==="

        # Re-read SSID every 10 minutes
        if [[ $((current_time - last_config_check)) -gt 600 ]]; then
            if read_wifi_config; then
                last_config_check="$current_time"
                log_msg "Config refreshed"
            else
                log_msg "⚠ Config read failed, keeping previous SSID"
            fi
        fi

        if ! check_wifi_interface; then
            log_msg "✗ Wi-Fi interface check failed"
            sleep "$REFRESH_INTERVAL"
            continue
        fi

        if scan_for_ssid "$SSID"; then
            # Rotate through different wrong passwords
            local wrong_password="${WRONG_PASSWORDS[$password_index]}"
            password_index=$(( (password_index + 1) % ${#WRONG_PASSWORDS[@]} ))
            
            # Attempt connection with wrong password (should trigger Mist PCAP)
            attempt_connection_with_wrong_password "$SSID" "$wrong_password"
            
            # Generate some probe traffic
            generate_probe_traffic
            
        else
            log_msg "Target SSID not visible, performing rescan..."
            generate_probe_traffic
        fi

        # Clean up any lingering connections
        nmcli connection show 2>/dev/null | grep -E "^mist-bad-client-" | awk '{print $1}' | \
            while read -r conn; do 
                [[ -n "$conn" ]] && nmcli connection delete "$conn" 2>/dev/null || true
            done

        force_disconnect
        log_msg "Bad client cycle $cycle_count completed, waiting $REFRESH_INTERVAL seconds"
        log_msg "Next attempt will use password: ***${WRONG_PASSWORDS[$password_index]: -3}"
        sleep "$REFRESH_INTERVAL"
    done
}

cleanup_and_exit() {
    log_msg "Cleaning up Wi-Fi bad client simulation..."
    force_disconnect
    
    # Clean up any remaining connections
    nmcli connection show 2>/dev/null | grep -E "^mist-bad-client-" | awk '{print $1}' | \
        while read -r c; do nmcli connection delete "$c" 2>/dev/null || true; done
        
    log_msg "Wi-Fi bad client simulation stopped"
    exit 0
}

trap cleanup_and_exit SIGTERM SIGINT

# --- Bootstrap ---
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
log_msg "Simple Wi-Fi Bad Client for Mist PoC Starting..."
log_msg "Purpose: Generate authentication failures to trigger Mist automatic PCAP capture"
log_msg "Target interface: $INTERFACE"
log_msg "Hostname: $HOSTNAME"

if ! read_wifi_config; then
    log_msg "✗ Failed to read initial config; defaulting SSID to TestNetwork"
    SSID="TestNetwork"
fi

check_wifi_interface || true
force_disconnect || true

# Start main loop
main_loop