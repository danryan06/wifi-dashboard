#!/usr/bin/env bash
# verify-hostnames.sh - Verify Wi-Fi hostname separation after SSID is configured

set -euo pipefail

DASHBOARD_DIR="/home/pi/wifi_test_dashboard"
LOG_FILE="$DASHBOARD_DIR/logs/main.log"

log_msg() {
    local level="$1"; shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] VERIFY-HOSTNAMES: $*"
    echo "$msg" | tee -a "$LOG_FILE"
}

log_msg INFO "Starting hostname verification..."

wlan0_file="$DASHBOARD_DIR/identity_wlan0.json"
wlan1_file="$DASHBOARD_DIR/identity_wlan1.json"

get_hostname() {
    local file="$1" field="$2"
    if [[ -f "$file" ]]; then
        if command -v jq >/dev/null 2>&1; then
            jq -r ".$field // \"unknown\"" "$file" 2>/dev/null || echo "unknown"
        else
            grep -o "\"$field\"[^\"]*\"[^\"]*\"" "$file" | cut -d'"' -f4 2>/dev/null || echo "unknown"
        fi
    else
        echo "unknown"
    fi
}

wlan0_expected=$(get_hostname "$wlan0_file" expected_hostname)
wlan0_actual=$(get_hostname "$wlan0_file" hostname)
wlan1_expected=$(get_hostname "$wlan1_file" expected_hostname)
wlan1_actual=$(get_hostname "$wlan1_file" hostname)

log_msg INFO "wlan0: expected='$wlan0_expected', actual='$wlan0_actual'"
log_msg INFO "wlan1: expected='$wlan1_expected', actual='$wlan1_actual'"

# Verification rules
if [[ "$wlan0_actual" == "CNXNMist-WiFiGood" && "$wlan1_actual" == "CNXNMist-WiFiBad" ]]; then
    log_msg INFO "✅ Hostname separation verified successfully"
    exit 0
elif [[ "$wlan0_actual" != "unknown" && "$wlan1_actual" != "unknown" && "$wlan0_actual" != "$wlan1_actual" ]]; then
    log_msg WARN "⚠ Hostnames are different but not standard: wlan0='$wlan0_actual', wlan1='$wlan1_actual'"
    exit 0
else
    log_msg WARN "❌ Hostname separation not established yet"
    log_msg WARN "This may resolve once Wi-Fi services connect to the configured SSID"
    exit 1
fi
