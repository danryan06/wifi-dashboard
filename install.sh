#!/usr/bin/env bash
set -euo pipefail

# Wi-Fi Test Dashboard Installer
# Downloads and installs complete dashboard system from GitHub
# Usage: curl -sSL https://raw.githubusercontent.com/danryan06/wifi-dashboard/main/install.sh | sudo bash

VERSION="v5.0.0"
REPO_URL="https://raw.githubusercontent.com/danryan06/wifi-dashboard/main"
INSTALL_DIR="/tmp/wifi-dashboard-install"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
log_success() { echo -e "${PURPLE}[SUCCESS]${NC} $1"; }

print_banner() {
    echo -e "${BLUE}"
    echo "███████████████████████████████████████████████████████████████████████████████"
    echo "█                                                                             █"
    echo "█  🌐 Wi-Fi Test Dashboard with Advanced Traffic Generation ${VERSION}        █"
    echo "█  🚦 Complete network testing solution for Raspberry Pi                     █"
    echo "█  📡 Speedtest CLI + YouTube Traffic + Interface Control                    █"
    echo "█                                                                             █"
    echo "███████████████████████████████████████████████████████████████████████████████"
    echo -e "${NC}"
}

check_requirements() {
    log_step "Checking system requirements..."
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
    
    # Check if running on Raspberry Pi
    if ! grep -q "Raspberry Pi" /proc/cpuinfo 2>/dev/null; then
        log_warn "This script is designed for Raspberry Pi, but will attempt to continue..."
    fi
    
    # Check internet connectivity
    if ! ping -c 1 google.com >/dev/null 2>&1; then
        log_error "Internet connection required for installation"
        exit 1
    fi
    
    # Detect Pi user
    PI_USER=$(getent passwd 1000 | cut -d: -f1 2>/dev/null || echo "pi")
    PI_HOME="/home/$PI_USER"
    export PI_USER PI_HOME
    
    log_info "✓ System requirements met"
    log_info "✓ Target user: $PI_USER ($PI_HOME)"
}

download_file() {
    local url="$1"
    local destination="$2"
    local description="${3:-file}"
    
    log_info "Downloading $description..."
    
    # Create destination directory if it doesn't exist
    mkdir -p "$(dirname "$destination")"
    
    # Download with error handling
    if curl -sSL --max-time 30 --retry 3 "$url" -o "$destination"; then
        log_info "✓ Downloaded $description"
        return 0
    else
        log_error "✗ Failed to download $description from $url"
        return 1
    fi
}

download_and_execute() {
    local script_path="$1"
    local description="$2"
    local temp_file="${INSTALL_DIR}/$(basename "$script_path")"
    
    log_step "$description"
    
    # Download the script
    if download_file "${REPO_URL}/${script_path}" "$temp_file" "$description"; then
        # Make executable and run
        chmod +x "$temp_file"
        if bash "$temp_file"; then
            log_success "✓ $description completed successfully"
        else
            log_error "✗ $description failed"
            return 1
        fi
    else
        log_error "✗ Could not download $description"
        return 1
    fi
}

create_install_directory() {
    log_step "Setting up installation environment..."
    
    # Clean up any previous installation attempts
    rm -rf "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    
    # Export variables for sub-scripts
    export INSTALL_DIR PI_USER PI_HOME VERSION REPO_URL
    
    log_info "✓ Installation directory created: $INSTALL_DIR"
}

