#!/usr/bin/env bash
# 08-finalize.sh - Finalize Wi-Fi Dashboard install with enhanced hostname verification
set -euo pipefail

# ---- Defaults for required env vars (safe under set -u) ----
: "${PI_USER:=pi}"
: "${PI_HOME:=/home/${PI_USER}}"
: "${VERSION:=v5.1.0}"     # fallback if the orchestrator didn't set VERSION

# Ensure common admin tools exist in PATH even under non-interactive shells
export PATH="/usr/sbin:/sbin:/usr/bin:/bin:/usr/local/bin"

log_info()  { echo -e "\033[0;32m[INFO]\033[0m $1"; }
log_warn()  { echo -e "\033[1;33m[WARN]\033[0m $1"; }
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

# Make all repo scripts executable (ignore if no files yet)
find "${DASHBOARD_DIR}/scripts" -type f -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

# Reload units in case prior steps wrote/changed them
systemctl daemon-reload

# -----------------------------------------------------------------------------
# System hostname setup
# -----------------------------------------------------------------------------
setup_system_hostname() {
    local system_hostname="CNXNMist-Dashboard"
    log_info "Setting up system hostname: $system_hostname"

    local current_hostname
    current_hostname=$(hostname)

    if [[ "$current_hostname" == "localhost" ]] || [[ "$current_hostname" == "raspberrypi" ]] || [[ "$current_hostname" == "raspberry" ]]; then
        if command -v hostnamectl >/dev/null 2>&1; then
            hostnamectl set-hostname "$system_hostname" 2>/dev/null && \
                log_info "✓ System hostname set: $system_hostname" || \
                log_warn "Failed to set system hostname"
        fi

        echo "$system_hostname" > /etc/hostname && \
            log_info "✓ Updated /etc/hostname" || \
            log_warn "Failed to update /etc/hostname"

        cp /etc/hosts /etc/hosts.backup.$(date +%s) 2>/dev/null || true
        sed -i '/^127\.0\.1\.1/d' /etc/hosts 2>/dev/null || true
        echo "127.0.1.1    $system_hostname" >> /etc/hosts

        log_info "✓ System hostname configured for dashboard services"
        log_info "✓ Services will use DHCP hostnames: CNXNMist-WiFiGood, CNXNMist-WiFiBad"
    else
        log_info "System hostname already customized ($current_hostname), not changing"
    fi
}

# -----------------------------------------------------------------------------
# Hostname separation verification
# -----------------------------------------------------------------------------
verify_hostname_separation() {
    local max_attempts=10
    local attempt=1

    log_info "🔍 Starting hostname separation verification..."

    while [[ $attempt -le $max_attempts ]]; do
        log_info "Verification attempt $attempt/$max_attempts..."
        sleep 5

        local wlan0_file="${DASHBOARD_DIR}/identity_wlan0.json"
        local wlan1_file="${DASHBOARD_DIR}/identity_wlan1.json"

        local wlan0_hostname="unknown"
        local wlan1_hostname="unknown"
        local wlan0_expected="unknown"
        local wlan1_expected="unknown"

        if [[ -f "$wlan0_file" ]]; then
            wlan0_hostname=$(jq -r '.hostname // "unknown"' "$wlan0_file" 2>/dev/null || echo "unknown")
            wlan0_expected=$(jq -r '.expected_hostname // "unknown"' "$wlan0_file" 2>/dev/null || echo "unknown")
            log_info "wlan0 identity: expected='$wlan0_expected', actual='$wlan0_hostname'"
        else
            log_warn "wlan0 identity file not found yet"
        fi

        if [[ -f "$wlan1_file" ]]; then
            wlan1_hostname=$(jq -r '.hostname // "unknown"' "$wlan1_file" 2>/dev/null || echo "unknown")
            wlan1_expected=$(jq -r '.expected_hostname // "unknown"' "$wlan1_file" 2>/dev/null || echo "unknown")
            log_info "wlan1 identity: expected='$wlan1_expected', actual='$wlan1_hostname'"
        else
            log_warn "wlan1 identity file not found yet"
        fi

        local verification_passed=false
        if [[ "$wlan0_hostname" == "CNXNMist-WiFiGood" && "$wlan1_hostname" == "CNXNMist-WiFiBad" ]]; then
            verification_passed=true
        elif [[ "$wlan0_hostname" != "unknown" && "$wlan1_hostname" != "unknown" && "$wlan0_hostname" != "$wlan1_hostname" ]]; then
            log_warn "Hostnames are different but not standard: wlan0='$wlan0_hostname', wlan1='$wlan1_hostname'"
            verification_passed=true
        fi

        if [[ "$verification_passed" == "true" ]]; then
            log_info "✅ Hostname separation verified successfully!"
            log_info "   wlan0: $wlan0_hostname"
            log_info "   wlan1: $wlan1_hostname"
            return 0
        fi

        log_warn "⏳ Hostname separation not yet established"
        log_info "Service status: wifi-good=$(systemctl is-active wifi-good.service 2>/dev/null || echo inactive), wifi-bad=$(systemctl is-active wifi-bad.service 2>/dev/null || echo inactive)"
        sleep 15
        ((attempt++))
    done

    log_warn "⚠ Hostname separation verification could not be confirmed (likely no Wi-Fi config yet)"
    log_warn "   Run check_status.sh after configuring Wi-Fi to verify identities"
    return 0
}

