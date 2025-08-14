#!/usr/bin/env bash
# scripts/install/05-templates.sh
# Download and install web interface templates

set -euo pipefail

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }

log_info "Installing web interface templates..."

# Download templates
download_file "${REPO_URL}/templates/dashboard.html" "$PI_HOME/wifi_test_dashboard/templates/dashboard.html" "Dashboard template"
download_file "${REPO_URL}/templates/traffic_control.html" "$PI_HOME/wifi_test_dashboard/templates/traffic_control.html" "Traffic control template"

# Set proper ownership
chown -R "$PI_USER:$PI_USER" "$PI_HOME/wifi_test_dashboard/templates"

log_info "✓ Web interface templates installed"