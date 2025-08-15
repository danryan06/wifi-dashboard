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

# Delete only target SSID profiles bound to this interface (safe for wlan0)
delete_target_profiles_for_iface() {
  local ssid="$SSID"
  local iface="$INTERFACE"

  # 1) Any active/bound wifi connections whose DEVICE == iface and SSID matches
  nmcli -t -f NAME,UUID,DEVICE,TYPE connection show \
    | awk -F: -v i="$iface" '$4=="wifi" && $3==i {print $2}' \
    | while read -r uuid; do
        local con_ssid
        con_ssid="$(nmcli -t -f 802-11-wireless.ssid connection show "$uuid" 2>/dev/null | cut -d: -f2)"
        [[ "$con_ssid" == "$ssid" ]] && nmcli connection delete "$uuid" 2>/dev/null || true
      done

  # 2) Wifi profiles pinned via connection.interface-name == iface
  nmcli -t -f NAME,UUID,TYPE connection show \
    | awk -F: '$3=="wifi"{print $2}' \
    | while read -r uuid; do
        local con_iface con_ssid
        con_iface="$(nmcli -t -f connection.interface-name connection show "$uuid" 2>/dev/null | cut -d: -f2)"
        [[ "${con_iface:-}" != "$iface" ]] && continue
        con_ssid="$(nmcli -t -f 802-11-wireless.ssid connection show "$uuid" 2>/dev/null | cut -d: -f2)"
        [[ "$con_ssid" == "$ssid" ]] && nmcli connection delete "$uuid" 2>/dev/null || true
      done
}

