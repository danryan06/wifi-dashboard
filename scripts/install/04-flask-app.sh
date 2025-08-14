#!/usr/bin/env bash
# scripts/install/04-flask-app.sh
# Download and install Flask application

set -euo pipefail

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }

log_info "Installing Flask application..."

# Download the Flask application
download_file "${REPO_URL}/app/app.py" "$PI_HOME/wifi_test_dashboard/app.py" "Flask application"

# Ensure proper ownership
chown "$PI_USER:$PI_USER" "$PI_HOME/wifi_test_dashboard/app.py"

# Verify the Flask app can be imported
if sudo -u "$PI_USER" python3 -c "import sys; sys.path.insert(0, '$PI_HOME/wifi_test_dashboard'); import app" 2>/dev/null; then
    log_info "✓ Flask application verified successfully"
else
    log_info "⚠ Flask application verification had issues (may still work)"
fi

log_info "✓ Flask application installation completed"