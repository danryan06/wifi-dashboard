# Wi-Fi Test Dashboard v5.1.0

🌐 **Advanced Raspberry Pi Traffic Generator with Wi-Fi Roaming for Juniper Mist PoC Demonstrations**

A comprehensive network testing platform that simulates realistic client behavior including **Wi-Fi roaming between access points**, designed specifically for Juniper Mist Proof of Concept demonstrations.

## 🆕 **What's New in v5.1.0**

### 🔄 **Wi-Fi Roaming Simulation**
- **Automatic BSSID Discovery**: Scans and catalogs all access points broadcasting the same SSID
- **Intelligent Roaming**: Automatically roams between APs every 2 minutes based on signal strength
- **Traffic Continuity**: Maintains downloads and data flows during roaming events
- **Demo-Ready Logging**: Enhanced logs perfect for live PoC demonstrations
- **Mist Analytics**: Full visibility of client roaming patterns in Mist dashboard

### 🏗️ **Integrated Architecture** 
- **Consolidated Services**: Traffic generation now integrated within client simulation services
- **Enhanced Performance**: Reduced resource usage and improved reliability
- **Simplified Management**: Fewer services to monitor and troubleshoot

## 🚀 **Features**

### **Wi-Fi Client Roaming Simulation**
- **Multi-BSSID Discovery**: Automatically finds all APs broadcasting the target SSID
- **Signal-Based Roaming**: Intelligently selects target APs based on signal strength
- **Configurable Intervals**: Customizable roaming frequency (default: every 2 minutes)
- **Roaming Analytics**: Detailed logging of roaming events for Mist dashboard visibility
- **Traffic Persistence**: Seamless data flow continuation during roaming events

### **Multi-Interface Traffic Generation**
- **Ethernet (eth0)**: Heavy traffic simulation with integrated speedtest and downloads
- **Wi-Fi Primary (wlan0)**: Good client with roaming + medium intensity traffic
- **Wi-Fi Secondary (wlan1)**: Authentication failure simulation for security testing

### **Advanced Traffic Types**
- **Speedtest CLI Integration**: Automated bandwidth testing across all interfaces
- **YouTube Traffic Simulation**: Video streaming simulation using yt-dlp
- **HTTP/HTTPS Downloads**: Concurrent file downloads from multiple sources
- **Continuous Ping Traffic**: Connectivity testing and latency monitoring
- **Network Emulation**: Built-in latency and packet loss simulation (netem)

### **Client Simulation**
- **Good Wi-Fi Client**: Successful authentication with realistic roaming behavior
- **Bad Wi-Fi Client**: Authentication failure simulation for security policy testing
- **Wired Client**: Ethernet-based traffic generation with DHCP hostname identification

### **Management & Monitoring**
- **Web Dashboard**: Real-time monitoring and configuration (port 5000)
- **Enhanced Logging**: Scrollable logs with roaming event details
- **Interface Assignment**: Automatic detection and optimal assignment of network interfaces
- **Service Management**: Integrated traffic generation within client services
- **System Controls**: Remote reboot/shutdown capabilities

## 📋 **Requirements**

### **Hardware**
- Raspberry Pi 4 (recommended) or Pi 3B+
- MicroSD card (32GB+ recommended)
- **2x USB Wi-Fi adapters** (for full roaming demonstration)
- Ethernet connection for wired testing
- **Multiple APs broadcasting the same SSID** (for roaming)

### **Software**
- Raspberry Pi OS (Bullseye or newer)
- Internet connection for installation

### **Network Setup for Roaming**
- **2+ Access Points** broadcasting identical SSID and security settings
- **Overlapping coverage** where Pi can receive signals from multiple APs
- **Different BSSIDs** (each AP will have unique MAC address)

## 🛠 **Installation**

### **Quick Install (Recommended)**
```bash
curl -sSL https://raw.githubusercontent.com/danryan06/wifi-dashboard/main/install.sh | sudo bash
```

### **Manual Installation**
1. Clone the repository:
```bash
git clone https://github.com/danryan06/wifi-dashboard.git
cd wifi-dashboard
```

2. Run the installer:
```bash
sudo ./install.sh
```

