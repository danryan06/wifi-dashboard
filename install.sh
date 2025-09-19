#!/usr/bin/env bash
# Enhanced Wi-Fi Test Dashboard Installer
# - Orders steps correctly
# - Plays nice on fresh Pis
# - Soft validation so first-boot doesn’t look like a failure
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

  local path="${WORK_DIR}/${script}"
  log_step "$desc"
  log_info "Downloading ${script} (attempt 1/3)..."

  if ! download_to "$script" "$path"; then
    log_error "❌ Failed to download ${script}"
    exit 1
  fi

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

  # Network is required to fetch scripts
  if ! curl -fsSL --max-time 10 https://google.com >/dev/null; then
    log_error "Internet connection is required"
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

  # Back up existing tree if present
  if [[ -d "$PI_HOME/wifi_test_dashboard" ]]; then
    log_warn "Existing installation detected, backing up..."
    mv "$PI_HOME/wifi_test_dashboard" "$PI_HOME/wifi_test_dashboard.backup.$(date +%s)"
  fi

  # Remove old DHCP hostname bits (created later by services when SSID exists)
  log_info "Cleaning previous hostname configurations..."
  rm -f /etc/dhcp/dhclient-wlan*.conf
  rm -f /etc/NetworkManager/conf.d/dhcp-hostname-*.conf
  rm -rf /var/run/wifi-dashboard

  # Disconnect Wi-Fi (avoids NM fighting while we reconfigure)
  if command -v nmcli >/dev/null 2>&1; then
    nmcli dev disconnect wlan0 2>/dev/null || true
    nmcli dev disconnect wlan1 2>/dev/null || true
    log_info "Disconnected Wi-Fi interfaces"
  else
    log_info "NetworkManager connection cleanup will be handled by cleanup script..."
  fi

  # Remove stale service units
  systemctl stop wifi-dashboard.service wifi-good.service wifi-bad.service wired-test.service 2>/dev/null || true
  systemctl disable wifi-dashboard.service wifi-good.service wifi-bad.service wired-test.service 2>/dev/null || true
  rm -f /etc/systemd/system/wifi-*.service /etc/systemd/system/wired-test.service
  systemctl daemon-reload

  log_info "✅ Fresh install state ensured"
}

# ───────────────────────────────────────────────────────────────────────────────
# Main sequence
# ───────────────────────────────────────────────────────────────────────────────
main_installation_sequence() {
  log_step "Starting enhanced installation sequence..."

  # Include full paths to match your repository structure
  run_install_script "scripts/install/01-dependencies-enhanced.sh" "Installing system dependencies with NetworkManager fixes"
  sleep 2

  run_install_script "scripts/install/02-cleanup.sh"              "Cleaning up previous installations"
  sleep 1

  run_install_script "scripts/install/03-directories.sh"          "Creating directory structure and baseline configuration"

  run_install_script "scripts/install/04.5-auto-interface-assignment.sh" "Auto-detecting and assigning network interfaces"
  sleep 2

  run_install_script "scripts/install/04-flask-app.sh"            "Installing Flask application"
  run_install_script "scripts/install/05-templates.sh"            "Installing web interface templates"
  run_install_script "scripts/install/06-traffic-scripts.sh"      "Installing traffic generation scripts"
  run_install_script "scripts/install/07-services.sh"             "Creating and configuring systemd services"
  sleep 2
  run_install_script "scripts/install/08-finalize.sh"             "Finalizing installation with hostname verification"
}

# ───────────────────────────────────────────────────────────────────────────────
# Validation (soft – no scary red X on fresh installs)
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
  )
  for f in "${need_files[@]}"; do
    if [[ ! -f "$f" ]]; then
      log_error "Missing file: $f"
      hard_issues=$((hard_issues+1))
    fi
  done

  # Services present?
  local svc=(wifi-dashboard wifi-good wifi-bad wired-test)
  for s in "${svc[@]}"; do
    if [[ ! -f "/etc/systemd/system/${s}.service" ]]; then
      log_error "Missing service unit: ${s}.service"
      hard_issues=$((hard_issues+1))
    fi
  done

  # DHCP hostname confs are created by the clients AFTER SSID is set.
  # On fresh installs these will be missing—treat as soft warnings only.
  if [[ ! -f "/etc/dhcp/dhclient-wlan0.conf" ]]; then
    log_warn "wlan0 DHCP hostname config not present yet (expected on fresh install)"
    soft_issues=$((soft_issues+1))
  fi
  if [[ ! -f "/etc/dhcp/dhclient-wlan1.conf" ]]; then
    log_warn "wlan1 DHCP hostname config not present yet (expected on fresh install)"
    soft_issues=$((soft_issues+1))
  fi

  if (( hard_issues > 0 )); then
    log_error "❌ Validation found $hard_issues hard issue(s). Please check $INSTALL_LOG."
    return 1
  fi

  if (( soft_issues > 0 )); then
    log_warn "⚠️ Validation found $soft_issues soft issue(s)."
    log_warn "   These are normal until you enter SSID/password in the dashboard."
    log_warn "   Once Wi-Fi services start, hostname/DHCP files will be created automatically."
  else
    log_info "✅ Installation validation passed with no issues"
  fi
  return 0
}

show_final_status() {
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

  echo
  echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║                    🎉 INSTALLATION COMPLETE!                    ║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
  echo

  [[ -n "$ip" ]] && log_info "Dashboard: http://${ip}:5000" || log_info "Open the dashboard at: http://<pi-ip>:5000"

  echo
  log_info "What’s installed:"
  log_info "  • NetworkManager configuration tuned for Pi"
  log_info "  • Auto-detected interface assignments"
  log_info "  • Hostname lock & per-interface DHCP hostnames"
  log_info "  • Dashboard + Wi-Fi good/bad + wired services"
  log_info "  • Traffic generation & diagnostics scripts"
  echo
  log_info "Next steps:"
  log_info "  1) Open the dashboard URL above"
  log_info "  2) Enter SSID and password"
  log_info "  3) Services auto-restart; verify in Status tab"
  echo
  log_info "Logs live at: $INSTALL_LOG"
}

# ───────────────────────────────────────────────────────────────────────────────
# Main
# ───────────────────────────────────────────────────────────────────────────────
print_banner
log_info "Starting Wi-Fi Dashboard installation..."
log_info "Target user: $PI_USER"
log_info "Installation directory: $PI_HOME/wifi_test_dashboard"
log_info "Version: $VERSION"
echo

check_prerequisites
ensure_fresh_install_state
main_installation_sequence
validate_installation || true
show_final_status
