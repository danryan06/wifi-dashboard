#!/usr/bin/env bash
# wifi_client.sh - role dispatcher for wifi-client@<interface> systemd template
# instances. Looks up the interface's persona in configs/clients.conf and execs
# the matching client script with the right environment.
#
# clients.conf format (one line per Wi-Fi client):
#   <interface>:<role>:<hostname>:<intensity>:<roaming>
# e.g.
#   wlan2:good:CNXNMist-WiFiGood2:light:true
set -euo pipefail

IFACE="${1:-}"
if [[ -z "$IFACE" ]]; then
  echo "usage: $0 <wifi-interface>" >&2
  exit 64
fi

DASHBOARD_DIR="${DASHBOARD_DIR:-/home/pi/wifi_test_dashboard}"
CLIENTS_CONF="$DASHBOARD_DIR/configs/clients.conf"
SCRIPTS_DIR="$DASHBOARD_DIR/scripts"

ROLE="good"
CLIENT_HOSTNAME="CNXNMist-WiFi-${IFACE}"
INTENSITY="light"
ROAMING="true"

if [[ -f "$CLIENTS_CONF" ]]; then
  while IFS=: read -r c_iface c_role c_host c_intensity c_roaming; do
    [[ -z "$c_iface" || "$c_iface" == \#* ]] && continue
    if [[ "$c_iface" == "$IFACE" ]]; then
      ROLE="${c_role:-$ROLE}"
      CLIENT_HOSTNAME="${c_host:-$CLIENT_HOSTNAME}"
      INTENSITY="${c_intensity:-$INTENSITY}"
      ROAMING="${c_roaming:-$ROAMING}"
      break
    fi
  done < "$CLIENTS_CONF"
fi

export INTERFACE="$IFACE"
export HOSTNAME="$CLIENT_HOSTNAME"
export LOG_FILE="$DASHBOARD_DIR/logs/wifi-${IFACE}.log"
export CLIENT_LABEL="WIFI-${IFACE^^}"

case "$ROLE" in
  bad)
    export WIFI_BAD_HOSTNAME="$CLIENT_HOSTNAME"
    exec bash "$SCRIPTS_DIR/fail_auth_loop.sh"
    ;;
  *)
    export WIFI_GOOD_HOSTNAME="$CLIENT_HOSTNAME"
    export WIFI_ROAMING_ENABLED="$ROAMING"
    export TRAFFIC_INTENSITY="$INTENSITY"
    exec bash "$SCRIPTS_DIR/connect_and_curl.sh"
    ;;
esac
