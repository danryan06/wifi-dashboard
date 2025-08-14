#!/usr/bin/env bash
# scripts/install/06-traffic-scripts.sh
# Download and install traffic generation scripts

set -euo pipefail

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }

log_info "Installing traffic generation scripts..."

# Create scripts directory
mkdir -p "$PI_HOME/wifi_test_dashboard/scripts"

# Download main traffic generator
log_info "Installing main traffic generator..."
if curl -sSL --max-time 30 --retry 3 "${REPO_URL}/scripts/traffic/interface_traffic_generator.sh" -o "$PI_HOME/wifi_test_dashboard/scripts/interface_traffic_generator.sh"; then
    log_info "✓ Downloaded interface_traffic_generator.sh"
else
    log_warn "✗ Failed to download interface_traffic_generator.sh, using existing version..."
fi

# Download wired simulation script
log_info "Installing wired simulation script..."
if curl -sSL --max-time 30 --retry 3 "${REPO_URL}/scripts/traffic/wired_simulation.sh" -o "$PI_HOME/wifi_test_dashboard/scripts/wired_simulation.sh"; then
    log_info "✓ Downloaded wired_simulation.sh"
else
    log_warn "✗ Failed to download wired_simulation.sh, creating basic fallback..."
    
    # Create basic fallback wired simulation script
    cat > "$PI_HOME/wifi_test_dashboard/scripts/wired_simulation.sh" << 'WIRED_FALLBACK_EOF'
#!/usr/bin/env bash
# Basic wired client simulation fallback

INTERFACE="eth0"
LOG_FILE="$HOME/wifi_test_dashboard/logs/wired.log"

log_msg() {
    echo "[$(date '+%F %T')] WIRED: $1" | tee -a "$LOG_FILE"
}

# Main loop
while true; do
    if ip link show "$INTERFACE" >/dev/null 2>&1; then
        # Simple connectivity test
        if ping -I "$INTERFACE" -c 3 8.8.8.8 >/dev/null 2>&1; then
            log_msg "✓ Ethernet connectivity OK"
        else
            log_msg "✗ Ethernet connectivity failed"
        fi
    else
        log_msg "✗ Interface $INTERFACE not found"
    fi
    sleep 30
done
WIRED_FALLBACK_EOF
fi

# Download Wi-Fi good client script
log_info "Installing Wi-Fi good client script..."
if curl -sSL --max-time 30 --retry 3 "${REPO_URL}/scripts/traffic/connect_and_curl.sh" -o "$PI_HOME/wifi_test_dashboard/scripts/connect_and_curl.sh"; then
    log_info "✓ Downloaded connect_and_curl.sh"
else
    log_warn "✗ Failed to download connect_and_curl.sh, creating basic fallback..."
    
    # Create basic fallback Wi-Fi good client script
    cat > "$PI_HOME/wifi_test_dashboard/scripts/connect_and_curl.sh" << 'WIFI_GOOD_FALLBACK_EOF'
#!/usr/bin/env bash
# Basic Wi-Fi good client simulation fallback

INTERFACE="wlan0"
LOG_FILE="$HOME/wifi_test_dashboard/logs/wifi-good.log"
CONFIG_FILE="$HOME/wifi_test_dashboard/configs/ssid.conf"

log_msg() {
    echo "[$(date '+%F %T')] WIFI-GOOD: $1" | tee -a "$LOG_FILE"
}

# Read config
read_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        SSID=$(head -n 1 "$CONFIG_FILE")
        PASSWORD=$(sed -n '2p' "$CONFIG_FILE")
        log_msg "Config loaded: SSID=$SSID"
    else
        log_msg "✗ Config file not found"
        return 1
    fi
}

# Main loop
while true; do
    if read_config; then
        # Simple Wi-Fi test
        if nmcli device wifi list | grep -q "$SSID"; then
            log_msg "✓ Target SSID visible: $SSID"
        else
            log_msg "⚠ Target SSID not visible: $SSID"
        fi
    fi
    sleep 60
done
WIFI_GOOD_FALLBACK_EOF
fi

# Download Wi-Fi bad client script
log_info "Installing Wi-Fi bad client script..."
if curl -sSL --max-time 30 --retry 3 "${REPO_URL}/scripts/traffic/fail_auth_loop.sh" -o "$PI_HOME/wifi_test_dashboard/scripts/fail_auth_loop.sh"; then
    log_info "✓ Downloaded fail_auth_loop.sh"