# -----------------------------------------------------------------------------
# Enhanced service startup
# -----------------------------------------------------------------------------
start_services_with_verification() {
    log_info "Starting services with staggered timing and verification..."

    log_info "Starting dashboard service..."
    systemctl start wifi-dashboard.service 2>/dev/null || true
    sleep 2

    log_info "Starting wired test service..."
    systemctl start wired-test.service 2>/dev/null || true
    sleep 2

    log_info "Starting Wi-Fi services..."
    systemctl start wifi-bad.service 2>/dev/null || true
    sleep 10
    systemctl start wifi-good.service 2>/dev/null || true
    sleep 10

    # Only verify if Wi-Fi config exists
    config_file="${DASHBOARD_DIR}/configs/ssid.conf"
    if [[ -s "$config_file" ]]; then
        log_info "🔍 Wi-Fi configuration detected, verifying hostname separation..."
        verify_hostname_separation
    else
        log_warn "⚠ No Wi-Fi config found yet, skipping hostname separation verification"
        log_warn "   Run check_status.sh after configuring Wi-Fi to confirm separation"
    fi
}

# -----------------------------------------------------------------------------
# MAIN EXECUTION
# -----------------------------------------------------------------------------
setup_system_hostname

# Write check_status.sh
cat > "${DASHBOARD_DIR}/scripts/check_status.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/sbin:/sbin:/usr/bin:/bin:/usr/local/bin"

DASHBOARD_DIR="/home/pi/wifi_test_dashboard"
CONFIG_FILE="${DASHBOARD_DIR}/configs/ssid.conf"

echo "=== Wi-Fi Dashboard System Status ==="
echo

# --- Service Status ---
echo "--- Service Status ---"
for service in wifi-dashboard wired-test wifi-good wifi-bad; do
  if systemctl list-unit-files | grep -q "^${service}\.service"; then
    status=$(systemctl is-active "${service}.service" 2>/dev/null || echo "inactive")
    enabled=$(systemctl is-enabled "${service}.service" 2>/dev/null || echo "disabled")
    echo "  - ${service}: ${status} (${enabled})"
  fi
done
echo

# --- Hostname Verification ---
echo "--- Hostname Verification ---"

ssid_configured=false
if [[ -f "$CONFIG_FILE" ]] && [[ -s "$CONFIG_FILE" ]]; then
  ssid_configured=true
fi

for iface in wlan0 wlan1; do
  identity_file="${DASHBOARD_DIR}/identity_${iface}.json"
  if [[ -f "$identity_file" ]]; then
    echo "  $iface identity:"
    if command -v jq >/dev/null 2>&1; then
      expected=$(jq -r '.expected_hostname // "unknown"' "$identity_file" 2>/dev/null)
      actual=$(jq -r '.hostname // "unknown"' "$identity_file" 2>/dev/null)
      echo "    Expected: $expected"
      echo "    Actual: $actual"

      if $ssid_configured; then
        if [[ "$expected" == "$actual" ]]; then
          echo "    Status: ✅ MATCH"
        else
          echo "    Status: ❌ MISMATCH"
        fi
      else
        echo "    Status: ⚠ Skipped (SSID not configured yet)"
      fi
    else
      cat "$identity_file" | grep -E "(hostname|expected_hostname)" | sed 's/^/    /'
    fi
    echo
  else
    echo "  $iface: No identity file found"
  fi
done

# --- Network Interfaces ---
echo "--- Network Interfaces ---"
nmcli device status 2>/dev/null || echo "NetworkManager not available"
echo

# --- Wi-Fi Configuration ---
echo "--- Wi-Fi Configuration ---"
if [[ -f "$CONFIG_FILE" ]]; then
  if head -1 "$CONFIG_FILE" 2>/dev/null | grep -q .; then
    ssid=$(head -1 "$CONFIG_FILE")
    echo "  SSID configured: ${ssid}"
  else
    echo "  Wi-Fi config file is present but empty"
  fi
else
  echo "  Wi-Fi config file missing"
fi
echo

# --- Logs ---
echo "Logs:"
echo "  - Main:     ${DASHBOARD_DIR}/logs/main.log"
echo "  - Wired:    ${DASHBOARD_DIR}/logs/wired.log"
echo "  - Wi-Fi OK: ${DASHBOARD_DIR}/logs/wifi-good.log"
echo "  - Wi-Fi Bad:${DASHBOARD_DIR}/logs/wifi-bad.log"
EOF
chmod +x "${DASHBOARD_DIR}/scripts/check_status.sh"
chown "$PI_USER:$PI_USER" "${DASHBOARD_DIR}/scripts/check_status.sh"

# Start services
start_services_with_verification

# Final summary
host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
log_info "✓ Installation finalized successfully"
[[ -n "${host_ip:-}" ]] && log_info "✓ Dashboard accessible at: http://${host_ip}:5000"

# Reminder if Wi-Fi not configured
if [[ ! -s "${DASHBOARD_DIR}/configs/ssid.conf" ]]; then
    log_warn "⚠ Wi-Fi configuration not set yet"
    log_warn "   Open the dashboard, configure your SSID/PSK, then rerun check_status.sh"
fi

log_info "✓ Use ${DASHBOARD_DIR}/scripts/check_status.sh for troubleshooting"
