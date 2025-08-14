# 📦 Wi-Fi Test Dashboard Installation Guide

Complete installation guide for the Wi-Fi Test Dashboard v5.0 with advanced traffic generation capabilities.

## 🎯 Overview

The Wi-Fi Test Dashboard is a comprehensive network testing platform designed for Juniper Mist Proof of Concept demonstrations. It simulates multiple client types across ethernet and Wi-Fi interfaces with advanced traffic generation including speedtest CLI integration and YouTube traffic simulation.

## 📋 Prerequisites

### Hardware Requirements
- **Raspberry Pi 4** (recommended) or Pi 3B+
- **MicroSD card** (32GB+ recommended)
- **2x USB Wi-Fi adapters** (in addition to built-in Wi-Fi)
- **Ethernet connection** for wired testing
- **Internet connection** during installation

### Software Requirements
- **Raspberry Pi OS** (Bullseye or newer)
- **SSH access** (for remote installation)
- **Sudo privileges** (installation runs as root)

### Network Requirements
- Internet connectivity for downloading packages
- Access to target Wi-Fi networks for testing
- DHCP server on test networks (recommended)

## 🚀 Installation Methods

### Method 1: Quick Install (Recommended)

The fastest way to get started:

```bash
curl -sSL https://raw.githubusercontent.com/danryan06/wifi-dashboard/main/install.sh | sudo bash
```

This single command will:
- Download and run the complete installer
- Install all dependencies
- Configure system services
- Set up the web dashboard
- Start traffic generation services

### Method 2: Manual Installation

For more control over the installation process:

#### Step 1: Clone Repository
```bash
git clone https://github.com/danryan06/wifi-dashboard.git
cd wifi-dashboard
```

#### Step 2: Run Installer
```bash
sudo ./install.sh
```

#### Step 3: Verify Installation
```bash
sudo systemctl status wifi-dashboard.service
```

### Method 3: Docker Installation (Future)

*Docker installation method coming in future releases*

## 🔧 Installation Process Details

The installer performs these steps automatically:

### Phase 1: System Dependencies (01-dependencies.sh)
- Updates package lists
- Installs core system packages
- Configures official Ookla Speedtest CLI
- Installs Python dependencies (Flask, requests)
- Installs YouTube tools (yt-dlp)
- Configures NetworkManager
- Sets up Wi-Fi country and unblocks devices

### Phase 2: Cleanup (02-cleanup.sh)
- Stops existing services
- Removes previous installations
- Cleans up old configuration

### Phase 3: Directory Structure (03-directories.sh)
- Creates main directory: `/home/pi/wifi_test_dashboard/`
- Sets up subdirectories: scripts, templates, configs, logs
- Creates initial configuration files
- Sets proper permissions

### Phase 4: Flask Application (04-flask-app.sh)
- Downloads or creates Flask web application
- Configures web dashboard
- Sets up API endpoints
- Verifies Python dependencies

### Phase 5: Web Templates (05-templates.sh)
- Downloads dashboard HTML templates
- Creates traffic control interface
- Sets up responsive web design
- Configures JavaScript functionality

### Phase 6: Traffic Scripts (06-traffic-scripts.sh)
- Downloads traffic generation scripts
- Creates client simulation scripts
- Sets up speedtest integration
- Configures YouTube traffic simulation
- Makes scripts executable

### Phase 7: System Services (07-services.sh)
- Creates systemd service files
- Configures service dependencies
- Sets up auto-restart policies
- Configures resource limits

### Phase 8: Finalization (08-finalize.sh)
- Enables and starts services
- Verifies installation
- Performs health checks
- Reports installation status

## 🌐 Post-Installation Configuration

### 1. Access the Dashboard

Open your web browser and navigate to:
```
http://[PI_IP_ADDRESS]:5000
```

To find your Pi's IP address:
```bash
hostname -I
```

### 2. Configure Wi-Fi Settings

1. Go to the **Wi-Fi Config** tab
2. Enter your target SSID and password
3. Click **Save Configuration**
4. Services will automatically restart with new settings

### 3. Monitor System Status

The **Status** tab shows:
- Current SSID configuration
- Primary IP address
- Active services count
- Network interfaces
- System time

### 4. Control Traffic Generation

Visit the **Traffic Control** page at:
```
http://[PI_IP_ADDRESS]:5000/traffic_control
```

This allows you to:
- Start/stop traffic on individual interfaces
- Monitor traffic generation status
- View real-time logs
- Control traffic intensity

### 5. Network Emulation

Use the **Network Emulation** tab to simulate:
- Network latency (0-5000ms)
- Packet loss (0-100%)
- Poor connection conditions
- Mobile network simulation

## 🔍 Verification

### Check Service Status
```bash
sudo systemctl status wifi-dashboard.service
sudo systemctl status wired-test.service
sudo systemctl status wifi-good.service
sudo systemctl status wifi-bad.service
sudo systemctl status traffic-eth0.service
sudo systemctl status traffic-wlan0.service
sudo systemctl status traffic-wlan1.service
```

### View Logs
```bash
# Dashboard logs
sudo journalctl -u wifi-dashboard.service -f

# Traffic generation logs
tail -f /home/pi/wifi_test_dashboard/logs/traffic-*.log

# All services
sudo journalctl -u wifi-* -u wired-* -u traffic-* -f
```

