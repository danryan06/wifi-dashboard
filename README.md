# Wi-Fi Test Dashboard v5.0.0

🌐 **Advanced Raspberry Pi Traffic Generator for Juniper Mist PoC Demonstrations**

A comprehensive network testing platform that simulates multiple client types across ethernet and Wi-Fi interfaces, designed specifically for Juniper Mist Proof of Concept demonstrations.

## 🚀 Features

### Multi-Interface Traffic Generation
- **Ethernet (eth0)**: Heavy traffic simulation with speedtest CLI, large downloads, and YouTube streaming
- **Wi-Fi Adapter 1 (wlan0)**: Medium intensity traffic with good authentication simulation
- **Wi-Fi Adapter 2 (wlan1)**: Light traffic with authentication failure simulation

### Advanced Traffic Types
- **Speedtest CLI Integration**: Automated bandwidth testing across all interfaces
- **YouTube Traffic Simulation**: Video streaming simulation using yt-dlp/youtube-dl
- **HTTP/HTTPS Downloads**: Concurrent file downloads from multiple sources
- **Ping Traffic**: Continuous connectivity testing
- **Network Emulation**: Built-in latency and packet loss simulation (netem)

### Client Simulation
- **Good Wi-Fi Client**: Successful authentication and normal traffic patterns
- **Bad Wi-Fi Client**: Authentication failure simulation for testing security policies
- **Wired Client**: Ethernet-based traffic generation with DHCP hostname identification

### Management & Monitoring
- **Web Dashboard**: Real-time monitoring and configuration (port 5000)
- **Traffic Control Interface**: Per-interface traffic management
- **Comprehensive Logging**: Detailed logs for all services and traffic types
- **Service Management**: Start/stop/restart individual components
- **System Controls**: Remote reboot/shutdown capabilities

## 📋 Requirements

### Hardware
- Raspberry Pi 4 (recommended) or Pi 3B+
- MicroSD card (32GB+ recommended)
- 2x USB Wi-Fi adapters (in addition to built-in Wi-Fi)
- Ethernet connection for wired testing

### Software
- Raspberry Pi OS (Bullseye or newer)
- Internet connection for installation

## 🛠 Installation

### Quick Install (Recommended)
```bash
curl -sSL https://raw.githubusercontent.com/danryan06/wifi-dashboard/main/install.sh | sudo bash
```

### Manual Installation
1. Clone the repository:
```bash
git clone https://github.com/danryan06/wifi-dashboard.git
cd wifi-dashboard
```

2. Run the installer:
```bash
sudo ./install.sh
```

### Installation Features
- **Automatic cleanup**: Removes previous installations
- **Dependency management**: Installs all required packages
- **Service configuration**: Sets up systemd services
- **Permission handling**: Configures sudo access for network operations
- **Verification**: Tests installation integrity

## 🎯 Usage

### 1. Access the Dashboard
Open your web browser and navigate to:
```
http://[PI_IP_ADDRESS]:5000
```

### 2. Configure Wi-Fi Settings
1. Go to the **Wi-Fi Config** tab
2. Enter your target SSID and password
3. Click **Save Configuration**
4. Services will automatically restart with new settings

### 3. Monitor Traffic Generation
- **Status Tab**: Real-time system information and service status
- **Logs Tab**: View detailed logs from all services
- **Traffic Control**: Manage per-interface traffic generation

### 4. Network Emulation
Use the **Network Emulation** tab to simulate:
- Network latency (0-5000ms)
- Packet loss (0-100%)

## 🔧 Configuration

### Traffic Intensity Settings
Each interface supports different traffic intensities:

**Light**: 
- Speedtest every 10 minutes
- Downloads every 5 minutes
- 2 concurrent downloads
- 50MB chunks

**Medium**:
- Speedtest every 5 minutes  
- Downloads every 2 minutes
- 3 concurrent downloads
- 100MB chunks

**Heavy**:
- Speedtest every 3 minutes
- Downloads every minute
- 5 concurrent downloads
- 200MB chunks

### Interface Configuration
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

## 📊 Services Overview

### Core Services
- `wifi-dashboard.service`: Web interface (Flask application)
- `wired-test.service`: Ethernet client simulation
- `wifi-good.service`: Successful Wi-Fi client simulation  
- `wifi-bad.service`: Failed authentication simulation