# Read Wi-Fi SSID from config file (but NEVER use the real password)
read_wifi_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    log_msg "✗ Config file not found: $CONFIG_FILE"
    return 1
  fi

  # Read first two tokens/lines safely; tolerate spaces in SSID
  mapfile -t lines < <(sed -n '1,2p' "$CONFIG_FILE")
  if [[ ${#lines[@]} -lt 1 ]]; then
    log_msg "✗ Config file incomplete (need at least SSID)"
    return 1
  fi

  SSID="${lines[0]}"

  if [[ -z "$SSID" ]]; then
    log_msg "✗ SSID is empty"
    return 1
  fi

  log_msg "✓ Target SSID loaded: $SSID (will ONLY use wrong passwords)"
  log_msg "ℹ️ Real password from config will be ignored for security testing"

  # Clear any existing NM connections for this SSID on this interface to prevent reuse
  delete_target_profiles_for_iface

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
    nmcli device set "$INTERFACE" managed yes 2>/dev/null || true
    sleep 2
  fi

  # Robust state extraction: yields numeric code or 'unknown'
  local state
  state="$(nmcli -t -f GENERAL.STATE device show "$INTERFACE" 2>/dev/null | cut -d: -f2 | awk '{print $1}')"
  state="${state:-unknown}"
  log_msg "Interface $INTERFACE state: $state"

  return 0
}

# Check if SSID is available for connection
scan_for_ssid() {
  local target_ssid="$1"
  log_msg "Scanning for SSID: $target_ssid"

  nmcli device wifi rescan ifname "$INTERFACE" 2>/dev/null || true
  sleep 3

  if nmcli device wifi list ifname "$INTERFACE" 2>/dev/null | grep -Fq "$target_ssid"; then
    log_msg "✓ Target SSID '$target_ssid' is visible"
    return 0
  else
    log_msg "✗ Target SSID '$target_ssid' not found in scan"
    return 1
  fi
}

# Force disconnect with better error handling
force_disconnect() {
  log_msg "Forcing disconnect on $INTERFACE"

  nmcli device disconnect "$INTERFACE" 2>/dev/null || true
  nmcli connection down id "$INTERFACE" 2>/dev/null || true
  sleep 2

  # Verify we're disconnected (scoped to this interface)
  local current_ssid="" cur_con="" con_ssid=""

  cur_con="$(nmcli -t -f GENERAL.CONNECTION device show "$INTERFACE" 2>/dev/null | cut -d: -f2)"
  if [[ -n "$cur_con" ]]; then
    if [[ "$cur_con" == "${SSID:-}" ]]; then
      current_ssid="$cur_con"
    else
      con_ssid="$(nmcli -t -f 802-11-wireless.ssid connection show "$cur_con" 2>/dev/null | cut -d: -f2)"
      current_ssid="$con_ssid"
    fi
  fi

  if [[ -z "$current_ssid" ]]; then
    current_ssid="$(iw dev "$INTERFACE" link 2>/dev/null | sed -n 's/^.*SSID: \(.*\)$/\1/p')"
  fi

  if [[ -n "$current_ssid" && -n "${SSID:-}" && "$current_ssid" == "$SSID" ]]; then
    log_msg "⚠ Still connected to: $current_ssid on $INTERFACE - attempting stronger disconnect"

    nmcli device disconnect "$INTERFACE" 2>/dev/null || true
    nmcli radio wifi off 2>/dev/null || true
    sleep 2
    nmcli radio wifi on 2>/dev/null || true
    sleep 3

    log_msg "Radio reset completed"
  else
    log_msg "✓ Successfully disconnected"
  fi
}

# Attempt connection with wrong password (should fail)
attempt_bad_connection() {
  local ssid="$1"
  local wrong_password="$2"
  local connection_name="wifi-bad-$RANDOM"

  log_msg "Attempting connection with wrong password: ***${wrong_password: -3}"

  # Ensure we start disconnected and no reusable profiles exist on this iface
  force_disconnect
  delete_target_profiles_for_iface

  # Create temporary connection with wrong password (autoconnect stays off by default)
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

  # Set hostname (non-fatal)
  if command -v hostnamectl >/dev/null 2>&1; then
    hostnamectl set-hostname "$HOSTNAME" 2>/dev/null || true
  fi

  log_msg "Attempting connection to $ssid (expected to fail)..."

  local connection_result=1
  local connection_output=""

  if connection_output=$(timeout "$CONNECTION_TIMEOUT" nmcli connection up "$connection_name" 2>&1); then
    log_msg "🚨 SECURITY ALERT: Connection succeeded with wrong password!"
    log_msg "🚨 SSID '$ssid' accepted password: ***${wrong_password: -3}"
    log_msg "🚨 This indicates an open/weak network or cached creds reuse"

    local ip_addr
    ip_addr="$(ip addr show "$INTERFACE" | awk '/inet /{print $2; exit}' 2>/dev/null || echo "unknown")"
    log_msg "🚨 Obtained IP address: $ip_addr"

    local security_info
    security_info="$(nmcli -t -f SECURITY dev wifi list ifname "$INTERFACE" 2>/dev/null | head -n1 || echo "unknown")"
    log_msg "🚨 Network security detected as: $security_info"

    local stored_connections
    stored_connections="$(nmcli -t -f NAME connection show 2>/dev/null | grep -v "$connection_name" || true)"
    log_msg "🚨 Other stored connections: ${stored_connections:-none}"

    log_msg "🚨 Forcing immediate disconnect due to security concern"
    force_disconnect
    log_msg "🚨 Connection attempt details: $connection_output"

    connection_result=0  # Unexpected success
  else
    if echo "$connection_output" | grep -qiE "authentication|password|key"; then
      log_msg "✓ Connection failed as expected (authentication failure)"
    elif echo "$connection_output" | grep -qi "timeout"; then
      log_msg "✓ Connection timed out (likely auth failure)"
    else
      log_msg "✓ Connection failed: $(echo "$connection_output" | head -n1)"
    fi
    connection_result=1  # Expected failure
  fi

  nmcli connection delete "$connection_name" 2>/dev/null || true
  force_disconnect
  return $connection_result
}

# Generate authentication failure patterns
generate_auth_failure_patterns() {
  local ssid="$1"
  local pattern_count=0

  log_msg "Pattern 1: Rapid authentication failures"
  for i in {1..3}; do
    local bad_pwd=${BAD_PASSWORDS[$((RANDOM % ${#BAD_PASSWORDS[@]}))]}
    attempt_bad_connection "$ssid" "$bad_pwd"
    ((++pattern_count))
    sleep 2
  done

  log_msg "Pattern 2: Common password variations"
  local base_passwords=("password" "admin" "guest")
  for base in "${base_passwords[@]}"; do
    for suffix in "123" "1" ""; do
      attempt_bad_connection "$ssid" "${base}${suffix}"
      ((++pattern_count))
      sleep 3
    done
  done

  log_msg "Pattern 3: Slow brute force simulation"
  local brute_passwords=("12345678" "qwerty123" "letmein" "hackme")
  for pwd in "${brute_passwords[@]}"; do
    attempt_bad_connection "$ssid" "$pwd"
    ((++pattern_count))
    sleep 5
  done

  log_msg "Completed authentication failure pattern ($pattern_count attempts)"
  return 0
}

# Simulate various attack patterns
simulate_attack_patterns() {
  local ssid="$1"

  force_disconnect
  sleep 2

  log_msg "Starting attack pattern simulation against: $ssid"

  log_msg "Simulating dictionary attack..."
  local dict_passwords=(
    "password" "123456" "password123" "admin" "qwerty"
    "letmein" "welcome" "monkey" "1234567890" "dragon"
  )
  for dict_pwd in "${dict_passwords[@]}"; do
    attempt_bad_connection "$ssid" "$dict_pwd"
    sleep $((RANDOM % 5 + 2))
  done

  log_msg "Simulating enterprise password attempts..."
  local enterprise_passwords=(
    "Company123" "Welcome1" "Password1" "Admin123"
    "Guest123" "Temp123" "Change123" "Default1"
  )
  for ent_pwd in "${enterprise_passwords[@]}"; do
    attempt_bad_connection "$ssid" "$ent_pwd"
    sleep $((RANDOM % 4 + 3))
  done

  log_msg "Simulating targeted password attempts..."
  local ssid_lower
  ssid_lower="$(echo "$ssid" | tr '[:upper:]' '[:lower:]')"
  local targeted_passwords=(
    "${ssid_lower}123" "${ssid_lower}1" "${ssid_lower}password"
    "${ssid_lower}2023" "${ssid_lower}2024" "${ssid_lower}wifi"
  )
  for target_pwd in "${targeted_passwords[@]}"; do
    attempt_bad_connection "$ssid" "$target_pwd"
    sleep $((RANDOM % 6 + 2))
  done
}

# Monitor and log wireless events (scoped to INTERFACE)
monitor_wireless_events() {
  local cur_con con_ssid current_ssid

  cur_con="$(nmcli -t -f GENERAL.CONNECTION device show "$INTERFACE" 2>/dev/null | cut -d: -f2)"
  if [[ -n "$cur_con" ]]; then
    if [[ "$cur_con" == "${SSID:-}" ]]; then
      current_ssid="$cur_con"
    else
      con_ssid="$(nmcli -t -f 802-11-wireless.ssid connection show "$cur_con" 2>/dev/null | cut -d: -f2)"
      current_ssid="$con_ssid"
    fi
  fi
  if [[ -z "${current_ssid:-}" ]]; then
    current_ssid="$(iw dev "$INTERFACE" link 2>/dev/null | sed -n 's/^.*SSID: \(.*\)$/\1/p')"
  fi

  if [[ -n "${current_ssid:-}" ]]; then
    if [[ -n "${SSID:-}" && "$current_ssid" == "$SSID" ]]; then
      log_msg "🚨 CRITICAL: Successfully connected to target SSID on $INTERFACE!"
      log_msg "🚨 This indicates the authentication failure simulation failed"
      local connection_details
      connection_details="$(nmcli -t -f SSID,SECURITY,SIGNAL,FREQ dev wifi list ifname "$INTERFACE" 2>/dev/null | grep -F "$current_ssid" | head -n1 || true)"
      log_msg "🚨 Connection details: ${connection_details:-unknown}"
      log_msg "🚨 FORCING IMMEDIATE DISCONNECT"
      force_disconnect
    else
      log_msg "Connected to different SSID on $INTERFACE: $current_ssid (disconnecting)"
      force_disconnect
    fi
  fi

  if command -v iwconfig >/dev/null 2>&1; then
    local wifi_info
    wifi_info="$(iwconfig "$INTERFACE" 2>/dev/null | grep -E "(Signal|Quality)" || true)"
    log_msg "Wireless status: ${wifi_info:-no signal info}"
  fi
}

# Generate deauthentication simulation
simulate_deauth_attempts() {
  log_msg "Simulating deauthentication scenarios..."

  for i in {1..3}; do
    log_msg "Deauth simulation cycle $i"
    local temp_connection="deauth-test-$RANDOM"
    local bad_pwd=${BAD_PASSWORDS[$((RANDOM % ${#BAD_PASSWORDS[@]}))]}

    if nmcli connection add \
        type wifi \
        con-name "$temp_connection" \
        ifname "$INTERFACE" \
        ssid "$SSID" \
        wifi-sec.key-mgmt wpa-psk \
        wifi-sec.psk "$bad_pwd" >/dev/null 2>&1; then
      timeout 10 nmcli connection up "$temp_connection" 2>/dev/null || true
      sleep 1
      nmcli connection down "$temp_connection" 2>/dev/null || true
      nmcli connection delete "$temp_connection" 2>/dev/null || true
      log_msg "Deauth cycle $i completed"
    fi
    sleep $((RANDOM % 3 + 2))
  done

  force_disconnect
}

# Main bad client loop
main_loop() {
  log_msg "Starting Wi-Fi bad client simulation (interface: $INTERFACE, hostname: $HOSTNAME)"
  log_msg "This will generate authentication failures for security testing"

  local cycle_count=0
  local last_config_check=0

  while true; do
    local current_time
    current_time="$(date +%s)"
    ((++cycle_count))

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
      sleep "$REFRESH_INTERVAL"
      continue
    fi

    # Monitor for any unexpected connections (on INTERFACE)
    monitor_wireless_events

    # Scan for target SSID
    if scan_for_ssid "$SSID"; then
      # Choose attack pattern based on cycle
      case $((cycle_count % 4)) in
        0) generate_auth_failure_patterns "$SSID" ;;
        1) simulate_attack_patterns "$SSID" ;;
        2) simulate_deauth_attempts ;;
        *)
          # Basic authentication failures
          local random_bad_pwd=${BAD_PASSWORDS[$((RANDOM % ${#BAD_PASSWORDS[@]}))]}
          attempt_bad_connection "$SSID" "$random_bad_pwd"
          ;;
      esac
    else
      log_msg "Target SSID not available, scanning again..."
      for retry in {1..3}; do
        sleep 10
        if scan_for_ssid "$SSID"; then
          break
        fi
        log_msg "Scan retry $retry failed"
      done
    fi

    # Ensure no saved profiles for this SSID exist on *this* interface
    delete_target_profiles_for_iface

    # Ensure we're disconnected before next cycle
    force_disconnect

    log_msg "Bad client cycle $cycle_count completed, waiting $REFRESH_INTERVAL seconds"
    sleep "$REFRESH_INTERVAL"
  done
}

# Cleanup function
cleanup_and_exit() {
  log_msg "Cleaning up Wi-Fi bad client simulation..."

  force_disconnect

  # Remove any temporary connections we may have created
  nmcli connection show 2>/dev/null \
    | grep -E "wifi-bad-|deauth-test-" \
    | awk '{print $1}' \
    | while read -r conn; do
        nmcli connection delete "$conn" 2>/dev/null || true
      done

  log_msg "Wi-Fi bad client simulation stopped"
  exit 0
}

# Signal handlers (no EXIT trap to avoid swallowing set -e diagnostics)
trap cleanup_and_exit SIGTERM SIGINT

# Initial setup
log_msg "Wi-Fi Bad Client Simulation Starting..."
log_msg "Purpose: Generate authentication failures for security testing"
log_msg "Target interface: $INTERFACE"
log_msg "Hostname: $HOSTNAME"
log_msg "Config file: $CONFIG_FILE"
log_msg "Log file: $LOG_FILE"

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

# Initial config read
if ! read_wifi_config; then
  log_msg "✗ Failed to read initial configuration"
  log_msg "Will use default wrong passwords against any available SSIDs"
  SSID="TestNetwork"  # Default for testing
fi

# Initial interface check and cleanup
if check_wifi_interface; then
  force_disconnect  # Start clean
  log_msg "✓ Interface $INTERFACE ready for bad client simulation"
else
  log_msg "⚠ Interface $INTERFACE not ready, but continuing anyway"
fi

# Start main loop
main_loop
