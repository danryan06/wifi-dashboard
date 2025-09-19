#!/usr/bin/env bash
# 02-cleanup-simple.sh — Simplified cleanup avoiding complex quoting issues

set -euo pipefail

# Logging helpers
log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
log_error(){ echo -e "\033[0;31m[ERROR]\033[0m $1"; }

# Require root
if [[ $EUID -ne 0 ]]; then
  log_error "Please run as root (use sudo)"; exit 1
fi

# User detection
TARGET_USER="${PI_USER:-${SUDO_USER:-$(id -un)}}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
[[ -z "${TARGET_HOME:-}" ]] && TARGET_HOME="/home/$TARGET_USER"
PI_HOME="${PI_HOME:-$TARGET_HOME}"
DASHBOARD_DIR="$PI_HOME/wifi_test_dashboard"

log_info "Starting simplified cleanup for fresh installations..."
log_info "Target user: $TARGET_USER  |  Home: $TARGET_HOME"

# =============================================================================
# 1) SERVICE CLEANUP
# =============================================================================

cleanup_service() {
  local svc="$1"
  local unit="/etc/systemd/system/${svc}.service"

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet "${svc}.service" 2>/dev/null; then
      log_info "Stopping service: ${svc}.service"
      systemctl stop "${svc}.service" || log_warn "Failed to stop ${svc}"
    fi
    if systemctl is-enabled --quiet "${svc}.service" 2>/dev/null; then
      log_info "Disabling service: ${svc}.service"
      systemctl disable "${svc}.service" || log_warn "Failed to disable ${svc}"
    fi
  fi

  if [[ -f "$unit" ]]; then
    log_info "Removing unit file: $unit"
    rm -f "$unit" || log_warn "Failed to remove $unit"
  fi
}

log_info "Stopping and removing existing dashboard services..."

# Service cleanup
SERVICES=(
  "wifi-good" "wifi-bad" "wifi-dashboard"
  "wifi_test_dashboard" "wifi-test-dashboard" "wifi_dashboard"
  "wired-test"
  "traffic-eth0" "traffic-wlan0" "traffic-wlan1" "traffic-lo"
)

for s in "${SERVICES[@]}"; do 
    cleanup_service "$s"
done

# Clean any wifi-*.service files
for unit in /etc/systemd/system/wifi-*.service /etc/systemd/system/traffic-*.service; do
  if [[ -f "$unit" ]]; then
    log_info "Removing service file: $unit"
    rm -f "$unit"
  fi
done

if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
fi
log_info "✓ Dashboard services cleaned up"

# =============================================================================
# 2) NETWORKMANAGER CLEANUP
# =============================================================================

log_info "Cleaning up NetworkManager connections..."

