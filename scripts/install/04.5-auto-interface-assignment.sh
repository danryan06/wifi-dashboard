#!/usr/bin/env bash
# scripts/install/04.5-auto-interface-assignment.sh
# Automatically detect all Wi-Fi interfaces and assign client personas.
#
# Outputs:
#   configs/interface-assignments.conf  - primary good/bad/wired summary
#   configs/clients.conf                - one persona line per Wi-Fi interface
#   INTERFACE_ASSIGNMENT.md             - human-readable summary
#
# Every detected Wi-Fi interface becomes a client:
#   best interface   -> good client (roaming, hostname CNXNMist-WiFiGood)
#   second interface -> bad client (auth failures, hostname CNXNMist-WiFiBad)
#   extra interfaces -> additional good clients (CNXNMist-WiFiGood2, 3, ...)
#                       run as wifi-client@<iface> template instances

set -euo pipefail

: "${PI_USER:=pi}"
: "${PI_HOME:=/home/${PI_USER}}"
DASHBOARD_DIR="${DASHBOARD_DIR:-${PI_HOME}/wifi_test_dashboard}"
CONFIG_DIR="${DASHBOARD_DIR}/configs"

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; }

log_info "Auto-detecting and assigning network interfaces..."

# Detect interface capabilities
detect_interface_capabilities() {
    local iface="$1"
    local capabilities=""

    if ! ip link show "$iface" >/dev/null 2>&1; then
        echo "not_found"
        return
    fi

    if [[ -d "/sys/class/net/$iface/device" ]]; then
        local device_path
        device_path=$(readlink -f "/sys/class/net/$iface/device" 2>/dev/null || echo "")

        if [[ "$device_path" == *"mmc"* ]] || [[ "$device_path" == *"sdio"* ]]; then
            capabilities="builtin"
            # Raspberry Pi 3B+, 4, Zero 2 W have dual-band built-in adapters
            if grep -q "Raspberry Pi 4\|Raspberry Pi 3 Model B Plus\|Raspberry Pi Zero 2" /proc/cpuinfo 2>/dev/null; then
                capabilities="builtin_dualband"
            fi
        elif [[ "$device_path" == *"usb"* ]]; then
            capabilities="usb"
            if command -v iwlist >/dev/null 2>&1; then
                ip link set "$iface" up 2>/dev/null || true
                sleep 2
                if iwlist "$iface" frequency 2>/dev/null | grep -q "5\."; then
                    capabilities="usb_dualband"
                else
                    capabilities="usb_2ghz"
                fi
                ip link set "$iface" down 2>/dev/null || true
            else
                capabilities="usb_unknown"
            fi
        else
            capabilities="unknown"
        fi
    else
        capabilities="virtual"
    fi

    echo "$capabilities"
}

# Get list of all Wi-Fi interfaces
wifi_interfaces=($(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^wlan[0-9]+$' | sort -V || true))

log_info "Detected Wi-Fi interfaces: ${wifi_interfaces[*]:-none}"

declare -A interface_caps
declare -A interface_priority

for iface in "${wifi_interfaces[@]}"; do
    caps=$(detect_interface_capabilities "$iface")
    interface_caps["$iface"]="$caps"
    log_info "  $iface: $caps"

    case "$caps" in
        "builtin_dualband") interface_priority["$iface"]=100 ;;
        "builtin")          interface_priority["$iface"]=90 ;;
        "usb_dualband")     interface_priority["$iface"]=80 ;;
        "usb_2ghz"|"usb_unknown") interface_priority["$iface"]=70 ;;
        *)                  interface_priority["$iface"]=50 ;;
    esac
done

# --- Select the good client (highest priority) ---
good_client_iface=""
max_priority=0
for iface in "${wifi_interfaces[@]}"; do
    priority=${interface_priority["$iface"]}
    if [[ $priority -gt $max_priority ]]; then
        max_priority=$priority
        good_client_iface="$iface"
    fi
done

# --- Select the bad client (different from good, prefer USB) ---
bad_client_iface=""
for iface in "${wifi_interfaces[@]}"; do
    if [[ "$iface" != "$good_client_iface" && "${interface_caps[$iface]}" == usb* ]]; then
        bad_client_iface="$iface"
        break
    fi
