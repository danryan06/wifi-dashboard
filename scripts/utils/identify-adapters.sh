#!/usr/bin/env bash
# identify-adapters.sh - Identify Wi-Fi adapters and their capabilities

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}🔍 Wi-Fi Adapter Identification Tool${NC}"
echo "======================================"

# Check which interfaces exist
echo -e "\n${GREEN}📡 Available Network Interfaces:${NC}"
ip link show | grep -E "(wlan|eth).*:" | while read -r line; do
    iface=$(echo "$line" | cut -d: -f2 | tr -d ' ')
    state=$(echo "$line" | grep -o "state [A-Z]*" | awk '{print $2}' || echo "UNKNOWN")
    echo "  $iface - State: $state"
done

echo -e "\n${GREEN}🔌 USB Wi-Fi Adapters:${NC}"
if command -v lsusb >/dev/null 2>&1; then
    lsusb | grep -i -E "(wireless|wifi|802\.11|wlan)" || echo "  No USB Wi-Fi adapters detected via lsusb"
else
    echo "  lsusb command not available"
fi

echo -e "\n${GREEN}⚙️ Wi-Fi Driver Information:${NC}"
for iface in wlan0 wlan1 wlan2; do
    if ip link show "$iface" >/dev/null 2>&1; then
        echo "  Interface: $iface"
        
        # Get driver info
        if command -v ethtool >/dev/null 2>&1; then
            driver=$(ethtool -i "$iface" 2>/dev/null | grep "driver:" | awk '{print $2}' || echo "unknown")
            echo "    Driver: $driver"
        fi
        
        # Get device path to determine if USB or built-in
        if [[ -L "/sys/class/net/$iface/device" ]]; then
            device_path=$(readlink -f "/sys/class/net/$iface/device")
            if [[ "$device_path" == *"usb"* ]]; then
                echo "    Type: USB Adapter"
                # Get USB vendor/product info
                if [[ -f "/sys/class/net/$iface/device/idVendor" ]] && [[ -f "/sys/class/net/$iface/device/idProduct" ]]; then
                    vendor=$(cat "/sys/class/net/$iface/device/idVendor" 2>/dev/null || echo "unknown")
                    product=$(cat "/sys/class/net/$iface/device/idProduct" 2>/dev/null || echo "unknown")
                    echo "    USB ID: $vendor:$product"
                fi
            else
                echo "    Type: Built-in (BCM43xxx chipset)"
            fi
        fi
        
        # Get current connection info
        if command -v iwconfig >/dev/null 2>&1; then
            iwconfig_output=$(iwconfig "$iface" 2>/dev/null || echo "")
            if echo "$iwconfig_output" | grep -q "ESSID:"; then
                essid=$(echo "$iwconfig_output" | grep "ESSID:" | sed 's/.*ESSID:"\([^"]*\)".*/\1/')
                freq=$(echo "$iwconfig_output" | grep "Frequency:" | sed 's/.*Frequency:\([^ ]*\).*/\1/' || echo "unknown")
                echo "    Connected to: $essid"
                echo "    Frequency: $freq"
                
                # Determine band
                if [[ "$freq" == "2."* ]]; then
                    echo "    Band: 2.4GHz"
                elif [[ "$freq" == "5."* ]]; then
                    echo "    Band: 5GHz"
                fi
            else
                echo "    Status: Not connected"
            fi
        fi
        
        # Get IP address
        ip_addr=$(ip addr show "$iface" | grep 'inet ' | awk '{print $2}' | head -n1 || echo "No IP")
        echo "    IP Address: $ip_addr"
        
        echo ""
    fi
done

echo -e "\n${GREEN}📊 Current Traffic Configuration:${NC}"
# Check which services are running
services=("traffic-eth0" "traffic-wlan0" "traffic-wlan1")
for service in "${services[@]}"; do
    if systemctl is-active --quiet "${service}.service" 2>/dev/null; then
        echo "  ✅ $service: ACTIVE"
    else
        echo "  ❌ $service: INACTIVE"
    fi
done

echo -e "\n${GREEN}🔄 Current Wi-Fi Client Assignments:${NC}"
echo "  Good Wi-Fi Client (wifi-good.service): wlan0"
echo "  Bad Wi-Fi Client (wifi-bad.service): wlan1"

# Check which interface is actually connected for good client
if systemctl is-active --quiet wifi-good.service; then
    echo -e "\n${GREEN}🔍 Good Wi-Fi Client Status:${NC}"
    current_ssid=$(nmcli -t -f active,ssid dev wifi | grep '^yes' | cut -d':' -f2 || echo "Not connected")
    echo "  Currently connected to: $current_ssid"
    
    # Find which interface is connected
    for iface in wlan0 wlan1; do
        if ip link show "$iface" >/dev/null 2>&1; then
            connection=$(nmcli -t -f device,state dev | grep "$iface" | cut -d':' -f2)
            if [[ "$connection" == "connected" ]]; then
                echo "  Active interface: $iface"
                break
            fi
        fi
    done
fi

echo -e "\n${YELLOW}💡 Recommendations:${NC}"
echo "  1. The Good Wi-Fi client uses wlan0 (usually built-in adapter)"
echo "  2. Built-in adapters typically only support 2.4GHz"
echo "  3. USB adapters may support both 2.4GHz and 5GHz"
echo "  4. For better performance, connect Good Wi-Fi to 5GHz if available"

echo -e "\n${GREEN}🚀 To increase Wi-Fi traffic:${NC}"
echo "  1. Edit traffic intensity: sudo nano /home/pi/wifi_test_dashboard/configs/settings.conf"
echo "  2. Change WLAN0_TRAFFIC_INTENSITY from 'medium' to 'heavy'"
echo "  3. Restart traffic service: sudo systemctl restart traffic-wlan0.service"

# Show current settings
echo -e "\n${GREEN}📋 Current Settings:${NC}"
settings_file="/home/pi/wifi_test_dashboard/configs/settings.conf"
if [[ -f "$settings_file" ]]; then
    echo "  Ethernet (eth0):"
    grep "ETH0_TRAFFIC" "$settings_file" | sed 's/^/    /'
    echo "  Wi-Fi 1 (wlan0):"
    grep "WLAN0_TRAFFIC" "$settings_file" | sed 's/^/    /'
    echo "  Wi-Fi 2 (wlan1):"
    grep "WLAN1_TRAFFIC" "$settings_file" | sed 's/^/    /'
else
    echo "  Settings file not found"
fi