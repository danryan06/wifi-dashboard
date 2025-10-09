#!/usr/bin/env bash
# Enhanced Wi-Fi Test Dashboard Installer with Comprehensive Cleanup
# - Complete removal of previous installations
# - Orders steps correctly for fresh Pi installations
# - Handles hostname conflicts properly
# - Robust error handling and validation

set -Eeuo pipefail

# Initialize log file
INSTALL_LOG="/tmp/wifi-dashboard-install.log"
mkdir -p "$(dirname "$INSTALL_LOG")"

trap 'echo -e "\033[0;31m[ERROR]\033[0m ❌ Installation failed at line $LINENO. See log: ${INSTALL_LOG:-/tmp/wifi-dashboard-install.log}"' ERR

# ───────────────────────────────────────────────────────────────────────────────
# Config
# ───────────────────────────────────────────────────────────────────────────────
# Auto-detect the branch from the curl command that downloaded this script
detect_branch() {
  # Look for the curl command in the process list that downloaded this script
  local curl_cmd
  curl_cmd=$(ps aux | grep -E "curl.*githubusercontent.*wifi-dashboard.*install\.sh" | grep -v grep | head -1)
  
  if [[ -n "$curl_cmd" ]]; then
    # Extract branch from URL like: .../wifi-dashboard/Optimizing-Code/install.sh
    if [[ "$curl_cmd" =~ githubusercontent\.com/[^/]+/[^/]+/([^/]+)/install\.sh ]]; then
      echo "${BASH_REMATCH[1]}"
      return
    fi
  fi
  
  # Fallback: check if BRANCH environment variable is set
  if [[ -n "${BRANCH:-}" ]]; then
    echo "$BRANCH"
    return
  fi
  
  # Default fallback
  echo "Optimizing-Code"
}

DETECTED_BRANCH="$(detect_branch)"
REPO_URL="${REPO_URL:-https://raw.githubusercontent.com/danryan06/wifi-dashboard/$DETECTED_BRANCH}"

# Log the detected branch for debugging
echo "🔍 Detected branch: $DETECTED_BRANCH"
echo "🔗 Using repository URL: $REPO_URL"
PI_USER="${PI_USER:-$(getent passwd 1000 | cut -d: -f1 2>/dev/null || echo 'pi')}"
PI_HOME="/home/$PI_USER"
VERSION="${VERSION:-v5.1.0-optimized}"

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
║          🌐 Wi-Fi Test Dashboard v5.1.0-optimized              ║
║          Enhanced with Complete Cleanup & Optimization          ║
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
    log_error "download_to called without required arguments"
    return 1
  fi

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
  local script="$1" desc="$2"

  if [[ -z "$script" || -z "$desc" ]]; then
    log_error "run_install_script called without proper arguments"
    exit 1
  fi

  local basename_script="$(basename "$script")"
  local path="${WORK_DIR}/${basename_script}"
  
  log_step "$desc"
  log_info "Downloading ${script}..."

  if ! download_to "$script" "$path"; then
    log_error "❌ Failed to download ${script}"
    exit 1
  fi

  chmod +x "$path"
  export PI_USER PI_HOME REPO_URL VERSION

  if bash "$path"; then
    log_info "✅ Completed: $desc"
  else
    log_error "❌ Failed: $desc"
    exit 1
  fi
}

# ───────────────────────────────────────────────────────────────────────────────
# Prerequisites Check
# ───────────────────────────────────────────────────────────────────────────────
check_prerequisites() {
  log_step "Checking installation prerequisites..."

  if [[ $EUID -ne 0 ]]; then
    log_error "This installer must be run as root (use: sudo bash install.sh)"
    exit 1
  fi

  if ! grep -q "Raspberry Pi" /proc/cpuinfo 2>/dev/null; then
    log_warn "Not running on Raspberry Pi - some features may not work optimally"
  fi

  if ! curl -fsSL --max-time 10 https://google.com >/dev/null; then
    log_error "Internet connection is required for installation"
    exit 1
  fi

  local free_kb
  free_kb=$(df / | awk 'NR==2{print $4}')
  if (( free_kb < 512000 )); then
    log_error "Insufficient disk space (need at least 500MB free)"
    exit 1
  fi

  log_info "✅ Prerequisites check passed"
}

