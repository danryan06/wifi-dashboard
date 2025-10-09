#!/usr/bin/env bash
set -euo pipefail

# Wi-Fi Dashboard Diagnostic Script
# Identifies issues with services and provides recommendations

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[CHECK]${NC} $1"; }

PI_USER=$(getent passwd 1000 | cut -d: -f1 2>/dev/null || echo "pi")
PI_HOME="/home/$PI_USER"
DASHBOARD_DIR="$PI_HOME/wifi_test_dashboard"

print_banner() {
    echo -e "${BLUE}"
    echo "=================================================================="
    echo "  🔍 Wi-Fi Dashboard Diagnostic Tool"
    echo "  📋 Checking system status and identifying issues"
    echo "=================================================================="
    echo -e "${NC}"
}

check_directory_structure() {
    log_step "Checking directory structure..."
    
    local required_dirs=(
        "$DASHBOARD_DIR"
        "$DASHBOARD_DIR/scripts"
        "$DASHBOARD_DIR/configs"
        "$DASHBOARD_DIR/logs"
        "$DASHBOARD_DIR/templates"
    )
    
    for dir in "${required_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            log_info "✓ Directory exists: $dir"
        else
            log_error "✗ Missing directory: $dir"
        fi
    done
}

check_required_files() {
    log_step "Checking required files..."
    
    local required_files=(
        "$DASHBOARD_DIR/app.py:Flask application"
        "$DASHBOARD_DIR/configs/ssid.conf:SSID configuration"
        "$DASHBOARD_DIR/configs/settings.conf:System settings"
        "$DASHBOARD_DIR/scripts/traffic/wired_simulation.sh:Wired client script"
        "$DASHBOARD_DIR/scripts/traffic/connect_and_curl.sh:Wi-Fi good client"
        "$DASHBOARD_DIR/scripts/traffic/fail_auth_loop.sh:Wi-Fi bad client"
        "$DASHBOARD_DIR/scripts/traffic/interface_traffic_generator.sh:Traffic generator"
    )
    
    for file_desc in "${required_files[@]}"; do
        local file="${file_desc%:*}"
        local desc="${file_desc#*:}"
        
        if [[ -f "$file" ]]; then
            if [[ -x "$file" && "$file" == *.sh ]]; then
                log_info "✓ $desc: exists and executable"
            elif [[ "$file" == *.sh ]]; then
                log_warn "⚠ $desc: exists but not executable"
            else
                log_info "✓ $desc: exists"
            fi
        else
            log_error "✗ $desc: missing ($file)"
        fi
    done
}

check_service_status() {
    log_step "Checking service status..."
    
    local services=(
        "wifi-dashboard:Main dashboard"
        "wired-test:Wired client simulation" 
        "wifi-good:Wi-Fi good client"
        "wifi-bad:Wi-Fi bad client"
        "traffic-eth0:Ethernet traffic"
        "traffic-wlan0:Wi-Fi 1 traffic"
        "traffic-wlan1:Wi-Fi 2 traffic"
    )
    
    for service_desc in "${services[@]}"; do
        local service="${service_desc%:*}"
        local desc="${service_desc#*:}"
        
        if systemctl is-enabled --quiet "${service}.service" 2>/dev/null; then
            if systemctl is-active --quiet "${service}.service"; then
                log_info "✓ $desc ($service): enabled and running"
            elif systemctl is-failed --quiet "${service}.service"; then
                log_error "✗ $desc ($service): enabled but failed"
            else
                log_warn "⚠ $desc ($service): enabled but activating/inactive"
            fi
        else
            log_error "✗ $desc ($service): not enabled"
        fi
    done
}

check_network_interfaces() {
    log_step "Checking network interfaces..."
    
    local interfaces=("eth0" "wlan0" "wlan1")
    
    for iface in "${interfaces[@]}"; do
        if ip link show "$iface" >/dev/null 2>&1; then
            local state=$(ip link show "$iface" | grep -o "state [A-Z]*" | awk '{print $2}')
            local ip_addr=$(ip addr show "$iface" | grep 'inet ' | awk '{print $2}' | head -n1)
            
            if [[ "$state" == "UP" ]]; then
                if [[ -n "$ip_addr" ]]; then
                    log_info "✓ Interface $iface: UP with IP $ip_addr"
                else
                    log_warn "⚠ Interface $iface: UP but no IP address"
                fi
            else
                log_warn "⚠ Interface $iface: $state"
            fi
        else
            log_error "✗ Interface $iface: not found"
        fi
    done
}

