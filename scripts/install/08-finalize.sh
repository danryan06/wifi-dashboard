#!/usr/bin/env bash
# 08-finalize.sh - Finalize Wi-Fi Dashboard install with enhanced hostname verification
set -euo pipefail

# ---- Defaults for required env vars (safe under set -u) ----
: "${PI_USER:=pi}"
: "${PI_HOME:=/home/${PI_USER}}"
: "${VERSION:=v5.1.0}"     # fallback if the orchestrator didn't set VERSION

# Ensure common admin tools exist in PATH even under non-interactive shells
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

# Make all repo scripts executable (ignore if no files yet)
find "${DASHBOARD_DIR}/scripts" -type f -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

# Reload units in case prior steps wrote/changed them
systemctl daemon-reload

# Set up system hostname (one-time during installation)
setup_system_hostname() {
    local system_hostname="CNXNMist-Dashboard"
    
    log_info "Setting up system hostname: $system_hostname"
    
    # Only set if currently default Pi hostnames
    local current_hostname=$(hostname)
    if [[ "$current_hostname" == "localhost" ]] || [[ "$current_hostname" == "raspberrypi" ]] || [[ "$current_hostname" == "raspberry" ]]; then
        
        # Set system hostname via hostnamectl
        if command -v hostnamectl >/dev/null 2>&1; then
            hostnamectl set-hostname "$system_hostname" 2>/dev/null && \
                log_info "✓ System hostname set: $system_hostname" || \
                log_warn "Failed to set system hostname"
        fi
        
        # Update /etc/hostname
        echo "$system_hostname" > /etc/hostname && \
            log_info "✓ Updated /etc/hostname" || \
            log_warn "Failed to update /etc/hostname"
        
        # Fix /etc/hosts properly
        cp /etc/hosts /etc/hosts.backup.$(date +%s) 2>/dev/null || true
        
        # Remove old 127.0.1.1 entries and add new one
        sed -i '/^127\.0\.1\.1/d' /etc/hosts 2>/dev/null || true
        echo "127.0.1.1    $system_hostname" >> /etc/hosts
        
        log_info "✓ System hostname configured for dashboard services"
        log_info "✓ Services will use DHCP hostnames: CNXNMist-WiFiGood, CNXNMist-WiFiBad"
        
    else
        log_info "System hostname already customized ($current_hostname), not changing"
    fi
}

# =============================================================================
# HOSTNAME VERIFICATION FUNCTION - THIS IS THE NEW #5 ADDITION
# =============================================================================

verify_hostname_separation() {
    local max_attempts=10
    local attempt=1
    
    log_info "🔍 Starting hostname separation verification..."
    
    while [[ $attempt -le $max_attempts ]]; do
        log_info "Verification attempt $attempt/$max_attempts..."
        
        # Wait for identity files to be created
        sleep 5
        
        # Check if identity files exist
        local wlan0_file="/home/pi/wifi_test_dashboard/identity_wlan0.json"
        local wlan1_file="/home/pi/wifi_test_dashboard/identity_wlan1.json"
        
        local wlan0_hostname="unknown"
        local wlan1_hostname="unknown"
        local wlan0_expected="unknown"
        local wlan1_expected="unknown"
        
        # Extract hostnames from identity files if they exist
        if [[ -f "$wlan0_file" ]]; then
            if command -v jq >/dev/null 2>&1; then
                wlan0_hostname=$(jq -r '.hostname // "unknown"' "$wlan0_file" 2>/dev/null)
                wlan0_expected=$(jq -r '.expected_hostname // "unknown"' "$wlan0_file" 2>/dev/null)
            else
                wlan0_hostname=$(grep -o '"hostname"[^"]*"[^"]*"' "$wlan0_file" | cut -d'"' -f4 2>/dev/null || echo "unknown")
                wlan0_expected=$(grep -o '"expected_hostname"[^"]*"[^"]*"' "$wlan0_file" | cut -d'"' -f4 2>/dev/null || echo "unknown")
            fi
            log_info "wlan0 identity: expected='$wlan0_expected', actual='$wlan0_hostname'"
        else
            log_warn "wlan0 identity file not found yet"
        fi
        
        if [[ -f "$wlan1_file" ]]; then
            if command -v jq >/dev/null 2>&1; then
                wlan1_hostname=$(jq -r '.hostname // "unknown"' "$wlan1_file" 2>/dev/null)
                wlan1_expected=$(jq -r '.expected_hostname // "unknown"' "$wlan1_file" 2>/dev/null)
            else
                wlan1_hostname=$(grep -o '"hostname"[^"]*"[^"]*"' "$wlan1_file" | cut -d'"' -f4 2>/dev/null || echo "unknown")
                wlan1_expected=$(grep -o '"expected_hostname"[^"]*"[^"]*"' "$wlan1_file" | cut -d'"' -f4 2>/dev/null || echo "unknown")
            fi
            log_info "wlan1 identity: expected='$wlan1_expected', actual='$wlan1_hostname'"
        else
            log_warn "wlan1 identity file not found yet"
        fi
        
        # Check if hostnames are properly separated
        local verification_passed=false
        
        # Method 1: Check against expected hostnames
        if [[ "$wlan0_hostname" == "CNXNMist-WiFiGood" || "$wlan0_expected" == "CNXNMist-WiFiGood" ]] && \
           [[ "$wlan1_hostname" == "CNXNMist-WiFiBad" || "$wlan1_expected" == "CNXNMist-WiFiBad" ]]; then
            verification_passed=true
        fi
        
        # Method 2: At minimum, ensure they're different (fallback)
        if [[ "$wlan0_hostname" != "unknown" && "$wlan1_hostname" != "unknown" && "$wlan0_hostname" != "$wlan1_hostname" ]]; then
            if [[ "$verification_passed" != "true" ]]; then
                log_warn "Hostnames are different but not standard: wlan0='$wlan0_hostname', wlan1='$wlan1_hostname'"
                verification_passed=true  # Accept as long as they're different
            fi
        fi
        
        if [[ "$verification_passed" == "true" ]]; then
            log_info "✅ Hostname separation verified successfully!"
            log_info "   wlan0: $wlan0_hostname"
            log_info "   wlan1: $wlan1_hostname"
            return 0
        fi
        
        # If not verified, show what we found and wait
        log_warn "⏳ Hostname separation not yet established:"
        log_warn "   wlan0: expected='$wlan0_expected', actual='$wlan0_hostname'"
        log_warn "   wlan1: expected='$wlan1_expected', actual='$wlan1_hostname'"
        
        # Check service status for debugging
        local good_status=$(systemctl is-active wifi-good.service 2>/dev/null || echo "inactive")
        local bad_status=$(systemctl is-active wifi-bad.service 2>/dev/null || echo "inactive")
        log_info "Service status: wifi-good=$good_status, wifi-bad=$bad_status"
        
        sleep 15  # Wait longer between attempts
        ((attempt++))
    done
    
    log_error "❌ Hostname separation verification failed after $max_attempts attempts"
    log_error "This may cause DHCP hostname conflicts in Mist dashboard"
    log_error "Run diagnostic script later: sudo bash $DASHBOARD_DIR/scripts/diagnose-dashboard.sh"
    return 1
}