if command -v nmcli >/dev/null 2>&1; then
  # Get all connection names
  local connections
  connections=$(nmcli -t -f NAME connection show 2>/dev/null || echo "")
  
  if [[ -n "$connections" ]]; then
    # Check each connection
    echo "$connections" | while IFS= read -r conn_name; do
      if [[ -n "$conn_name" ]]; then
        # Simple pattern matching
        case "$conn_name" in
          *CNXNMist*|*wifi*|*dashboard*|*mist*|*traffic*|*test*|*Ryan*|*Bad*|*Good*)
            log_info "Removing dashboard connection: $conn_name"
            nmcli connection delete "$conn_name" 2>/dev/null || log_warn "Could not remove $conn_name"
            ;;
        esac
      fi
    done
  else
    log_info "No NetworkManager connections found"
  fi

  # Remove orphaned keyfiles
  for f in /etc/NetworkManager/system-connections/*; do
    if [[ -f "$f" ]]; then
      base="$(basename "$f")"
      case "$base" in
        *CNXNMist*|*wifi*|*dashboard*|*mist*|*traffic*|*test*|*Ryan*|*Bad*|*Good*)
          log_info "Removing orphaned NM keyfile: $base"
          rm -f "$f" || log_warn "Could not remove $f"
          ;;
      esac
    fi
  done

  # Disconnect interfaces
  log_info "Disconnecting Wi-Fi interfaces..."
  for iface in wlan0 wlan1 wlan2; do
    if ip link show "$iface" >/dev/null 2>&1; then
      nmcli device disconnect "$iface" 2>/dev/null || true
      log_info "Disconnected $iface"
    fi
  done

  # Reload configuration
  nmcli connection reload >/dev/null 2>&1 || true
  log_info "NetworkManager configuration reloaded"
else
  log_warn "nmcli not found; skipping NetworkManager cleanup"
fi

# =============================================================================
# 3) FRESH INSTALL STATE CLEANUP
# =============================================================================

log_info "Ensuring clean hostname state for fresh install..."

# Remove DHCP hostname configurations
log_info "Removing DHCP hostname configurations..."
rm -f /etc/dhcp/dhclient-wlan*.conf
rm -f /etc/NetworkManager/conf.d/dhcp-hostname-*.conf

# Clean hostname lock system
log_info "Cleaning hostname lock system..."
rm -rf /var/run/wifi-dashboard

# Clean any hostname-related temp files
rm -f /tmp/wifi-dashboard-hostname-*
rm -f /tmp/*-hostname.lock

log_info "✓ Fresh hostname state cleanup completed"

# =============================================================================
# 4) CRON CLEANUP
# =============================================================================

log_info "Pruning dashboard-related cron jobs..."

clean_cron_user() {
  local user="$1"
  local cur

  cur="$(crontab -u "$user" -l 2>/dev/null || echo "")"
  if [[ -z "$cur" ]]; then
    return 0
  fi

  # Check if there are dashboard entries
  if echo "$cur" | grep -q -E "wifi.*dashboard|traffic.*generator"; then
    log_info "Found cron entries for $user; removing dashboard entries"
    # Filter out dashboard entries
    local cleaned
    cleaned="$(echo "$cur" | grep -v -E "wifi.*dashboard|traffic.*generator" || echo "")"
    if [[ -n "$cleaned" ]]; then
      echo "$cleaned" | crontab -u "$user" -
    else
      crontab -u "$user" -r 2>/dev/null || true
    fi
  fi
}

clean_cron_user "$TARGET_USER"
clean_cron_user "root"

# =============================================================================
# 5) FILES AND LOGS CLEANUP
# =============================================================================

log_info "Removing leftover files and logs..."

# Logs
rm -f /var/log/wifi-*.log /var/log/wifi_*.log /var/log/traffic-*.log 2>/dev/null || true

# State/temp files
rm -rf /tmp/wifi-dashboard-* /tmp/wifi_* /tmp/bad_client_*.conf /tmp/wpa_roam_*.conf 2>/dev/null || true

# Identity files and stats
rm -f "$PI_HOME/wifi_test_dashboard/identity_"*.json 2>/dev/null || true
rm -f "$PI_HOME/wifi_test_dashboard/stats_"*.json 2>/dev/null || true

# Old dashboard dir (backup instead of delete)
if [[ -n "${DASHBOARD_DIR:-}" && -d "$DASHBOARD_DIR" && "$DASHBOARD_DIR" != "/" ]]; then
  log_info "Backing up old dashboard directory: $DASHBOARD_DIR"
  mv "$DASHBOARD_DIR" "${DASHBOARD_DIR}.backup.$(date +%s)" 2>/dev/null || {
    log_warn "Could not backup $DASHBOARD_DIR, attempting removal..."
    rm -rf "$DASHBOARD_DIR" || log_warn "Could not remove $DASHBOARD_DIR"
  }
fi

# =============================================================================
# 6) PROCESS CLEANUP (SIMPLIFIED)
# =============================================================================

log_info "Cleaning up lingering processes..."

# Kill processes by name (safer approach)
pkill -f "wifi-dashboard" 2>/dev/null || true
pkill -f "wifi-good" 2>/dev/null || true
pkill -f "wifi-bad" 2>/dev/null || true
pkill -f "traffic-generator" 2>/dev/null || true
pkill -f "wpa_supplicant.*wlan" 2>/dev/null || true

# Wait a moment for processes to exit
sleep 2

log_info "✓ Process cleanup completed"

# =============================================================================
# COMPLETION
# =============================================================================

log_info "✓ Simplified cleanup completed successfully"
log_info "System is ready for fresh dashboard installation"
exit 0