else
    log_warn "✗ Failed to download fail_auth_loop.sh, creating basic fallback..."
    
    # Create basic fallback Wi-Fi bad client script
    cat > "$PI_HOME/wifi_test_dashboard/scripts/fail_auth_loop.sh" << 'WIFI_BAD_FALLBACK_EOF'
#!/usr/bin/env bash
# Basic Wi-Fi bad client simulation fallback

INTERFACE="wlan1"
LOG_FILE="$HOME/wifi_test_dashboard/logs/wifi-bad.log"
CONFIG_FILE="$HOME/wifi_test_dashboard/configs/ssid.conf"

log_msg() {
    echo "[$(date '+%F %T')] WIFI-BAD: $1" | tee -a "$LOG_FILE"
}

# Read config for SSID only
read_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        SSID=$(head -n 1 "$CONFIG_FILE")
        log_msg "Target SSID: $SSID"
    else
        log_msg "✗ Config file not found"
        SSID="TestNetwork"
    fi
}

# Main loop
while true; do
    read_config
    log_msg "Simulating authentication failure for: $SSID"
    
    # Create temporary bad connection attempt
    local bad_connection="wifi-bad-test-$$"
    if nmcli connection add type wifi con-name "$bad_connection" ifname "$INTERFACE" ssid "$SSID" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "wrongpassword" >/dev/null 2>&1; then
        # Attempt connection (should fail)
        if timeout 20 nmcli connection up "$bad_connection" >/dev/null 2>&1; then
            log_msg "🚨 Unexpected success with wrong password!"
        else
            log_msg "✓ Authentication failed as expected"
        fi
        nmcli connection delete "$bad_connection" >/dev/null 2>&1
    fi
    
    sleep 45
done
WIFI_BAD_FALLBACK_EOF
fi

# Download diagnostic and utility scripts
log_info "Installing utility scripts..."

# Download diagnostic script
if curl -sSL --max-time 30 --retry 3 "${REPO_URL}/scripts/diagnose-dashboard.sh" -o "$PI_HOME/wifi_test_dashboard/scripts/diagnose-dashboard.sh"; then
    log_info "✓ Downloaded diagnose-dashboard.sh"
else
    log_warn "✗ Failed to download diagnostic script"
fi

# Download fix script
if curl -sSL --max-time 30 --retry 3 "${REPO_URL}/scripts/fix-services.sh" -o "$PI_HOME/wifi_test_dashboard/scripts/fix-services.sh"; then
    log_info "✓ Downloaded fix-services.sh"
else
    log_warn "✗ Failed to download fix script"
fi

# Make scripts executable and fix line endings
find "$PI_HOME/wifi_test_dashboard/scripts" -name "*.sh" -exec chmod +x {} \;
find "$PI_HOME/wifi_test_dashboard/scripts" -name "*.sh" -exec dos2unix {} \; 2>/dev/null || true

# Set proper ownership
chown -R "$PI_USER:$PI_USER" "$PI_HOME/wifi_test_dashboard/scripts"

# Verify critical scripts exist
log_info "Verifying traffic generation scripts..."

CRITICAL_SCRIPTS=(
    "$PI_HOME/wifi_test_dashboard/scripts/interface_traffic_generator.sh"
    "$PI_HOME/wifi_test_dashboard/scripts/wired_simulation.sh"
    "$PI_HOME/wifi_test_dashboard/scripts/connect_and_curl.sh"
    "$PI_HOME/wifi_test_dashboard/scripts/fail_auth_loop.sh"
)

missing_scripts=0
for script in "${CRITICAL_SCRIPTS[@]}"; do
    if [[ -f "$script" && -x "$script" ]]; then
        log_info "✓ $(basename "$script") ready"
    else
        log_warn "✗ $(basename "$script") missing or not executable"
        ((missing_scripts++))
    fi
done

if [[ $missing_scripts -eq 0 ]]; then
    log_info "✓ All traffic generation scripts installed successfully"
else
    log_warn "⚠ $missing_scripts script(s) missing - services may not work correctly"
    log_warn "You can run the fix script later: sudo bash $PI_HOME/wifi_test_dashboard/scripts/fix-services.sh"
fi

# Test script syntax if possible
log_info "Testing script syntax..."
for script in "${CRITICAL_SCRIPTS[@]}"; do
    if [[ -f "$script" ]]; then
        if bash -n "$script" 2>/dev/null; then
            log_info "✓ $(basename "$script") syntax OK"
        else
            log_warn "⚠ $(basename "$script") syntax error detected"
        fi
    fi
done

log_info "✓ Traffic generation scripts installation completed"