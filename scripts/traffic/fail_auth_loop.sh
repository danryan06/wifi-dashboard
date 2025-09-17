#!/usr/bin/env bash
set -euo pipefail

# Wi-Fi Bad Client - Simplified and Fixed
# Generates authentication failures for security testing



INTERFACE="${INTERFACE:-wlan1}"
HOSTNAME="CNXNMist-WiFiBad"
LOG_FILE="/home/pi/wifi_test_dashboard/logs/wifi-bad.log"
CONFIG_FILE="/home/pi/wifi_test_dashboard/configs/ssid.conf"
SETTINGS="/home/pi/wifi_test_dashboard/configs/settings.conf"

# Ensure system hostname is set correctly
if command -v hostnamectl >/dev/null 2>&1; then
  sudo hostnamectl set-hostname "$HOSTNAME" 2>/dev/null || true
fi

# Keep service alive on errors
set +e

log_msg() {
    local msg="[$(date '+%F %T')] WIFI-BAD: $1"
    echo "$msg" | tee -a "$LOG_FILE"
}

# Create log directory
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

# Load settings
[[ -f "$SETTINGS" ]] && source "$SETTINGS" || true

INTERFACE="${WIFI_BAD_INTERFACE:-$INTERFACE}"
HOSTNAME="${WIFI_BAD_HOSTNAME:-$HOSTNAME}"
REFRESH_INTERVAL="${WIFI_BAD_REFRESH_INTERVAL:-45}"
CONNECTION_TIMEOUT="${WIFI_CONNECTION_TIMEOUT:-20}"

# Wrong passwords to use
WRONG_PASSWORDS=(
    "wrongpassword123"
    "incorrectpwd"
    "badpassword"
    "admin123"
    "guest123"
    "password123"
)