done
if [[ -z "$bad_client_iface" ]]; then
    for iface in "${wifi_interfaces[@]}"; do
        if [[ "$iface" != "$good_client_iface" ]]; then
            bad_client_iface="$iface"
            break
        fi
    done
fi

if [[ -z "$good_client_iface" ]]; then
    if [[ ${#wifi_interfaces[@]} -gt 0 ]]; then
        good_client_iface="${wifi_interfaces[0]}"
        log_warn "No optimal interface found, using first available: $good_client_iface"
    else
        log_error "No Wi-Fi interfaces detected!"
        exit 1
    fi
fi

# --- Extra interfaces become additional good clients ---
extra_ifaces=()
for iface in "${wifi_interfaces[@]}"; do
    [[ "$iface" == "$good_client_iface" || "$iface" == "$bad_client_iface" ]] && continue
    extra_ifaces+=("$iface")
done

log_info "Interface assignments:"
log_info "  Good Wi-Fi client: $good_client_iface (${interface_caps[$good_client_iface]})"
if [[ -n "$bad_client_iface" ]]; then
    log_info "  Bad Wi-Fi client:  $bad_client_iface (${interface_caps[$bad_client_iface]})"
else
    log_warn "  Bad Wi-Fi client:  Not available (only one Wi-Fi interface)"
fi
if (( ${#extra_ifaces[@]} > 0 )); then
    log_info "  Extra Wi-Fi clients: ${extra_ifaces[*]} (wifi-client@ instances)"
fi
log_info "  Wired client:      eth0"

# Determine traffic intensity for the good client based on capabilities
good_traffic_intensity="medium"
case "${interface_caps[$good_client_iface]}" in
    "builtin_dualband") good_traffic_intensity="heavy" ;;
    "usb_dualband")     good_traffic_intensity="medium" ;;
    *)                  good_traffic_intensity="light" ;;
esac
bad_traffic_intensity="light"

mkdir -p "$CONFIG_DIR"

# --- interface-assignments.conf (primary good/bad/wired summary) ---
cat > "$CONFIG_DIR/interface-assignments.conf" << EOF
# Auto-generated interface assignments
# Generated: $(date)

# Good Wi-Fi client assignment
WIFI_GOOD_INTERFACE=$good_client_iface
WIFI_GOOD_INTERFACE_TYPE=${interface_caps[$good_client_iface]}
WIFI_GOOD_HOSTNAME=CNXNMist-WiFiGood
WIFI_GOOD_TRAFFIC_INTENSITY=$good_traffic_intensity

# Bad Wi-Fi client assignment
WIFI_BAD_INTERFACE=${bad_client_iface:-none}
WIFI_BAD_INTERFACE_TYPE=${interface_caps[$bad_client_iface]:-none}
WIFI_BAD_HOSTNAME=CNXNMist-WiFiBad
WIFI_BAD_TRAFFIC_INTENSITY=$bad_traffic_intensity

# Wired client assignment
WIRED_INTERFACE=eth0
WIRED_HOSTNAME=CNXNMist-Wired
WIRED_TRAFFIC_INTENSITY=heavy

# Interface capabilities detected
$(for iface in "${wifi_interfaces[@]}"; do
    echo "# $iface: ${interface_caps[$iface]}"
done)
EOF

# --- clients.conf (one persona per Wi-Fi interface, any count) ---
CLIENTS_CONF="$CONFIG_DIR/clients.conf"
{
    echo "# Auto-generated Wi-Fi client personas - one per interface"
    echo "# Format: <interface>:<role>:<hostname>:<intensity>:<roaming>"
    echo "# Generated: $(date)"
    echo "${good_client_iface}:good:CNXNMist-WiFiGood:${good_traffic_intensity}:true"
    if [[ -n "$bad_client_iface" ]]; then
        echo "${bad_client_iface}:bad:CNXNMist-WiFiBad:${bad_traffic_intensity}:false"
    fi
    n=2
    for iface in "${extra_ifaces[@]}"; do
        echo "${iface}:good:CNXNMist-WiFiGood${n}:light:true"
        n=$((n + 1))
    done
} > "$CLIENTS_CONF"
log_info "✓ Wrote client personas to clients.conf"

# Update main settings.conf with discovered interfaces
if [[ -f "$CONFIG_DIR/settings.conf" ]]; then
    sed -i "s/WIFI_GOOD_INTERFACE=.*/WIFI_GOOD_INTERFACE=$good_client_iface/" "$CONFIG_DIR/settings.conf"
    sed -i "s/WIFI_BAD_INTERFACE=.*/WIFI_BAD_INTERFACE=${bad_client_iface:-wlan1}/" "$CONFIG_DIR/settings.conf"

    # Enforce canonical hostnames (no band suffixes)
    sed -i "s/WIFI_GOOD_HOSTNAME=.*/WIFI_GOOD_HOSTNAME=CNXNMist-WiFiGood/" "$CONFIG_DIR/settings.conf"
    if [[ -n "$bad_client_iface" ]]; then
        sed -i "s/WIFI_BAD_HOSTNAME=.*/WIFI_BAD_HOSTNAME=CNXNMist-WiFiBad/" "$CONFIG_DIR/settings.conf"
    fi

    sed -i "s/WLAN0_TRAFFIC_INTENSITY=.*/WLAN0_TRAFFIC_INTENSITY=$good_traffic_intensity/" "$CONFIG_DIR/settings.conf"
    if [[ -n "$bad_client_iface" ]]; then
        sed -i "s/WLAN1_TRAFFIC_INTENSITY=.*/WLAN1_TRAFFIC_INTENSITY=$bad_traffic_intensity/" "$CONFIG_DIR/settings.conf"
    fi
fi

# --- Human-readable summary ---
cat > "$DASHBOARD_DIR/INTERFACE_ASSIGNMENT.md" << EOF
# 📡 Wi-Fi Test Dashboard - Interface Assignment

**Auto-detected on:** $(date)
**Raspberry Pi Model:** $(grep "Model" /proc/cpuinfo | cut -d: -f2 | xargs || echo "Unknown")

## Clients

| Interface | Role | Hostname | Intensity | Roaming | Capabilities |
|-----------|------|----------|-----------|---------|--------------|
| eth0 | wired | CNXNMist-Wired | heavy | n/a | ethernet |
| $good_client_iface | good | CNXNMist-WiFiGood | $good_traffic_intensity | yes | ${interface_caps[$good_client_iface]} |
$(if [[ -n "$bad_client_iface" ]]; then
    echo "| $bad_client_iface | bad (auth failures) | CNXNMist-WiFiBad | $bad_traffic_intensity | no | ${interface_caps[$bad_client_iface]} |"
fi)
$(n=2; for iface in "${extra_ifaces[@]}"; do
    echo "| $iface | good (wifi-client@$iface) | CNXNMist-WiFiGood${n} | light | yes | ${interface_caps[$iface]} |"
    n=$((n + 1))
done)

## Scaling with more USB adapters

Plug additional USB Wi-Fi adapters (via a **powered** hub) and re-run:

\`\`\`bash
sudo bash $DASHBOARD_DIR/scripts/install/04.5-auto-interface-assignment.sh
sudo bash $DASHBOARD_DIR/scripts/install/07-services.sh
\`\`\`

Each new adapter appears in Mist as its own client (unique MAC + DHCP hostname).

## Manual Override

Edit \`configs/clients.conf\` (format: \`iface:role:hostname:intensity:roaming\`)
and restart services: \`sudo systemctl restart wifi-good wifi-bad 'wifi-client@*'\`
EOF

chown -R "$PI_USER:$PI_USER" "$CONFIG_DIR" 2>/dev/null || true
chown "$PI_USER:$PI_USER" "$DASHBOARD_DIR/INTERFACE_ASSIGNMENT.md" 2>/dev/null || true

log_info "✓ Auto-interface assignment completed"
log_info "✓ Configuration saved to interface-assignments.conf and clients.conf"
log_info "✓ Installation summary: INTERFACE_ASSIGNMENT.md"
