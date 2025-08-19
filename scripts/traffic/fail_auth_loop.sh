#!/usr/bin/env bash
set -euo pipefail


# Wi-Fi Bad Client Simulation
# Repeatedly attempts to connect with *wrong* passwords to generate auth failures

INTERFACE="wlan1"
HOSTNAME="CNXNMist-WiFiBad"
LOG_FILE="/home/pi/wifi_test_dashboard/logs/wifi-bad.log"
CONFIG_FILE="/home/pi/wifi_test_dashboard/configs/ssid.conf"
SETTINGS="/home/pi/wifi_test_dashboard/configs/settings.conf"
ROTATE_HELPER="/home/pi/wifi_test_dashboard/scripts/log_rotation_utils.sh"


# Keep service alive; log failing command instead of exiting
set -E
trap 'ec=$?; echo "[$(date "+%F %T")] TRAP-ERR: cmd=\"$BASH_COMMAND\" ec=$ec line=$LINENO" | tee -a "$LOG_FILE"; ec=0' ERR

# ---- Settings / helpers ------------------------------------------------------

[[ -f "$SETTINGS" ]] && source "$SETTINGS" || true
[[ -f "$ROTATE_HELPER" ]] && source "$ROTATE_HELPER" || true

# Defaults overridable by settings/env
LOG_MAX_BYTES="${LOG_MAX_BYTES:-${MAX_LOG_SIZE_BYTES:-524288}}" # 512KB fallback
WIFI_BAD_INTERFACE="${WIFI_BAD_INTERFACE:-$INTERFACE}"
WIFI_BAD_HOSTNAME="${WIFI_BAD_HOSTNAME:-$HOSTNAME}"
WIFI_BAD_REFRESH_INTERVAL="${WIFI_BAD_REFRESH_INTERVAL:-45}"
WIFI_CONNECTION_TIMEOUT="${WIFI_CONNECTION_TIMEOUT:-30}"

INTERFACE="$WIFI_BAD_INTERFACE"
HOSTNAME="$WIFI_BAD_HOSTNAME"
REFRESH_INTERVAL="$WIFI_BAD_REFRESH_INTERVAL"
CONNECTION_TIMEOUT="$WIFI_CONNECTION_TIMEOUT"

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

log_msg() {
  local msg="[$(date '+%F %T')] WIFI-BAD: $1"
  echo "$msg" | tee -a "$LOG_FILE"
  command -v rotate_log >/dev/null 2>&1 && rotate_log "$LOG_FILE" "$LOG_MAX_BYTES"
}

# Wrong passwords to rotate
BAD_PASSWORDS=(
  "wrongpassword123" "badpassword" "incorrectpwd" "hackme123" "password123"
  "admin123" "guest" "12345678" "qwerty123" "letmein"
)

# ---- Config / cache clearing -------------------------------------------------

read_wifi_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    log_msg "✗ Config file not found: $CONFIG_FILE"
    return 1
  fi

  # Only the SSID (line 1) is used; real password is *ignored* on purpose
  mapfile -t lines < "$CONFIG_FILE"
  if [[ "${#lines[@]}" -lt 1 ]]; then
    log_msg "✗ Config file incomplete (need at least SSID)"
    return 1
  fi

  SSID="${lines[0]}"
  if [[ -z "${SSID:-}" ]]; then
    log_msg "✗ SSID is empty"
    return 1
  fi

  log_msg "✓ Target SSID loaded: $SSID (real password ignored)"
  clear_cached_credentials "$SSID"
  return 0
}

clear_cached_credentials() {
  local ssid="$1"
  log_msg "🧹 Clearing cached credentials for SSID: $ssid"

  # Delete any Wi-Fi connection profiles whose SSID equals our target
  while IFS= read -r conn_name; do
    [[ -z "$conn_name" ]] && continue
    local conn_ssid
    conn_ssid="$(nmcli -t -f 802-11-wireless.ssid connection show "$conn_name" 2>/dev/null | cut -d: -f2 || true)"
    if [[ "$conn_ssid" == "$ssid" ]]; then
      log_msg "🧹 Removing cached connection: $conn_name"
      nmcli connection delete "$conn_name" 2>/dev/null || true
    fi
  done < <(nmcli -t -f NAME,TYPE connection show 2>/dev/null | grep ':wifi$' | cut -d: -f1)

  force_disconnect
  log_msg "✓ Credential cache cleared for $ssid"
}

# ---- Interface & connectivity helpers ---------------------------------------

check_wifi_interface() {
  if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
    log_msg "✗ Wi-Fi interface $INTERFACE not found"
    return 1
  fi

  # Make sure interface is managed by NetworkManager
  if ! nmcli device show "$INTERFACE" >/dev/null 2>&1; then
    log_msg "Setting $INTERFACE to managed mode"
    nmcli device set "$INTERFACE" managed yes 2>/dev/null || true
    sleep 2
  fi

  # Robust state read
  local state
  state="$(nmcli -t -f GENERAL.STATE device show "$INTERFACE" 2>/dev/null | cut -d: -f2 | awk '{print $1}')"
  state="${state:-unknown}"
  log_msg "Interface $INTERFACE state: $state"
  return 0
}

