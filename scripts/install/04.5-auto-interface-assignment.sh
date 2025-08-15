#!/usr/bin/env bash
# scripts/install/04.5-auto-interface-assignment.sh
# Automatically detect and assign network interfaces optimally

set -euo pipefail

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; }

log_info "Auto-detecting and assigning network interfaces..."

# Detect interface capabilities
detect_interface_capabilities() {
    local iface="$1"
    local capabilities=""
    
    # Check if interface exists
    if ! ip link show "$iface" >/dev/null 2>&1; then
        echo "not_found"
        return
    fi
    
    # Determine interface type and capabilities
    if [[ -d "/sys/class/net/$iface/device" ]]; then
        local device_path=$(readlink -f "/sys/class/net/$iface/device" 2>/dev/null || echo "")
        
        # Check if it's built-in or USB
        if [[ "$device_path" == *"mmc"* ]] || [[ "$device_path" == *"sdio"* ]]; then
            capabilities="builtin"
            
            # Check for dual-band capability (Raspberry Pi 3B+, 4, Zero 2 W have dual-band)
            if grep -q "Raspberry Pi 4\|Raspberry Pi 3 Model B Plus\|Raspberry Pi Zero 2" /proc/cpuinfo 2>/dev/null; then
                capabilities="builtin_dualband"
            fi
            
        elif [[ "$device_path" == *"usb"* ]]; then
            capabilities="usb"
            
            # Try to detect if USB adapter supports 5GHz
            if command -v iwlist >/dev/null 2>&1; then
                # Bring interface up temporarily to scan capabilities
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
wifi_interfaces=($(ip link show | grep -E "wlan[0-9]" | cut -d: -f2 | tr -d ' ' || true))

log_info "Detected Wi-Fi interfaces: ${wifi_interfaces[*]:-none}"

# Analyze each interface
declare -A interface_caps
declare -A interface_priority

for iface in "${wifi_interfaces[@]}"; do
    caps=$(detect_interface_capabilities "$iface")
    interface_caps["$iface"]="$caps"
    
    log_info "  $iface: $caps"
    
    # Assign priority for good client assignment
    case "$caps" in
        "builtin_dualband")
            interface_priority["$iface"]=100  # Highest priority
            ;;
        "builtin")
            interface_priority["$iface"]=90
            ;;
        "usb_dualband")
            interface_priority["$iface"]=80
            ;;
        "usb_2ghz"|"usb_unknown")
            interface_priority["$iface"]=70
            ;;
        *)
            interface_priority["$iface"]=50
            ;;
    esac
done

# Sort interfaces by priority for assignment
good_client_iface=""
bad_client_iface=""

# Find best interface for good client (highest priority)
max_priority=0
for iface in "${wifi_interfaces[@]}"; do
    priority=${interface_priority["$iface"]}
    if [[ $priority -gt $max_priority ]]; then
        max_priority=$priority
        good_client_iface="$iface"
    fi
done

# Find interface for bad client (different from good client, prefer USB)
for iface in "${wifi_interfaces[@]}"; do
    if [[ "$iface" != "$good_client_iface" ]]; then
        caps=${interface_caps["$iface"]}
        if [[ "$caps" == usb* ]]; then
            bad_client_iface="$iface"
            break
        fi
    fi
done

# If no USB available for bad client, use any other interface
if [[ -z "$bad_client_iface" ]]; then
    for iface in "${wifi_interfaces[@]}"; do
        if [[ "$iface" != "$good_client_iface" ]]; then
            bad_client_iface="$iface"
            break
        fi
    done
fi

# Validate we have at least one interface
if [[ -z "$good_client_iface" ]]; then
    if [[ ${#wifi_interfaces[@]} -gt 0 ]]; then
        good_client_iface="${wifi_interfaces[0]}"
        log_warn "No optimal interface found, using first available: $good_client_iface"
    else
        log_error "No Wi-Fi interfaces detected!"
        exit 1
    fi
fi

# Create interface assignment configuration
log_info "Interface assignments:"
log_info "  Good Wi-Fi client: $good_client_iface (${interface_caps[$good_client_iface]})"
if [[ -n "$bad_client_iface" ]]; then
    log_info "  Bad Wi-Fi client:  $bad_client_iface (${interface_caps[$bad_client_iface]})"
else
    log_warn "  Bad Wi-Fi client:  Not available (only one Wi-Fi interface)"
fi
log_info "  Wired client:      eth0"

# Generate optimized settings.conf
log_info "Generating optimized configuration..."

# Determine traffic intensities based on capabilities
good_traffic_intensity="medium"
bad_traffic_intensity="light"

case "${interface_caps[$good_client_iface]}" in
    "builtin_dualband")
        good_traffic_intensity="heavy"  # Built-in dual-band can handle heavy traffic
        ;;
    "usb_dualband")
        good_traffic_intensity="medium"  # USB dual-band gets medium
        ;;
    *)
        good_traffic_intensity="light"   # 2.4GHz only gets light traffic
        ;;
