#!/usr/bin/env bash
set -euo pipefail

# Wi-Fi Bad Client - FIXED to Actually Attempt Associations
# Generates real authentication failures that will show up in Mist logs

INTERFACE="${INTERFACE:-wlan1}"
HOSTNAME="CNXNMist-WiFiBad"
LOG_FILE="/home/pi/wifi_test_dashboard/logs/wifi-bad.log"
CONFIG_FILE="/home/pi/wifi_test_dashboard/configs/ssid.conf"
SETTINGS="/home/pi/wifi_test_dashboard/configs/settings.conf"

# Ensure system hostname is set correctly
#if command -v hostnamectl >/dev/null 2>&1; then
 # sudo hostnamectl set-hostname "$HOSTNAME" 2>/dev/null || true
# fi

# Keep service alive on errors - don't exit on failures
set +e

# --- Privilege helper for nmcli ---
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  SUDO="sudo"
else
  SUDO=""
fi

log_msg() {
    local msg="[$(date '+%F %T')] WIFI-BAD: $1"
    echo "$msg" | tee -a "$LOG_FILE"
}

set_device_hostname() {
    local desired_hostname="$1"
    local interface="$2"
    
    log_msg "🏷️ Setting DHCP hostname to: $desired_hostname for interface $interface (NOT changing system hostname)"
    
    # Get the MAC address for this interface for logging
    local mac_addr=$(ip link show "$interface" 2>/dev/null | awk '/link\/ether/ {print $2}' || echo "unknown")
    log_msg "📱 Interface $interface MAC address: $mac_addr"
    
    # REMOVED: Don't set system hostname - causes conflicts between services
    # Instead, only set DHCP hostname for this specific interface
    
    # Method 1: Set NetworkManager DHCP hostname for this interface
    log_msg "🌐 Setting DHCP hostname for interface $interface connections"
    
    # Configure all existing connections on this interface
    local existing_connections
    existing_connections=$($SUDO nmcli -t -f NAME,DEVICE connection show --active | grep ":$interface$" | cut -d: -f1)
    
    if [[ -n "$existing_connections" ]]; then
        while read -r connection_name; do
            if [[ -n "$connection_name" ]]; then
                log_msg "🔧 Updating connection '$connection_name' DHCP hostname to '$desired_hostname'"
                $SUDO nmcli connection modify "$connection_name" \
                    connection.dhcp-hostname "$desired_hostname" \
                    ipv4.dhcp-hostname "$desired_hostname" \
                    ipv4.dhcp-send-hostname yes \
                    ipv6.dhcp-hostname "$desired_hostname" \
                    ipv6.dhcp-send-hostname yes 2>/dev/null && \
                    log_msg "✅ Updated connection '$connection_name'" || \
                    log_msg "⚠️ Failed to update connection '$connection_name'"
            fi
        done <<< "$existing_connections"
    fi
    
    # Method 2: Create interface-specific dhclient config
    configure_dhcp_hostname "$desired_hostname" "$interface"
    
    log_msg "✅ Interface $interface configured to send DHCP hostname: $desired_hostname"
    return 0
}

setup_system_hostname() {
    local system_hostname="${1:-CNXNMist-Dashboard}"
    
    log_msg "🏠 Setting up system hostname (one-time): $system_hostname"
    
    # Method 1: Set system hostname via hostnamectl
    if command -v hostnamectl >/dev/null 2>&1; then
        if $SUDO hostnamectl set-hostname "$system_hostname" 2>/dev/null; then
            log_msg "✅ System hostname set via hostnamectl: $system_hostname"
        else
            log_msg "❌ Failed to set hostname via hostnamectl"
        fi
    fi
    
    # Method 2: Update /etc/hostname
    if echo "$system_hostname" | $SUDO tee /etc/hostname >/dev/null 2>&1; then
        log_msg "✅ Updated /etc/hostname: $system_hostname"
    else
        log_msg "❌ Failed to update /etc/hostname"
    fi
# Method 3: Fix /etc/hosts properly
    $SUDO cp /etc/hosts /etc/hosts.backup.$(date +%s) 2>/dev/null || true
    
    # Remove old 127.0.1.1 entries and add new one
    $SUDO sed -i '/^127\.0\.1\.1/d' /etc/hosts 2>/dev/null || true
    echo "127.0.1.1    $system_hostname" | $SUDO tee -a /etc/hosts >/dev/null
    
    log_msg "✅ Updated /etc/hosts with system hostname: $system_hostname"
    
    # Verify
    local actual_hostname=$(hostname)
    if [[ "$actual_hostname" == "$system_hostname" ]]; then
        log_msg "✅ System hostname verification successful: $actual_hostname"
    else
        log_msg "⚠️ System hostname verification: expected '$system_hostname', got '$actual_hostname'"
    fi
    
    return 0
}
# =============================================================================
# 2. Enhanced DHCP Client Configuration
# =============================================================================