# Read Wi-Fi SSID (but use wrong password)
read_wifi_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_msg "✗ Config file not found: $CONFIG_FILE"
        return 1
    fi

    local lines
    mapfile -t lines < "$CONFIG_FILE"
    if [[ ${#lines[@]} -lt 1 ]]; then
        log_msg "✗ Config file incomplete (need at least SSID)"
        return 1
    fi

    SSID="${lines[0]}"
    if [[ -z "$SSID" ]]; then
        log_msg "✗ SSID is empty"
        return 1
    fi

    log_msg "✓ Target SSID loaded: $SSID"
    return 0
}

# Check interface
check_wifi_interface() {
    if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
        log_msg "✗ Wi-Fi interface $INTERFACE not found"
        return 1
    fi

    # Bring interface up
    if ! ip link show "$INTERFACE" | grep -q "state UP"; then
        log_msg "Bringing $INTERFACE up..."
        sudo ip link set "$INTERFACE" up 2>/dev/null || true
        sleep 2
    fi

    # Ensure NetworkManager manages interface
    if ! nmcli device show "$INTERFACE" >/dev/null 2>&1; then
        log_msg "Setting $INTERFACE to managed mode"
        sudo nmcli device set "$INTERFACE" managed yes 2>/dev/null || true
        sleep 2
    fi

    return 0
}

# Scan for target SSID
scan_for_ssid() {
    local target_ssid="$1"
    log_msg "Scanning for target SSID: $target_ssid"
    
    nmcli device wifi rescan ifname "$INTERFACE" 2>/dev/null || true
    sleep 3
    
    if nmcli device wifi list ifname "$INTERFACE" 2>/dev/null | grep -Fq "$target_ssid"; then
        log_msg "✓ Target SSID '$target_ssid' is visible"
        return 0
    fi
    
    log_msg "✗ Target SSID '$target_ssid' not found"
    return 1
}

# Force disconnect
force_disconnect() {
    log_msg "Ensuring $INTERFACE is disconnected"
    nmcli device disconnect "$INTERFACE" 2>/dev/null || true
    sleep 1
}

# Attempt connection with wrong password
attempt_bad_connection() {
    local ssid="$1"
    local wrong_password="$2"
    local connection_name="bad-client-$RANDOM"

    log_msg "Attempting connection with wrong password: ***${wrong_password: -3}"

    force_disconnect
    
    # Create connection with wrong password
    if nmcli connection add \
        type wifi \
        con-name "$connection_name" \
        ifname "$INTERFACE" \
        ssid "$ssid" \
        wifi-sec.key-mgmt wpa-psk \
        wifi-sec.psk "$wrong_password" \
        ipv4.method disabled \
        ipv6.method ignore >/dev/null 2>&1; then
        
        log_msg "✓ Created connection with wrong password"
    else
        log_msg "✗ Failed to create connection"
        return 1
    fi

    # Attempt connection (should fail)
    log_msg "Attempting connection (expecting auth failure)..."
    if timeout "$CONNECTION_TIMEOUT" nmcli connection up "$connection_name" >/dev/null 2>&1; then
        log_msg "🚨 WARNING: Connection succeeded with wrong password!"
        force_disconnect
    else
        log_msg "✓ Authentication failed as expected"
    fi

    # Clean up
    nmcli connection delete "$connection_name" 2>/dev/null || true
    force_disconnect
    
    log_msg "✓ Authentication failure attempt completed"
    return 0
}

# Generate probe traffic
generate_probe_traffic() {
    log_msg "Generating probe traffic..."
    nmcli device wifi rescan ifname "$INTERFACE" 2>/dev/null || true
    local network_count
    network_count=$(nmcli device wifi list ifname "$INTERFACE" 2>/dev/null | wc -l || echo "0")
    log_msg "📡 Probe scan completed: $network_count networks visible"
}

# Main loop
main_loop() {
    log_msg "Starting Wi-Fi bad client for authentication failure testing"
    log_msg "Interface: $INTERFACE, Hostname: $HOSTNAME"

    local cycle_count=0
    local last_config_check=0
    local password_index=0

    while true; do
        local current_time
        current_time=$(date +%s)
        cycle_count=$((cycle_count + 1))

        log_msg "=== Bad Client Cycle $cycle_count ==="

        # Re-read config every 10 minutes
        if [[ $((current_time - last_config_check)) -gt 600 ]]; then
            if read_wifi_config; then
                last_config_check=$current_time
                log_msg "Config refreshed"
            else
                log_msg "⚠ Config read failed, keeping previous SSID"
            fi
        fi

        # Check interface
        if ! check_wifi_interface; then
            log_msg "✗ Wi-Fi interface check failed"
            sleep "$REFRESH_INTERVAL"
            continue
        fi

        # Scan for SSID
        if scan_for_ssid "$SSID"; then
            # Use wrong password
            local wrong_password="${WRONG_PASSWORDS[$password_index]}"
            password_index=$(( (password_index + 1) % ${#WRONG_PASSWORDS[@]} ))
            
            # Attempt connection (should fail)
            attempt_bad_connection "$SSID" "$wrong_password"
            
            # Generate probe traffic
            generate_probe_traffic
        else
            log_msg "Target SSID not visible, performing scan..."
            generate_probe_traffic
        fi

        # Clean up any leftover connections
        nmcli connection show 2>/dev/null | grep -E "^bad-client-" | awk '{print $1}' | \
            while read -r conn; do
                [[ -n "$conn" ]] && nmcli connection delete "$conn" 2>/dev/null || true
            done

        force_disconnect
        log_msg "Bad client cycle $cycle_count completed, waiting $REFRESH_INTERVAL seconds"
        sleep "$REFRESH_INTERVAL"
    done
}

# Cleanup
cleanup_and_exit() {
    log_msg "Cleaning up Wi-Fi bad client simulation..."
    force_disconnect
    
    # Clean up connections
    nmcli connection show 2>/dev/null | grep -E "^bad-client-" | awk '{print $1}' | \
        while read -r conn; do
            [[ -n "$conn" ]] && nmcli connection delete "$conn" 2>/dev/null || true
        done
        
    log_msg "Wi-Fi bad client simulation stopped"
    exit 0
}

trap cleanup_and_exit SIGTERM SIGINT EXIT

# Initialize
log_msg "Wi-Fi Bad Client Starting..."
log_msg "Purpose: Generate authentication failures for security testing"

# Initial config read
if ! read_wifi_config; then
    log_msg "✗ Failed to read config, using default"
    SSID="TestNetwork"
fi

check_wifi_interface || true
force_disconnect || true

# Start main loop
main_loop