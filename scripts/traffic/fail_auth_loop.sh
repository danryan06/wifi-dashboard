#!/usr/bin/env bash
set -euo pipefail

# Wi-Fi Bad Client Simulation
# Continuously attempts to connect with wrong credentials to generate auth failures

INTERFACE="wlan1"
HOSTNAME="CNXNMist-WiFiBad"
LOG_FILE="/home/pi/wifi_test_dashboard/logs/wifi-bad.log"
CONFIG_FILE="/home/pi/wifi_test_dashboard/configs/ssid.conf"
SETTINGS="/home/pi/wifi_test_dashboard/configs/settings.conf"

# Source settings if available
[[ -f "$SETTINGS" ]] && source "$SETTINGS" || true

# Override with environment variables if set
INTERFACE="${WIFI_BAD_INTERFACE:-$INTERFACE}"
HOSTNAME="${WIFI_BAD_HOSTNAME:-$HOSTNAME}"
REFRESH_INTERVAL="${WIFI_BAD_REFRESH_INTERVAL:-45}"
BAD_PASSWORD="${WIFI_BAD_PASSWORD:-wrongpassword123}"
CONNECTION_TIMEOUT="${WIFI_CONNECTION_TIMEOUT:-30}"

# Array of wrong passwords to cycle through
BAD_PASSWORDS=(
    "wrongpassword123"
    "badpassword"
    "incorrectpwd"
    "hackme123"
    "password123"
    "admin123"
    "guest"
    "12345678"
    "qwerty123"
    "letmein"
)

log_msg() {
    echo "[$(date '+%F %T')] WIFI-BAD: $1" | tee -a "$LOG_FILE"
}

# Read Wi-Fi SSID from config file (but use wrong password)
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
    
    if [[ -z "$SSID" ]]; then
        log_msg "✗ SSID is empty"
        return 1
    fi
    
    log_msg "✓ Target SSID loaded: $SSID (will use wrong passwords)"
    return 0
}

# Check if Wi-Fi interface exists and is managed
check_wifi_interface() {
    if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
        log_msg "✗ Wi-Fi interface $INTERFACE not found"
        return 1
    fi
    
    # Ensure NetworkManager manages this interface
    if ! nmcli device show "$INTERFACE" >/dev/null 2>&1; then
        log_msg "Setting $INTERFACE to managed mode"
        sudo nmcli device set "$INTERFACE" managed yes || true
        sleep 2
    fi
    
    local state=$(nmcli device show "$INTERFACE" | grep 'GENERAL.STATE' | awk '{print $2}')
    log_msg "Interface $INTERFACE state: $state"
    
    return 0
}

# Check if SSID is available for connection
scan_for_ssid() {
    local target_ssid="$1"
    
    log_msg "Scanning for SSID: $target_ssid"
    
    # Trigger a Wi-Fi scan
    nmcli device wifi rescan ifname "$INTERFACE" 2>/dev/null || true
    sleep 3
    
    # Check if our target SSID is visible
    if nmcli device wifi list ifname "$INTERFACE" | grep -q "$target_ssid"; then
        log_msg "✓ Target SSID '$target_ssid' is visible"
        return 0
    else
        log_msg "✗ Target SSID '$target_ssid' not found in scan"
        return 1
    fi
}

# Attempt connection with wrong password (should fail)
attempt_bad_connection() {
    local ssid="$1"
    local wrong_password="$2"
    local connection_name="wifi-bad-$RANDOM"
    
    log_msg "Attempting connection with wrong password: $wrong_password"
    
    # Create temporary connection with wrong password
    if nmcli connection add \
        type wifi \
        con-name "$connection_name" \
        ifname "$INTERFACE" \
        ssid "$ssid" \
        wifi-sec.key-mgmt wpa-psk \
        wifi-sec.psk "$wrong_password" \
        ipv4.method auto \
        ipv6.method auto >/dev/null 2>&1; then
        
        log_msg "Created temporary bad connection: $connection_name"
    else
        log_msg "✗ Failed to create connection profile"
        return 1
    fi
    
    # Set hostname for DHCP identification (if it somehow connects)
    if command -v hostnamectl >/dev/null 2>&1; then
        sudo hostnamectl set-hostname "$HOSTNAME" 2>/dev/null || true
    fi
    
    # Attempt to connect (this should fail due to wrong password)
    log_msg "Attempting connection to $ssid (expected to fail)..."
    
    local connection_result=0
    if timeout "$CONNECTION_TIMEOUT" nmcli connection up "$connection_name" 2>/dev/null; then
        log_msg "🚨 UNEXPECTED: Connection succeeded with wrong password!"
        log_msg "This indicates a security issue with the target network"
        connection_result=0
    else
        log_msg "✓ Connection failed as expected (authentication failure)"
        connection_result=1
    fi
    
    # Clean up the connection profile
    nmcli connection delete "$connection_name" 2>/dev/null || true
    
    return $connection_result
}

