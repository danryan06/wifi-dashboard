#!/usr/bin/env bash
# Enhanced Wi-Fi Dashboard Installer with Hostname Conflict Prevention
# Designed for fresh Pi installations with proper sequencing

set -Eeuo pipefail
trap 'echo "❌ Installation failed at line $LINENO. Check logs for details."' ERR

# Colors and logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Configuration
REPO_URL="${REPO_URL:-https://raw.githubusercontent.com/danryan06/wifi-dashboard/main}"
PI_USER="${PI_USER:-$(getent passwd 1000 | cut -d: -f1 2>/dev/null || echo 'pi')}"
PI_HOME="/home/$PI_USER"
VERSION="v5.1.0"
INSTALL_LOG="/tmp/wifi-dashboard-install.log"

# Enhanced error handling
exec > >(tee -a "$INSTALL_LOG")
exec 2>&1

print_banner() {
    echo -e "${BLUE}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════╗
║                   🌐 Wi-Fi Test Dashboard v5.1.0                ║
║              Enhanced Installation with Hostname Fixes           ║
╚══════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

check_prerequisites() {
    log_step "Checking installation prerequisites..."
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log_error "This installer must be run as root (use sudo)"
        exit 1
    fi
    
    # Check if this is a Raspberry Pi
    if ! grep -q "Raspberry Pi" /proc/cpuinfo 2>/dev/null; then
        log_warn "Not running on Raspberry Pi - some features may not work"
    fi
    
    # Check network connectivity
    if ! curl -s --max-time 10 https://google.com >/dev/null; then
        log_error "Internet connection required for installation"
        exit 1
    fi
    
    # Check available space (need at least 500MB)
    local available_kb
    available_kb=$(df / | awk 'NR==2 {print $4}')
    if [[ $available_kb -lt 512000 ]]; then
        log_error "Insufficient disk space (need at least 500MB free)"
        exit 1
    fi
    
    log_info "✅ Prerequisites check passed"
}

# Enhanced hostname state cleanup for fresh installs
ensure_fresh_install_state() {
    log_step "Ensuring clean state for fresh installation..."
    
    # Remove any existing Wi-Fi dashboard installations
    if [[ -d "$PI_HOME/wifi_test_dashboard" ]]; then
        log_warn "Existing installation detected, backing up..."
        mv "$PI_HOME/wifi_test_dashboard" "$PI_HOME/wifi_test_dashboard.backup.$(date +%s)"
    fi
    
    # Clean hostname-related configurations
    log_info "Cleaning previous hostname configurations..."
    rm -f /etc/dhcp/dhclient-wlan*.conf
    rm -f /etc/NetworkManager/conf.d/dhcp-hostname-*.conf
    rm -rf /var/run/wifi-dashboard
    
    # NetworkManager cleanup will be handled by 02-cleanup.sh
    log_info "NetworkManager connection cleanup will be handled by cleanup script..."
    
    # Just disconnect interfaces for now
    if command -v nmcli >/dev/null 2>&1; then
        for iface in wlan0 wlan1; do
            nmcli device disconnect "$iface" 2>/dev/null || true
        done
        log_info "Disconnected Wi-Fi interfaces"
    fi
    
    # Stop any existing services
    local services=("wifi-dashboard" "wifi-good" "wifi-bad" "wired-test" "traffic-eth0" "traffic-wlan0" "traffic-wlan1")
    for service in "${services[@]}"; do
        systemctl stop "${service}.service" 2>/dev/null || true
        systemctl disable "${service}.service" 2>/dev/null || true
    done
    
    # Clean service files
    rm -f /etc/systemd/system/wifi-*.service
    rm -f /etc/systemd/system/traffic-*.service
    systemctl daemon-reload
    
    log_info "✅ Fresh install state ensured"
}

download_script() {
    local script_name="$1"
    local target_path="$2"
    local max_retries=3
    local retry=1
    
    while [[ $retry -le $max_retries ]]; do
        log_info "Downloading $script_name (attempt $retry/$max_retries)..."
        
        if curl -fsSL --max-time 30 "${REPO_URL}/scripts/install/${script_name}" -o "$target_path"; then
            chmod +x "$target_path"
            log_info "✅ Downloaded: $script_name"
            return 0
        else
            log_warn "Download failed: $script_name (attempt $retry)"
            ((retry++))
            sleep 2
        fi
    done
    
    log_error "Failed to download $script_name after $max_retries attempts"
    return 1
}

run_install_script() {
    local script_name="$1"
    local description="$2"
    local script_path="/tmp/${script_name}"

    log_step "$description"

    # Download script
    if ! download_script "$script_name" "$script_path"; then
        log_error "Failed to download $script_name"
        return 1
    fi

    # Set environment variables for the script
    export PI_USER="$PI_USER"
    export PI_HOME="$PI_HOME"
    export REPO_URL="$REPO_URL"
    export VERSION="$VERSION"

    # Execute script with error handling
    if bash "$script_path"; then
        log_info "✅ Completed: $description"
        return 0
    else
        # Special case: allow cleanup script to fail gracefully
        if [[ "$script_name" == "02-cleanup.sh" ]]; then
            log_warn "⚠ Cleanup script failed, continuing installation anyway"
            return 0
        fi

        log_error "❌ Failed: $description"
        return 1
    fi
}


# CRITICAL: Enhanced installation sequence with proper timing
main_installation_sequence() {
    log_step "Starting enhanced installation sequence..."
    
    # Phase 1: System Preparation (Critical First)
    run_install_script "01-dependencies-enhanced.sh" "Installing system dependencies with NetworkManager fixes"
    sleep 2  # Let NetworkManager stabilize
    
    run_install_script "02-cleanup.sh" "Cleaning up previous installations"
    sleep 1
    
    # Phase 2: Structure Setup
    run_install_script "03-directories.sh" "Creating directory structure and baseline configuration"
    
    # Phase 3: Interface Detection (CRITICAL - Must happen before service creation)
    run_install_script "04.5-auto-interface-assignment.sh" "Auto-detecting and assigning network interfaces"
    sleep 2  # Allow interface detection to complete
    
    # Phase 4: Application Components
    run_install_script "04-flask-app.sh" "Installing Flask application"
    run_install_script "05-templates.sh" "Installing web interface templates"
    run_install_script "06-traffic-scripts.sh" "Installing traffic generation scripts"
    
    # Phase 5: Service Creation (AFTER interface detection)
    run_install_script "07-services.sh" "Creating and configuring systemd services"
    sleep 2  # Let systemd register services
    
    # Phase 6: Final Setup with Enhanced Verification
    run_install_script "08-finalize.sh" "Finalizing installation with hostname verification"
}

# Post-installation validation
validate_installation() {
    log_step "Validating installation..."
    
    local issues=0
    
    # Check directory structure
    local required_dirs=(
        "$PI_HOME/wifi_test_dashboard"
        "$PI_HOME/wifi_test_dashboard/scripts"
        "$PI_HOME/wifi_test_dashboard/configs"
        "$PI_HOME/wifi_test_dashboard/logs"
        "$PI_HOME/wifi_test_dashboard/templates"
    )
    
    for dir in "${required_dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            log_error "Missing directory: $dir"
            ((issues++))
        fi
    done
    
    # Check critical files
    local critical_files=(
        "$PI_HOME/wifi_test_dashboard/app.py"
        "$PI_HOME/wifi_test_dashboard/scripts/connect_and_curl.sh"
        "$PI_HOME/wifi_test_dashboard/scripts/fail_auth_loop.sh"
        "$PI_HOME/wifi_test_dashboard/configs/interface-assignments.conf"
    )
    
    for file in "${critical_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            log_error "Missing file: $file"
            ((issues++))
        fi
    done
    
    # Check service files
    local services=("wifi-dashboard" "wifi-good" "wifi-bad" "wired-test")
    for service in "${services[@]}"; do
        if [[ ! -f "/etc/systemd/system/${service}.service" ]]; then
            log_error "Missing service file: ${service}.service"
            ((issues++))
        fi
    done
    
    # Check hostname configurations
    if [[ ! -f "/etc/dhcp/dhclient-wlan0.conf" ]]; then
        log_warn "Missing wlan0 DHCP hostname config"
        ((issues++))
    fi
    
    if [[ ! -f "/etc/dhcp/dhclient-wlan1.conf" ]]; then
        log_warn "Missing wlan1 DHCP hostname config"
        ((issues++))
    fi
    
    if [[ $issues -eq 0 ]]; then
        log_info "✅ Installation validation passed"
        return 0
    else
        log_error "❌ Installation validation failed with $issues issues"
        return 1
    fi
}

# Enhanced final status report
show_final_status() {
    local dashboard_ip
    dashboard_ip=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "IP_NOT_FOUND")
    
    echo
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗"
    echo -e "║                    🎉 INSTALLATION COMPLETE!                    ║"
    echo -e "╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo
    log_info "🌐 Dashboard URL: http://$dashboard_ip:5000"
    echo
    log_info "📋 What's been installed:"
    log_info "  ✅ Enhanced NetworkManager configuration"
    log_info "  ✅ Wi-Fi interface auto-detection and assignment"
    log_info "  ✅ Hostname conflict prevention system"
    log_info "  ✅ Dual-interface Wi-Fi testing services"
    log_info "  ✅ Heavy traffic generation with roaming"
    log_info "  ✅ Web-based configuration and monitoring"
    echo
    log_info "🔧 Next Steps:"
    log_info "  1. Open http://$dashboard_ip:5000 in your browser"
    log_info "  2. Configure your Wi-Fi network in the Wi-Fi Config tab"
    log_info "  3. Services will start automatically after configuration"
    log_info "  4. Monitor progress in the Status and Logs tabs"
    echo
    log_info "🚀 Service Management:"
    log_info "  Check status: sudo systemctl status wifi-good wifi-bad"
    log_info "  View logs: sudo journalctl -u wifi-good -f"
    log_info "  Run diagnostics: sudo bash $PI_HOME/wifi_test_dashboard/scripts/diagnose-dashboard.sh"
    echo
    log_info "🎊 Your enhanced Wi-Fi testing system is ready!"
    log_info "Installation log saved to: $INSTALL_LOG"
}

# Main execution
main() {
    print_banner
    
    log_info "Starting Wi-Fi Dashboard installation..."
    log_info "Target user: $PI_USER"
    log_info "Installation directory: $PI_HOME/wifi_test_dashboard"
    log_info "Version: $VERSION"
    echo
    
    check_prerequisites
    ensure_fresh_install_state
    main_installation_sequence
    
    if validate_installation; then
        show_final_status
        exit 0
    else
        log_error "Installation validation failed. Check $INSTALL_LOG for details."
        exit 1
    fi
}

# Execute main function
main "$@"