configure_dhcp_hostname() {
    local hostname="$1"
    local interface="$2"
    
    log_msg "🌐 Configuring DHCP to send hostname: $hostname for $interface"
    
    # Create dhclient configuration for this interface
    local dhclient_conf="/etc/dhcp/dhclient-${interface}.conf"
    
    $SUDO mkdir -p /etc/dhcp
    
    cat <<EOF | $SUDO tee "$dhclient_conf" >/dev/null
# DHCP client configuration for $interface
# Generated by Wi-Fi Dashboard

# Send hostname in DHCP requests
send host-name "$hostname";

# Request hostname from server
request subnet-mask, broadcast-address, time-offset, routers,
        domain-name, domain-name-servers, domain-search, host-name,
        dhcp6.name-servers, dhcp6.domain-search, dhcp6.fqdn, dhcp6.sntp-servers,
        netbios-name-servers, netbios-scope, interface-mtu,
        rfc3442-classless-static-routes, ntp-servers;

# Override any server-provided hostname
supersede host-name "$hostname";
EOF
    
    log_msg "✅ Created DHCP client config: $dhclient_conf"
    
    # Also configure NetworkManager to use this dhclient config
    local nm_conf="/etc/NetworkManager/conf.d/dhcp-hostname-${interface}.conf"
    
    cat <<EOF | $SUDO tee "$nm_conf" >/dev/null
[connection-dhcp-${interface}]
match-device=interface-name:${interface}

[ipv4]
dhcp-hostname=${hostname}
dhcp-send-hostname=yes

[ipv6]
dhcp-hostname=${hostname}
dhcp-send-hostname=yes
EOF
    
    log_msg "✅ Created NetworkManager DHCP config: $nm_conf"
    
    # Reload NetworkManager configuration
    $SUDO nmcli general reload || true
    
    return 0
}

# =============================================================================
# 3. MAC Address Verification and Logging
# =============================================================================

verify_device_identity() {
    local interface="$1"
    local expected_hostname="$2"
    
    log_msg "🔍 Verifying device identity for $interface"
    
    # Get interface details
    local mac_addr=$(ip link show "$interface" 2>/dev/null | awk '/link\/ether/ {print $2}' || echo "unknown")
    local ip_addr=$(ip -4 addr show "$interface" 2>/dev/null | awk '/inet / {print $2}' | head -1 || echo "none")
    local current_hostname=$(hostname)
    
    # Log all identity information
    log_msg "📊 Device Identity Report:"
    log_msg "   Interface: $interface"
    log_msg "   MAC Address: $mac_addr"
    log_msg "   IP Address: $ip_addr"
    log_msg "   Current Hostname: $current_hostname"
    log_msg "   Expected Hostname: $expected_hostname"
    
    # Check if we're connected and get BSSID info
    local bssid=""
    local ssid=""
    
    if $SUDO nmcli device show "$interface" 2>/dev/null | grep -q "connected"; then
        bssid=$($SUDO nmcli -t -f active,bssid dev wifi 2>/dev/null | awk -F: '$1=="yes"{print $2; exit}' || echo "unknown")
        ssid=$($SUDO nmcli -t -f active,ssid dev wifi 2>/dev/null | awk -F: '$1=="yes"{print $2; exit}' || echo "unknown")
        
        log_msg "   Connected SSID: $ssid"
        log_msg "   Connected BSSID: $bssid"
    else
        log_msg "   Connection Status: Not connected"
    fi
    
    # Create identity file for debugging
    local identity_file="/home/pi/wifi_test_dashboard/identity_${interface}.json"
    cat > "$identity_file" << EOF
{
    "interface": "$interface",
    "mac_address": "$mac_addr",
    "ip_address": "$ip_addr",
    "hostname": "$current_hostname",
    "expected_hostname": "$expected_hostname",
    "ssid": "$ssid",
    "bssid": "$bssid",
    "timestamp": "$(date -Iseconds)"
}
EOF
    
    log_msg "✅ Identity information saved to: $identity_file"
    
    return 0
}