# Generate authentication failure patterns
generate_auth_failure_patterns() {
    local ssid="$1"
    local pattern_count=0
    
    # Pattern 1: Rapid consecutive failures
    log_msg "Pattern 1: Rapid authentication failures"
    for i in {1..3}; do
        local bad_pwd=${BAD_PASSWORDS[$((RANDOM % ${#BAD_PASSWORDS[@]}))]}
        attempt_bad_connection "$ssid" "$bad_pwd"
        ((pattern_count++))
        sleep 2
    done
    
    # Pattern 2: Different password variations
    log_msg "Pattern 2: Common password variations"
    local base_passwords=("password" "admin" "guest")
    for base in "${base_passwords[@]}"; do
        for suffix in "123" "1" ""; do
            attempt_bad_connection "$ssid" "${base}${suffix}"
            ((pattern_count++))
            sleep 3
        done
    done
    
    # Pattern 3: Brute force simulation (slow)
    log_msg "Pattern 3: Slow brute force simulation"
    local brute_passwords=("12345678" "qwerty123" "letmein" "hackme")
    for pwd in "${brute_passwords[@]}"; do
        attempt_bad_connection "$ssid" "$pwd"
        ((pattern_count++))
        sleep 5  # Slower for brute force pattern
    done
    
    log_msg "Completed authentication failure pattern ($pattern_count attempts)"
    return 0
}

# Simulate various attack patterns
simulate_attack_patterns() {
    local ssid="$1"
    
    # Disconnect any existing connections
    nmcli device disconnect "$INTERFACE" 2>/dev/null || true
    sleep 2
    
    log_msg "Starting attack pattern simulation against: $ssid"
    
    # Pattern A: Dictionary attack simulation
    log_msg "Simulating dictionary attack..."
    local dict_passwords=(
        "password" "123456" "password123" "admin" "qwerty" 
        "letmein" "welcome" "monkey" "1234567890" "dragon"
    )
    
    for dict_pwd in "${dict_passwords[@]}"; do
        attempt_bad_connection "$ssid" "$dict_pwd"
        sleep $((RANDOM % 5 + 2))  # Random delay 2-6 seconds
    done
    
    # Pattern B: Common enterprise passwords
    log_msg "Simulating enterprise password attempts..."
    local enterprise_passwords=(
        "Company123" "Welcome1" "Password1" "Admin123"
        "Guest123" "Temp123" "Change123" "Default1"
    )
    
    for ent_pwd in "${enterprise_passwords[@]}"; do
        attempt_bad_connection "$ssid" "$ent_pwd"
        sleep $((RANDOM % 4 + 3))  # Random delay 3-6 seconds
    done
    
    # Pattern C: Targeted attacks (based on SSID)
    log_msg "Simulating targeted password attempts..."
    local ssid_lower=$(echo "$ssid" | tr '[:upper:]' '[:lower:]')
    local targeted_passwords=(
        "${ssid_lower}123"
        "${ssid_lower}1"
        "${ssid_lower}password"
        "${ssid_lower}2023"
        "${ssid_lower}2024"
        "${ssid_lower}wifi"
    )
    
    for target_pwd in "${targeted_passwords[@]}"; do
        attempt_bad_connection "$ssid" "$target_pwd"
        sleep $((RANDOM % 6 + 2))  # Random delay 2-7 seconds
    done
}

# Monitor and log wireless events
monitor_wireless_events() {
    # Check for any successful connections (shouldn't happen)
    local current_ssid=$(nmcli -t -f active,ssid dev wifi | grep '^yes' | cut -d':' -f2)
    
    if [[ -n "$current_ssid" ]]; then
        if [[ "$current_ssid" == "$SSID" ]]; then
            log_msg "🚨 WARNING: Successfully connected to target SSID!"
            log_msg "This indicates the authentication failure simulation failed"
            
            # Disconnect immediately
            nmcli device disconnect "$INTERFACE"
            log_msg "Disconnected from unexpected successful connection"
        else
            log_msg "Connected to different SSID: $current_ssid (disconnecting)"
            nmcli device disconnect "$INTERFACE"
        fi
    fi
    
    # Get signal strength and other wireless info
    if command -v iwconfig >/dev/null 2>&1; then
        local wifi_info=$(iwconfig "$INTERFACE" 2>/dev/null | grep -E "(Signal|Quality)" || echo "No signal info")
        log_msg "Wireless status: $wifi_info"
    fi
}

# Generate deauthentication simulation
simulate_deauth_attempts() {
    log_msg "Simulating deauthentication scenarios..."
    
    # Simulate rapid connect/disconnect cycles
    for i in {1..3}; do
        log_msg "Deauth simulation cycle $i"
        
        # Quick connection attempt
        local temp_connection="deauth-test-$RANDOM"
        local bad_pwd=${BAD_PASSWORDS[$((RANDOM % ${#BAD_PASSWORDS[@]}))]}
        
        # Create connection
        if nmcli connection add \
            type wifi \
            con-name "$temp_connection" \
            ifname "$INTERFACE" \
            ssid "$SSID" \
            wifi-sec.key-mgmt wpa-psk \
            wifi-sec.psk "$bad_pwd" >/dev/null 2>&1; then
            
            # Quick attempt and immediate cancellation
            timeout 10 nmcli connection up "$temp_connection" 2>/dev/null || true
            sleep 1
            nmcli connection down "$temp_connection" 2>/dev/null || true
            nmcli connection delete "$temp_connection" 2>/dev/null || true
            
            log_msg "Deauth cycle $i completed"
        fi
        
        sleep $((RANDOM % 3 + 2))
    done
}

# Main bad client loop
main_loop() {
    log_msg "Starting Wi-Fi bad client simulation (interface: $INTERFACE, hostname: $HOSTNAME)"
    log_msg "This will generate authentication failures for security testing"
    
    local cycle_count=0
    local last_config_check=0
    
    while true; do
        local current_time=$(date +%s)
        ((cycle_count++))
        
        log_msg "=== Bad Client Cycle $cycle_count ==="
        
        # Re-read config periodically (every 10 minutes)
        if [[ $((current_time - last_config_check)) -gt 600 ]]; then
            if read_wifi_config; then
                last_config_check=$current_time
                log_msg "Config refreshed"
            else
                log_msg "⚠ Config read failed, using previous values"
            fi
        fi
        
        if ! check_wifi_interface; then
            log_msg "✗ Wi-Fi interface check failed"
            sleep $REFRESH_INTERVAL
            continue
        fi
        
        # Monitor for any unexpected connections
        monitor_wireless_events
        
        # Scan for target SSID
        if scan_for_ssid "$SSID"; then
            # Choose attack pattern based on cycle
            case $((cycle_count % 4)) in
                0)
                    generate_auth_failure_patterns "$SSID"
                    ;;
                1)
                    simulate_attack_patterns "$SSID"
                    ;;
                2)
                    simulate_deauth_attempts
                    ;;
                *)
                    # Basic authentication failures
                    local random_bad_pwd=${BAD_PASSWORDS[$((RANDOM % ${#BAD_PASSWORDS[@]}))]}
                    attempt_bad_connection "$SSID" "$random_bad_pwd"
                    ;;
            esac
        else
            log_msg "Target SSID not available, scanning again..."
            # If SSID not found, try a few more scans
            for retry in {1..3}; do
                sleep 10
                if scan_for_ssid "$SSID"; then
                    break
                fi
                log_msg "Scan retry $retry failed"
            done
        fi
        
        # Ensure we're disconnected before next cycle
        nmcli device disconnect "$INTERFACE" 2>/dev/null || true
        
        log_msg "Bad client cycle $cycle_count completed, waiting $REFRESH_INTERVAL seconds"
        sleep $REFRESH_INTERVAL
    done
}

# Cleanup function
cleanup_and_exit() {
    log_msg "Cleaning up Wi-Fi bad client simulation..."
    
    # Disconnect and clean up any remaining connections
    nmcli device disconnect "$INTERFACE" 2>/dev/null || true
    
    # Remove any temporary connections we may have created
    nmcli connection show | grep "wifi-bad-" | awk '{print $1}' | while read -r conn; do
        nmcli connection delete "$conn" 2>/dev/null || true
    done
    
    log_msg "Wi-Fi bad client simulation stopped"
    exit 0
}

# Signal handlers
trap cleanup_and_exit SIGTERM SIGINT

# Initial setup
log_msg "Wi-Fi Bad Client Simulation Starting..."
log_msg "Purpose: Generate authentication failures for security testing"
log_msg "Target interface: $INTERFACE"
log_msg "Hostname: $HOSTNAME"

# Initial config read
if ! read_wifi_config; then
    log_msg "✗ Failed to read initial configuration"
    log_msg "Will use default wrong passwords against any available SSIDs"
    SSID="TestNetwork"  # Default for testing
fi

# Start main loop
main_loop