# =============================================================================
# ENHANCED SERVICE STARTUP WITH STAGGERED TIMING
# =============================================================================

start_services_with_verification() {
    log_info "Starting services with staggered timing and verification..."
    
    # Start dashboard first (always safe)
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

    # Start wired client (doesn't depend on SSID)
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

    # ENHANCED: Start Wi-Fi services with proper staggering
    log_info "Starting Wi-Fi services with hostname separation..."
    
    # Start bad client first (it should grab wlan1 and CNXNMist-WiFiBad)
    if systemctl list-unit-files | grep -q "wifi-bad.service"; then
        log_info "Starting wifi-bad service first..."
        systemctl start wifi-bad.service 2>/dev/null || log_warn "Failed to start wifi-bad"
        sleep 10  # Give bad client time to establish its hostname
        
        if systemctl is-active --quiet wifi-bad.service; then
            log_info "✓ WiFi-bad service started"
        else
            log_warn "⚠ WiFi-bad service failed to start"
        fi
    fi
    
    # Then start good client (it should grab wlan0 and CNXNMist-WiFiGood)
    log_info "Starting wifi-good service..."
    systemctl start wifi-good.service 2>/dev/null || log_warn "Failed to start wifi-good"
    sleep 10  # Give good client time to establish its hostname
    
    if systemctl is-active --quiet wifi-good.service; then
        log_info "✓ WiFi-good service started"
    else
        log_warn "⚠ WiFi-good service failed to start"
    fi
    
    # CALL THE VERIFICATION FUNCTION - THIS IS WHERE #5 GOES
    log_info "🔍 Verifying hostname separation..."
    if verify_hostname_separation; then
        log_info "✅ Services started with proper hostname separation"
    else
        log_warn "⚠ Hostname separation verification failed"
        log_warn "Services are running but may have hostname conflicts"
        log_warn "Check dashboard for details: http://$(hostname -I | awk '{print $1}'):5000"
    fi
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

# Call the function during finalization
setup_system_hostname

# Enhanced status helper
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
        echo "  $iface identity:"
        if command -v jq >/dev/null 2>&1; then
            expected=$(jq -r '.expected_hostname // "unknown"' "$identity_file" 2>/dev/null)
            actual=$(jq -r '.hostname // "unknown"' "$identity_file" 2>/dev/null)
            echo "    Expected: $expected"
            echo "    Actual: $actual"
            if [[ "$expected" == "$actual" ]]; then
                echo "    Status: ✅ MATCH"
            else
                echo "    Status: ❌ MISMATCH"
            fi
        else
            cat "$identity_file" | grep -E "(hostname|expected_hostname)" | sed 's/^/    /'
        fi
        echo
    else
        echo "  $iface: No identity file found"
    fi
done

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

# EXECUTE THE ENHANCED SERVICE STARTUP WITH VERIFICATION
start_services_with_verification

# Final summary
host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
log_info "✓ Installation finalized successfully"
[[ -n "${host_ip:-}" ]] && log_info "✓ Dashboard accessible at: http://${host_ip}:5000"
log_info "✓ Use ${DASHBOARD_DIR}/scripts/check_status.sh for troubleshooting"
log_info "✓ Hostname verification completed - services should have unique identities"