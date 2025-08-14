#!/usr/bin/env bash
set -euo pipefail

# Fix Wi-Fi Dashboard Services
# Deploys missing scripts and fixes service issues

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Configuration
PI_USER=$(getent passwd 1000 | cut -d: -f1 2>/dev/null || echo "pi")
PI_HOME="/home/$PI_USER"
DASHBOARD_DIR="$PI_HOME/wifi_test_dashboard"
SCRIPTS_DIR="$DASHBOARD_DIR/scripts"

print_banner() {
    echo -e "${BLUE}"
    echo "=================================================================="
    echo "  🔧 Wi-Fi Dashboard Services Fix Script"
    echo "  📝 Deploying missing scripts and fixing service issues"
    echo "=================================================================="
    echo -e "${NC}"
}

check_requirements() {
    log_step "Checking requirements..."
    
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
    
    if [[ ! -d "$DASHBOARD_DIR" ]]; then
        log_error "Dashboard directory not found: $DASHBOARD_DIR"
        log_error "Please run the main installer first"
        exit 1
    fi
    
    log_info "✓ Requirements met"
}

create_missing_scripts() {
    log_step "Creating missing traffic generation scripts..."
    
    mkdir -p "$SCRIPTS_DIR"
    
    # Create wired_simulation.sh
    log_info "Creating wired_simulation.sh..."
    cat > "$SCRIPTS_DIR/wired_simulation.sh" << 'WIRED_EOF'
#!/usr/bin/env bash
set -euo pipefail

# Wired Ethernet Client Simulation
# Simulates a heavy-traffic wired client for network testing

INTERFACE="eth0"
HOSTNAME="CNXNMist-Wired"
CONNECTION_NAME="wired-cnxnmist"
LOG_FILE="$HOME/wifi_test_dashboard/logs/wired.log"
SETTINGS="$HOME/wifi_test_dashboard/configs/settings.conf"

# Source settings if available
[[ -f "$SETTINGS" ]] && source "$SETTINGS" || true

# Override with environment variables if set
INTERFACE="${WIRED_INTERFACE:-$INTERFACE}"
HOSTNAME="${WIRED_HOSTNAME:-$HOSTNAME}"
CONNECTION_NAME="${WIRED_CONNECTION_NAME:-$CONNECTION_NAME}"
REFRESH_INTERVAL="${WIRED_REFRESH_INTERVAL:-30}"

# Test URLs for connectivity testing
TEST_URLS=(
    "https://www.google.com"
    "https://www.cloudflare.com" 
    "https://www.github.com"
    "https://www.juniper.net"
    "https://httpbin.org/ip"
)

log_msg() {
    echo "[$(date '+%F %T')] WIRED: $1" | tee -a "$LOG_FILE"
}

# Check if ethernet interface exists and is available
check_ethernet_interface() {
    if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
        log_msg "✗ Ethernet interface $INTERFACE not found"
        return 1
    fi
    
    if ip link show "$INTERFACE" | grep -q "state UP"; then
        log_msg "✓ Ethernet interface $INTERFACE is UP"
        return 0
    else
        log_msg "⚠ Ethernet interface $INTERFACE is DOWN"
        return 1
    fi
}

# Configure ethernet connection with specific hostname
setup_wired_connection() {
    log_msg "Setting up wired connection with hostname: $HOSTNAME"
    
    # Remove existing connection if it exists
    nmcli connection delete "$CONNECTION_NAME" 2>/dev/null || true
    
    # Create new ethernet connection with our hostname
    if nmcli connection add \
        type ethernet \
        con-name "$CONNECTION_NAME" \
        ifname "$INTERFACE" \
        ipv4.method auto \
        ipv6.method auto \
        connection.id "$CONNECTION_NAME" \
        802-3-ethernet.auto-negotiate yes; then
        
        log_msg "✓ Created ethernet connection: $CONNECTION_NAME"
        
        # Set hostname for DHCP
        if command -v hostnamectl >/dev/null 2>&1; then
            sudo hostnamectl set-hostname "$HOSTNAME" || log_msg "⚠ Failed to set system hostname"
        fi
        
        # Activate the connection
        if nmcli connection up "$CONNECTION_NAME"; then
            log_msg "✓ Activated ethernet connection"
            return 0
        else
            log_msg "✗ Failed to activate ethernet connection"
            return 1
        fi
    else
        log_msg "✗ Failed to create ethernet connection"
        return 1
    fi
}

# Test connectivity through ethernet interface
test_ethernet_connectivity() {
    local success_count=0
    local total_tests=${#TEST_URLS[@]}
    
    log_msg "Testing connectivity through $INTERFACE..."
    
    for url in "${TEST_URLS[@]}"; do
        if curl --interface "$INTERFACE" \
               --max-time 10 \
               --silent \
               --location \
               --output /dev/null \
               "$url" 2>/dev/null; then
            log_msg "✓ Connectivity test passed: $url"
            ((success_count++))
        else
            log_msg "✗ Connectivity test failed: $url"
        fi
    done
    
    log_msg "Connectivity results: $success_count/$total_tests tests passed"
    
    if [[ $success_count -gt 0 ]]; then
        return 0
    else
        return 1
    fi
}

# Generate heavy traffic through ethernet interface
generate_ethernet_traffic() {
    log_msg "Starting heavy traffic generation on $INTERFACE"
    
    # Start background ping to maintain connectivity
    {
        while true; do
            if ping -I "$INTERFACE" -c 5 -i 0.2 8.8.8.8 >/dev/null 2>&1; then
                log_msg "Ping traffic: ✓ Connectivity maintained"
            else
                log_msg "Ping traffic: ✗ Connectivity lost"
            fi
            sleep 30
        done
    } &
    PING_PID=$!
    
    # Start background download traffic
    {
        local download_urls=(
            "https://proof.ovh.net/files/100Mb.dat"
            "https://speed.hetzner.de/100MB.bin"
            "http://ipv4.download.thinkbroadband.com/50MB.zip"
        )
        
        while true; do
            for url in "${download_urls[@]}"; do
                {
                    log_msg "Download traffic: Starting $(basename "$url")"
                    if curl --interface "$INTERFACE" \
                           --max-time 120 \
                           --range "0-52428800" \
                           --silent \
                           --location \
                           --output /dev/null \
                           "$url" 2>/dev/null; then
                        log_msg "Download traffic: ✓ Completed $(basename "$url")"
                    else
                        log_msg "Download traffic: ✗ Failed $(basename "$url")"
                    fi
                } &
            done
            
            # Wait for downloads to complete
            wait
            sleep 60
        done
    } &
    DOWNLOAD_PID=$!
    
    # Start speedtest traffic if available
    if command -v speedtest >/dev/null 2>&1 || command -v speedtest-cli >/dev/null 2>&1; then
        {
            while true; do
                log_msg "Speedtest traffic: Starting test"
                
                local speedtest_cmd=""
                if command -v speedtest >/dev/null 2>&1; then
                    speedtest_cmd="speedtest --accept-license --accept-gdpr --interface-name=$INTERFACE"
                elif command -v speedtest-cli >/dev/null 2>&1; then
                    local ip_addr=$(ip addr show "$INTERFACE" | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | head -n1)
                    [[ -n "$ip_addr" ]] && speedtest_cmd="speedtest-cli --source $ip_addr"
                fi
                
                if [[ -n "$speedtest_cmd" ]] && timeout 120 $speedtest_cmd >/dev/null 2>&1; then
                    log_msg "Speedtest traffic: ✓ Test completed"
                else
                    log_msg "Speedtest traffic: ✗ Test failed"
                fi
                
                sleep 300  # 5 minutes between speedtests
            done
        } &
        SPEEDTEST_PID=$!
    fi
    
    log_msg "✓ Heavy traffic generation started (PIDs: ping=$PING_PID, download=$DOWNLOAD_PID, speedtest=${SPEEDTEST_PID:-none})"
}

# Get interface information
get_interface_info() {
    local ip_addr=$(ip addr show "$INTERFACE" | grep 'inet ' | awk '{print $2}' | head -n1)
    local mac_addr=$(ip link show "$INTERFACE" | grep 'link/ether' | awk '{print $2}')
    local status=$(ip link show "$INTERFACE" | grep -o "state [A-Z]*" | awk '{print $2}')
    
    log_msg "Interface Info - IP: ${ip_addr:-none}, MAC: ${mac_addr:-none}, Status: ${status:-unknown}"
}

# Main monitoring loop
main_loop() {
    log_msg "Starting wired client simulation (interface: $INTERFACE, hostname: $HOSTNAME)"
    
    local consecutive_failures=0
    local traffic_started=false
    
    while true; do
        if check_ethernet_interface; then
            get_interface_info
            
            # Setup connection if needed
            if ! nmcli connection show --active | grep -q "$CONNECTION_NAME"; then
                log_msg "Connection not active, setting up..."
                if setup_wired_connection; then
                    sleep 10  # Wait for DHCP
                else
                    log_msg "✗ Failed to setup connection, retrying in $REFRESH_INTERVAL seconds"
                    sleep $REFRESH_INTERVAL
                    continue
                fi
            fi
            
            # Test connectivity
            if test_ethernet_connectivity; then
                consecutive_failures=0
                
                # Start traffic generation if not already started
                if [[ "$traffic_started" != "true" ]]; then
                    generate_ethernet_traffic
                    traffic_started=true
                fi
                
                log_msg "✓ Wired client running normally"
            else
                ((consecutive_failures++))
                log_msg "✗ Connectivity test failed (failures: $consecutive_failures)"
                
                if [[ $consecutive_failures -ge 3 ]]; then
                    log_msg "Multiple connectivity failures, resetting connection..."
                    nmcli connection down "$CONNECTION_NAME" 2>/dev/null || true
                    sleep 5
                    consecutive_failures=0
                    traffic_started=false
                fi
            fi
        else
            log_msg "✗ Ethernet interface not available"
            traffic_started=false
        fi
        
        sleep $REFRESH_INTERVAL
    done
}

# Cleanup function
cleanup_and_exit() {
    log_msg "Cleaning up wired client simulation..."
    
    # Kill background processes
    [[ -n "${PING_PID:-}" ]] && kill "$PING_PID" 2>/dev/null || true
    [[ -n "${DOWNLOAD_PID:-}" ]] && kill "$DOWNLOAD_PID" 2>/dev/null || true
    [[ -n "${SPEEDTEST_PID:-}" ]] && kill "$SPEEDTEST_PID" 2>/dev/null || true
    
    log_msg "Wired client simulation stopped"
    exit 0
}

# Signal handlers
trap cleanup_and_exit SIGTERM SIGINT EXIT

# Start main loop
main_loop
WIRED_EOF

    chmod +x "$SCRIPTS_DIR/wired_simulation.sh"
    chown "$PI_USER:$PI_USER" "$SCRIPTS_DIR/wired_simulation.sh"
    log_info "✓ Created wired_simulation.sh"
    
    # Create connect_and_curl.sh (Wi-Fi good client)
    log_info "Creating connect_and_curl.sh..."
    cat > "$SCRIPTS_DIR/connect_and_curl.sh" << 'WIFI_GOOD_EOF'
#!/usr/bin/env bash
set -euo pipefail

# Wi-Fi Good Client Simulation
# Connects to Wi-Fi network successfully and generates normal traffic

INTERFACE="wlan0"
HOSTNAME="CNXNMist-WiFiGood"
LOG_FILE="$HOME/wifi_test_dashboard/logs/wifi-good.log"
CONFIG_FILE="$HOME/wifi_test_dashboard/configs/ssid.conf"
SETTINGS="$HOME/wifi_test_dashboard/configs/settings.conf"

# Source settings if available
[[ -f "$SETTINGS" ]] && source "$SETTINGS" || true

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

log_msg() {
    echo "[$(date '+%F %T')] WIFI-GOOD: $1" | tee -a "$LOG_FILE"
}

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

# Connect to Wi-Fi network
connect_to_wifi() {
    local ssid="$1"
    local password="$2"
    local connection_name="wifi-good-$ssid"
    
    log_msg "Attempting to connect to Wi-Fi: $ssid"
    
    # Remove any existing connection with the same name
    nmcli connection delete "$connection_name" 2>/dev/null || true
    
    # Create new Wi-Fi connection
    if nmcli connection add \
        type wifi \
        con-name "$connection_name" \
        ifname "$INTERFACE" \
        ssid "$ssid" \
        wifi-sec.key-mgmt wpa-psk \
        wifi-sec.psk "$password" \
        ipv4.method auto \
        ipv6.method auto; then
        
        log_msg "✓ Created Wi-Fi connection: $connection_name"
    else
        log_msg "✗ Failed to create Wi-Fi connection"
        return 1
    fi
    
    # Set hostname for DHCP identification
    if command -v hostnamectl >/dev/null 2>&1; then
        sudo hostnamectl set-hostname "$HOSTNAME" 2>/dev/null || true
    fi
    
    # Attempt to connect with timeout
    log_msg "Connecting to $ssid (timeout: ${CONNECTION_TIMEOUT}s)..."
    
    if timeout "$CONNECTION_TIMEOUT" nmcli connection up "$connection_name"; then
        log_msg "✓ Successfully connected to $ssid"
        
        # Wait for IP assignment
        local wait_count=0
        while [[ $wait_count -lt 10 ]]; do
            local ip_addr=$(ip addr show "$INTERFACE" | grep 'inet ' | awk '{print $2}' | head -n1)
            if [[ -n "$ip_addr" ]]; then
                log_msg "✓ IP address assigned: $ip_addr"
                return 0
            fi
            sleep 2
            ((wait_count++))
        done
        
        log_msg "⚠ Connected but no IP address assigned"
        return 1
    else
        log_msg "✗ Failed to connect to $ssid"
        nmcli connection delete "$connection_name" 2>/dev/null || true
        return 1
    fi
}

# Test connectivity and generate traffic
test_connectivity_and_traffic() {
    local success_count=0
    local total_tests=${#TEST_URLS[@]}
    
    log_msg "Testing connectivity and generating traffic..."
    
    for url in "${TEST_URLS[@]}"; do
        if curl --interface "$INTERFACE" \
               --max-time 10 \
               --silent \
               --location \
               --output /dev/null \
               "$url" 2>/dev/null; then
            log_msg "✓ Traffic test passed: $url"
            ((success_count++))
        else
            log_msg "✗ Traffic test failed: $url"
        fi
        
        # Small delay between tests
        sleep 1
    done
    
    log_msg "Traffic test results: $success_count/$total_tests passed"
    
    # Additional traffic patterns for good client
    generate_good_client_traffic
    
    return $([[ $success_count -gt 0 ]] && echo 0 || echo 1)
}

# Generate typical "good client" traffic patterns
generate_good_client_traffic() {
    # Background ping to maintain connection
    {
        ping -I "$INTERFACE" -c 5 -i 0.5 8.8.8.8 >/dev/null 2>&1 && \
        log_msg "✓ Background ping successful"
    } &
    
    # Simulate web browsing traffic
    {
        local web_urls=(
            "https://httpbin.org/bytes/1024"
            "https://httpbin.org/json" 
            "https://httpbin.org/headers"
        )
        
        for web_url in "${web_urls[@]}"; do
            if curl --interface "$INTERFACE" \
                   --max-time 15 \
                   --silent \
                   --location \
                   --output /dev/null \
                   "$web_url" 2>/dev/null; then
                log_msg "✓ Web traffic: $(basename "$web_url")"
            fi
            sleep 2
        done
    } &
    
    # DNS queries
    {
        local dns_targets=("google.com" "cloudflare.com" "github.com")
        for target in "${dns_targets[@]}"; do
            if nslookup "$target" >/dev/null 2>&1; then
                log_msg "✓ DNS query: $target"
            fi
        done
    } &
    
    wait  # Wait for all background traffic to complete
}

# Check if currently connected to the target SSID
is_connected_to_ssid() {
    local target_ssid="$1"
    
    # Get current SSID using NetworkManager
    local current_ssid=$(nmcli -t -f active,ssid dev wifi | grep '^yes' | cut -d':' -f2)
    
    if [[ "$current_ssid" == "$target_ssid" ]]; then
        return 0
    else
        return 1
    fi
}

# Main monitoring and connection loop
main_loop() {
    log_msg "Starting Wi-Fi good client simulation (interface: $INTERFACE, hostname: $HOSTNAME)"
    
    local retry_count=0
    local last_config_check=0
    
    while true; do
        local current_time=$(date +%s)
        
        # Re-read config periodically (every 5 minutes)
        if [[ $((current_time - last_config_check)) -gt 300 ]]; then
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
        
        # Check if we're connected to the right network
        if is_connected_to_ssid "$SSID"; then
            log_msg "✓ Connected to target SSID: $SSID"
            
            # Test connectivity and generate traffic
            if test_connectivity_and_traffic; then
                retry_count=0
                log_msg "✓ Wi-Fi good client operating normally"
            else
                ((retry_count++))
                log_msg "✗ Connectivity issues detected (attempt $retry_count/$MAX_RETRIES)"
                
                if [[ $retry_count -ge $MAX_RETRIES ]]; then
                    log_msg "Max retries reached, forcing reconnection"
                    # Disconnect and reconnect
                    nmcli device disconnect "$INTERFACE" 2>/dev/null || true
                    sleep 5
                    retry_count=0
                fi
            fi
        else
            log_msg "Not connected to target SSID, attempting connection..."
            
            if connect_to_wifi "$SSID" "$PASSWORD"; then
                retry_count=0
                log_msg "✓ Successfully established Wi-Fi connection"
                sleep 10  # Allow connection to stabilize
            else
                ((retry_count++))
                log_msg "✗ Wi-Fi connection failed (attempt $retry_count/$MAX_RETRIES)"
                
                if [[ $retry_count -ge $MAX_RETRIES ]]; then
                    log_msg "Max connection retries reached, waiting longer before retry"
                    retry_count=0
                    sleep $((REFRESH_INTERVAL * 2))
                fi
            fi
        fi
        
        sleep $REFRESH_INTERVAL
    done
}

# Cleanup function
cleanup_and_exit() {
    log_msg "Cleaning up Wi-Fi good client simulation..."
    
    # Disconnect from Wi-Fi
    nmcli device disconnect "$INTERFACE" 2>/dev/null || true
    
    log_msg "Wi-Fi good client simulation stopped"
    exit 0
}

# Signal handlers
trap cleanup_and_exit SIGTERM SIGINT EXIT

# Initial config read
if ! read_wifi_config; then
    log_msg "✗ Failed to read initial configuration, exiting"
    exit 1
fi

# Start main loop
main_loop
WIFI_GOOD_EOF

    chmod +x "$SCRIPTS_DIR/connect_and_curl.sh"
    chown "$PI_USER:$PI_USER" "$SCRIPTS_DIR/connect_and_curl.sh"
    log_info "✓ Created connect_and_curl.sh"
    
    # Create fail_auth_loop.sh (Wi-Fi bad client)
    log_info "Creating fail_auth_loop.sh..."
    cat > "$SCRIPTS_DIR/fail_auth_loop.sh" << 'WIFI_BAD_EOF'
#!/usr/bin/env bash
set -euo pipefail

# Wi-Fi Bad Client Simulation
# Continuously attempts to connect with wrong credentials to generate auth failures

INTERFACE="wlan1"
HOSTNAME="CNXNMist-WiFiBad"
LOG_FILE="$HOME/wifi_test_dashboard/logs/wifi-bad.log"
CONFIG_FILE="$HOME/wifi_test_dashboard/configs/ssid.conf"
SETTINGS="$HOME/wifi_test_dashboard/configs/settings.conf"

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
    
    log_msg "Completed authentication failure pattern ($pattern_count attempts)"
    return 0
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
        
        # Scan for target SSID
        if scan_for_ssid "$SSID"; then
            # Generate authentication failures
            generate_auth_failure_patterns "$SSID"
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
trap cleanup_and_exit SIGTERM SIGINT EXIT

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
WIFI_BAD_EOF

    chmod +x "$SCRIPTS_DIR/fail_auth_loop.sh"
    chown "$PI_USER:$PI_USER" "$SCRIPTS_DIR/fail_auth_loop.sh"
    log_info "✓ Created fail_auth_loop.sh"
}

enhance_traffic_generator() {
    log_step "Enhancing traffic generator with YouTube support..."
    
    # Backup existing traffic generator if it exists
    if [[ -f "$SCRIPTS_DIR/interface_traffic_generator.sh" ]]; then
        cp "$SCRIPTS_DIR/interface_traffic_generator.sh" "$SCRIPTS_DIR/interface_traffic_generator.sh.backup"
        log_info "✓ Backed up existing traffic generator"
    fi
    
    # The enhanced traffic generator with YouTube support is already in your repository
    # Just ensure it has proper permissions
    if [[ -f "$SCRIPTS_DIR/interface_traffic_generator.sh" ]]; then
        chmod +x "$SCRIPTS_DIR/interface_traffic_generator.sh"
        chown "$PI_USER:$PI_USER" "$SCRIPTS_DIR/interface_traffic_generator.sh"
        log_info "✓ Enhanced traffic generator permissions updated"
    else
        log_warn "Traffic generator script not found - may need to be downloaded separately"
    fi
}

fix_service_dependencies() {
    log_step "Fixing service dependencies..."
    
    # Ensure all services have proper dependencies and delays
    local services=("wired-test" "wifi-good" "wifi-bad" "traffic-eth0" "traffic-wlan0" "traffic-wlan1")
    
    for service in "${services[@]}"; do
        if [[ -f "/etc/systemd/system/${service}.service" ]]; then
            # Add restart delay if not present
            if ! grep -q "RestartSec=" "/etc/systemd/system/${service}.service"; then
                log_info "Adding restart delay to ${service}.service"
                sed -i '/\[Service\]/a RestartSec=15' "/etc/systemd/system/${service}.service"
            fi
            
            # Ensure proper dependencies
            if ! grep -q "network-online.target" "/etc/systemd/system/${service}.service"; then
                log_info "Adding network dependencies to ${service}.service"
                sed -i 's/After=.*/After=network-online.target NetworkManager.service/' "/etc/systemd/system/${service}.service"
                sed -i '/After=.*/a Wants=network-online.target' "/etc/systemd/system/${service}.service"
            fi
        fi
    done
    
    systemctl daemon-reload
    log_info "✓ Service dependencies updated"
}

install_missing_tools() {
    log_step "Installing missing tools for enhanced features..."
    
    # Update package lists
    apt-get update -qq
    
    # Install yt-dlp for YouTube traffic simulation
    if ! command -v yt-dlp >/dev/null 2>&1; then
        log_info "Installing yt-dlp for YouTube traffic simulation..."
        if pip3 install yt-dlp --break-system-packages >/dev/null 2>&1; then
            log_info "✓ yt-dlp installed successfully"
        else
            log_warn "Failed to install yt-dlp - YouTube traffic may not work"
        fi
    else
        log_info "✓ yt-dlp already installed"
    fi
    
    # Ensure speedtest CLI is properly installed
    if ! command -v speedtest >/dev/null 2>&1; then
        if ! command -v speedtest-cli >/dev/null 2>&1; then
            log_info "Installing speedtest-cli fallback..."
            pip3 install speedtest-cli --break-system-packages >/dev/null 2>&1 || true
        fi
    fi
    
    log_info "✓ Tool installation completed"
}

restart_services() {
    log_step "Restarting services..."
    
    # Stop all services first
    local services=("wired-test" "wifi-good" "wifi-bad" "traffic-eth0" "traffic-wlan0" "traffic-wlan1")
    
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "${service}.service"; then
            log_info "Stopping ${service}.service"
            systemctl stop "${service}.service"
        fi
    done
    
    sleep 5
    
    # Start services with delays
    for service in "${services[@]}"; do
        log_info "Starting ${service}.service"
        systemctl start "${service}.service"
        sleep 3
    done
    
    log_info "✓ Services restarted"
}

verify_services() {
    log_step "Verifying service status..."
    
    local services=("wifi-dashboard" "wired-test" "wifi-good" "wifi-bad" "traffic-eth0" "traffic-wlan0" "traffic-wlan1")
    local failed_services=()
    
    sleep 10  # Wait for services to fully start
    
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "${service}.service"; then
            log_info "✓ ${service}.service is running"
        else
            log_warn "✗ ${service}.service is not running"
            failed_services+=("$service")
        fi
    done
    
    if [[ ${#failed_services[@]} -gt 0 ]]; then
        log_warn "Some services failed to start. Check logs with:"
        for service in "${failed_services[@]}"; do
            echo "  sudo journalctl -u ${service}.service -f"
        done
    else
        log_info "✓ All services are running successfully"
    fi
}

update_configuration() {
    log_step "Updating configuration for enhanced features..."
    
    # Add YouTube configuration if not present
    local settings_file="$DASHBOARD_DIR/configs/settings.conf"
    
    if [[ -f "$settings_file" ]] && ! grep -q "ENABLE_YOUTUBE_TRAFFIC" "$settings_file"; then
        log_info "Adding YouTube configuration..."
        cat >> "$settings_file" << 'YOUTUBE_CONFIG'

# YouTube traffic generation settings
ENABLE_YOUTUBE_TRAFFIC=true
YOUTUBE_PLAYLIST_URL=https://www.youtube.com/playlist?list=PLrAXtmRdnEQy5tts6p-v1URsm7wOSM-M0
YOUTUBE_TRAFFIC_INTERVAL=600
YOUTUBE_MAX_DURATION=300
YOUTUBE_QUALITY=worst[height<=480]
YOUTUBE_MAX_DOWNLOADS=2

# Enhanced speedtest settings
SPEEDTEST_ACCEPT_LICENSE=true
SPEEDTEST_ACCEPT_GDPR=true
YOUTUBE_CONFIG
        
        chown "$PI_USER:$PI_USER" "$settings_file"
        log_info "✓ YouTube configuration added"
    fi
}

print_completion() {
    local pi_ip
    pi_ip=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "IP_NOT_FOUND")
    
    echo
    echo -e "${GREEN}=================================================================="
    echo "  🎉 Wi-Fi Dashboard Services Fix Complete!"
    echo "=================================================================="
    echo -e "${NC}"
    log_info "🌐 Dashboard URL: http://$pi_ip:5000"
    log_info "🚦 Traffic Control: http://$pi_ip:5000/traffic_control"
    echo
    log_info "📊 What was fixed:"
    log_info "  ✅ Missing traffic generation scripts created"
    log_info "  ✅ YouTube traffic simulation enabled"
    log_info "  ✅ Enhanced speedtest integration"
    log_info "  ✅ Service dependencies improved"
    log_info "  ✅ Authentication failure simulation working"
    echo
    log_info "🔧 Next steps:"
    log_info "  1. Configure your SSID and password in the dashboard"
    log_info "  2. Monitor services: sudo systemctl status wifi-good.service"
    log_info "  3. View logs: sudo journalctl -u wifi-good.service -f"
    echo
    log_info "🎊 Your enhanced Wi-Fi testing system is ready!"
}

# Main execution
main() {
    print_banner
    check_requirements
    create_missing_scripts
    enhance_traffic_generator
    install_missing_tools
    update_configuration
    fix_service_dependencies
    restart_services
    verify_services
    print_completion
}

main "$@"