# =============================================================================
# 4. Connection Setup with Proper Hostname Assignment
# =============================================================================

connect_with_hostname() {
    local ssid="$1"
    local password="$2"
    local interface="$3"
    local desired_hostname="$4"
    
    log_msg "🔗 Connecting $interface to '$ssid' with hostname '$desired_hostname'"
    
    # Step 1: Set hostname BEFORE connection
    set_device_hostname "$desired_hostname" "$interface"
    
    # Step 2: Configure DHCP to send our hostname
    configure_dhcp_hostname "$desired_hostname" "$interface"
    
    # Step 3: Ensure clean connection state
    $SUDO nmcli device disconnect "$interface" 2>/dev/null || true
    sleep 2
    
    # Step 4: Connect with explicit hostname setting
    local connection_name="${desired_hostname}-wifi-$$"
    
    if $SUDO nmcli connection add \
        type wifi \
        con-name "$connection_name" \
        ifname "$interface" \
        ssid "$ssid" \
        wifi-sec.key-mgmt wpa-psk \
        wifi-sec.psk "$password" \
        connection.dhcp-hostname "$desired_hostname" \
        ipv4.dhcp-hostname "$desired_hostname" \
        ipv4.dhcp-send-hostname yes \
        ipv6.dhcp-hostname "$desired_hostname" \
        ipv6.dhcp-send-hostname yes \
        connection.autoconnect no 2>/dev/null; then
        
        log_msg "✅ Created connection profile with hostname: $desired_hostname"
        
        # Activate the connection
        if $SUDO nmcli connection up "$connection_name" 2>/dev/null; then
            log_msg "✅ Connection activated successfully"
            
            # Wait for DHCP and verify identity
            sleep 10
            verify_device_identity "$interface" "$desired_hostname"
            
            # Clean up connection profile (optional - or keep for reuse)
            # $SUDO nmcli connection delete "$connection_name" 2>/dev/null || true
            
            return 0
        else
            log_msg "❌ Failed to activate connection"
            $SUDO nmcli connection delete "$connection_name" 2>/dev/null || true
            return 1
        fi
    else
        log_msg "❌ Failed to create connection profile"
        return 1
    fi
}

# Create log directory
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

# Load settings
[[ -f "$SETTINGS" ]] && source "$SETTINGS" || true

INTERFACE="${WIFI_BAD_INTERFACE:-$INTERFACE}"
HOSTNAME="${WIFI_BAD_HOSTNAME:-$HOSTNAME}"
REFRESH_INTERVAL="${WIFI_BAD_REFRESH_INTERVAL:-45}"
CONNECTION_TIMEOUT="${WIFI_CONNECTION_TIMEOUT:-20}"

# Wrong passwords to cycle through
WRONG_PASSWORDS=(
    "wrongpassword123"
    "incorrectpwd"
    "badpassword"
    "admin123"
    "guest123"
    "password123"
    "letmein"
    "12345678"
    "qwerty"
    "hackme"
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
    # Trim whitespace
    SSID=$(echo "$SSID" | xargs)
    
    if [[ -z "$SSID" ]]; then
        log_msg "✗ SSID is empty after trimming"
        return 1
    fi

    log_msg "✓ Target SSID loaded: '$SSID'"
    return 0
}

# Check interface with enhanced validation
check_wifi_interface() {
    if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
        log_msg "✗ Wi-Fi interface $INTERFACE not found"
        return 1
    fi

    # Force interface up
    log_msg "Ensuring $INTERFACE is up..."
    $SUDO ip link set "$INTERFACE" up 2>/dev/null || true
    sleep 2

    # Ensure NetworkManager manages interface
    log_msg "Setting $INTERFACE to managed mode..."
    $SUDO nmcli device set "$INTERFACE" managed yes 2>/dev/null || true
    sleep 3

    # Check if interface is now managed
    local managed_state
    managed_state=$($SUDO nmcli device show "$INTERFACE" 2>/dev/null | grep "GENERAL.STATE" | awk '{print $2}' || echo "unknown")
    log_msg "Interface $INTERFACE state: $managed_state"

    return 0
}

