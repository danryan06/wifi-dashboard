#!/usr/bin/env bash
# scripts/install/03-directories.sh
# Create directory structure and basic configuration

set -euo pipefail

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }

log_info "Creating directory structure..."

# Create main directory structure
mkdir -p "$PI_HOME/wifi_test_dashboard"/{scripts,templates,configs,logs}
# --- Default settings (only create if missing/empty) ---
if [[ ! -s "$DASHBOARD_DIR/configs/settings.conf" ]]; then
  cat >"$DASHBOARD_DIR/configs/settings.conf" <<'EOF'
# ===== Wi-Fi Good Client (integrated traffic) =====
# Master switch for integrated traffic inside connect_and_curl.sh
WIFI_GOOD_INTEGRATED_TRAFFIC=true

# Speedtest controls
WIFI_GOOD_RUN_SPEEDTEST=false
WIFI_GOOD_SPEEDTEST_INTERVAL=900      # seconds between speedtests

# YouTube traffic controls
WIFI_GOOD_RUN_YOUTUBE=false
WIFI_GOOD_YT_INTERVAL=1800            # seconds between yt pulls
YT_TEST_VIDEO_URL="https://www.youtube.com/watch?v=BaW_jenozKc"  # yt-dlp's test video

# Traffic intensity: light | medium | heavy
WLAN0_TRAFFIC_INTENSITY=medium

# Roaming controls
WIFI_ROAMING_ENABLED=true
WIFI_ROAMING_INTERVAL=120
WIFI_ROAMING_SCAN_INTERVAL=30
WIFI_MIN_SIGNAL_THRESHOLD=-75
WIFI_ROAMING_SIGNAL_DIFF=10
WIFI_BAND_PREFERENCE=2.4  # 2.4 | 5 | both

# Interface / hostnames (can be overridden by interface-assignments.conf)
WIFI_GOOD_HOSTNAME="CNXNMist-WiFiGood"
WIFI_BAD_HOSTNAME="CNXNMist-WiFiBad"

# Timeouts & retries
WIFI_CONNECTION_TIMEOUT=30
WIFI_MAX_RETRY_ATTEMPTS=3
WIFI_GOOD_REFRESH_INTERVAL=60
EOF

  chown "$PI_USER:$PI_USER" "$DASHBOARD_DIR/configs/settings.conf"
  log_info "Created default settings: $DASHBOARD_DIR/configs/settings.conf"
else
  log_info "settings.conf already present; leaving as-is"
fi

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