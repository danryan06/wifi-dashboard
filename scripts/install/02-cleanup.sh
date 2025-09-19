#!/usr/bin/env bash
# 02-cleanup.sh — Enhanced cleanup for fresh installations with hostname conflict prevention

# Strict mode + useful error trap
set -Eeuo pipefail
trap 'rc=$?; echo -e "\033[0;31m[ERROR]\033[0m Cleanup aborted (exit $rc) at line $LINENO while running: $BASH_COMMAND"; exit $rc' ERR

# Safer globbing and path
shopt -s nullglob
export PATH="/usr/sbin:/sbin:/usr/bin:/bin:$PATH"

# Logging helpers
log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
log_error(){ echo -e "\033[0;31m[ERROR]\033[0m $1"; }

# Require root (installer typically runs as root)
if [[ $EUID -ne 0 ]]; then
  log_error "Please run as root (e.g., via the installer or: sudo bash 02-cleanup.sh)"; exit 1
fi

# Determine the target (non-root) user for user-scoped cleanup
TARGET_USER="${PI_USER:-${SUDO_USER:-$(id -un)}}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
[[ -z "${TARGET_HOME:-}" ]] && TARGET_HOME="/home/$TARGET_USER"
PI_HOME="${PI_HOME:-$TARGET_HOME}"

# Optional: old dashboard dir (safe-guarded)
DASHBOARD_DIR="$PI_HOME/wifi_test_dashboard"

log_info "Starting enhanced cleanup for fresh installations..."
log_info "Target user: $TARGET_USER  |  Home: $TARGET_HOME"

# =============================================================================
# ENHANCED FRESH INSTALL STATE CLEANUP - NEW SECTION #3
# =============================================================================

