#!/usr/bin/env bash
# 02-cleanup.sh - Simplified cleanup for Wi-Fi Dashboard fresh installs
set -euo pipefail

# ---- Defaults for required env vars ----
: "${PI_USER:=pi}"
: "${PI_HOME:=/home/${PI_USER}}"

# Logging helpers
log_info()  { echo -e "\033[0;32m[INFO]\033[0m $1"; }
log_warn()  { echo -e "\033[1;33m[WARN]\033[0m $1"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; }

log_info "Starting simplified cleanup for fresh installations..."
log_info "Target user: $PI_USER  |  Home: $PI_HOME"

# -----------------------------------------------------------------------------
# Function: stop and disable old services
# -----------------------------------------------------------------------------
cleanup_services() {
    local services=(
        wifi-dashboard
        wifi-good
        wifi-bad
        wired-test
        traffic-eth0
        traffic-wlan0
        traffic-wlan1
    )

    log_info "Stopping and removing existing dashboard services..."
    for service in "${services[@]}"; do
        systemctl stop "${service}.service" 2>/dev/null || true
        systemctl disable "${service}.service" 2>/dev/null || true
        rm -f "/etc/systemd/system/${service}.service"
    done

    systemctl daemon-reload
    log_info "✓ Dashboard services cleaned up"
}

# -----------------------------------------------------------------------------
# Function: clean old configs and locks
# -----------------------------------------------------------------------------
cleanup_configs() {
    log_info "Cleaning up NetworkManager connections..."
    if command -v nmcli >/dev/null 2>&1; then
        # Prevent grep from aborting when there are no matches
        nmcli connection show | grep -E "(CNXNMist|wifi-test|dashboard)" || true | \
        awk '{print $1}' | while read -r conn; do
            if [[ -n "$conn" ]]; then
                nmcli connection delete "$conn" 2>/dev/null || true
            fi
        done
    fi

    log_info "Removing old hostname/DHCP configs..."
    rm -f /etc/dhcp/dhclient-wlan*.conf       || true
    rm -f /etc/NetworkManager/conf.d/dhcp-hostname-*.conf || true
    rm -rf /var/run/wifi-dashboard            || true
}

# -----------------------------------------------------------------------------
# Function: backup old dashboard directories
# -----------------------------------------------------------------------------
backup_old_install() {
    if [[ -d "$PI_HOME/wifi_test_dashboard" ]]; then
        local backup_path="${PI_HOME}/wifi_test_dashboard.backup.$(date +%s)"
        log_warn "Existing dashboard directory found, backing up to $backup_path"
        mv "$PI_HOME/wifi_test_dashboard" "$backup_path"
    fi
}

# -----------------------------------------------------------------------------
# MAIN EXECUTION
# -----------------------------------------------------------------------------
cleanup_services
cleanup_configs
backup_old_install

log_info "✅ Cleanup complete. System ready for fresh installation."
