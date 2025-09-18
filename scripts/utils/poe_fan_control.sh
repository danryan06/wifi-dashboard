#!/bin/bash
# PoE HAT Fan Control Configuration Script
# Configures fan temperature thresholds for quieter demo operation

set -e

LOG_PREFIX="[POE-FAN]"
CONFIG_FILE="/boot/config.txt"
BACKUP_FILE="/boot/config.txt.backup.$(date +%Y%m%d_%H%M%S)"

log_msg() {
    echo "$LOG_PREFIX $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (use sudo)"
    exit 1
fi

# Check if PoE HAT is detected
if ! dmesg | grep -q "rpi-poe-fan"; then
    log_msg "WARNING: PoE HAT fan not detected. Script will still configure settings."
fi

log_msg "Configuring PoE HAT fan for demo-friendly operation..."

# Create backup
cp "$CONFIG_FILE" "$BACKUP_FILE"
log_msg "Backup created: $BACKUP_FILE"

# Remove any existing PoE fan settings
sed -i '/^dtparam=poe_fan_temp/d' "$CONFIG_FILE"

# Add optimized fan settings for demo environments
cat >> "$CONFIG_FILE" << 'EOF'

# PoE HAT Fan Control - Demo Optimized Settings
# Higher temperature thresholds for quieter operation during presentations
dtparam=poe_fan_temp0=70000  # Start fan at 70°C (default: 60°C)
dtparam=poe_fan_temp1=75000  # Increase speed at 75°C (default: 65°C)  
dtparam=poe_fan_temp2=80000  # Higher speed at 80°C (default: 70°C)
dtparam=poe_fan_temp3=85000  # Max speed at 85°C (default: 75°C)

EOF

log_msg "Fan temperature thresholds configured:"
log_msg "  - Fan starts: 70°C (was 60°C)"
log_msg "  - Speed level 1: 75°C (was 65°C)"
log_msg "  - Speed level 2: 80°C (was 70°C)"
log_msg "  - Max speed: 85°C (was 75°C)"

# Verify configuration was added
if grep -q "dtparam=poe_fan_temp0" "$CONFIG_FILE"; then
    log_msg "✅ Fan configuration successfully added to $CONFIG_FILE"
else
    log_msg "❌ Failed to add fan configuration"
    exit 1
fi

# Create thermal monitoring script
cat > /usr/local/bin/thermal_monitor.sh << 'EOF'
#!/bin/bash
# Simple thermal monitoring for PoE HAT
TEMP=$(cat /sys/class/thermal/thermal_zone0/temp)
TEMP_C=$((TEMP / 1000))
FAN_STATE=$(cat /sys/class/thermal/cooling_device0/cur_state 2>/dev/null || echo "N/A")

echo "[$(date '+%Y-%m-%d %H:%M:%S')] CPU: ${TEMP_C}°C | Fan: Level $FAN_STATE"

# Log warning if temperature is high
if (( TEMP_C > 75 )); then
    echo "WARNING: High temperature detected: ${TEMP_C}°C"
fi
EOF

chmod +x /usr/local/bin/thermal_monitor.sh
log_msg "Created thermal monitoring script: /usr/local/bin/thermal_monitor.sh"

# Optional: Create systemd service for thermal monitoring
cat > /etc/systemd/system/thermal-monitor.service << 'EOF'
[Unit]
Description=Thermal Monitor for PoE HAT
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/thermal_monitor.sh
User=root

[Install]
WantedBy=multi-user.target
EOF

# Create timer for periodic monitoring
cat > /etc/systemd/system/thermal-monitor.timer << 'EOF'
[Unit]
Description=Run thermal monitor every 5 minutes
Requires=thermal-monitor.service

[Timer]
OnCalendar=*:0/5
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable thermal-monitor.timer
systemctl start thermal-monitor.timer

log_msg "✅ Thermal monitoring service installed and started"

# Function to restore defaults if needed
cat > /usr/local/bin/restore_poe_fan_defaults.sh << 'EOF'
#!/bin/bash
# Restore PoE HAT fan to default settings
sed -i '/^dtparam=poe_fan_temp/d' /boot/config.txt
cat >> /boot/config.txt << 'EOL'

# PoE HAT Fan Control - Default Settings
dtparam=poe_fan_temp0=60000
dtparam=poe_fan_temp1=65000
dtparam=poe_fan_temp2=70000
dtparam=poe_fan_temp3=75000

EOL
echo "PoE HAT fan settings restored to defaults. Reboot required."
EOF

chmod +x /usr/local/bin/restore_poe_fan_defaults.sh
log_msg "Created restore script: /usr/local/bin/restore_poe_fan_defaults.sh"

log_msg ""
log_msg "🔥 IMPORTANT NOTES:"
log_msg "  • Changes take effect after reboot"
log_msg "  • Monitor temperatures during extended demos"
log_msg "  • Run 'sudo /usr/local/bin/thermal_monitor.sh' to check current temp"
log_msg "  • Use 'sudo /usr/local/bin/restore_poe_fan_defaults.sh' to restore defaults"
log_msg "  • Reboot required: sudo reboot"
log_msg ""

# Prompt for immediate reboot
read -p "Reboot now to apply fan settings? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    log_msg "Rebooting in 5 seconds..."
    sleep 5
    reboot
else
    log_msg "Remember to reboot when convenient: sudo reboot"
fi