### **Installation Features**
- **Automatic cleanup**: Removes previous installations
- **Intelligent interface detection**: Auto-assigns optimal Wi-Fi interfaces
- **Dependency management**: Installs all required packages including roaming tools
- **Service configuration**: Sets up integrated traffic generation services
- **Roaming capability**: Enables Wi-Fi roaming simulation by default
- **Verification**: Tests installation integrity and roaming readiness

## 🎯 **Usage**

### **1. Access the Dashboard**
Open your web browser and navigate to:
```
http://[PI_IP_ADDRESS]:5000
```

### **2. Configure Wi-Fi Settings**
1. Go to the **Wi-Fi Config** tab
2. Enter your target SSID and password
3. Click **Save Configuration**
4. Services will automatically restart with roaming enabled

### **3. Monitor Roaming Activity**
- **Status Tab**: Real-time system information and interface assignments
- **Interfaces Tab**: View automatic interface assignments and capabilities
- **Logs Tab**: Watch live roaming events and traffic generation
- **Enhanced Log Viewing**: Scrollable logs with roaming event details

### **4. Verify Roaming Setup**
```bash
# Check for multiple BSSIDs with your SSID
sudo nmcli device wifi list | grep "YourSSID"

# Monitor roaming events live
sudo journalctl -u wifi-good.service -f | grep -E "(Roaming|BSSID|📡|🔄)"

# Check roaming configuration
grep "ROAMING" /home/pi/wifi_test_dashboard/configs/settings.conf
```

## 🔧 **Configuration**

### **Roaming Configuration**
Edit `/home/pi/wifi_test_dashboard/configs/settings.conf`:

```bash
# Wi-Fi Roaming Settings
WIFI_ROAMING_ENABLED=true              # Enable roaming simulation
WIFI_ROAMING_INTERVAL=120              # Roam every 2 minutes
WIFI_ROAMING_SCAN_INTERVAL=30          # Scan for BSSIDs every 30 seconds
WIFI_MIN_SIGNAL_THRESHOLD=-75          # Minimum signal strength (dBm)
WIFI_ROAMING_VERBOSE_LOGGING=true      # Enhanced demo logging
```

### **Traffic Intensity Settings**
```bash
# Per-interface traffic settings
ETH0_TRAFFIC_INTENSITY=heavy           # Ethernet: Heavy traffic
WLAN0_TRAFFIC_INTENSITY=medium         # Wi-Fi Primary: Medium traffic + roaming
WLAN1_TRAFFIC_INTENSITY=light          # Wi-Fi Secondary: Auth failures only

# Enhanced roaming traffic
WIFI_GOOD_INTEGRATED_TRAFFIC=true      # Traffic continues during roaming
DEMO_TRAFFIC_CONTINUITY=true           # Maintain traffic flow for demos
```

### **Mist Demo Optimizations**
```bash
# Demo-specific settings
MIST_DEMO_MODE=true                    # Enable demo-friendly features
MIST_ROAMING_NOTIFICATIONS=true        # Enhanced roaming event logging
DEMO_ROAMING_FREQUENCY=enhanced        # More frequent roaming for demo impact
```

## 📊 **Services Architecture**

### **Integrated Services (v5.1.0)**
- `wifi-dashboard.service`: Web interface (Flask application)
- `wired-test.service`: Ethernet client simulation with integrated heavy traffic
- `wifi-good.service`: Wi-Fi client with roaming simulation and integrated medium traffic
- `wifi-bad.service`: Authentication failure simulation for security testing

### **Service Management**
```bash
# View service status
sudo systemctl status wifi-dashboard wifi-good wifi-bad wired-test

# Monitor roaming client
sudo systemctl status wifi-good.service

# View real-time roaming logs
sudo journalctl -u wifi-good.service -f

# Restart roaming client
sudo systemctl restart wifi-good.service
```

## 🗂 **Directory Structure**

