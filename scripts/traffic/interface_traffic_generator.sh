#!/usr/bin/env bash
set -euo pipefail

# Per-interface background traffic generator
# Usage: interface_traffic_generator.sh <interface> [loop|once]
# Logs to: /home/pi/wifi_test_dashboard/logs/traffic-<iface>.log
# Respects optional caps via scripts/log_rotation_utils.sh

SETTINGS="/home/pi/wifi_test_dashboard/configs/settings.conf"
ROTATE_HELPER="/home/pi/wifi_test_dashboard/scripts/log_rotation_utils.sh"
LOG_DIR="/home/pi/wifi_test_dashboard/logs"

[[ -f "$SETTINGS" ]] && source "$SETTINGS" || true
[[ -f "$ROTATE_HELPER" ]] && source "$ROTATE_HELPER" || true
mkdir -p "$LOG_DIR" 2>/dev/null || true

LOG_MAX_BYTES="${LOG_MAX_BYTES:-${MAX_LOG_SIZE_BYTES:-524288}}"  # default 512KB

IFACE="${1:-}"
ACTION="${2:-loop}"  # loop | once

if [[ -z "$IFACE" ]]; then
  echo "[traffic] usage: $0 <interface> [loop|once]" >&2
  exit 1
fi

LOG_FILE="$LOG_DIR/traffic-${IFACE}.log"

log_msg() {
  local msg="[$(date '+%F %T')] TRAFFIC[$IFACE]: $1"
  echo "$msg" | tee -a "$LOG_FILE"
  command -v rotate_log >/dev/null 2>&1 && rotate_log "$LOG_FILE" "$LOG_MAX_BYTES"
}

# ---------------- Intensity presets ----------------
# Defaults (overridden by *_TRAFFIC_INTENSITY in settings.conf per iface)
case "${TRAFFIC_INTENSITY_OVERRIDE:-medium}" in
  heavy)   DL_SIZE=104857600; PING_CNT=20; SLEEP_BASE=2 ;;
  medium)  DL_SIZE=52428800 ; PING_CNT=10; SLEEP_BASE=4 ;;
  light|*) DL_SIZE=10485760 ; PING_CNT=5 ; SLEEP_BASE=6 ;;
esac

# Interface-specific overrides from settings.conf
case "$IFACE" in
  eth0)
    case "${ETH0_TRAFFIC_INTENSITY:-${TRAFFIC_INTENSITY_OVERRIDE:-medium}}" in
      heavy)   DL_SIZE=104857600; PING_CNT=20; SLEEP_BASE=2 ;;
      medium)  DL_SIZE=52428800 ; PING_CNT=10; SLEEP_BASE=4 ;;
      light|*) DL_SIZE=10485760 ; PING_CNT=5 ; SLEEP_BASE=6 ;;
    esac
    ;;
  wlan0)
    case "${WLAN0_TRAFFIC_INTENSITY:-${TRAFFIC_INTENSITY_OVERRIDE:-medium}}" in
      heavy)   DL_SIZE=104857600; PING_CNT=20; SLEEP_BASE=2 ;;
      medium)  DL_SIZE=52428800 ; PING_CNT=10; SLEEP_BASE=4 ;;
      light|*) DL_SIZE=10485760 ; PING_CNT=5 ; SLEEP_BASE=6 ;;
    esac
    ;;
  wlan1)
    case "${WLAN1_TRAFFIC_INTENSITY:-${TRAFFIC_INTENSITY_OVERRIDE:-medium}}" in
      heavy)   DL_SIZE=104857600; PING_CNT=20; SLEEP_BASE=2 ;;
      medium)  DL_SIZE=52428800 ; PING_CNT=10; SLEEP_BASE=4 ;;
      light|*) DL_SIZE=10485760 ; PING_CNT=5 ; SLEEP_BASE=6 ;;
    esac
    ;;
esac

# ---------------- Targets ----------------
HTTP_TARGETS=(
  "https://ash-speed.hetzner.com/100MB.bin"
  "https://proof.ovh.net/files/100Mb.dat"
  "http://ipv4.download.thinkbroadband.com/50MB.zip"
)

# ---------------- Helpers ----------------
iface_is_up() {
  ip link show "$IFACE" >/dev/null 2>&1 || return 1
  ip link show "$IFACE" | grep -q "state UP"
}

ensure_iface_up() {
  if ! ip link show "$IFACE" >/dev/null 2>&1; then
    log_msg "✗ Interface $IFACE not found"
    return 1
  fi
  if ! iface_is_up; then
    log_msg "Bringing $IFACE up..."
    sudo ip link set "$IFACE" up || true
    sleep 2
  fi
  return 0
}

do_icmp() {
  log_msg "PING x$PING_CNT"
  ping -I "$IFACE" -c "$PING_CNT" -W 2 1.1.1.1 >/dev/null 2>&1 && log_msg "✓ ping 1.1.1.1" || log_msg "✗ ping 1.1.1.1"
  ping -I "$IFACE" -c "$PING_CNT" -W 2 8.8.8.8  >/dev/null 2>&1 && log_msg "✓ ping 8.8.8.8"  || log_msg "✗ ping 8.8.8.8"
}

do_dns() {
  log_msg "DNS lookups"
  getent hosts google.com      >/dev/null 2>&1 && log_msg "✓ DNS google.com"      || log_msg "✗ DNS google.com"
  getent hosts cloudflare.com  >/dev/null 2>&1 && log_msg "✓ DNS cloudflare.com"  || log_msg "✗ DNS cloudflare.com"
  getent hosts github.com      >/dev/null 2>&1 && log_msg "✓ DNS github.com"      || log_msg "✗ DNS github.com"
}

do_http_pulls() {
  local size="$DL_SIZE" t
  for t in "${HTTP_TARGETS[@]}"; do
    log_msg "curl GET (range 0-$size) $t"
    curl --interface "$IFACE" --max-time 180 --range 0-"$size" \
         --silent --location --output /dev/null "$t" \
      && log_msg "✓ curl ok" || log_msg "✗ curl failed"
    sleep $((SLEEP_BASE + (RANDOM % 3)))
  done
}

do_iperf_local_if_available() {
  if command -v iperf3 >/dev/null 2>&1; then
    if pgrep -f "iperf3 --server" >/dev/null 2>&1; then
      log_msg "iperf3 client to localhost (bind $IFACE)"
      iperf3 -c 127.0.0.1 -t 5 -b 0 -J >/dev/null 2>&1 \
        && log_msg "✓ iperf3 ok" || log_msg "✗ iperf3 failed"
    fi
  fi
}

one_cycle() {
  ensure_iface_up || { log_msg "Waiting for $IFACE to come up..."; sleep $((SLEEP_BASE*2)); return 0; }
  do_icmp
  do_dns
  do_http_pulls
  do_iperf_local_if_available
}

# ---------------- Main ----------------
log_msg "traffic generator start (iface=$IFACE, DL_SIZE=$DL_SIZE, PING_CNT=$PING_CNT)"

if [[ "$ACTION" == "once" ]]; then
  one_cycle
  exit 0
fi

# loop mode
while true; do
  one_cycle
  sleep $((SLEEP_BASE * 5))
done