# Enhanced SSID scanning
scan_for_ssid() {
    local target_ssid="$1"
    log_msg "🔍 Scanning for target SSID: '$target_ssid'"
    
    # Force fresh scan
    log_msg "Triggering Wi-Fi rescan..."
    $SUDO nmcli device wifi rescan ifname "$INTERFACE" 2>/dev/null || true
    sleep 5
    
    # Check if SSID is visible
    local scan_results
    scan_results=$($SUDO nmcli device wifi list ifname "$INTERFACE" 2>/dev/null || echo "")
    
    if [[ -z "$scan_results" ]]; then
        log_msg "✗ No scan results returned"
        return 1
    fi
    
    # Debug: Show first few networks found
    local network_count
    network_count=$(echo "$scan_results" | wc -l)
    log_msg "📋 Scan found $network_count networks"
    
    if echo "$scan_results" | grep -F "$target_ssid" >/dev/null; then
        log_msg "✓ Target SSID '$target_ssid' is visible in scan results"
        return 0
    else
        log_msg "✗ Target SSID '$target_ssid' not found in scan results"
        # Debug: Show what SSIDs we did find (first 5)
        log_msg "Available SSIDs:"
        echo "$scan_results" | awk 'NR>1 {print $2}' | head -5 | while read -r found_ssid; do
            [[ -n "$found_ssid" ]] && log_msg "  - '$found_ssid'"
        done
        return 1
    fi
}

# Force disconnect with cleanup
force_disconnect() {
    log_msg "🔌 Ensuring $INTERFACE is disconnected and clean..."
    
    # Disconnect device
    $SUDO nmcli device disconnect "$INTERFACE" 2>/dev/null || true
    
    # Kill any existing wpa_supplicant for this interface
    pkill -f "wpa_supplicant.*$INTERFACE" 2>/dev/null || true
    
    # Clean up any temporary connection profiles
    local temp_connections
    temp_connections=$($SUDO nmcli -t -f NAME connection show 2>/dev/null | grep -E "^bad-client-|^wifi-bad-|^temp-bad-" || true)
    
    if [[ -n "$temp_connections" ]]; then
        echo "$temp_connections" | while read -r conn; do
            [[ -n "$conn" ]] && $SUDO nmcli connection delete "$conn" 2>/dev/null || true
        done
        log_msg "🧹 Cleaned up temporary connection profiles"
    fi
    
    sleep 2
}

# FIXED: Enhanced bad connection attempt that actually tries to associate
attempt_bad_connection() {
    local ssid="$1"
    local wrong_password="$2"
    local connection_name="bad-client-$(date +%s)-$RANDOM"

    log_msg "🔓 Attempting authentication with wrong password: '***${wrong_password: -3}' for SSID '$ssid'"

    # Ensure clean state
    force_disconnect

    # Method 1: Try nmcli connection profile (enhanced)
    log_msg "📝 Creating connection profile with wrong credentials..."
    
    local profile_created=false
    if $SUDO nmcli connection add \
        type wifi \
        con-name "$connection_name" \
        ifname "$INTERFACE" \
        ssid "$ssid" \
        wifi-sec.key-mgmt wpa-psk \
        wifi-sec.psk "$wrong_password" \
        ipv4.method manual \
        ipv4.addresses "192.168.255.1/24" \
        ipv6.method ignore \
        connection.autoconnect no 2>/dev/null; then
        
        profile_created=true
        log_msg "✓ Created connection profile with wrong password"
        
        # Attempt to activate profile (this should trigger auth failure)
        log_msg "🔌 Attempting activation (expecting auth failure)..."
        if timeout "$CONNECTION_TIMEOUT" $SUDO nmcli connection up "$connection_name" 2>&1; then
            log_msg "🚨 UNEXPECTED: Connection succeeded with wrong password!"
            log_msg "⚠️ This indicates a security issue with the target network"
        else
            log_msg "✓ Authentication failed as expected (profile method)"
        fi
        
        # Clean up profile
        $SUDO nmcli connection delete "$connection_name" 2>/dev/null || true
    else
        log_msg "✗ Failed to create connection profile"
    fi

    # Method 2: Direct nmcli device wifi connect (if profile method failed)
    if [[ "$profile_created" != "true" ]]; then
        log_msg "🔄 Trying direct nmcli device wifi connect..."
        
        local connect_output
        if connect_output=$(timeout "$CONNECTION_TIMEOUT" $SUDO nmcli device wifi connect "$ssid" password "$wrong_password" ifname "$INTERFACE" 2>&1); then
            log_msg "🚨 UNEXPECTED: Direct connect succeeded with wrong password!"
            log_msg "Output: $connect_output"
        else
            log_msg "✓ Direct connect authentication failed as expected"
            log_msg "Error output: $connect_output"
        fi
    fi

    # Method 3: Low-level wpa_supplicant attempt for maximum visibility
    log_msg "🔧 Attempting low-level wpa_supplicant connection..."
    
    local wpa_conf="/tmp/bad_client_$$.conf"
    cat > "$wpa_conf" << EOF
ctrl_interface=/run/wpa_supplicant
ctrl_interface_group=0
ap_scan=1
fast_reauth=1

network={
    ssid="$ssid"
    psk="$wrong_password"
    key_mgmt=WPA-PSK
    scan_ssid=1
    priority=1
}
EOF

    # Kill any existing wpa_supplicant
    pkill -f "wpa_supplicant.*$INTERFACE" 2>/dev/null || true
    sleep 1

    # Start wpa_supplicant with verbose logging
    if timeout "$CONNECTION_TIMEOUT" $SUDO wpa_supplicant -i "$INTERFACE" -c "$wpa_conf" -D nl80211 -d 2>/dev/null; then
        log_msg "🚨 UNEXPECTED: wpa_supplicant succeeded with wrong password!"
    else
        log_msg "✓ wpa_supplicant authentication failed as expected"
    fi

    # Cleanup
    pkill -f "wpa_supplicant.*$INTERFACE" 2>/dev/null || true
    rm -f "$wpa_conf"
    
    # Final cleanup
    force_disconnect
    
    log_msg "✅ Authentication failure cycle completed"
    return 0
}

