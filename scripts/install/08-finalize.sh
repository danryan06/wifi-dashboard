#!/usr/bin/env bash
# 08-finalize.sh - Finalize Wi-Fi Dashboard install (robust, safe under set -u)
set -euo pipefail

# ---- Defaults for required env vars (safe under set -u) ----
: "${PI_USER:=pi}"
: "${PI_HOME:=/home/${PI_USER}}"
: "${VERSION:=v5.0.2}"     # fallback if the orchestrator didn't set VERSION

# Ensure common admin tools exist in PATH even under non-interactive shells
export PATH="/usr/sbin:/sbin:/usr/bin:/bin:/usr/local/bin"

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }

log_info "Finalizing installation..."

DASHBOARD_DIR="${PI_HOME}/wifi_test_dashboard"
LOG_DIR="${DASHBOARD_DIR}/logs"
CONFIGS_DIR="${DASHBOARD_DIR}/configs"

# Create dirs (idempotent) and set ownership
mkdir -p "$LOG_DIR" "$CONFIGS_DIR" "${DASHBOARD_DIR}/scripts"
chown -R "$PI_USER:$PI_USER" "$DASHBOARD_DIR"

# Write install banner to main log
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Install/upgrade to ${VERSION}" >> "${LOG_DIR}/main.log"
chown "$PI_USER:$PI_USER" "${LOG_DIR}/main.log"

# Make all repo scripts executable (ignore if no files yet)
find "${DASHBOARD_DIR}/scripts" -type f -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

# Reload units in case prior steps wrote/changed them
systemctl daemon-reload

# --- Start dashboard first (always safe) ---
log_info "Starting dashboard service..."
if systemctl start wifi-dashboard.service 2>/dev/null; then
  sleep 2
  if systemctl is-active --quiet wifi-dashboard.service; then
    log_info "✓ Dashboard service started successfully"
  else
    log_warn "⚠ Dashboard service not running"
  fi
else
  log_warn "⚠ Failed to start wifi-dashboard.service"
fi

# --- Start wired client (doesn't depend on SSID) ---
log_info "Starting wired test service..."
if systemctl start wired-test.service 2>/dev/null; then
  sleep 2
  if systemctl is-active --quiet wired-test.service; then
    log_info "✓ Wired test service started successfully"
  else
    log_warn "⚠ Wired test service not running"
  fi
else
  log_warn "⚠ Failed to start wired-test.service"
fi

# --- Wi-Fi services policy ---
# Leave Wi-Fi (good/bad) to auto-start after UI config is saved.
log_info "Wi-Fi services will start automatically when configuration is complete"
log_info "Configure Wi-Fi in the dashboard; services will connect afterwards"

# --- Convenience status helper ---
cat > "${DASHBOARD_DIR}/scripts/check_status.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/sbin:/sbin:/usr/bin:/bin:/usr/local/bin"

echo "=== Wi-Fi Dashboard System Status ==="
echo
echo "--- Service Status ---"
for service in wifi-dashboard wired-test wifi-good wifi-bad; do
  if systemctl list-unit-files | grep -q "^${service}\.service"; then
    status=$(systemctl is-active "${service}.service" 2>/dev/null || echo "inactive")
    enabled=$(systemctl is-enabled "${service}.service" 2>/dev/null || echo "disabled")
    echo "  - ${service}: ${status} (${enabled})"
  fi
done
echo
echo "--- Network Interfaces ---"
nmcli device status 2>/dev/null || echo "NetworkManager not available"
echo
echo "--- Wi-Fi Configuration ---"
config_file="/home/pi/wifi_test_dashboard/configs/ssid.conf"
if [[ -f "$config_file" ]]; then
  if head -1 "$config_file" 2>/dev/null | grep -q .; then
    ssid=$(head -1 "$config_file")
    echo "  SSID configured: ${ssid}"
  else
    echo "  Wi-Fi config file is present but empty"
  fi
else
  echo "  Wi-Fi config file missing"
fi
echo
echo "Logs:"
echo "  - Main:     /home/pi/wifi_test_dashboard/logs/main.log"
echo "  - Wired:    /home/pi/wifi_test_dashboard/logs/wired.log"
echo "  - Wi-Fi OK: /home/pi/wifi_test_dashboard/logs/wifi-good.log"
echo "  - Wi-Fi Bad:/home/pi/wifi_test_dashboard/logs/wifi-bad.log"
EOF
chmod +x "${DASHBOARD_DIR}/scripts/check_status.sh"
chown "$PI_USER:$PI_USER" "${DASHBOARD_DIR}/scripts/check_status.sh"

# --- Friendly summary ---
host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
log_info "✓ Installation finalized successfully"
[[ -n "${host_ip:-}" ]] && log_info "✓ Dashboard accessible at: http://${host_ip}:5000"
log_info "✓ Use ${DASHBOARD_DIR}/scripts/check_status.sh for troubleshooting"