# ───────────────────────────────────────────────────────────────────────────────
# ENHANCED: Comprehensive Cleanup for Fresh Install
# ───────────────────────────────────────────────────────────────────────────────
ensure_fresh_install_state() {
  log_step "Performing comprehensive cleanup for fresh installation..."

  # ─────────────────────────────────────────────────────────────────────
  # 1. Stop all services first
  # ─────────────────────────────────────────────────────────────────────
  log_info "🛑 Stopping all services..."
  local services=(wifi-dashboard wifi-good wifi-bad wired-test traffic-eth0 traffic-wlan0 traffic-wlan1)
  for service in "${services[@]}"; do
    if systemctl is-active --quiet "${service}.service" 2>/dev/null; then
      log_warn "Stopping ${service}.service..."
      systemctl stop "${service}.service" 2>/dev/null || true
    fi
  done

  # ─────────────────────────────────────────────────────────────────────
  # 2. Disable all services
  # ─────────────────────────────────────────────────────────────────────
  log_info "🔌 Disabling all services..."
  for service in "${services[@]}"; do
    if systemctl is-enabled --quiet "${service}.service" 2>/dev/null; then
      log_warn "Disabling ${service}.service..."
      systemctl disable "${service}.service" 2>/dev/null || true
    fi
  done

  # ─────────────────────────────────────────────────────────────────────
  # 3. Remove service unit files
  # ─────────────────────────────────────────────────────────────────────
  log_info "🗑️  Removing service unit files..."
  rm -f /etc/systemd/system/wifi-*.service
  rm -f /etc/systemd/system/wired-*.service
  rm -f /etc/systemd/system/traffic-*.service
  systemctl daemon-reload
  log_info "✅ Service files removed"

  # ─────────────────────────────────────────────────────────────────────
  # 4. Backup existing installation
  # ─────────────────────────────────────────────────────────────────────
  if [[ -d "$PI_HOME/wifi_test_dashboard" ]]; then
    local BACKUP_DIR="$PI_HOME/wifi_test_dashboard.backup.$(date +%s)"
    log_warn "📦 Existing installation detected, backing up..."
    mv "$PI_HOME/wifi_test_dashboard" "$BACKUP_DIR"
    log_info "✅ Backup saved to: $BACKUP_DIR"
  else
    log_info "No existing installation found - clean slate"
  fi

  # ─────────────────────────────────────────────────────────────────────
  # 5. Remove ALL configuration files (will be recreated)
  # ─────────────────────────────────────────────────────────────────────
  log_info "🧹 Cleaning configuration files..."
  
  # DHCP hostname configs
  rm -f /etc/dhcp/dhclient-eth*.conf
  rm -f /etc/dhcp/dhclient-wlan*.conf
  
  # NetworkManager hostname configs
  rm -f /etc/NetworkManager/conf.d/dhcp-hostname-*.conf
  
  # Runtime directories
  rm -rf /var/run/wifi-dashboard
  
  # Temp installation files
  rm -rf /tmp/wifi-dashboard-old 2>/dev/null || true
  
  log_info "✅ Configuration files cleaned"

  # ─────────────────────────────────────────────────────────────────────
  # 6. Disconnect Wi-Fi interfaces to avoid conflicts
  # ─────────────────────────────────────────────────────────────────────
  if command -v nmcli >/dev/null 2>&1; then
    log_info "📡 Disconnecting Wi-Fi interfaces..."
    nmcli dev disconnect wlan0 2>/dev/null || true
    nmcli dev disconnect wlan1 2>/dev/null || true
    log_info "✅ Wi-Fi interfaces disconnected"
  fi

  # ─────────────────────────────────────────────────────────────────────
  # 7. Clean any leftover Python processes
  # ─────────────────────────────────────────────────────────────────────
  log_info "🔄 Cleaning leftover processes..."
  pkill -f "python.*app.py" 2>/dev/null || true
  pkill -f "flask.*run" 2>/dev/null || true
  sleep 2
  
  log_info "✅ Fresh install state ensured - ready for installation"
  echo
}