scan_for_ssid() {
  local target_ssid="$1"
  log_msg "Scanning for SSID: $target_ssid"
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
  log_msg "Forcing disconnect on $INTERFACE"

  nmcli device disconnect "$INTERFACE" 2>/dev/null || true
  nmcli connection down id "$INTERFACE" 2>/dev/null || true
  sleep 2

  # Determine *this interface's* SSID, not global
  local current_ssid=""
  local cur_con
  cur_con="$(nmcli -t -f GENERAL.CONNECTION device show "$INTERFACE" 2>/dev/null | cut -d: -f2 || true)"
  if [[ -n "$cur_con" ]]; then
    if [[ "${cur_con}" == "${SSID:-__none__}" ]]; then
      current_ssid="$cur_con"
    else
      current_ssid="$(nmcli -t -f 802-11-wireless.ssid connection show "$cur_con" 2>/dev/null | cut -d: -f2 || true)"
    fi
  fi
  if [[ -z "$current_ssid" ]]; then
    current_ssid="$(iw dev "$INTERFACE" link 2>/dev/null | sed -n 's/^.*SSID: \(.*\)$/\1/p')"
  fi

  if [[ -n "$current_ssid" && -n "${SSID:-}" && "$current_ssid" == "$SSID" ]]; then
    log_msg "⚠ Still connected to: $current_ssid on $INTERFACE — escalating"
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

# ---- Bad connection attempts -------------------------------------------------

attempt_bad_connection() {
  local ssid="$1"
  local wrong_password="$2"
  local connection_name="wifi-bad-$RANDOM"

  log_msg "Attempting connection with wrong password: ***${wrong_password: -3}"

  force_disconnect
  clear_cached_credentials "$ssid"

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

  # Try to connect (should fail)
  log_msg "Attempting connection to $ssid (expected to fail)..."
  local connection_output=""
  if connection_output="$(timeout "$CONNECTION_TIMEOUT" nmcli connection up "$connection_name" 2>&1)"; then
    log_msg "🚨 WARNING: Connection unexpectedly succeeded with a wrong password!"
    log_msg "🚨 Forcing immediate disconnect"
    force_disconnect
    log_msg "🚨 Output: ${connection_output}"
    nmcli connection delete "$connection_name" 2>/dev/null || true
    return 0   # treat as success in terms of 'event generated'
  else
    if echo "$connection_output" | grep -qiE "auth|password|key"; then
      log_msg "✓ Connection failed as expected (auth failure)"
    elif echo "$connection_output" | grep -qi "timeout"; then
      log_msg "✓ Connection timed out (likely auth failure)"
    else
      log_msg "✓ Connection failed: $(echo "$connection_output" | head -n1)"
    fi
  fi

  nmcli connection delete "$connection_name" 2>/dev/null || true
  force_disconnect
  return 1
}

generate_auth_failure_patterns() {
  local ssid="$1"
  local count=0

  log_msg "Pattern 1: Rapid failures"
  for _ in {1..3}; do
    attempt_bad_connection "$ssid" "${BAD_PASSWORDS[$((RANDOM % ${#BAD_PASSWORDS[@]}))]}" || true
    ((count++)) || true
    sleep 2
  done

  log_msg "Pattern 2: Common variants"
  local bases=("password" "admin" "guest")
  for b in "${bases[@]}"; do
    for sfx in "123" "1" ""; do
      attempt_bad_connection "$ssid" "${b}${sfx}" || true
      ((count++)) || true
      sleep 3
    done
  done

  log_msg "Pattern 3: Slow brute pattern"
  local brute=("12345678" "qwerty123" "letmein" "hackme")
  for p in "${brute[@]}"; do
    attempt_bad_connection "$ssid" "$p" || true
    ((count++)) || true
    sleep 5
  done

  log_msg "Completed auth failure pattern ($count attempts)"
}

simulate_attack_patterns() {
  local ssid="$1"
  force_disconnect
  sleep 2

  log_msg "Simulating dictionary attack..."
  local dictpw=( "password" "123456" "password123" "admin" "qwerty" "letmein" "welcome" "monkey" "1234567890" "dragon" )
  for pw in "${dictpw[@]}"; do
    attempt_bad_connection "$ssid" "$pw" || true
    sleep $((RANDOM % 5 + 2))
  done

  log_msg "Simulating enterprise passwords..."
  local entpw=( "Company123" "Welcome1" "Password1" "Admin123" "Guest123" "Temp123" "Change123" "Default1" )
  for pw in "${entpw[@]}"; do
    attempt_bad_connection "$ssid" "$pw" || true
    sleep $((RANDOM % 4 + 3))
  done

  log_msg "Simulating targeted (SSID-based) passwords..."
  local ssid_lower
  ssid_lower="$(echo "$ssid" | tr '[:upper:]' '[:lower:]')"
  local targ=( "${ssid_lower}123" "${ssid_lower}1" "${ssid_lower}password" "${ssid_lower}2023" "${ssid_lower}2024" "${ssid_lower}wifi" )
  for pw in "${targ[@]}"; do
    attempt_bad_connection "$ssid" "$pw" || true
    sleep $((RANDOM % 6 + 2))
  done
}

simulate_deauth_attempts() {
  log_msg "Simulating deauth-like quick connect/disconnect..."
  for i in {1..3}; do
    local temp="deauth-test-$RANDOM"
    local bad="${BAD_PASSWORDS[$((RANDOM % ${#BAD_PASSWORDS[@]}))]}"
    nmcli connection add type wifi con-name "$temp" ifname "$INTERFACE" ssid "$SSID" \
      wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$bad" >/dev/null 2>&1 || true
    timeout 10 nmcli connection up "$temp" 2>/dev/null || true
    sleep 1
    nmcli connection down "$temp" 2>/dev/null || true
    nmcli connection delete "$temp" 2>/dev/null || true
    log_msg "Deauth cycle $i completed"
    sleep $((RANDOM % 3 + 2))
  done
  force_disconnect
}

monitor_wireless_events() {
  # If wlan1 accidentally associates, drop immediately
  local dev_ssid
  dev_ssid="$(iw dev "$INTERFACE" link 2>/dev/null | sed -n 's/^.*SSID: \(.*\)$/\1/p')"
  if [[ -n "${dev_ssid:-}" ]]; then
    if [[ -n "${SSID:-}" && "$dev_ssid" == "$SSID" ]]; then
      log_msg "🚨 CRITICAL: $INTERFACE associated to target SSID unexpectedly — disconnecting"
      force_disconnect
    else
      log_msg "Connected to unexpected SSID '$dev_ssid' on $INTERFACE — disconnecting"
      force_disconnect
    fi
  fi
}

# ---- Main loop ---------------------------------------------------------------

main_loop() {
  log_msg "Starting Wi-Fi bad client simulation (interface: $INTERFACE, hostname: $HOSTNAME)"
  log_msg "This will generate authentication failures for security testing"

  local cycle_count=0
  local last_config_check=0

  while true; do
    local current_time
    current_time="$(date +%s)"
    ((++cycle_count)) || true
    log_msg "=== Bad Client Cycle $cycle_count ==="

    # Re-read SSID every 10 min
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

    monitor_wireless_events

    if scan_for_ssid "$SSID"; then
      case $((cycle_count % 4)) in
        0) generate_auth_failure_patterns "$SSID" ;;
        1) simulate_attack_patterns "$SSID" ;;
        2) simulate_deauth_attempts ;;
        *) attempt_bad_connection "$SSID" "${BAD_PASSWORDS[$((RANDOM % ${#BAD_PASSWORDS[@]}))]}" || true ;;
      esac
    else
      log_msg "Target SSID not visible, rescanning..."
      for r in {1..3}; do
        sleep 10
        scan_for_ssid "$SSID" && break || log_msg "Scan retry $r failed"
      done
    fi

    # Ensure no saved profile for target SSID lingers
    nmcli -t -f NAME connection show | awk -v s="$SSID" '$0==s {print $0}' | \
      xargs -r -n1 nmcli connection delete 2>/dev/null || true

    force_disconnect
    log_msg "Bad client cycle $cycle_count completed, waiting $REFRESH_INTERVAL seconds"
    sleep "$REFRESH_INTERVAL"
  done
}

