#!/usr/bin/env bash
# Wi-Fi Test Dashboard Installer
# - Installs from a local git checkout (manual install) or clones the repo
#   (curl | bash quick install) - every installed file comes from the same
#   revision, with no embedded fallback copies to drift out of date.
# - Orders steps correctly for fresh Pi installations
# - Robust error handling and validation

set -Eeuo pipefail
trap 'echo -e "\033[0;31m[ERROR]\033[0m ❌ Installation failed at line $LINENO. See log: $INSTALL_LOG"' ERR

# ───────────────────────────────────────────────────────────────────────────────
# Config
# ───────────────────────────────────────────────────────────────────────────────
REPO_GIT_URL="${REPO_GIT_URL:-https://github.com/danryan06/wifi-dashboard.git}"
BRANCH="${BRANCH:-main}"
PI_USER="${PI_USER:-$(getent passwd 1000 | cut -d: -f1 2>/dev/null || echo 'pi')}"
PI_HOME="/home/$PI_USER"
VERSION="${VERSION:-v5.2.0}"

WORK_DIR="/tmp/wifi-dashboard"
INSTALL_LOG="${WORK_DIR}/install.log"
SRC_DIR=""

mkdir -p "$WORK_DIR"
exec > >(tee -a "$INSTALL_LOG") 2>&1

# ───────────────────────────────────────────────────────────────────────────────
# Pretty logs
# ───────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }

print_banner() {
  echo -e "${BLUE}"
  cat << 'EOF'
╔══════════════════════════════════════════════════════════════════╗
║                   🌐 Wi-Fi Test Dashboard                        ║
║          Multi-Client Traffic Generator for Mist PoCs            ║
╚══════════════════════════════════════════════════════════════════╝
EOF
  echo -e "${NC}"
}

# ───────────────────────────────────────────────────────────────────────────────
# Source resolution: local checkout or fresh clone
# ───────────────────────────────────────────────────────────────────────────────
resolve_source_dir() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"

  if [[ -n "$script_dir" && -f "$script_dir/scripts/install/07-services.sh" ]]; then
    SRC_DIR="$script_dir"
    log_info "Installing from local checkout: $SRC_DIR"
    return 0
  fi

  # Quick install (curl | bash): clone the repository
  if ! command -v git >/dev/null 2>&1; then
    log_info "Installing git..."
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y git >/dev/null 2>&1
  fi

  SRC_DIR="$WORK_DIR/src"
  rm -rf "$SRC_DIR"
  log_step "Cloning $REPO_GIT_URL (branch: $BRANCH)..."

  local attempt=0
  while (( attempt < 3 )); do
    attempt=$(( attempt + 1 ))
    if git clone --depth 1 --branch "$BRANCH" "$REPO_GIT_URL" "$SRC_DIR" >/dev/null 2>&1; then
      log_info "✓ Repository cloned"
      return 0
    fi
    log_warn "Clone attempt $attempt failed, retrying..."
    sleep 3
  done

  log_error "Failed to clone $REPO_GIT_URL"
  exit 1
}

run_install_script() {
  # run_install_script <relative-path> <description>
  local script="${1:-}" desc="${2:-}"

  if [[ -z "$script" || -z "$desc" ]]; then
    log_error "run_install_script called without proper arguments (got: '$script', '$desc')"
    exit 1
  fi

  local path="$SRC_DIR/$script"
  if [[ ! -f "$path" ]]; then
    log_error "❌ Missing install script: $path"
    exit 1
  fi

  log_step "$desc"
  export PI_USER PI_HOME SRC_DIR VERSION

  if bash "$path"; then
    log_info "✅ Completed: $desc"
  else
    log_error "❌ Failed: $desc"
    exit 1
  fi
}

# ───────────────────────────────────────────────────────────────────────────────
# Checks / prep
# ───────────────────────────────────────────────────────────────────────────────
check_prerequisites() {
  log_step "Checking installation prerequisites..."

  if [[ $EUID -ne 0 ]]; then
    log_error "This installer must be run as root (use: sudo bash install.sh)"
    exit 1
  fi

  # Check if this is a Raspberry Pi (warn if not)
  if ! grep -q "Raspberry Pi" /proc/cpuinfo 2>/dev/null; then
    log_warn "Not running on Raspberry Pi - some features may not work optimally"
  fi

  # Network is required to install packages (and clone when quick-installing)
  if ! curl -fsSL --max-time 10 https://google.com >/dev/null; then
    log_error "Internet connection is required for installation"
    exit 1
  fi

  # Space (>=500MB)
  local free_kb
  free_kb=$(df / | awk 'NR==2{print $4}')
  if (( free_kb < 512000 )); then
    log_error "Insufficient disk space (need at least 500MB free)"
    exit 1
  fi

  log_info "✅ Prerequisites check passed"
}

