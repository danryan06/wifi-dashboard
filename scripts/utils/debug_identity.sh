#!/bin/bash
echo "🔍 Wi-Fi Dashboard Identity Debug Report"
echo "======================================="
echo ""

echo "📊 System Hostname Information:"
echo "  Current hostname (hostname): $(hostname)"
echo "  System hostname (hostnamectl): $(hostnamectl status --static 2>/dev/null || echo 'N/A')"
echo "  /etc/hostname: $(cat /etc/hostname 2>/dev/null || echo 'N/A')"
echo "  /etc/hosts entry: $(grep 127.0.1.1 /etc/hosts 2>/dev/null || echo 'N/A')"
echo ""

echo "📱 Network Interface Information:"
for iface in wlan0 wlan1 eth0; do
    if ip link show "$iface" >/dev/null 2>&1; then
        echo "  Interface: $iface"
        echo "    MAC: $(ip link show $iface | awk '/link\/ether/ {print $2}' || echo 'N/A')"
        echo "    IP: $(ip -4 addr show $iface | awk '/inet / {print $2}' | head -1 || echo 'N/A')"
        echo "    State: $(ip link show $iface | grep -o 'state [A-Z]*' | awk '{print $2}' || echo 'N/A')"
        
        # Check if connected and get SSID/BSSID
        if nmcli device show "$iface" 2>/dev/null | grep -q "connected"; then
            echo "    SSID: $(nmcli -t -f active,ssid dev wifi 2>/dev/null | awk -F: '$1=="yes"{print $2; exit}' || echo 'N/A')"
            echo "    BSSID: $(nmcli -t -f active,bssid dev wifi 2>/dev/null | awk -F: '$1=="yes"{print $2; exit}' || echo 'N/A')"
        else
            echo "    Status: Not connected"
        fi
        echo ""
    fi
done

echo "🔧 Service Status:"
for service in wifi-good wifi-bad wired-test; do
    if systemctl list-unit-files | grep -q "^${service}\.service"; then
        status=$(systemctl is-active "${service}.service" 2>/dev/null || echo "inactive")
        echo "  $service: $status"
    fi
done
echo ""

echo "📋 Identity Files:"
ls -la /home/pi/wifi_test_dashboard/identity_*.json 2>/dev/null || echo "  No identity files found"

echo ""
echo "🎯 Recent Log Entries (last 5 lines each):"
for log in wifi-good wifi-bad; do
    echo "  $log.log:"
    tail -5 "/home/pi/wifi_test_dashboard/logs/${log}.log" 2>/dev/null | sed 's/^/    /' || echo "    Log not found"
    echo ""
done