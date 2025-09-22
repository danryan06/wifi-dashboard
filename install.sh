#!/usr/bin/env bash
# Enhanced Wi-Fi Test Dashboard Installer
# - Orders steps correctly for fresh Pi installations
# - Handles hostname conflicts properly
# - Robust error handling and validation
# - Clear next steps at the end

set -Eeuo pipefail
trap 'echo -e "\033[0;31m[ERROR]\033[0m ❌ Installation failed at line $LINENO. See log: $INSTALL_LOG"' ERR

# ───────────────────────────────────────────────────────────────────────────────
# Config
# ───────────────────────────────────────────────────────────────────────────────
REPO_URL="${REPO_URL:-https://raw.githubusercontent.com/danryan06/wifi-dashboard/main}"
PI_USER="${PI_USER:-$(getent passwd 1000 | cut -d: -f1 2>/dev/null || echo 'pi')}"
PI_HOME="/home/$PI_USER"
VERSION="${VERSION:-v5.1.0}"

WORK_DIR="/tmp/wifi-dashboard"
INSTALL_LOG="${WORK_DIR}/install.log"

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
║                   🌐 Wi-Fi Test Dashboard v5.1.0                ║
║            Enhanced Installation with Hostname Fixes             ║
╚══════════════════════════════════════════════════════════════════╝
EOF
  echo -e "${NC}"
}

# ───────────────────────────────────────────────────────────────────────────────
# Helpers
# ───────────────────────────────────────────────────────────────────────────────
download_to() {
  local file="${1:-}"
  local target="${2:-}"
  local attempt=0

  if [[ -z "$file" || -z "$target" ]]; then
    log_error "download_to called without required arguments (file='$file', target='$target')"
    return 1
  fi

  # Ensure target directory exists
  mkdir -p "$(dirname "$target")"

  while (( attempt < 3 )); do
    attempt=$(( attempt + 1 ))
    if curl -fsSL "${REPO_URL:-}/$file" -o "$target"; then
      return 0
    else
      log_warn "Download attempt $attempt for $file failed, retrying..."
      sleep 2
    fi
  done
  return 1
}