check_dependencies() {
    log_step "Checking software dependencies..."
    
    local required_commands=(
        "python3:Python 3"
        "pip3:Python package manager"
        "nmcli:NetworkManager CLI"
        "curl:HTTP client"
        "systemctl:System control"
    )
    
    local optional_commands=(
        "speedtest:Official Speedtest CLI"
        "speedtest-cli:Python Speedtest CLI"
        "yt-dlp:YouTube downloader"
        "youtube-dl:YouTube downloader (fallback)"
    )
    
    for cmd_desc in "${required_commands[@]}"; do
        local cmd="${cmd_desc%:*}"
        local desc="${cmd_desc#*:}"
        
        if command -v "$cmd" >/dev/null 2>&1; then
            log_info "✓ $desc ($cmd): available"
        else
            log_error "✗ $desc ($cmd): missing"
        fi
    done
    
    for cmd_desc in "${optional_commands[@]}"; do
        local cmd="${cmd_desc%:*}"
        local desc="${cmd_desc#*:}"
        
        if command -v "$cmd" >/dev/null 2>&1; then
            log_info "✓ $desc ($cmd): available"
        else
            log_warn "⚠ $desc ($cmd): missing (optional)"
        fi
    done
}

check_logs() {
    log_step "Checking recent log entries..."
    
    local log_files=(
        "$DASHBOARD_DIR/logs/main.log"
        "$DASHBOARD_DIR/logs/wired.log"
        "$DASHBOARD_DIR/logs/wifi-good.log"
        "$DASHBOARD_DIR/logs/wifi-bad.log"
    )
    
    for log_file in "${log_files[@]}"; do
        if [[ -f "$log_file" ]]; then
            local last_entry=$(tail -n 1 "$log_file" 2>/dev/null || echo "")
            if [[ -n "$last_entry" ]]; then
                log_info "✓ $(basename "$log_file"): has recent entries"
            else
                log_warn "⚠ $(basename "$log_file"): empty or no recent entries"
            fi
        else
            log_warn "⚠ $(basename "$log_file"): missing"
        fi
    done
}

show_service_errors() {
    log_step "Showing recent service errors..."
    
    local services=("wired-test" "wifi-good" "wifi-bad" "traffic-eth0" "traffic-wlan0" "traffic-wlan1")
    
    for service in "${services[@]}"; do
        if systemctl is-failed --quiet "${service}.service" 2>/dev/null; then
            echo -e "${RED}--- ${service}.service errors ---${NC}"
            journalctl -u "${service}.service" --no-pager -n 5 2>/dev/null || echo "No journal entries"
            echo
        fi
    done
}

check_configuration() {
    log_step "Checking configuration..."
    
    if [[ -f "$DASHBOARD_DIR/configs/ssid.conf" ]]; then
        local line_count=$(wc -l < "$DASHBOARD_DIR/configs/ssid.conf")
        if [[ $line_count -ge 2 ]]; then
            local ssid=$(head -n 1 "$DASHBOARD_DIR/configs/ssid.conf")
            log_info "✓ SSID configuration: configured for '$ssid'"
        else
            log_warn "⚠ SSID configuration: incomplete (need SSID and password)"
        fi
    else
        log_error "✗ SSID configuration: missing"
    fi
    
    if [[ -f "$DASHBOARD_DIR/configs/settings.conf" ]]; then
        log_info "✓ System settings: exists"
        
        # Check for YouTube configuration
        if grep -q "ENABLE_YOUTUBE_TRAFFIC" "$DASHBOARD_DIR/configs/settings.conf"; then
            log_info "✓ YouTube traffic: configured"
        else
            log_warn "⚠ YouTube traffic: not configured"
        fi
    else
        log_warn "⚠ System settings: missing"
    fi
}

