#!/usr/bin/env bash
# scripts/install/03-directories.sh
# Create directory structure and basic configuration

set -euo pipefail

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }

log_info "Creating directory structure..."

# Create main directory structure
mkdir -p "$PI_HOME/wifi_test_dashboard"/{scripts,templates,configs,logs}
chown -R "$PI_USER:$PI_USER" "$PI_HOME/wifi_test_dashboard"

log_info "✓ Created main directories"

# Create configuration files
log_info "Creating configuration files..."

cat > "$PI_HOME/wifi_test_dashboard/configs/ssid.conf" <<EOF
TestSSID
TestPassword
EOF
chmod 600 "$PI_HOME/wifi_test_dashboard/configs/ssid.conf"

cat > "$PI_HOME/wifi_test_dashboard/configs/settings.conf" <<EOF
# Dashboard settings
LOG_LEVEL=INFO
REFRESH_INTERVAL=30
CURL_TIMEOUT=10
TEST_URLS=https://www.google.com,https://www.cloudflare.com,https://www.github.com

# Interface-specific traffic generation settings
ENABLE_INTERFACE_TRAFFIC=true

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
YOUTUBE_TRAFFIC_INTERVAL=600
YOUTUBE_MAX_DURATION=300

# Global traffic settings
DEFAULT_SPEEDTEST_INTERVAL=300
DEFAULT_DOWNLOAD_INTERVAL=60
DEFAULT_CONCURRENT_DOWNLOADS=3
MAX_DOWNLOAD_SIZE=104857600
EOF
chmod 644 "$PI_HOME/wifi_test_dashboard/configs/settings.conf"

log_info "✓ Created configuration files"

# Initialize log files
log_info "Initializing log files..."

LOG_FILES=(
    "main.log" "wired.log" "wifi-good.log" "wifi-bad.log"
    "traffic-eth0.log" "traffic-wlan0.log" "traffic-wlan1.log"
)

for log_file in "${LOG_FILES[@]}"; do
    log_path="$PI_HOME/wifi_test_dashboard/logs/$log_file"
    echo "[$(date '+%F %T')] Install/upgrade to $VERSION" > "$log_path"
    chmod 664 "$log_path"
    chown "$PI_USER:$PI_USER" "$log_path"
done

log_info "✓ Initialized log files"

# Set final ownership
chown -R "$PI_USER:$PI_USER" "$PI_HOME/wifi_test_dashboard"

log_info "✓ Directory structure and configuration completed"