run_install_script() {
  # run_install_script <filename> <description>
  set +u
  local script="$1" desc="$2"
  set -u

  if [[ -z "$script" || -z "$desc" ]]; then
    log_error "run_install_script called without proper arguments (got: '$script', '$desc')"
    exit 1
  fi

  # Use basename for local filename to avoid subdirectory issues
  local basename_script="$(basename "$script")"
  local path="${WORK_DIR}/${basename_script}"
  
  log_step "$desc"
  log_info "Downloading ${script}..."

  if ! download_to "$script" "$path"; then
    log_error "❌ Failed to download ${script}"
    exit 1
  fi

  # Make script executable
  chmod +x "$path"

  # Set environment variables for the script
  export PI_USER PI_HOME REPO_URL VERSION

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

  # Network is required to fetch scripts
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
    nmcli dev disconnect wlan0 2>/dev/null || true
    nmcli dev disconnect wlan1 2>/dev/null || true
    log_info "Disconnected Wi-Fi interfaces"
  fi

  # Remove any existing service units
  local services=(wifi-dashboard wifi-good wifi-bad wired-test traffic-eth0 traffic-wlan0 traffic-wlan1)
  for service in "${services[@]}"; do
    systemctl stop "${service}.service" 2>/dev/null || true
    systemctl disable "${service}.service" 2>/dev/null || true
  done

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
  log_step "Starting enhanced installation sequence..."

  # Phase 1: System Preparation (CRITICAL FIRST)
  run_install_script "scripts/install/01-dependencies-enhanced.sh" "Installing system dependencies with NetworkManager fixes"
  sleep 3  # Let NetworkManager stabilize

  run_install_script "scripts/install/02-cleanup.sh" "Cleaning up previous installations thoroughly"
  sleep 2

  # Phase 2: Structure Setup
  run_install_script "scripts/install/03-directories.sh" "Creating directory structure and baseline configuration"

  # Phase 3: Interface Detection (CRITICAL - Must happen before service creation)
  run_install_script "scripts/install/04.5-auto-interface-assignment.sh" "Auto-detecting and assigning network interfaces optimally"
  sleep 3  # Allow interface detection to complete

  # Phase 4: Application Components
  run_install_script "scripts/install/04-flask-app.sh" "Installing Flask web application"
  run_install_script "scripts/install/05-templates.sh" "Installing web interface templates"
  run_install_script "scripts/install/06-traffic-scripts.sh" "Installing traffic generation scripts"

  # Phase 5: Service Creation (AFTER interface detection)
  run_install_script "scripts/install/07-services.sh" "Creating and configuring systemd services with proper dependencies"
  sleep 3  # Let systemd register services

  # Phase 6: Final Setup with Enhanced Verification
  run_install_script "scripts/install/08-finalize.sh" "Finalizing installation with hostname verification and service startup"
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
    "$PI_HOME/wifi_test_dashboard/configs/interface-assignments.conf"
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

  # Check if services are enabled
  for s in "${svc[@]}"; do
    if ! systemctl is-enabled "${s}.service" >/dev/null 2>&1; then
      log_warn "Service ${s}.service is not enabled"
      soft_issues=$((soft_issues+1))
    fi
  done

  # DHCP hostname configs are created by services AFTER SSID is configured
  # This is normal on fresh installs
  if [[ ! -f "/etc/dhcp/dhclient-wlan0.conf" ]]; then
    log_warn "wlan0 DHCP hostname config not present yet (normal on fresh install)"
    soft_issues=$((soft_issues+1))
  fi
  if [[ ! -f "/etc/dhcp/dhclient-wlan1.conf" ]]; then
    log_warn "wlan1 DHCP hostname config not present yet (normal on fresh install)"
    soft_issues=$((soft_issues+1))
  fi

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
    log_warn "Services will create hostname configs automatically after SSID setup"
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
  log_info "  ✅ Enhanced NetworkManager configuration for fresh Pi"
  log_info "  ✅ Automatic Wi-Fi interface detection and assignment"
  log_info "  ✅ Hostname conflict prevention with lock system"
  log_info "  ✅ Dual-interface Wi-Fi testing (good/bad client simulation)"
  log_info "  ✅ Heavy traffic generation with intelligent roaming"
  log_info "  ✅ Web-based configuration and real-time monitoring"
  log_info "  ✅ Comprehensive logging and diagnostic tools"
  echo
  log_info "🚀 Next Steps:"
  log_info "  1. Open the dashboard URL above in your browser"
  log_info "  2. Navigate to the 'Wi-Fi Config' tab"
  log_info "  3. Enter your Wi-Fi network SSID and password"
  log_info "  4. Services will restart automatically with your settings"
  log_info "  5. Monitor progress in the 'Status' and 'Logs' tabs"
  echo
  log_info "🔧 Useful Commands:"
  log_info "  • Check service status: sudo systemctl status wifi-good wifi-bad"
  log_info "  • View live logs: sudo journalctl -u wifi-good -f"
  log_info "  • Run diagnostics: sudo bash $PI_HOME/wifi_test_dashboard/scripts/diagnose-dashboard.sh"
  log_info "  • Fix any issues: sudo bash $PI_HOME/wifi_test_dashboard/scripts/fix-services.sh"
  echo
  log_info "📊 What the system will do:"
  log_info "  • Good Wi-Fi client: Connects successfully, generates realistic traffic, roams between APs"
  log_info "  • Bad Wi-Fi client: Generates authentication failures for security testing"
  log_info "  • Wired client: Heavy ethernet traffic simulation"
  log_info "  • Each client uses unique DHCP hostnames (CNXNMist-WiFiGood, CNXNMist-WiFiBad, CNXNMist-Wired)"
  echo
  log_info "🎊 Your enhanced Wi-Fi testing system is ready for Mist dashboard monitoring!"
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
  log_info "Repository: $REPO_URL"
  echo

  check_prerequisites
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