main_installation() {
    log_step "Starting main installation process..."
    
    # Installation steps in order
    local install_steps=(
        "scripts/install/01-dependencies.sh:Installing system dependencies"
        "scripts/install/02-cleanup.sh:Cleaning up previous installations"  
        "scripts/install/03-directories.sh:Creating directory structure"
        "scripts/install/04-flask-app.sh:Installing Flask application"
        "scripts/install/05-templates.sh:Installing web interface templates"
        "scripts/install/06-traffic-scripts.sh:Installing traffic generation scripts"
        "scripts/install/07-services.sh:Configuring system services"
        "scripts/install/08-finalize.sh:Finalizing installation"
    )
    
    local step_num=1
    local total_steps=${#install_steps[@]}
    
    for step in "${install_steps[@]}"; do
        local script_path="${step%:*}"
        local description="${step#*:}"
        
        echo
        log_step "[$step_num/$total_steps] $description"
        
        if download_and_execute "$script_path" "$description"; then
            log_success "Step $step_num completed successfully"
        else
            log_error "Step $step_num failed. Installation cannot continue."
            exit 1
        fi
        
        ((step_num++))
    done
}

verify_installation() {
    log_step "Verifying installation..."
    
    local checks=(
        "Dashboard directory:/home/$PI_USER/wifi_test_dashboard"
        "Flask application:/home/$PI_USER/wifi_test_dashboard/app.py"
        "Dashboard service:/etc/systemd/system/wifi-dashboard.service"
        "Configuration files:/home/$PI_USER/wifi_test_dashboard/configs"
    )
    
    local failed_checks=0
    
    for check in "${checks[@]}"; do
        local description="${check%:*}"
        local path="${check#*:}"
        
        if [[ -e "$path" ]]; then
            log_info "✓ $description: Found"
        else
            log_error "✗ $description: Missing ($path)"
            ((failed_checks++))
        fi
    done
    
    # Check if dashboard service is running
    if systemctl is-active --quiet wifi-dashboard.service; then
        log_info "✓ Dashboard service: Running"
    else
        log_warn "⚠ Dashboard service: Not running (may need manual start)"
    fi
    
    if [[ $failed_checks -eq 0 ]]; then
        log_success "✓ Installation verification passed"
        return 0
    else
        log_error "✗ Installation verification failed ($failed_checks issues)"
        return 1
    fi
}

cleanup_installation() {
    log_step "Cleaning up installation files..."
    rm -rf "$INSTALL_DIR"
    log_info "✓ Installation files cleaned up"
}

print_success_message() {
    local pi_ip
    pi_ip=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "IP_NOT_FOUND")
    
    echo
    echo -e "${GREEN}███████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${GREEN}█                                                                             █${NC}"
    echo -e "${GREEN}█  🎉 INSTALLATION COMPLETE! 🎉                                              █${NC}"
    echo -e "${GREEN}█                                                                             █${NC}"
    echo -e "${GREEN}█  Wi-Fi Test Dashboard ${VERSION} installed successfully!                    █${NC}"
    echo -e "${GREEN}█                                                                             █${NC}"
    echo -e "${GREEN}███████████████████████████████████████████████████████████████████████████████${NC}"
    echo
    log_success "🌐 DASHBOARD ACCESS:"
    log_success "  • Main Dashboard: http://$pi_ip:5000"
    log_success "  • Traffic Control: http://$pi_ip:5000/traffic_control"
    echo
    log_success "🚦 FEATURES INSTALLED:"
    log_success "  ✅ Web-based dashboard with real-time monitoring"
    log_success "  ✅ Speedtest CLI integration for bandwidth testing"
    log_success "  ✅ YouTube traffic simulation capabilities"
    log_success "  ✅ Interface-specific traffic generation (eth0, wlan0, wlan1)"
    log_success "  ✅ Wi-Fi client simulation (good and bad authentication)"
    log_success "  ✅ Network emulation tools (netem)"
    log_success "  ✅ Comprehensive logging and monitoring"
    echo
    log_success "🔧 NEXT STEPS:"
    log_success "  1. Open http://$pi_ip:5000 in your web browser"
    log_success "  2. Configure your SSID and password in the Wi-Fi Config tab"
    log_success "  3. Visit the Traffic Control page to start traffic generation"
    log_success "  4. Monitor system logs for verification"
    echo
    log_success "📚 DOCUMENTATION:"
    log_success "  • GitHub: https://github.com/danryan06/wifi-dashboard"
    log_success "  • Troubleshooting: Check /home/$PI_USER/wifi_test_dashboard/logs/"
    echo
    log_success "📊 MONITORING COMMANDS:"
    log_success "  • Dashboard status: sudo systemctl status wifi-dashboard.service"
    log_success "  • View logs: sudo journalctl -u wifi-dashboard.service -f"
    log_success "  • Traffic services: sudo systemctl status traffic-eth0.service"
    echo
    echo -e "${PURPLE}🎊 Your advanced Wi-Fi testing system is ready!${NC}"
    echo
}

# Error handling
handle_error() {
    local exit_code=$?
    echo
    log_error "Installation failed with exit code $exit_code"
    log_error "Check the output above for details"
    echo
    log_info "For support:"
    log_info "  • Check logs in $INSTALL_DIR if available"
    log_info "  • Visit: https://github.com/danryan06/wifi-dashboard/issues"
    log_info "  • Include your system info and error messages"
    
    cleanup_installation 2>/dev/null || true
    exit $exit_code
}

# Set error trap
trap handle_error ERR

# Main execution
main() {
    print_banner
    check_requirements
    create_install_directory
    main_installation
    
    if verify_installation; then
        cleanup_installation
        print_success_message
    else
        log_error "Installation completed but verification failed"
        log_error "The system may not work correctly"
        exit 1
    fi
}

# Run main function
main "$@"