#!/usr/bin/env bash
set -euo pipefail



# Wired client traffic simulation (eth0)
# Generates steady “good client” traffic on Ethernet

INTERFACE="eth0"
HOSTNAME="CNXNMist-Wired"
LOG_FILE="/home/pi/wifi_test_dashboard/logs/wired.log"
SETTINGS="/home/pi/wifi_test_dashboard/configs/settings.conf"
ROTATE_HELPER="/home/pi/wifi_test_dashboard/scripts/log_rotation_utils.sh"
TRAFFIC_GEN="/home/pi/wifi_test_dashboard/scripts/traffic/interface_traffic_generator.sh"

# Keep service alive; log failing command instead of exiting
set -E
trap 'ec=$?; echo "[$(date "+%F %T")] TRAP-ERR: cmd=\"$BASH_COMMAND\" ec=$ec line=$LINENO" | tee -a "$LOG_FILE"; ec=0' ERR

[[ -f "$SETTINGS" ]] && source "$SETTINGS" || true
[[ -f "$ROTATE_HELPER" ]] && source "$ROTATE_HELPER" || true

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
LOG_MAX_BYTES="${LOG_MAX_BYTES:-${MAX_LOG_SIZE_BYTES:-524288}}"  # default 512KB

log_msg() {
  local msg="[$(date '+%F %T')] WIRED: $1"
  echo "$msg" | tee -a "$LOG_FILE"
  command -v rotate_log >/dev/null 2>&1 && rotate_log "$LOG_FILE" "$LOG_MAX_BYTES"
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
  log_msg "Connectivity checks on $INTERFACE"
  ping -I "$INTERFACE" -c 3 -W 2 1.1.1.1 >/dev/null 2>&1 && log_msg "✓ ping 1.1.1.1" || log_msg "✗ ping 1.1.1.1"
  curl --interface "$INTERFACE" -m 10 -s https://www.google.com >/dev/null && log_msg "✓ curl google.com" || log_msg "✗ curl google.com"
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
      log_msg "No IPv4 address on $INTERFACE; retrying DHCP?"
      # gentle kick
      sudo dhclient -1 "$INTERFACE" >/dev/null 2>&1 || true
      sleep 5
      ipaddr="$(check_ip || true)"
    fi

    if [[ -n "$ipaddr" ]]; then
      log_msg "✓ $INTERFACE has IP: $ipaddr"
      basic_tests
      # Run one cycle of the shared traffic generator
      if [[ -x "$TRAFFIC_GEN" ]]; then
        "$TRAFFIC_GEN" "$INTERFACE" once || true
      fi
    else
      log_msg "✗ Still no IP on $INTERFACE"
    fi

    sleep "${REFRESH_INTERVAL:-60}"
  done
}

log_msg "Wired client bootstrap"
log_msg "Log file: $LOG_FILE"

MODE="${1:-loop}"                   # default loop for systemd
SLEEP="${WIRED_REFRESH_INTERVAL:-60}"

if [[ "$MODE" == "loop" ]]; then
  while true; do
    main_loop
    sleep "$SLEEP"
  done
else
  main_loop
fi

