#!/usr/bin/env bash
# fix-services.sh - Repair utility for the Wi-Fi Test Dashboard.
#
# Re-detects interfaces, regenerates the systemd units and restarts all
# services using the scripts already installed on the device. It deliberately
# contains NO embedded copies of application scripts - the single source of
# truth is what the installer put in <dashboard>/scripts/.

set -uo pipefail

PI_USER="${PI_USER:-pi}"
PI_HOME="/home/$PI_USER"
DASHBOARD_DIR="$PI_HOME/wifi_test_dashboard"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    log_error "Run as root: sudo bash $0"
    exit 1
fi

if [[ ! -d "$DASHBOARD_DIR" ]]; then
    log_error "Dashboard directory not found: $DASHBOARD_DIR (run install.sh first)"
    exit 1
fi

all_client_units() {
    echo "wired-test.service wifi-good.service wifi-bad.service"
    systemctl list-units --all --plain --no-legend 'wifi-client@*' 2>/dev/null | awk '{print $1}'
}

# ─── 1. Stop services ────────────────────────────────────────────────────────
log_step "Stopping dashboard services..."
for unit in $(all_client_units) wifi-dashboard.service; do
    systemctl stop "$unit" 2>/dev/null || true
done

# ─── 2. Clean stale NetworkManager test connections ─────────────────────────
log_step "Cleaning stale NetworkManager connections..."
if command -v nmcli >/dev/null 2>&1; then
    nmcli -t -f NAME connection show 2>/dev/null | \
        grep -E "^(CNXNMist|wifi-bad-|wifi-lock-|bssid-lock-)" | \
        while read -r conn; do
            [[ -n "$conn" ]] && nmcli connection delete "$conn" 2>/dev/null || true
        done
fi
rm -rf /var/run/wifi-dashboard 2>/dev/null || true

# ─── 3. Fix permissions ──────────────────────────────────────────────────────
log_step "Fixing ownership and permissions..."
mkdir -p "$DASHBOARD_DIR"/{logs,configs,stats,scripts,templates}
find "$DASHBOARD_DIR/scripts" -type f -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
chown -R "$PI_USER:$PI_USER" "$DASHBOARD_DIR"
chmod 600 "$DASHBOARD_DIR/configs/ssid.conf" 2>/dev/null || true

# ─── 4. Regenerate interface assignments and service units ──────────────────
log_step "Re-detecting interfaces and regenerating services..."
export PI_USER PI_HOME
if [[ -x "$DASHBOARD_DIR/scripts/install/04.5-auto-interface-assignment.sh" ]]; then
    bash "$DASHBOARD_DIR/scripts/install/04.5-auto-interface-assignment.sh" || \
        log_warn "Interface auto-assignment reported issues"
else
    log_warn "04.5-auto-interface-assignment.sh not installed; keeping existing assignments"
fi

if [[ -x "$DASHBOARD_DIR/scripts/install/07-services.sh" ]]; then
    bash "$DASHBOARD_DIR/scripts/install/07-services.sh" || {
        log_error "Service regeneration failed"
        exit 1
    }
else
    log_error "07-services.sh not installed; cannot regenerate units"
    exit 1
fi

# ─── 5. Restart everything ───────────────────────────────────────────────────
log_step "Restarting services..."
systemctl daemon-reload
systemctl restart wifi-dashboard.service 2>/dev/null || log_warn "wifi-dashboard failed to restart"
for unit in $(all_client_units); do
    systemctl restart "$unit" 2>/dev/null || log_warn "$unit failed to restart"
done

# ─── 6. Status summary ───────────────────────────────────────────────────────
sleep 3
log_step "Service status:"
for unit in wifi-dashboard.service $(all_client_units); do
    state="$(systemctl is-active "$unit" 2>/dev/null || echo unknown)"
    if [[ "$state" == "active" ]]; then
        log_info "  ✓ $unit: $state"
    else
        log_warn "  ✗ $unit: $state"
    fi
done

ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo
log_info "✅ Repair complete."
[[ -n "${ip:-}" ]] && log_info "Dashboard: http://${ip}:5000"
log_info "Follow logs with: sudo journalctl -u wifi-good -f"
