#!/usr/bin/env bash
# scripts/install/06-traffic-scripts.sh
# Download and install traffic generation scripts

set -euo pipefail

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }

log_info "Installing traffic generation scripts..."

# Create scripts directory
mkdir -p "$PI_HOME/wifi_test_dashboard/scripts"

# Download traffic generation scripts
download_file "${REPO_URL}/scripts/traffic/interface_traffic_generator.sh" "$PI_HOME/wifi_test_dashboard/scripts/interface_traffic_generator.sh" "Main traffic generator"
download_file "${REPO_URL}/scripts/traffic/wired_simulation.sh" "$PI_HOME/wifi_test_dashboard/scripts/wired_simulation.sh" "Wired simulation script"
download_file "${REPO_URL}/scripts/traffic/wifi_good_client.sh" "$PI_HOME/wifi_test_dashboard/scripts/connect_and_curl.sh" "Wi-Fi good client script"
download_file "${REPO_URL}/scripts/traffic/wifi_bad_client.sh" "$PI_HOME/wifi_test_dashboard/scripts/fail_auth_loop.sh" "Wi-Fi bad client script"

# Make scripts executable and fix line endings
chmod +x "$PI_HOME/wifi_test_dashboard/scripts"/*.sh
dos2unix "$PI_HOME/wifi_test_dashboard/scripts"/*.sh 2>/dev/null || true

# Set proper ownership
chown -R "$PI_USER:$PI_USER" "$PI_HOME/wifi_test_dashboard/scripts"

log_info "✓ Traffic generation scripts installed"