ensure_fresh_hostname_state() {
    log_info "🧹 Ensuring clean hostname state for fresh install..."
    
    # Remove any conflicting DHCP client configs
    log_info "Removing DHCP hostname configurations..."
    rm -f /etc/dhcp/dhclient-wlan*.conf
    rm -f /etc/NetworkManager/conf.d/dhcp-hostname-*.conf
    
    # Clean hostname lock system
    log_info "Cleaning hostname lock system..."
    rm -rf /var/run/wifi-dashboard
    
    # Remove any orphaned NetworkManager keyfiles
    log_info "Cleaning NetworkManager keyfiles..."
    for f in /etc/NetworkManager/system-connections/*; do
        base="$(basename "$f")"
        if [[ "$base" =~ (CNXNMist|wifi|dashboard|mist|traffic|test|Ryan|Bad|Good) ]]; then
            log_info "Removing orphaned NM keyfile: $base"
            rm -f -- "$f" || log_warn "Could not remove $f"
        fi
    done
    
    # Clean any hostname-related temp files
    rm -f /tmp/wifi-dashboard-hostname-*
    rm -f /tmp/*-hostname.lock
    
    log_info "✓ Fresh hostname state cleanup completed"
}

# ------------------------------
# 1) Stop/disable/remove services
# ------------------------------
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
    rm -f -- "$unit" || log_warn "Failed to remove $unit"
  fi
}

log_info "Stopping and removing existing dashboard services..."

# Add/adjust names here as needed
SERVICES=(
  "wifi-good" "wifi-bad" "wifi-dashboard"
  "wifi_test_dashboard" "wifi-test-dashboard" "wifi_dashboard"
  "wired-test"
  "traffic-eth0" "traffic-wlan0" "traffic-wlan1" "traffic-lo"
)

for s in "${SERVICES[@]}"; do cleanup_service "$s"; done
for unit in /etc/systemd/system/wifi-*.service; do
  bn="$(basename "$unit" .service)"
  cleanup_service "$bn"
done

if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
fi
log_info "✓ Dashboard services cleaned up (or were not present)"

# --------------------------------------
# 2) Enhanced NetworkManager cleanup
# --------------------------------------
log_info "Performing enhanced NetworkManager connection cleanup..."
log_info "Cleaning up orphaned network configurations..."

if command -v nmcli >/dev/null 2>&1; then
  nm_list="$(nmcli -t -f NAME,UUID connection show 2>/dev/null || true)"
  if [[ -n "$nm_list" ]]; then
    log_info "Found NetworkManager connections, checking for dashboard-related ones..."
    IFS=$'\n'
    for line in $nm_list; do
      # Interpret last colon-delimited field as UUID, the rest as NAME (so names may contain ':')
      name="${line%:*}"
      uuid="${line##*:}"
      [[ "$uuid" == "$name" ]] && uuid=""  # in case there's no UUID

      # Enhanced patterns for fresh install cleanup
      HINTS="${EXTRA_NAME_HINTS:-wifi|dashboard|mist|traffic|test|wifi[-_]good|wifi[-_]bad|Ryan|Mist|Test|CNXNMist|bad-client|wifi-lock|temp-bad}"
      if [[ "$name" =~ $HINTS ]]; then
        log_info "Removing dashboard connection: $name"

        if [[ -n "$uuid" && "$uuid" != "--" ]]; then
          nmcli connection delete "$uuid" >/dev/null 2>&1 \
            && log_info "✓ Successfully removed: $name" \
            || { log_warn "Delete by UUID failed for $name ($uuid). Trying by name..."; nmcli connection delete "$name" >/dev/null 2>&1 || log_warn "Could not remove $name"; }
        else
          nmcli connection delete "$name" >/dev/null 2>&1 \
            && log_info "✓ Successfully removed: $name" \
            || log_warn "Could not remove: $name"
        fi
      fi
    done
    unset IFS
  else
    log_info "No NetworkManager connections found"
  fi

  # Force disconnect interfaces to clear state
  log_info "Disconnecting Wi-Fi interfaces to clear state..."
  for iface in wlan0 wlan1 wlan2; do
    if ip link show "$iface" >/dev/null 2>&1; then
      nmcli device disconnect "$iface" >/dev/null 2>&1 || true
      log_info "Disconnected $iface"
    fi
  done

  # Reload NM to pick up changes (no restart to avoid disruption)
  nmcli connection reload >/dev/null 2>&1 || true
  log_info "NetworkManager configuration reloaded"
else
  log_warn "nmcli not found; skipping NetworkManager cleanup"
fi

# -----------------------------
# 3) Cron cleanup (root & user)
# -----------------------------
log_info "Pruning dashboard-related cron jobs (root and $TARGET_USER)..."

clean_cron_user() {
  local user="$1"
  local cur cleaned

  cur="$(crontab -u "$user" -l 2>/dev/null || true)"
  # Nothing to do if no crontab
  [[ -z "$cur" ]] && return 0

  # Ensure grep failures don't trip pipefail by capturing output, not piping to crontab directly
  if printf "%s\n" "$cur" | grep -qE "wifi.*dashboard|traffic.*generator"; then
    log_info "Found cron entries for $user; removing dashboard entries"
    cleaned="$(printf "%s\n" "$cur" | grep -vE "wifi.*dashboard|traffic.*generator" || true)"
    if [[ -n "$cleaned" ]]; then
      printf "%s\n" "$cleaned" | crontab -u "$user" - || { log_warn "Could not update $user crontab; removing entirely"; crontab -u "$user" -r 2>/dev/null || true; }
    else
      crontab -u "$user" -r 2>/dev/null || true
    fi
  fi
}

clean_cron_user "$TARGET_USER"
clean_cron_user "root"

# -----------------------------
# 4) Files, logs, and processes
# -----------------------------
log_info "Removing leftover files and logs..."

# Logs
rm -f /var/log/wifi-*.log /var/log/wifi_*.log /var/log/traffic-*.log 2>/dev/null || true

# State/temp with enhanced patterns
rm -rf /tmp/wifi-dashboard-* /tmp/wifi_* /tmp/bad_client_*.conf /tmp/wpa_roam_*.conf 2>/dev/null || true

# Identity files and stats
rm -f "$PI_HOME/wifi_test_dashboard/identity_"*.json 2>/dev/null || true
rm -f "$PI_HOME/wifi_test_dashboard/stats_"*.json 2>/dev/null || true

# Old dashboard dir (only if it looks sane)
if [[ -n "${DASHBOARD_DIR:-}" && -d "$DASHBOARD_DIR" && "$DASHBOARD_DIR" != "/" ]]; then
  log_info "Backing up old dashboard directory: $DASHBOARD_DIR"
  # Create backup instead of deleting
  mv "$DASHBOARD_DIR" "${DASHBOARD_DIR}.backup.$(date +%s)" 2>/dev/null || {
    log_warn "Could not backup $DASHBOARD_DIR, attempting removal..."
    rm -rf -- "$DASHBOARD_DIR" || log_warn "Could not remove $DASHBOARD_DIR"
  }
fi

# Kill any lingering processes (best-effort)
# Build a PID list safely:
# - Match likely dashboard/test processes
# - Exclude the installer/this script so we don't nuke ourselves
# - Exclude our own PID and parent PID
mapfile -t KILL_PIDS < <(
  ps -eo pid=,args= \
  | awk '
      BEGIN{IGNORECASE=1}
      # Positive matches - enhanced patterns
      /(wifi-(good|bad)\b|wifi-dashboard\b|traffic-(eth0|wlan0|wlan1|lo)\b|traffic-.*(gen|generator)|wpa_supplicant.*wlan|dhclient.*wlan)/ &&
      # Negative matches: don't kill the installer or this script
      !/wifi-dashboard-install/ && !/install\.sh/ && !/02-cleanup\.sh/ && !/enhanced.*install/ {
        print $1
      }' \
  | sort -u
)

# Filter out our own shell and parent just in case
SAFE_PIDS=()
for pid in "${KILL_PIDS[@]}"; do
  [[ -z "$pid" ]] && continue
  if [[ "$pid" -ne $$ && "$pid" -ne $PPID ]]; then
    SAFE_PIDS+=("$pid")
  fi
done

if (( ${#SAFE_PIDS[@]} > 0 )); then
  log_warn "Some dashboard-related processes may still be running; attempting to terminate:"
  # Graceful first
  for pid in "${SAFE_PIDS[@]}"; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 1
  # Forceful if needed
  for pid in "${SAFE_PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done
else
  log_info "✓ No lingering dashboard processes found"
fi

# =============================================================================
# EXECUTE FRESH INSTALL STATE CLEANUP - CALL THE NEW FUNCTION
# =============================================================================
ensure_fresh_hostname_state

log_info "✓ Enhanced cleanup completed successfully"
log_info "System is ready for fresh dashboard installation with hostname conflict prevention"
exit 0