provide_recommendations() {
    echo
    echo -e "${BLUE}=================================================================="
    echo "  💡 RECOMMENDATIONS"
    echo "=================================================================="
    echo -e "${NC}"
    
    # Check what's wrong and provide specific recommendations
    local issues_found=false
    
    # Check for missing scripts
    if [[ ! -f "$DASHBOARD_DIR/scripts/wired_simulation.sh" ]] || \
       [[ ! -f "$DASHBOARD_DIR/scripts/connect_and_curl.sh" ]] || \
       [[ ! -f "$DASHBOARD_DIR/scripts/fail_auth_loop.sh" ]]; then
        echo -e "${YELLOW}🔧 Missing traffic generation scripts detected${NC}"
        echo "   Run the fix script to create missing scripts:"
        echo "   sudo bash fix-services.sh"
        echo
        issues_found=true
    fi
    
    # Check for services in activating state
    local activating_services=()
    local services=("wired-test" "wifi-good" "wifi-bad" "traffic-eth0" "traffic-wlan0" "traffic-wlan1")
    
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "${service}.service" 2>/dev/null; then
            continue
        elif systemctl status "${service}.service" 2>/dev/null | grep -q "activating"; then
            activating_services+=("$service")
        fi
    done
    
    if [[ ${#activating_services[@]} -gt 0 ]]; then
        echo -e "${YELLOW}⏳ Services stuck in 'activating' state:${NC}"
        for service in "${activating_services[@]}"; do
            echo "   - $service"
        done
        echo "   Try restarting these services:"
        for service in "${activating_services[@]}"; do
            echo "   sudo systemctl restart ${service}.service"
        done
        echo
        issues_found=true
    fi
    
    # Check for missing YouTube tools
    if ! command -v yt-dlp >/dev/null 2>&1 && ! command -v youtube-dl >/dev/null 2>&1; then
        echo -e "${YELLOW}📺 YouTube traffic simulation unavailable${NC}"
        echo "   Install yt-dlp for YouTube traffic generation:"
        echo "   sudo pip3 install yt-dlp --break-system-packages"
        echo
        issues_found=true
    fi
    
    # Check for speedtest tools
    if ! command -v speedtest >/dev/null 2>&1 && ! command -v speedtest-cli >/dev/null 2>&1; then
        echo -e "${YELLOW}⚡ Speedtest tools missing${NC}"
        echo "   Install speedtest tools:"
        echo "   sudo pip3 install speedtest-cli --break-system-packages"
        echo
        issues_found=true
    fi
    
    # Check SSID configuration
    if [[ ! -f "$DASHBOARD_DIR/configs/ssid.conf" ]] || [[ $(wc -l < "$DASHBOARD_DIR/configs/ssid.conf") -lt 2 ]]; then
        echo -e "${YELLOW}📶 Wi-Fi not configured${NC}"
        echo "   Configure your SSID and password:"
        echo "   1. Open http://$(hostname -I | awk '{print $1}'):5000"
        echo "   2. Go to Wi-Fi Config tab"
        echo "   3. Enter your SSID and password"
        echo
        issues_found=true
    fi
    
    # Check interface availability
    local missing_interfaces=()
    for iface in "wlan0" "wlan1"; do
        if ! ip link show "$iface" >/dev/null 2>&1; then
            missing_interfaces+=("$iface")
        fi
    done
    
    if [[ ${#missing_interfaces[@]} -gt 0 ]]; then
        echo -e "${YELLOW}📡 Missing Wi-Fi interfaces:${NC}"
        for iface in "${missing_interfaces[@]}"; do
            echo "   - $iface"
        done
        echo "   You may need additional USB Wi-Fi adapters"
        echo "   Or configure NetworkManager to manage these interfaces:"
        for iface in "${missing_interfaces[@]}"; do
            echo "   sudo nmcli device set $iface managed yes"
        done
        echo
        issues_found=true
    fi
    
    if [[ "$issues_found" == "false" ]]; then
        echo -e "${GREEN}✅ No major issues detected!${NC}"
        echo "   Your Wi-Fi Dashboard appears to be working correctly."
        echo "   Monitor services with: sudo systemctl status wifi-dashboard.service"
        echo
    fi
    
    echo -e "${BLUE}📋 Useful Commands:${NC}"
    echo "   View dashboard: http://$(hostname -I | awk '{print $1}'):5000"
    echo "   Check service status: sudo systemctl status wifi-good.service"
    echo "   View live logs: sudo journalctl -u wifi-good.service -f"
    echo "   Restart services: sudo systemctl restart wifi-good.service"
    echo "   Run full fix: sudo bash fix-services.sh"
}

generate_fix_script() {
    local fix_script="/tmp/fix-services.sh"
    
    log_step "Generating fix script..."
    
    cat > "$fix_script" << 'FIX_SCRIPT_EOF'
#!/usr/bin/env bash
# Quick fix for common Wi-Fi Dashboard issues

set -euo pipefail

PI_USER=$(getent passwd 1000 | cut -d: -f1 2>/dev/null || echo "pi")
PI_HOME="/home/$PI_USER"
DASHBOARD_DIR="$PI_HOME/wifi_test_dashboard"

echo "🔧 Quick Fix for Wi-Fi Dashboard Services"
echo "==========================================="

# Create missing directories
mkdir -p "$DASHBOARD_DIR"/{scripts,configs,logs,templates}

# Fix permissions
chown -R "$PI_USER:$PI_USER" "$DASHBOARD_DIR"
find "$DASHBOARD_DIR" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

# Install missing Python packages
pip3 install flask requests --break-system-packages >/dev/null 2>&1 || true
pip3 install yt-dlp --break-system-packages >/dev/null 2>&1 || true
pip3 install speedtest-cli --break-system-packages >/dev/null 2>&1 || true

# Restart services with delays
services=("wifi-dashboard" "wired-test" "wifi-good" "wifi-bad" "traffic-eth0" "traffic-wlan0" "traffic-wlan1")

echo "Restarting services..."
for service in "${services[@]}"; do
    if systemctl is-enabled --quiet "${service}.service" 2>/dev/null; then
        echo "  Restarting $service..."
        systemctl restart "${service}.service" || true
        sleep 2
    fi
done

echo "✅ Quick fix completed!"
echo "Check status at: http://$(hostname -I | awk '{print $1}'):5000"
FIX_SCRIPT_EOF

    chmod +x "$fix_script"
    
    log_info "✓ Fix script generated: $fix_script"
    echo "   Run with: sudo bash $fix_script"
}

main() {
    print_banner
    check_directory_structure
    check_required_files
    check_service_status
    check_network_interfaces
    check_dependencies
    check_configuration
    check_logs
    show_service_errors
    provide_recommendations
    generate_fix_script
    
    echo
    echo -e "${GREEN}🎊 Diagnostic complete!${NC}"
    echo "Review the recommendations above to fix any issues."
}

main "$@"