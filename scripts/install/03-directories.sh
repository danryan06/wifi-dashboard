#!/usr/bin/env bash
# scripts/install/03-directories.sh
# Create directory structure and basic configuration

set -euo pipefail

# --------- Safe defaults so this script is self-contained ----------
: "${PI_USER:=pi}"
: "${PI_HOME:=/home/${PI_USER}}"
: "${VERSION:=v5.0.x}"
DASHBOARD_DIR="${PI_HOME}/wifi_test_dashboard"
# ------------------------------------------------------------------

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }

log_info "Creating directory structure..."

# Create main directory structure
mkdir -p "${DASHBOARD_DIR}"/{scripts,templates,configs,logs}

# ----------------------- settings.conf ----------------------------
# Only create if missing (don’t overwrite user’s changes)
SETTINGS="${DASHBOARD_DIR}/configs/settings.conf"
if [[ ! -s "$SETTINGS" ]]; then
  cat >"$SETTINGS" <<'EOF'
# ================= Wi-Fi Dashboard Settings =================

# ---------- Web / refresh ----------
LOG_LEVEL=INFO
REFRESH_INTERVAL=30
CURL_TIMEOUT=10

# ---------- Test URLs (comma-separated) ----------
TEST_URLS=https://www.google.com,https://www.cloudflare.com,https://www.github.com

# ---------- Integrated traffic (wifi-good) ----------
WIFI_GOOD_INTEGRATED_TRAFFIC=true
# Traffic intensity: light | medium | heavy
WLAN0_TRAFFIC_INTENSITY=medium

# ---------- Optional traffic: speedtest & YouTube ----------
# Installers may enable these and install packages
WIFI_GOOD_RUN_SPEEDTEST=false
WIFI_GOOD_SPEEDTEST_INTERVAL=900       # seconds between speedtests

WIFI_GOOD_RUN_YOUTUBE=false
WIFI_GOOD_YT_INTERVAL=1800             # seconds between yt pulls
YT_TEST_VIDEO_URL="https://www.youtube.com/watch?v=BaW_jenozKc"

# ---------- Per-interface traffic generator (if used) ----------
ENABLE_INTERFACE_TRAFFIC=true
ETH0_TRAFFIC_TYPE=all
ETH0_TRAFFIC_INTENSITY=heavy
WLAN1_TRAFFIC_TYPE=ping
WLAN1_TRAFFIC_INTENSITY=light

# ---------- Roaming controls ----------
WIFI_ROAMING_ENABLED=true
WIFI_ROAMING_INTERVAL=120
WIFI_ROAMING_SCAN_INTERVAL=30
WIFI_MIN_SIGNAL_THRESHOLD=-75
WIFI_ROAMING_SIGNAL_DIFF=10
# 2.4 | 5 | both
WIFI_BAND_PREFERENCE=2.4

# ---------- Hostnames (may be overridden by interface-assignments.conf) ----------
WIFI_GOOD_HOSTNAME="CNXNMist-WiFiGood"
WIFI_BAD_HOSTNAME="CNXNMist-WiFiBad"

# ---------- Timeouts & retries ----------
WIFI_CONNECTION_TIMEOUT=30
WIFI_MAX_RETRY_ATTEMPTS=3
WIFI_GOOD_REFRESH_INTERVAL=60
EOF
  chown "${PI_USER}:${PI_USER}" "$SETTINGS"
  log_info "Created default settings: $SETTINGS"
else
  log_info "settings.conf already present; leaving as-is"
fi

# ------------------------- ssid.conf ------------------------------
SSID_CONF="${DASHBOARD_DIR}/configs/ssid.conf"
if [[ ! -s "$SSID_CONF" ]]; then
  cat > "$SSID_CONF" <<EOF
TestSSID
TestPassword
EOF
  chmod 600 "$SSID_CONF"
  chown "${PI_USER}:${PI_USER}" "$SSID_CONF"
  log_info "Created placeholder Wi-Fi config: $SSID_CONF"
else
  log_info "ssid.conf already present; leaving as-is"
fi

# --------------------- Initialize log files -----------------------
log_info "Initializing log files..."
declare -a LOG_FILES=(
  "main.log"
  "wired.log"
  "wifi-good.log"
  "wifi-bad.log"
  "traffic-eth0.log"
)

for lf in "${LOG_FILES[@]}"; do
  log_path="${DASHBOARD_DIR}/logs/${lf}"
  # Create if missing; always append the install banner once
  touch "$log_path"
  echo "[$(date '+%F %T')] Install/upgrade to ${VERSION}" >> "$log_path"
  chmod 664 "$log_path"
  chown "${PI_USER}:${PI_USER}" "$log_path"
done

# ------------------ Final ownership & perms -----------------------
chown -R "${PI_USER}:${PI_USER}" "${DASHBOARD_DIR}"

log_info "✓ Directory structure and configuration completed"
