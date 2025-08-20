#!/usr/bin/env bash
set -euo pipefail

# Wired client traffic simulation (eth0)
# Generates steady "good client" traffic on Ethernet

INTERFACE="eth0"
HOSTNAME="CNXNMist-Wired"
LOG_FILE="/home/pi/wifi_test_dashboard/logs/wired.log"
SETTINGS="/home/pi/wifi_test_dashboard/configs/settings.conf"
ROTATE_HELPER="/home/pi/wifi_test_dashboard/scripts/log_rotation_utils.sh"

# Keep service alive; log failing command instead of exiting
set -E
trap 'ec=$?; echo "[$(date "+%F %T")] TRAP-ERR: cmd=\"$BASH_COMMAND\" ec=$ec line=$LINENO" | tee -a "$LOG_FILE"; ec=0' ERR

[[ -f "$SETTINGS" ]] && source "$SETTINGS" || true
[[ -f "$ROTATE_HELPER" ]] && source "$ROTATE_HELPER" || true

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
LOG_MAX_BYTES="${LOG_MAX_BYTES:-${MAX_LOG_SIZE_BYTES:-524288}}"  # default 512KB

# Try to locate the traffic generator
TRAFFIC_GEN=""
for p in \
  "/home/pi/wifi_test_dashboard/scripts/interface_traffic_generator.sh" \
  "/home/pi/wifi_test_dashboard/scripts/traffic/interface_traffic_generator.sh"
do
  [[ -f "$p" ]] && TRAFFIC_GEN="$p" && break
done

log_msg() {
  local msg="[$(date '+%F %T')] WIRED: $1"

  if command -v rotate_log >/dev/null 2>&1; then
    rotate_log "$LOG_FILE" "${LOG_MAX_BYTES:-5}"
  fi

  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  echo "$msg" | tee -a "$LOG_FILE"
}

check_interface() {
  if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
    log_msg "✗ Interface $INTERFACE not found"
    return 1
  fi
  if ! ip link show "$INTERFACE" | grep -q "state UP"; then
    log_msg "Bringing $INTERFACE up..."
    sudo ip link set "$INTERFACE" up || true
    sleep 2
  fi
  return 0
}

check_ip() {
  ip -4 addr show dev "$INTERFACE" | awk '/inet /{print $2}' | head -n1
}

basic_tests() {
  log_msg "Basic connectivity checks on $INTERFACE"
  
  # Safe ping test
  if ping -I "$INTERFACE" -c 3 -W 2 1.1.1.1 >/dev/null 2>&1; then
    log_msg "✓ ping 1.1.1.1"
  else
    log_msg "✗ ping 1.1.1.1"
  fi
  
  # Safe curl test
  if curl --interface "$INTERFACE" -m 10 -s https://www.google.com >/dev/null 2>&1; then
    log_msg "✓ curl google.com"
  else
    log_msg "✗ curl google.com"
  fi
}

generate_heavy_traffic() {
  if [[ -n "$TRAFFIC_GEN" && -x "$TRAFFIC_GEN" ]]; then
    log_msg "🚀 Starting heavy traffic generation using $TRAFFIC_GEN"
    
    # Run traffic generator once with heavy intensity
    TRAFFIC_LOG_FILE="$LOG_FILE" \
    TRAFFIC_INTENSITY_OVERRIDE="heavy" \
      bash "$TRAFFIC_GEN" "$INTERFACE" once || true
      
    log_msg "✓ Heavy traffic generation cycle completed"
  else
    log_msg "⚠ Traffic generator not found - only basic tests available"
  fi
}

start_iperf_server_if_needed() {
  if ! pgrep -f "iperf3 --server" >/dev/null 2>&1; then
    log_msg "Starting iperf3 server in background"
    nohup iperf3 --server --interval 0 >/dev/null 2>&1 &
    disown || true
  fi
}

main_loop() {
  log_msg "Wired simulation starting (iface=$INTERFACE host=$HOSTNAME)"
  log_msg "Heavy traffic generation enabled for realistic testing"
  
  start_iperf_server_if_needed

  while true; do
    if ! check_interface; then
      log_msg "Waiting for $INTERFACE to become available..."
      sleep 10
      continue
    fi

    local ipaddr
    ipaddr="$(check_ip || true)"
    if [[ -z "$ipaddr" ]]; then
      log_msg "No IPv4 address on $INTERFACE; requesting DHCP..."
      # gentle kick
      sudo dhclient -1 "$INTERFACE" >/dev/null 2>&1 || true
      sleep 5
      ipaddr="$(check_ip || true)"
    fi

    if [[ -n "$ipaddr" ]]; then
      log_msg "✓ $INTERFACE has IP: $ipaddr"
      
      # Do basic connectivity tests
      basic_tests
      
      # Generate heavy traffic (speedtest, downloads, etc.)
      generate_heavy_traffic
      
      log_msg "✓ Wired client cycle completed - heavy traffic generated"
    else
      log_msg "✗ Still no IP on $INTERFACE"
    fi

    sleep "${WIRED_REFRESH_INTERVAL:-60}"
  done
}

# Initialize
log_msg "Wired client bootstrap with heavy traffic generation"
log_msg "Log file: $LOG_FILE"
log_msg "Traffic generator: ${TRAFFIC_GEN:-not found}"

main_loop