esac

# Create interface assignment file
cat > "$PI_HOME/wifi_test_dashboard/configs/interface-assignments.conf" << EOF
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

# Update main settings.conf with discovered interfaces
if [[ -f "$PI_HOME/wifi_test_dashboard/configs/settings.conf" ]]; then
    # Update interface assignments in settings.conf
    sed -i "s/WIFI_GOOD_INTERFACE=.*/WIFI_GOOD_INTERFACE=$good_client_iface/" "$PI_HOME/wifi_test_dashboard/configs/settings.conf"
    sed -i "s/WIFI_BAD_INTERFACE=.*/WIFI_BAD_INTERFACE=${bad_client_iface:-wlan1}/" "$PI_HOME/wifi_test_dashboard/configs/settings.conf"
    
    # Update hostnames based on capabilities
    if [[ "${interface_caps[$good_client_iface]}" == *"dualband"* ]]; then
        sed -i "s/WIFI_GOOD_HOSTNAME=.*/WIFI_GOOD_HOSTNAME=CNXNMist-WiFiGood-5G/" "$PI_HOME/wifi_test_dashboard/configs/settings.conf"
    else
        sed -i "s/WIFI_GOOD_HOSTNAME=.*/WIFI_GOOD_HOSTNAME=CNXNMist-WiFiGood-2G/" "$PI_HOME/wifi_test_dashboard/configs/settings.conf"
    fi
    
    if [[ -n "$bad_client_iface" ]]; then
        sed -i "s/WIFI_BAD_HOSTNAME=.*/WIFI_BAD_HOSTNAME=CNXNMist-WiFiBad-2G/" "$PI_HOME/wifi_test_dashboard/configs/settings.conf"
    fi
    
    # Update traffic intensities
    sed -i "s/WLAN0_TRAFFIC_INTENSITY=.*/WLAN0_TRAFFIC_INTENSITY=$good_traffic_intensity/" "$PI_HOME/wifi_test_dashboard/configs/settings.conf"
    if [[ -n "$bad_client_iface" ]]; then
        sed -i "s/WLAN1_TRAFFIC_INTENSITY=.*/WLAN1_TRAFFIC_INTENSITY=$bad_traffic_intensity/" "$PI_HOME/wifi_test_dashboard/configs/settings.conf"
    fi
fi

# Update scripts with correct interface assignments
log_info "Updating scripts with interface assignments..."

# Update good Wi-Fi client script
if [[ -f "$PI_HOME/wifi_test_dashboard/scripts/connect_and_curl.sh" ]]; then
    sed -i "s/INTERFACE=\"wlan[0-9]\"/INTERFACE=\"$good_client_iface\"/" "$PI_HOME/wifi_test_dashboard/scripts/connect_and_curl.sh"
    
    if [[ "${interface_caps[$good_client_iface]}" == *"dualband"* ]]; then
        sed -i "s/HOSTNAME=\".*\"/HOSTNAME=\"CNXNMist-WiFiGood-5G\"/" "$PI_HOME/wifi_test_dashboard/scripts/connect_and_curl.sh"
    else
        sed -i "s/HOSTNAME=\".*\"/HOSTNAME=\"CNXNMist-WiFiGood-2G\"/" "$PI_HOME/wifi_test_dashboard/scripts/connect_and_curl.sh"
    fi
fi

# Update bad Wi-Fi client script
if [[ -f "$PI_HOME/wifi_test_dashboard/scripts/fail_auth_loop.sh" && -n "$bad_client_iface" ]]; then
    sed -i "s/INTERFACE=\"wlan[0-9]\"/INTERFACE=\"$bad_client_iface\"/" "$PI_HOME/wifi_test_dashboard/scripts/fail_auth_loop.sh"
    sed -i "s/HOSTNAME=\".*\"/HOSTNAME=\"CNXNMist-WiFiBad-2G\"/" "$PI_HOME/wifi_test_dashboard/scripts/fail_auth_loop.sh"
