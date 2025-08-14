# 🔧 Wi-Fi Test Dashboard Troubleshooting Guide

This guide helps you diagnose and fix common issues with the Wi-Fi Test Dashboard system.

## 🚀 Quick Diagnostic

Run the diagnostic script first to identify issues:

```bash
sudo bash /home/pi/wifi_test_dashboard/scripts/diagnose-dashboard.sh
```

## 📋 Common Issues

### 1. Services Stuck in "Activating" State

**Symptoms:**
- Services show "activating" but never start
- Dashboard shows services as inactive
- No log entries being generated

**Causes:**
- Missing script files
- Incorrect file permissions
- Network interfaces not ready
- Missing dependencies

**Solutions:**

#### A. Run the Fix Script
```bash
sudo bash /home/pi/wifi_test_dashboard/scripts/fix-services.sh
```

#### B. Manual Fixes
```bash
# Check if scripts exist
ls -la /home/pi/wifi_test_dashboard/scripts/

# Fix permissions
sudo chown -R pi:pi /home/pi/wifi_test_dashboard
sudo chmod +x /home/pi/wifi_test_dashboard/scripts/*.sh

# Restart services
sudo systemctl daemon-reload
sudo systemctl restart wifi-good.service
```

### 2. Missing Wi-Fi Adapters

**Symptoms:**
- `wlan0` or `wlan1` interfaces not found
- Services fail with "interface not found" errors

**Solutions:**

#### A. Check Available Interfaces
```bash
ip link show
nmcli device status
```

#### B. Add USB Wi-Fi Adapters
- Connect 2 USB Wi-Fi adapters for full functionality
- Ensure adapters are compatible with Linux

#### C. Configure NetworkManager
```bash
# Ensure NetworkManager manages Wi-Fi interfaces
sudo nmcli device set wlan0 managed yes
sudo nmcli device set wlan1 managed yes
```

### 3. No Internet Connectivity

**Symptoms:**
- Traffic generation fails
- Speedtest services error out
- YouTube traffic doesn't work

**Solutions:**

#### A. Check Basic Connectivity
```bash
ping -c 3 8.8.8.8
curl -I https://www.google.com
```

#### B. DNS Issues
```bash
# Test DNS resolution
nslookup google.com

# Fix DNS if needed
echo "nameserver 8.8.8.8" | sudo tee -a /etc/resolv.conf
```

### 4. YouTube Traffic Not Working

**Symptoms:**
- Traffic generation works but no YouTube activity
- yt-dlp errors in logs

**Solutions:**

#### A. Install yt-dlp
```bash
sudo pip3 install yt-dlp --break-system-packages
```

#### B. Test YouTube Downloader
```bash
yt-dlp --list-formats "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
```

#### C. Alternative: Use youtube-dl
```bash
sudo apt-get install youtube-dl
```

### 5. Speedtest Not Working

**Symptoms:**
- Speedtest services fail
- No bandwidth testing happening

**Solutions:**

#### A. Install Official Speedtest CLI
```bash
curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | sudo bash
sudo apt-get update
sudo apt-get install speedtest
```

#### B. Accept License
```bash
speedtest --accept-license --accept-gdpr
```

#### C. Fallback to Python Version
```bash
sudo pip3 install speedtest-cli --break-system-packages
```

### 6. Configuration Issues

**Symptoms:**
- Wi-Fi not connecting
- Services can't read configuration

**Solutions:**

#### A. Check Configuration Files
```bash
ls -la /home/pi/wifi_test_dashboard/configs/
cat /home/pi/wifi_test_dashboard/configs/ssid.conf
```

#### B. Fix Configuration Format
```bash
# SSID configuration should have exactly 2 lines:
echo "YourSSID" > /home/pi/wifi_test_dashboard/configs/ssid.conf
echo "YourPassword" >> /home/pi/wifi_test_dashboard/configs/ssid.conf
chmod 600 /home/pi/wifi_test_dashboard/configs/ssid.conf
```

### 7. Dashboard Not Accessible

**Symptoms:**
- Can't reach http://PI_IP:5000
- Dashboard service not running

