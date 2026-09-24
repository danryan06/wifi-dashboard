#!/usr/bin/env bash
# scripts/install/04-flask-app.sh
# Install the Flask application from the source checkout.

set -euo pipefail

: "${PI_USER:=pi}"
: "${PI_HOME:=/home/${PI_USER}}"
: "${SRC_DIR:?SRC_DIR must point at the repository checkout}"

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }

log_info "Installing Flask application..."

install -m 644 "$SRC_DIR/app/app.py" "$PI_HOME/wifi_test_dashboard/app.py"
chown "$PI_USER:$PI_USER" "$PI_HOME/wifi_test_dashboard/app.py"
log_info "✓ Installed Flask application"

# Verify the Flask app can be imported
if sudo -u "$PI_USER" python3 -c "import sys; sys.path.insert(0, '$PI_HOME/wifi_test_dashboard'); import app" 2>/dev/null; then
    log_info "✓ Flask application verified successfully"
else
    log_info "⚠ Flask application verification had issues (may still work)"
fi

log_info "✓ Flask application installation completed"