```
/home/pi/wifi_test_dashboard/
├── app.py                              # Flask web application with enhanced interface view
├── INTERFACE_ASSIGNMENT.md             # Auto-generated interface assignment summary
├── configs/
│   ├── ssid.conf                       # Wi-Fi credentials (SSID/password)
│   ├── settings.conf                   # System configuration with roaming settings
│   └── interface-assignments.conf     # Auto-detected interface assignments
├── scripts/
│   ├── traffic/
│   │   ├── connect_and_curl.sh         # Wi-Fi good client with roaming (ENHANCED)
│   │   ├── fail_auth_loop.sh           # Wi-Fi bad client (auth failures)
│   │   ├── wired_simulation.sh         # Wired client with integrated traffic
│   │   └── interface_traffic_generator.sh # Shared traffic generator
│   ├── install/                        # Installation sub-scripts
│   ├── diagnose-dashboard.sh           # System diagnostic tool
│   └── fix-services.sh                 # Service repair utility
├── templates/
│   ├── dashboard.html                  # Enhanced web interface with interface view
│   └── traffic_control.html            # Traffic management interface
└── logs/
    ├── main.log                        # Dashboard logs
    ├── wired.log                       # Ethernet client logs
    ├── wifi-good.log                   # Wi-Fi good client with roaming event logs
    └── wifi-bad.log                    # Wi-Fi bad client logs
```

## 🔍 **Roaming Monitoring & Troubleshooting**

### **Roaming Event Logs**
```bash
# Watch roaming events in real-time
sudo journalctl -u wifi-good.service -f | grep -E "(🔍|📡|🔄|✅|📍)"

# Check recent roaming activity
grep -E "(Roaming|BSSID)" /home/pi/wifi_test_dashboard/logs/wifi-good.log | tail -10

# Verify BSSID discovery
grep "Found BSSID" /home/pi/wifi_test_dashboard/logs/wifi-good.log
```

### **Expected Roaming Log Messages**
```bash
[2024-XX-XX XX:XX:XX] WIFI-GOOD: 🔍 Scanning for BSSIDs broadcasting SSID: YourSSID
[2024-XX-XX XX:XX:XX] WIFI-GOOD: 📡 Found BSSID: aa:bb:cc:dd:ee:f1 (Signal: -42dBm)
[2024-XX-XX XX:XX:XX] WIFI-GOOD: 📡 Found BSSID: aa:bb:cc:dd:ee:f2 (Signal: -48dBm)
[2024-XX-XX XX:XX:XX] WIFI-GOOD: 🎯 Multiple BSSIDs found (2) - roaming enabled!
[2024-XX-XX XX:XX:XX] WIFI-GOOD: ⏰ Roaming interval reached, evaluating roaming opportunity...
[2024-XX-XX XX:XX:XX] WIFI-GOOD: 🔄 Initiating roaming to BSSID: aa:bb:cc:dd:ee:f2
[2024-XX-XX XX:XX:XX] WIFI-GOOD: ✅ Roaming successful! Connected to: aa:bb:cc:dd:ee:f2
[2024-XX-XX XX:XX:XX] WIFI-GOOD: 📍 Current: BSSID aa:bb:cc:dd:ee:f2 (-48dBm) | Available BSSIDs: 2
```

### **Common Roaming Issues**

#### **Only One BSSID Found**
```bash
# Check if multiple APs are broadcasting the same SSID
sudo nmcli device wifi list | grep "YourSSID"

# Ensure APs have overlapping coverage
iwconfig wlan0  # Check current signal strength

# Verify roaming is enabled
grep "WIFI_ROAMING_ENABLED" /home/pi/wifi_test_dashboard/configs/settings.conf
```

#### **Roaming Not Occurring**
```bash
# Check roaming interval hasn't been reached
grep "Roaming interval reached" /home/pi/wifi_test_dashboard/logs/wifi-good.log

# Verify signal thresholds
grep "signal.*threshold" /home/pi/wifi_test_dashboard/logs/wifi-good.log

# Check for roaming errors
grep -i "roaming.*fail" /home/pi/wifi_test_dashboard/logs/wifi-good.log
```

### **Performance Optimization**

#### **Hardware Optimization**
- **Position Pi** where it receives signals from multiple APs
- **Use external antennas** if built-in signal is weak
- **Ensure USB Wi-Fi adapters** are properly detected
- **Check power supply** - roaming requires stable power

#### **Configuration Tuning**
```bash
# Faster roaming for demos
WIFI_ROAMING_INTERVAL=90               # Roam every 1.5 minutes

# More sensitive signal detection
WIFI_MIN_SIGNAL_THRESHOLD=-80          # Accept weaker signals

# Enhanced scanning
WIFI_ROAMING_SCAN_INTERVAL=20          # Scan every 20 seconds
```