ensure_fresh_install_state() {
  log_step "Ensuring clean state for fresh installation..."

  # Back up existing installation if present
  if [[ -d "$PI_HOME/wifi_test_dashboard" ]]; then
    log_warn "Existing installation detected, backing up..."
    mv "$PI_HOME/wifi_test_dashboard" "$PI_HOME/wifi_test_dashboard.backup.$(date +%s)"
  fi

  # Remove old DHCP hostname configs (will be recreated by services)
  log_info "Cleaning previous hostname configurations..."
  rm -f /etc/dhcp/dhclient-wlan*.conf
  rm -f /etc/NetworkManager/conf.d/dhcp-hostname-*.conf
  rm -rf /var/run/wifi-dashboard

  # Disconnect Wi-Fi interfaces to avoid conflicts during installation
  if command -v nmcli >/dev/null 2>&1; then
    for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^wlan[0-9]+$' || true); do
      nmcli dev disconnect "$iface" 2>/dev/null || true
    done
    log_info "Disconnected Wi-Fi interfaces"
  fi

  # Remove any existing service units
  local services=(wifi-dashboard wifi-good wifi-bad wired-test traffic-eth0 traffic-wlan0 traffic-wlan1)
  for service in "${services[@]}"; do
    systemctl stop "${service}.service" 2>/dev/null || true
    systemctl disable "${service}.service" 2>/dev/null || true
  done

  # Template instances from multi-adapter setups
  while read -r unit _rest; do
    [[ -n "$unit" ]] || continue
    systemctl stop "$unit" 2>/dev/null || true
    systemctl disable "$unit" 2>/dev/null || true
  done < <(systemctl list-units --all --plain --no-legend 'wifi-client@*' 2>/dev/null)

  # Clean service files
  rm -f /etc/systemd/system/wifi-*.service
  rm -f /etc/systemd/system/wired-test.service
  rm -f /etc/systemd/system/traffic-*.service
  systemctl daemon-reload

  log_info "✅ Fresh install state ensured"
}

# ───────────────────────────────────────────────────────────────────────────────
# Main sequence - CRITICAL: Proper ordering for fresh Pi installs
# ───────────────────────────────────────────────────────────────────────────────
main_installation_sequence() {
  log_step "Starting installation sequence..."

  # Phase 1: System Preparation (CRITICAL FIRST)
  run_install_script "scripts/install/01-dependencies-enhanced.sh" "Installing system dependencies with NetworkManager fixes"
  sleep 3  # Let NetworkManager stabilize

  run_install_script "scripts/install/02-cleanup.sh" "Cleaning up previous installations thoroughly"
  sleep 2

  # Phase 2: Structure Setup
  run_install_script "scripts/install/03-directories.sh" "Creating directory structure and baseline configuration"

  # Phase 3: Interface Detection (CRITICAL - Must happen before service creation)
  run_install_script "scripts/install/04.5-auto-interface-assignment.sh" "Auto-detecting Wi-Fi adapters and assigning client personas"
  sleep 3  # Allow interface detection to complete

  # Phase 4: Application Components
  run_install_script "scripts/install/04-flask-app.sh" "Installing Flask web application"
  run_install_script "scripts/install/05-templates.sh" "Installing web interface templates"
  run_install_script "scripts/install/06-traffic-scripts.sh" "Installing traffic generation scripts"

  # Phase 5: Service Creation (AFTER interface detection)
  run_install_script "scripts/install/07-services.sh" "Creating and configuring systemd services"
  sleep 3  # Let systemd register services

  # Phase 6: Final Setup with Enhanced Verification
  run_install_script "scripts/install/08-finalize.sh" "Finalizing installation with hostname configs and service startup"
}