# Generate additional probe traffic to increase visibility
generate_probe_traffic() {
    log_msg "📡 Generating probe request traffic..."
    
    # Force multiple scans to generate probe requests
    for i in {1..3}; do
        $SUDO nmcli device wifi rescan ifname "$INTERFACE" 2>/dev/null || true
        sleep 2
    done
    
    # List networks to generate more probe activity
    local network_count
    network_count=$($SUDO nmcli device wifi list ifname "$INTERFACE" 2>/dev/null | wc -l || echo "0")
    log_msg "📊 Probe scan cycle $i completed: $network_count networks visible"
    
    # Add some random delay to make traffic more realistic
    sleep $((2 + RANDOM % 3))
}

# Enhanced connection attempts with multiple wrong passwords
attempt_multiple_failures() {
    local ssid="$1"
    local attempts="${2:-3}"
    
    log_msg "🔥 Starting multiple authentication failure attempts for '$ssid'"
    
    for ((i=1; i<=attempts; i++)); do
        local wrong_password="${WRONG_PASSWORDS[$((RANDOM % ${#WRONG_PASSWORDS[@]}))]}"
        log_msg "📢 Attempt $i/$attempts with password variation"
        
        attempt_bad_connection "$ssid" "$wrong_password"
        
        # Add realistic delay between attempts
        if [[ $i -lt $attempts ]]; then
            local delay=$((5 + RANDOM % 10))
            log_msg "⏱️ Waiting ${delay}s before next attempt..."
            sleep "$delay"
        fi
    done
    
    log_msg "✅ Multiple authentication failure cycle completed"
}