## 🎪 **Mist PoC Demonstration**

### **What Mist Dashboard Will Show**
1. **Client Roaming Events**: Real-time client movement between APs
2. **Roaming Analytics**: Success rates, timing, signal strength patterns
3. **Traffic Continuity**: Uninterrupted data flow during roaming
4. **RF Analytics**: Signal strength trends and roaming triggers
5. **Client Journey**: Complete path of client movement through the network

### **Demo Talking Points**
- *"Watch our simulated client automatically roam between your access points every 2 minutes..."*
- *"Notice how Mist tracks the client's movement and provides detailed roaming analytics..."*
- *"See how traffic continues seamlessly during roaming events - no interruption to user experience..."*
- *"Mist's AI learns from these patterns to optimize AP placement and roaming parameters..."*
- *"The client appears with hostname 'CNXNMist-WiFiGood-Roaming' for easy identification..."*

### **Live Demo Commands**
```bash
# Show current connection
iwconfig wlan0 | grep "Access Point"

# Monitor roaming live during demo
sudo journalctl -u wifi-good.service -f | grep --color=always -E "(🔄|✅|📍)"

# Show all discovered BSSIDs
sudo nmcli device wifi list | grep "DemoSSID"

# Display roaming statistics
grep -c "Roaming successful" /home/pi/wifi_test_dashboard/logs/wifi-good.log
```

## 🛡 **Security Considerations**

- Dashboard runs on port 5000 (consider firewall rules for customer networks)
- Wi-Fi credentials stored in `/home/pi/wifi_test_dashboard/configs/ssid.conf` (permissions 600)
- Roaming generates connection events that may trigger security monitoring
- Authentication failure simulation (bad client) is clearly logged for security teams
- Services run as pi user (not root) for security isolation

## 🤝 **Contributing**

1. Fork the repository
2. Create a feature branch: `git checkout -b feature-name`
3. Test roaming functionality with multiple APs
4. Commit changes: `git commit -am 'Add roaming enhancement'`
5. Push to branch: `git push origin feature-name`
6. Submit a pull request

## 📄 **License**

This project is licensed under the MIT License - see the LICENSE file for details.

## 🏷 **Version History**

### **v5.1.0 (Current) - Enhanced Wi-Fi Roaming**
- ✅ **Wi-Fi client roaming simulation** between multiple BSSIDs
- ✅ **Intelligent BSSID discovery** and signal-based roaming decisions
- ✅ **Traffic continuity** during roaming events for realistic behavior
- ✅ **Enhanced logging** with roaming event details for PoC demonstrations
- ✅ **Integrated traffic generation** within client simulation services
- ✅ **Auto-interface assignment** with capability detection
- ✅ **Mist PoC optimizations** including demo-friendly hostnames and logging
- ✅ **Improved web interface** with interface assignment visualization

### **v5.0.0 - Advanced Traffic Generation**
- Enhanced traffic generation with speedtest CLI and YouTube simulation
- Per-interface traffic control and monitoring
- Improved web interface with traffic control page
- Advanced logging and monitoring capabilities
- Modular installation system

### **v4.8.0 - Foundation**
- Basic multi-interface support
- Web dashboard implementation
- Service-based architecture
- Network emulation support

## 📞 **Support**

### **For Technical Issues:**
- **Check logs first**: `/home/pi/wifi_test_dashboard/logs/wifi-good.log`
- **Run diagnostics**: `sudo bash /home/pi/wifi_test_dashboard/scripts/diagnose-dashboard.sh`
- **Verify roaming setup**: Ensure multiple APs broadcast the same SSID
- **Open GitHub issue** with system info and logs

### **For Mist PoC Support:**
- **Verify interface assignments**: Check `INTERFACE_ASSIGNMENT.md`
- **Confirm roaming events**: Monitor logs during demonstration
- **Check Mist dashboard**: Verify client appears with roaming hostname
- **Signal strength**: Ensure Pi receives adequate signal from multiple APs

### **Repository Information:**
- **Main Repository**: https://github.com/danryan06/wifi-dashboard
- **Issues**: https://github.com/danryan06/wifi-dashboard/issues
- **Documentation**: https://github.com/danryan06/wifi-dashboard/wiki

---