# ───────────────────────────────────────────────────────────────────────────────
# Validation (soft validation for fresh installs)
# ───────────────────────────────────────────────────────────────────────────────
validate_installation() {
  log_step "Validating installation..."

  local soft_issues=0 hard_issues=0

  # Directory structure
  local need_dirs=(
    "$PI_HOME/wifi_test_dashboard"
    "$PI_HOME/wifi_test_dashboard/scripts"
    "$PI_HOME/wifi_test_dashboard/configs"
    "$PI_HOME/wifi_test_dashboard/logs"
    "$PI_HOME/wifi_test_dashboard/templates"
  )
  for d in "${need_dirs[@]}"; do
    if [[ ! -d "$d" ]]; then
      log_error "Missing directory: $d"
      hard_issues=$((hard_issues+1))
    fi
  done

  # Critical files
  local need_files=(
    "$PI_HOME/wifi_test_dashboard/app.py"
    "$PI_HOME/wifi_test_dashboard/scripts/connect_and_curl.sh"
    "$PI_HOME/wifi_test_dashboard/scripts/fail_auth_loop.sh"
    "$PI_HOME/wifi_test_dashboard/scripts/wired_simulation.sh"
    "$PI_HOME/wifi_test_dashboard/scripts/wifi_client.sh"
    "$PI_HOME/wifi_test_dashboard/scripts/apply_netem.sh"
    "$PI_HOME/wifi_test_dashboard/configs/interface-assignments.conf"
    "$PI_HOME/wifi_test_dashboard/configs/clients.conf"
    "$PI_HOME/wifi_test_dashboard/configs/settings.conf"
  )
  for f in "${need_files[@]}"; do
    if [[ ! -f "$f" ]]; then
      log_error "Missing file: $f"
      hard_issues=$((hard_issues+1))
    fi
  done

  # Service units
  local svc=(wifi-dashboard wifi-good wifi-bad wired-test)
  for s in "${svc[@]}"; do
    if [[ ! -f "/etc/systemd/system/${s}.service" ]]; then
      log_error "Missing service unit: ${s}.service"
      hard_issues=$((hard_issues+1))
    fi
  done
  if [[ ! -f "/etc/systemd/system/wifi-client@.service" ]]; then
    log_warn "Missing wifi-client@.service template (extra adapters won't start)"
    soft_issues=$((soft_issues+1))
  fi

  # Check if services are enabled
  for s in "${svc[@]}"; do
    if ! systemctl is-enabled "${s}.service" >/dev/null 2>&1; then
      log_warn "Service ${s}.service is not enabled"
      soft_issues=$((soft_issues+1))
    fi
  done

  # Check NetworkManager status
  if ! systemctl is-active --quiet NetworkManager; then
    log_error "NetworkManager is not running"
    hard_issues=$((hard_issues+1))
  fi

  # Results
  if (( hard_issues > 0 )); then
    log_error "❌ Validation found $hard_issues critical issue(s)"
    log_error "Installation may not function properly. Check $INSTALL_LOG for details."
    return 1
  fi

  if (( soft_issues > 0 )); then
    log_warn "⚠️ Validation found $soft_issues minor issue(s)"
    log_warn "These are normal on fresh installs until Wi-Fi is configured"
  else
    log_info "✅ Installation validation passed with no issues"
  fi
  return 0
}

show_final_status() {
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}' || echo "")"

  echo
  echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║                    🎉 INSTALLATION COMPLETE!                    ║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
  echo

  if [[ -n "$ip" ]]; then
    log_info "🌐 Dashboard URL: http://${ip}:5000"
  else
    log_info "🌐 Dashboard URL: http://<your-pi-ip>:5000"
  fi

  echo
  log_info "📋 What's been installed:"
  log_info "  ✅ Automatic Wi-Fi adapter detection - every adapter becomes a client"
  log_info "  ✅ Good client with intelligent roaming + bad client (auth failures)"
  log_info "  ✅ Extra USB adapters run as wifi-client@<iface> instances"
  log_info "  ✅ Per-interface DHCP hostnames (unique client identity in Mist)"
  log_info "  ✅ Heavy wired traffic generation + per-interface network emulation"
  log_info "  ✅ Web-based configuration and real-time monitoring"
  echo
  log_info "🚀 Next Steps:"
  log_info "  1. Open the dashboard URL above in your browser"
  log_info "  2. Navigate to the 'Wi-Fi Config' tab"
  log_info "  3. Enter your Wi-Fi network SSID and password"
  log_info "  4. Services will restart automatically with your settings"
  log_info "  5. Monitor progress in the 'Status' and 'Logs' tabs"
  echo
  log_info "🔧 Useful Commands:"
  log_info "  • Check service status: sudo systemctl status wifi-good wifi-bad 'wifi-client@*'"
  log_info "  • View live logs: sudo journalctl -u wifi-good -f"
  log_info "  • Run diagnostics: sudo bash $PI_HOME/wifi_test_dashboard/scripts/diagnose-dashboard.sh"
  log_info "  • Client personas: $PI_HOME/wifi_test_dashboard/configs/clients.conf"
  echo
  log_info "📡 Scaling: plug more USB Wi-Fi adapters into a POWERED hub, then re-run:"
  log_info "  sudo bash $PI_HOME/wifi_test_dashboard/scripts/install/04.5-auto-interface-assignment.sh"
  log_info "  sudo bash $PI_HOME/wifi_test_dashboard/scripts/install/07-services.sh"
  echo
  log_info "🎊 Your Wi-Fi testing system is ready for Mist dashboard monitoring!"
  log_info "📄 Installation log: $INSTALL_LOG"
}

# ───────────────────────────────────────────────────────────────────────────────
# Main execution
# ───────────────────────────────────────────────────────────────────────────────
main() {
  print_banner

  log_info "Starting Wi-Fi Dashboard installation..."
  log_info "Target user: $PI_USER"
  log_info "Installation directory: $PI_HOME/wifi_test_dashboard"
  log_info "Version: $VERSION"

  check_prerequisites
  resolve_source_dir
  ensure_fresh_install_state
  main_installation_sequence

  if validate_installation; then
    show_final_status
    exit 0
  else
    log_error "Installation validation failed"
    log_error "Some components may not work correctly"
    log_error "Check the dashboard and logs for more information"
    show_final_status  # Still show next steps
    exit 1
  fi
}

# Execute main function
main "$@"