**Solutions:**

#### A. Check Dashboard Service
```bash
sudo systemctl status wifi-dashboard.service
sudo systemctl restart wifi-dashboard.service
```

#### B. Check Firewall
```bash
sudo ufw status
sudo ufw allow 5000
```

#### C. Check IP Address
```bash
hostname -I
# Use the first IP address shown
```

## 🔍 Advanced Diagnostics

### View Service Logs
```bash
# Dashboard logs
sudo journalctl -u wifi-dashboard.service -f

# Individual service logs
sudo journalctl -u wifi-good.service -n 20
sudo journalctl -u wired-test.service -n 20
sudo journalctl -u traffic-eth0.service -n 20
```

### Check Network Interfaces
```bash
# Show all interfaces
ip addr show

# Show Wi-Fi status
iwconfig

# Show NetworkManager connections
nmcli connection show
nmcli device wifi list
```

### Monitor Traffic Generation
```bash
# Watch traffic logs
tail -f /home/pi/wifi_test_dashboard/logs/traffic-*.log

# Monitor network activity
sudo iftop -i eth0
sudo nethogs
```

### Check Dependencies
```bash
# Python packages
pip3 list | grep -E "(flask|requests|speedtest|yt-dlp)"

# System packages
dpkg -l | grep -E "(network-manager|curl|python3)"

# Commands availability
command -v speedtest || echo "speedtest missing"
command -v yt-dlp || echo "yt-dlp missing"
command -v nmcli || echo "nmcli missing"
```

## 🛠 Service Management

### Start/Stop Services
```bash
# Start all services
sudo systemctl start wifi-dashboard wired-test wifi-good wifi-bad

# Stop all services
sudo systemctl stop wifi-dashboard wired-test wifi-good wifi-bad

# Restart with delays
sudo systemctl restart wifi-dashboard
sleep 5
sudo systemctl restart wired-test
sleep 3
sudo systemctl restart wifi-good
sleep 3
sudo systemctl restart wifi-bad
```

### Service Status
```bash
# Check all service statuses
sudo systemctl status wifi-dashboard wired-test wifi-good wifi-bad traffic-*

# Enable services to start on boot
sudo systemctl enable wifi-dashboard wired-test wifi-good wifi-bad
```

## 🔄 Reset and Reinstall

### Clean Reset
```bash
# Stop all services
sudo systemctl stop wifi-dashboard wired-test wifi-good wifi-bad traffic-*

# Remove old installation
sudo rm -rf /home/pi/wifi_test_dashboard

# Reinstall
curl -sSL https://raw.githubusercontent.com/danryan06/wifi-dashboard/main/install.sh | sudo bash
```

### Partial Reset (Keep Configuration)
```bash
# Backup configuration
cp -r /home/pi/wifi_test_dashboard/configs /tmp/wifi-dashboard-backup

# Reset scripts only
rm -rf /home/pi/wifi_test_dashboard/scripts
sudo bash /home/pi/wifi_test_dashboard/scripts/fix-services.sh

# Restore configuration
cp -r /tmp/wifi-dashboard-backup/* /home/pi/wifi_test_dashboard/configs/
```

## 📞 Getting Help

### Check System Requirements
- Raspberry Pi 3B+ or 4 (recommended)
- Raspberry Pi OS (Bullseye or newer)
- Internet connection
- 2x USB Wi-Fi adapters (optional but recommended)

### Log Collection
When seeking help, collect these logs:
```bash
# System info
uname -a
cat /etc/os-release

# Service status
sudo systemctl status wifi-dashboard wired-test wifi-good wifi-bad

# Recent logs
sudo journalctl --since "1 hour ago" -u wifi-dashboard -u wired-test -u wifi-good -u wifi-bad

# Network configuration
ip addr show
nmcli device status
```

### Community Support
- GitHub Issues: https://github.com/danryan06/wifi-dashboard/issues
- Include system information and error logs
- Describe steps to reproduce the issue

---

**💡 Remember:** Most issues can be resolved by running the diagnostic script followed by the fix script. When in doubt, check the logs first!