### Traffic Generation Services
- `traffic-eth0.service`: Ethernet traffic generation
- `traffic-wlan0.service`: Wi-Fi adapter 1 traffic generation
- `traffic-wlan1.service`: Wi-Fi adapter 2 traffic generation

### Service Management
```bash
# View service status
sudo systemctl status wifi-dashboard.service

# Restart a service
sudo systemctl restart traffic-eth0.service

# View real-time logs
sudo journalctl -u wifi-good.service -f

# Check all services
sudo systemctl status wifi-dashboard wired-test wifi-good wifi-bad traffic-*
```

## 🗂 Directory Structure

```
/home/pi/wifi_test_dashboard/
├── app.py                          # Flask web application
├── configs/
│   ├── ssid.conf                   # Wi-Fi credentials (SSID/password)
│   └── settings.conf               # System configuration
├── scripts/
│   ├── interface_traffic_generator.sh   # Main traffic generator
│   ├── wired_simulation.sh              # Ethernet client simulation
│   ├── connect_and_curl.sh              # Wi-Fi good client
│   └── fail_auth_loop.sh                # Wi-Fi bad client
├── templates/
│   ├── dashboard.html              # Main web interface
│   └── traffic_control.html        # Traffic management interface
└── logs/
    ├── main.log                    # Dashboard logs
    ├── wired.log                   # Ethernet client logs
    ├── wifi-good.log               # Good Wi-Fi client logs
    ├── wifi-bad.log                # Bad Wi-Fi client logs
    ├── traffic-eth0.log            # Ethernet traffic logs
    ├── traffic-wlan0.log           # Wi-Fi adapter 1 traffic logs
    └── traffic-wlan1.log           # Wi-Fi adapter 2 traffic logs
```

## 🔍 Troubleshooting

### Common Issues

**Services not starting:**
```bash
sudo systemctl daemon-reload
sudo systemctl restart wifi-dashboard.service
```

**Wi-Fi adapters not detected:**
```bash
# Check interface availability
ip link show

# Ensure NetworkManager manages interfaces
sudo nmcli device set wlan0 managed yes
sudo nmcli device set wlan1 managed yes
```

**Permission errors:**
```bash
# Verify sudoers configuration
sudo visudo -f /etc/sudoers.d/wifi_test_dashboard
```

**Traffic generation not working:**
```bash
# Check interface IP addresses
ip addr show eth0
ip addr show wlan0
ip addr show wlan1

# Test interface connectivity
ping -I eth0 8.8.8.8
```

### Log Analysis
```bash
# View all logs simultaneously
sudo journalctl -u wifi-dashboard -u wired-test -u wifi-good -u wifi-bad -f

# Check traffic generation logs
tail -f /home/pi/wifi_test_dashboard/logs/traffic-*.log

# Debug network issues
sudo nmcli connection show --active
```

### Performance Optimization
- Monitor CPU usage: `top` or `htop`
- Check memory usage: `free -h`
- Monitor network interfaces: `iftop` or `nethogs`
- Adjust traffic intensity in settings.conf

## 🛡 Security Considerations

- Dashboard runs on port 5000 (consider firewall rules)
- Wi-Fi credentials stored in `/home/pi/wifi_test_dashboard/configs/ssid.conf` (permissions 600)
- Sudo permissions configured for network operations only
- Services run as pi user (not root)

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feature-name`
3. Commit changes: `git commit -am 'Add feature'`
4. Push to branch: `git push origin feature-name`
5. Submit a pull request

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.

## 🏷 Version History

### v5.0.0 (Current)
- Enhanced traffic generation with speedtest CLI and YouTube simulation
- Per-interface traffic control and monitoring
- Improved web interface with traffic control page
- Advanced logging and monitoring capabilities
- Modular installation system

### v4.8.0
- Basic multi-interface support
- Web dashboard implementation
- Service-based architecture
- Network emulation support

## 📞 Support

For issues and questions:
- Open an issue on GitHub
- Check the troubleshooting section above
- Review system logs for error details

---

**Built for Juniper Mist PoC demonstrations** 🌐