#!/usr/bin/env bash
# scripts/install/05-templates.sh
# Install web interface templates from the source checkout.

set -euo pipefail

: "${PI_USER:=pi}"
: "${PI_HOME:=/home/${PI_USER}}"
: "${SRC_DIR:?SRC_DIR must point at the repository checkout}"

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }

TEMPLATE_DIR="$PI_HOME/wifi_test_dashboard/templates"
mkdir -p "$TEMPLATE_DIR"

log_info "Installing web interface templates..."

install -m 644 "$SRC_DIR/templates/dashboard.html" "$TEMPLATE_DIR/dashboard.html"
install -m 644 "$SRC_DIR/templates/traffic_control.html" "$TEMPLATE_DIR/traffic_control.html"

chown -R "$PI_USER:$PI_USER" "$TEMPLATE_DIR"

log_info "✓ Templates installed"