# ───────────────────────────────────────────────────────────────────────────────
# Main Installation Sequence
# ───────────────────────────────────────────────────────────────────────────────
main_installation_sequence() {
  log_step "Starting installation sequence..."

  # Phase 1: System Preparation
  run_install_script "scripts/install/01-dependencies-enhanced.sh" "Installing system dependencies"
  sleep 3

  run_install_script "scripts/install/02-cleanup.sh" "Additional cleanup"
  sleep 2

  # Phase 2: Structure Setup
  run_install_script "scripts/install/03-directories.sh" "Creating directory structure"

  # Phase 3: Interface Detection
  run_install_script "scripts/install/04.5-auto-interface-assignment.sh" "Auto-detecting network interfaces"
  sleep 3

  # Phase 4: Application Components
  run_install_script "scripts/install/04-flask-app.sh" "Installing Flask application"
  run_install_script "scripts/install/05-templates.sh" "Installing web templates"
  run_install_script "scripts/install/06-traffic-scripts.sh" "Installing traffic scripts"

  # Phase 5: Service Creation
  run_install_script "scripts/install/07-services.sh" "Creating systemd services"
  sleep 3

  # Phase 6: Finalization
  run_install_script "scripts/install/08-finalize.sh" "Finalizing installation"
}

# ───────────────────────────────────────────────────────────────────────────────
# Validation
# ───────────────────────────────────────────────────────────────────────────────
validate_installation() {
  log_step "Validating installation..."

  local soft_issues=0 hard_issues=0

  # Check directories
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

  # Check critical files
  local need_files=(
    "$PI_HOME/wifi_test_dashboard/app.py"
    "$PI_HOME/wifi_test_dashboard/scripts/traffic/connect_and_curl.sh"
    "$PI_HOME/wifi_test_dashboard/scripts/traffic/fail_auth_loop.sh"
    "$PI_HOME/wifi_test_dashboard/scripts/traffic/wired_simulation.sh"
  )
  for f in "${need_files[@]}"; do
    if [[ ! -f "$f" ]]; then
      log_error "Missing file: $f"
      hard_issues=$((hard_issues+1))
    fi
  done

  # Check service units
  local svc=(wifi-dashboard wifi-good wifi-bad wired-test)
  for s in "${svc[@]}"; do
    if [[ ! -f "/etc/systemd/system/${s}.service" ]]; then
      log_error "Missing service: ${s}.service"
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

  if (( hard_issues > 0 )); then
    log_error "❌ Validation found $hard_issues critical issue(s)"
    return 1
  fi

  if (( soft_issues > 0 )); then
    log_warn "⚠️ Validation found $soft_issues minor issue(s)"
    log_warn "These are normal on fresh installs"
  else
    log_info "✅ Installation validation passed"
  fi
  return 0
}

# ───────────────────────────────────────────────────────────────────────────────
# Final Status
# ───────────────────────────────────────────────────────────────────────────────
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
  log_info "✨ What's New (v5.1.0-optimized):"
  log_info "  ✅ Single stats system (no more conflicts)"
  log_info "  ✅ Heavy traffic generation (100MB+ downloads)"
  log_info "  ✅ Traffic intensity controls in web UI"
  log_info "  ✅ Simplified hostname management"
  log_info "  ✅ Network emulation support"
  echo
  log_info "🚀 Next Steps:"
  log_info "  1. Open the dashboard URL above"
  log_info "  2. Go to 'Wi-Fi Config' tab and enter your SSID/password"
  log_info "  3. Check 'Traffic Intensity' tab to adjust traffic levels"
  log_info "  4. Monitor real-time stats in 'Status' tab"
  log_info "  5. View logs in 'Logs' tab"
  echo
  log_info "🔧 Useful Commands:"
  log_info "  • Service status: sudo systemctl status wifi-good wifi-bad wired-test"
  log_info "  • View logs: sudo journalctl -u wired-test -f"
  log_info "  • Dashboard logs: cat $PI_HOME/wifi_test_dashboard/logs/main.log"
  echo
  log_info "📄 Installation log: $INSTALL_LOG"
  echo
}

# ───────────────────────────────────────────────────────────────────────────────
# Main Execution
# ───────────────────────────────────────────────────────────────────────────────
main() {
  print_banner
  
  log_info "Starting Wi-Fi Dashboard installation..."
  log_info "Target user: $PI_USER"
  log_info "Installation directory: $PI_HOME/wifi_test_dashboard"
  log_info "Version: $VERSION"
  echo

  check_prerequisites
  ensure_fresh_install_state  # ← ENHANCED with comprehensive cleanup
  main_installation_sequence

  if validate_installation; then
    show_final_status
    exit 0
  else
    log_error "Installation validation failed"
    show_final_status
    exit 1
  fi
}

main "$@"