fi

# Create installation summary
cat > "$PI_HOME/wifi_test_dashboard/INTERFACE_ASSIGNMENT.md" << EOF
# 📡 Wi-Fi Test Dashboard - Interface Assignment

**Auto-detected on:** $(date)  
**Raspberry Pi Model:** $(cat /proc/cpuinfo | grep "Model" | cut -d: -f2 | xargs || echo "Unknown")

## 🎯 Optimal Configuration Applied

### Good Wi-Fi Client
- **Interface:** \`$good_client_iface\`
- **Type:** ${interface_caps[$good_client_iface]}
- **Hostname:** CNXNMist-WiFiGood$([ "${interface_caps[$good_client_iface]}" == *"dualband"* ] && echo "-5G" || echo "-2G")
- **Traffic Intensity:** $good_traffic_intensity
- **Capabilities:** $([ "${interface_caps[$good_client_iface]}" == *"dualband"* ] && echo "Dual-band (2.4GHz + 5GHz)" || echo "2.4GHz only")

### Bad Wi-Fi Client
$(if [[ -n "$bad_client_iface" ]]; then
cat << BADCLIENT
- **Interface:** \`$bad_client_iface\`
- **Type:** ${interface_caps[$bad_client_iface]}
- **Hostname:** CNXNMist-WiFiBad-2G
- **Traffic Intensity:** $bad_traffic_intensity
- **Purpose:** Authentication failure simulation
BADCLIENT
else
echo "- **Status:** Not available (only one Wi-Fi interface detected)"
fi)

### Wired Client
- **Interface:** \`eth0\`
- **Hostname:** CNXNMist-Wired
- **Traffic Intensity:** heavy

## 🚀 Performance Expectations

$(case "${interface_caps[$good_client_iface]}" in
    "builtin_dualband")
        echo "**Excellent Performance Expected**"
        echo "- Built-in dual-band adapter with 5GHz support"
        echo "- High throughput capability"
        echo "- Better range and reliability"
        ;;
    "builtin")
        echo "**Good Performance Expected**"
        echo "- Built-in adapter with reliable connectivity"
        echo "- 2.4GHz operation"
        ;;
    "usb_dualband")
        echo "**Good Performance Expected**"
        echo "- USB dual-band adapter with 5GHz support"
        echo "- May be limited by USB bandwidth"
        ;;
    *)
        echo "**Basic Performance Expected**"
        echo "- 2.4GHz operation only"
        echo "- Suitable for testing but limited throughput"
        ;;
esac)

## 🔍 Interface Details

$(for iface in "${wifi_interfaces[@]}"; do
    echo "### $iface"
    echo "- **Type:** ${interface_caps[$iface]}"
    echo "- **Assignment:** $([ "$iface" == "$good_client_iface" ] && echo "Good client" || ([ "$iface" == "$bad_client_iface" ] && echo "Bad client" || echo "Unused"))"
    echo
done)

## 💡 Optimization Notes

- The system automatically selected the best available interface for the good client
- $([ "${interface_caps[$good_client_iface]}" == *"dualband"* ] && echo "5GHz will be used when available for better performance" || echo "Consider adding a dual-band USB adapter for better performance")
- Traffic intensities are set based on interface capabilities
- Bad client uses separate interface to avoid interference

## 🔧 Manual Override

If you need to change interface assignments, edit:
- \`configs/settings.conf\` - Main configuration
- \`configs/interface-assignments.conf\` - Interface assignments
- Then restart services: \`sudo systemctl restart wifi-good wifi-bad\`
EOF

# Set ownership
chown -R "$PI_USER:$PI_USER" "$PI_HOME/wifi_test_dashboard/configs/"
chown "$PI_USER:$PI_USER" "$PI_HOME/wifi_test_dashboard/INTERFACE_ASSIGNMENT.md"

log_info "✓ Auto-interface assignment completed"
log_info "✓ Configuration saved to interface-assignments.conf"
log_info "✓ Installation summary: INTERFACE_ASSIGNMENT.md"