cleanup_and_exit() {
  log_msg "Cleaning up Wi-Fi bad client simulation..."
  force_disconnect
  nmcli connection show 2>/dev/null | grep -E "^(wifi-bad-|deauth-test-)" | awk '{print $1}' | \
    while read -r c; do nmcli connection delete "$c" 2>/dev/null || true; done
  log_msg "Wi-Fi bad client simulation stopped"
  exit 0
}

trap cleanup_and_exit SIGTERM SIGINT

# ---- Bootstrap ---------------------------------------------------------------

log_msg "Wi-Fi Bad Client Simulation Starting..."
log_msg "Purpose: Generate authentication failures for security testing"
log_msg "Target interface: $INTERFACE"
log_msg "Hostname: $HOSTNAME"
log_msg "Log file: $LOG_FILE"

if ! read_wifi_config; then
  log_msg "✗ Failed to read initial config; defaulting SSID to TestNetwork"
  SSID="TestNetwork"
fi

check_wifi_interface || true
force_disconnect || true

# --- loop wrapper (uses your existing main_loop) ---
MODE="${1:-loop}"                        # default: loop for systemd
SLEEP="${WIFI_BAD_REFRESH_INTERVAL:-30}" # seconds between cycles

if [[ "$MODE" == "loop" ]]; then
  while true; do
    main_loop
    sleep "$SLEEP"
  done
else
  main_loop
fi
# --- end wrapper ---