### Test Network Interfaces
```bash
# Check interface availability
ip link show eth0
ip link show wlan0
ip link show wlan1

# Test connectivity
ping -I eth0 -c 3 8.8.8.8
ping -I wlan0 -c 3 8.8.8.8  # (if connected)
```

## 🛠 Customization

### Traffic Intensity Settings

Edit `/home/pi/wifi_test_dashboard/configs/settings.conf`:

```bash
# Per-interface traffic settings
ETH0_TRAFFIC_TYPE=all
ETH0_TRAFFIC_INTENSITY=heavy
WLAN0_TRAFFIC_TYPE=all
WLAN0_TRAFFIC_INTENSITY=medium
WLAN1_TRAFFIC_TYPE=ping
WLAN1_TRAFFIC_INTENSITY=light

# YouTube traffic settings
ENABLE_YOUTUBE_TRAFFIC=true
YOUTUBE_PLAYLIST_URL=https://www.youtube.com/playlist?list=PLrAXtmRdnEQy5tts6p-v1URsm7wOSM-M0
```

### Service Configuration

Modify service behavior in `/etc/systemd/system/`:
- `wifi-dashboard.service` - Web interface
- `wired-test.service` - Ethernet client
- `wifi-good.service` - Successful Wi-Fi client
- `wifi-bad.service` - Failed authentication client
- `traffic-*.service` - Traffic generation services

After changes:
```bash
sudo systemctl daemon-reload
sudo systemctl restart [service-name]
```

## 🚨 Troubleshooting Installation

### Common Installation Issues

#### Network Connectivity Problems
```bash
# Test internet connection
ping -c 3 google.com

# Check DNS resolution
nslookup github.com

# Fix DNS if needed
echo "nameserver 8.8.8.8" | sudo tee -a /etc/resolv.conf
```

#### Permission Errors
```bash
# Fix ownership
sudo chown -R pi:pi /home/pi/wifi_test_dashboard

# Fix script permissions
sudo chmod +x /home/pi/wifi_test_dashboard/scripts/*.sh
```

#### Missing Dependencies
```bash
# Manually install Python packages
sudo pip3 install flask requests --break-system-packages

# Install missing system packages
sudo apt-get update
sudo apt-get install network-manager python3 python3-pip curl
```

#### Service Failures
```bash
# Check specific service errors
sudo journalctl -u wifi-dashboard.service --no-pager

# Restart failed services
sudo systemctl restart wifi-dashboard.service
```

### Recovery Options

#### Quick Fix
```bash
# Run diagnostic and fix script
sudo bash /home/pi/wifi_test_dashboard/scripts/diagnose-dashboard.sh
sudo bash /home/pi/wifi_test_dashboard/scripts/fix-services.sh
```

#### Reinstall
```bash
# Complete reinstallation
curl -sSL https://raw.githubusercontent.com/danryan06/wifi-dashboard/main/install.sh | sudo bash
```

## 📊 Performance Optimization

### Resource Usage

The dashboard is designed to be lightweight:
- **Memory**: ~512MB total for all services
- **CPU**: Low impact during normal operation
- **Storage**: ~100MB for installation
- **Network**: Configurable traffic generation

### Optimization Tips

1. **Adjust Traffic Intensity**: Lower intensity on resource-constrained systems
2. **Monitor Resource Usage**: Use `htop` to watch system load
3. **Limit Concurrent Downloads**: Reduce concurrent traffic streams
4. **Use Faster SD Card**: Class 10 or better recommended

## 🔄 Updates and Maintenance

### Updating the Dashboard
```bash
# Check for updates (manual process currently)
cd wifi-dashboard
git pull origin main
sudo ./install.sh
```

### Log Rotation
Logs are automatically managed, but for manual cleanup:
```bash
# Clean old logs
sudo journalctl --vacuum-time=7d

# Clean dashboard logs
find /home/pi/wifi_test_dashboard/logs -name "*.log" -mtime +7 -delete
```

### Backup Configuration
```bash
# Backup important files
tar -czf wifi-dashboard-backup.tar.gz \
  /home/pi/wifi_test_dashboard/configs/ \
  /etc/systemd/system/wifi-*.service \
  /etc/systemd/system/traffic-*.service
```

## 📞 Support

### Getting Help

1. **Check Documentation**: Review README.md and this guide
2. **Run Diagnostics**: Use the built-in diagnostic script
3. **Check Logs**: Review service logs for error messages
4. **Community Support**: Open an issue on GitHub

### Reporting Issues

When reporting issues, include:
- Raspberry Pi model and OS version
- Installation method used
- Error messages from logs
- Output from diagnostic script
- Steps to reproduce the problem

### GitHub Repository
- **Main Repository**: https://github.com/danryan06/wifi-dashboard
- **Issues**: https://github.com/danryan06/wifi-dashboard/issues
- **Documentation**: https://github.com/danryan06/wifi-dashboard/wiki

---

**🎉 Congratulations!** You now have a fully functional Wi-Fi Test Dashboard with advanced traffic generation capabilities. The system is ready for Juniper Mist PoC demonstrations and network testing scenarios.