#!/usr/bin/env bash
# 08-finalize.sh - Finalize Wi-Fi Dashboard install (clean version without early hostname checks)
set -euo pipefail

# ---- Defaults for required env vars ----
: "${PI_USER:=pi}"
: "${PI_HOME:=/home/${PI_USER}}"
: "${VERSION:=v5.1.0}"

export PATH="/usr/sbin:/sbin:/usr/bin:/bin:/usr/local/bin"

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; }

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

# Make all repo scripts executable
find "${DASHBOARD_DIR}/scripts" -type f -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

# Reload systemd units
systemctl daemon-reload

# Set system hostname (one-time)
setup_system_hostname() {
    local system_hostname="CNXNMist-Dashboard"
    local current_hostname
    current_hostname=$(hostname)

    if [[ "$current_hostname" == "localhost" || "$current_hostname" == "raspberrypi" || "$current_hostname" == "raspberry" ]]; then
        log_info "Setting system hostname to $system_hostname"

        if command -v hostnamectl >/dev/null 2>&1; then
            hostnamectl set-hostname "$system_hostname" || log_warn "Failed to set hostname via hostnamectl"
        fi

        echo "$system_hostname" > /etc/hostname || log_warn "Failed to update /etc/hostname"
        cp /etc/hosts /etc/hosts.backup.$(date +%s) 2>/dev/null || true
        sed -i '/^127\.0\.1\.1/d' /etc/hosts 2>/dev/null || true
        echo "127.0.1.1    $system_hostname" >> /etc/hosts

        log_info "✓ System hostname configured"
    else
        log_info "System hostname already set ($current_hostname), leaving as-is"
    fi
}

setup_system_hostname

# Create check_status.sh helper
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
echo "--- Hostname Verification ---"
for iface in wlan0 wlan1; do
    identity_file="/home/pi/wifi_test_dashboard/identity_${iface}.json"
    if [[ -f "$identity_file" ]]; then
        if command -v jq >/dev/null 2>&1; then
            expected=$(jq -r '.expected_hostname // "unknown"' "$identity_file" 2>/dev/null)
            actual=$(jq -r '.hostname // "unknown"' "$identity_file" 2>/dev/null)
            echo "  $iface -> expected: $expected | actual: $actual"
        else
            cat "$identity_file" | grep -E "(hostname|expected_hostname)" | sed 's/^/    /'
        fi
        echo
    else
        echo "  $iface: No identity file yet"
    fi
done

echo "--- Network Interfaces ---"
nmcli device status 2>/dev/null || echo "NetworkManager not available"
echo
EOF
chmod +x "${DASHBOARD_DIR}/scripts/check_status.sh"
chown "$PI_USER:$PI_USER" "${DASHBOARD_DIR}/scripts/check_status.sh"

# Start only safe services
log_info "Starting dashboard service..."
systemctl start wifi-dashboard.service || log_warn "Failed to start wifi-dashboard"
log_info "Starting wired test service..."
systemctl start wired-test.service || log_warn "Failed to start wired-test"

# Skip Wi-Fi until SSID is configured
log_info "Skipping Wi-Fi client startup until SSID is configured"
log_info "Hostname verification will run after Wi-Fi config is saved"

# Final summary
host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
log_info "✓ Installation finalized successfully"
[[ -n "${host_ip:-}" ]] && log_info "✓ Dashboard available at: http://${host_ip}:5000"
log_info "✓ Use check_status.sh or verify-hostnames.sh after Wi-Fi config to confirm identities"
