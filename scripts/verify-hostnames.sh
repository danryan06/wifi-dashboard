#!/usr/bin/env bash
# verify-hostnames.sh - Verify per-client DHCP hostname separation.
# Reads configs/clients.conf (any number of Wi-Fi clients) and each client's
# identity_<iface>.json written by the client scripts.

set -euo pipefail

DASHBOARD_DIR="/home/pi/wifi_test_dashboard"
CLIENTS_CONF="$DASHBOARD_DIR/configs/clients.conf"
LOG_FILE="$DASHBOARD_DIR/logs/main.log"

log_msg() {
    local level="$1"; shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] VERIFY-HOSTNAMES: $*"
    echo "$msg" | tee -a "$LOG_FILE"
}

get_field() {
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

log_msg INFO "Starting hostname verification..."

if [[ ! -f "$CLIENTS_CONF" ]]; then
    log_msg WARN "No clients.conf found; nothing to verify yet"
    exit 0
fi

issues=0
checked=0
declare -A seen_hostnames

while IFS=: read -r iface role expected _rest; do
    [[ -z "$iface" || "$iface" == \#* ]] && continue
    checked=$((checked + 1))

    identity_file="$DASHBOARD_DIR/identity_${iface}.json"
    actual=$(get_field "$identity_file" hostname)

    log_msg INFO "$iface (role=$role): expected='$expected', reported='$actual'"

    if [[ "$actual" == "unknown" ]]; then
        log_msg WARN "$iface: no identity report yet (client may not have connected)"
        continue
    fi

    if [[ -n "${seen_hostnames[$actual]:-}" ]]; then
        log_msg WARN "❌ Hostname collision: '$actual' used by both ${seen_hostnames[$actual]} and $iface"
        issues=$((issues + 1))
    fi
    seen_hostnames["$actual"]="$iface"
done < "$CLIENTS_CONF"

if (( checked == 0 )); then
    log_msg WARN "clients.conf contains no client entries"
    exit 0
fi

if (( issues == 0 )); then
    log_msg INFO "✅ Hostname separation verified (no collisions among ${#seen_hostnames[@]} reported hostnames)"
    exit 0
else
    log_msg WARN "❌ Found $issues hostname collision(s); check clients.conf and service logs"
    exit 1
fi