eenhanced_bad_client_main_loop() {
    log_msg "🚀 Starting Wi-Fi bad client with ENHANCED identity management"
    log_msg "Interface: $INTERFACE, Hostname: $HOSTNAME"
    log_msg "Purpose: Generate visible authentication failures in Mist dashboard"

    # FIXED: Set up system hostname ONLY if not already set
    local current_system_hostname=$(hostname)
    if [[ "$current_system_hostname" == "localhost" ]] || [[ "$current_system_hostname" == "raspberrypi" ]] || [[ -z "$current_system_hostname" ]]; then
        setup_system_hostname "CNXNMist-Dashboard"
    else
        log_msg "🏠 System hostname already set: $current_system_hostname (not changing)"
    fi

    # Set DHCP hostname for THIS interface only
    set_device_hostname "$HOSTNAME" "$INTERFACE"
    configure_dhcp_hostname "$HOSTNAME" "$INTERFACE"
    
    # Verify our identity
    verify_device_identity "$INTERFACE" "$HOSTNAME"

    local cycle_count=0
    local last_config_check=0
    local last_identity_check=0

    while true; do
        local current_time
        current_time=$(date +%s)
        cycle_count=$((cycle_count + 1))

        log_msg "🔴 === Bad Client Cycle $cycle_count ==="

        # Re-verify identity periodically (every 5 minutes)  
        if [[ $((current_time - last_identity_check)) -gt 300 ]]; then
            log_msg "🔍 Periodic identity verification..."
            set_device_hostname "$HOSTNAME" "$INTERFACE"
            verify_device_identity "$INTERFACE" "$HOSTNAME"
            last_identity_check=$current_time
        fi

        # Re-read config periodically
        if [[ $((current_time - last_config_check)) -gt 600 ]]; then
            if read_wifi_config; then
                last_config_check=$current_time
                log_msg "✅ Config refreshed"
            else
                log_msg "⚠️ Config read failed, using previous SSID: '${SSID:-TestNetwork}'"
                SSID="${SSID:-TestNetwork}"
            fi
        fi

        # Check interface health
        if ! check_wifi_interface; then
            log_msg "✗ Wi-Fi interface check failed, retrying in $REFRESH_INTERVAL seconds"
            sleep "$REFRESH_INTERVAL"
            continue
        fi

        # Generate initial probe traffic
        generate_probe_traffic

        # Scan for target SSID
        if scan_for_ssid "$SSID"; then
            log_msg "🎯 Target SSID '$SSID' is available for authentication failure testing"
            
            # Determine number of attempts for this cycle (vary for realism)
            local attempt_count=$((2 + RANDOM % 3))  # 2-4 attempts
            log_msg "📋 Planning $attempt_count authentication failure attempts"
            
            # Execute multiple failure attempts
            attempt_multiple_failures "$SSID" "$attempt_count"
            
        else
            log_msg "❌ Target SSID '$SSID' not visible"
            log_msg "🔍 Performing extended scan for SSID discovery..."
            
            # Extended scanning when SSID not found
            for scan_retry in {1..3}; do
                log_msg "🔄 Extended scan attempt $scan_retry/3..."
                generate_probe_traffic
                if scan_for_ssid "$SSID"; then
                    log_msg "✅ Found SSID on retry $scan_retry"
                    break
                fi
                sleep 5
            done
        fi

        # Additional probe traffic at end of cycle
        generate_probe_traffic

        # Ensure complete disconnect and cleanup
        force_disconnect

        # Re-verify identity after each cycle
        verify_device_identity "$INTERFACE" "$HOSTNAME"

        # Vary the cycle timing slightly for more realistic behavior
        local actual_interval=$((REFRESH_INTERVAL + RANDOM % 15 - 7))
        log_msg "🔴 Bad client cycle $cycle_count completed, waiting ${actual_interval}s"
        log_msg "📊 Summary: Attempted auth failures against '$SSID' as '$HOSTNAME'"
        
        sleep "$actual_interval"
    done
}

# Enhanced cleanup
cleanup_and_exit() {
    log_msg "🧹 Cleaning up Wi-Fi bad client simulation..."
    
    # Kill any background processes
    pkill -f "wpa_supplicant.*$INTERFACE" 2>/dev/null || true
    
    # Force disconnect and cleanup
    force_disconnect
    
    # Remove any leftover temp files
    rm -f /tmp/bad_client_*.conf
    
    log_msg "✅ Wi-Fi bad client simulation stopped cleanly"
    exit 0
}

trap cleanup_and_exit SIGTERM SIGINT EXIT

# Initialize
log_msg "🔴 Wi-Fi Bad Client Starting (ENHANCED FOR MIST VISIBILITY)..."
log_msg "Purpose: Generate REAL authentication failures visible in Mist dashboard"
log_msg "Target interface: $INTERFACE"
log_msg "Expected hostname: $HOSTNAME"

# Initial config read
if ! read_wifi_config; then
    log_msg "✗ Failed to read config, using default test SSID"
    SSID="TestNetwork"
fi

# Initial interface setup
check_wifi_interface || true
force_disconnect || true

log_msg "🎯 Target SSID for auth failures: '$SSID'"
log_msg "🔥 Starting aggressive authentication failure generation..."

# Start main loop
enhanced_bad_client_main_loop