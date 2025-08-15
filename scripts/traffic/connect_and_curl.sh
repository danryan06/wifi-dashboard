# FIXED: Connect to Wi-Fi network with password preservation
connect_to_wifi() {
    local ssid="$1"
    local password="$2"
    local connection_name="wifi-good-$ssid"
    
    log_msg "Attempting to connect to Wi-Fi: $ssid (interface: $INTERFACE, hostname: $HOSTNAME)"
    
    # Check if connection already exists
    local connection_exists=false
    if nmcli connection show "$connection_name" >/dev/null 2>&1; then
        connection_exists=true
        log_msg "Connection profile '$connection_name' already exists, reusing..."
    else
        log_msg "Creating new connection profile '$connection_name'..."
        
        # Create new WiFi connection ONLY if it doesn't exist
        if nmcli connection add \
            type wifi \
            con-name "$connection_name" \
            ifname "$INTERFACE" \
            ssid "$ssid" \
            wifi-sec.key-mgmt wpa-psk \
            wifi-sec.psk "$password" \
            ipv4.method auto \
            ipv6.method auto \
            ipv4.dhcp-hostname "$HOSTNAME" \
            ipv6.dhcp-hostname "$HOSTNAME"; then
            
            log_msg "✓ Created Wi-Fi connection: $connection_name (interface: $INTERFACE, hostname: $HOSTNAME)"
            connection_exists=true
        else
            log_msg "✗ Failed to create Wi-Fi connection for interface $INTERFACE"
            return 1
        fi
    fi
    
    # Only proceed if we have a valid connection profile
    if [[ "$connection_exists" != "true" ]]; then
        log_msg "✗ No valid connection profile available"
        return 1
    fi
    
    # Attempt to connect with timeout
    log_msg "Connecting to $ssid on $INTERFACE (timeout: ${CONNECTION_TIMEOUT}s)..."
    
    if timeout "$CONNECTION_TIMEOUT" nmcli connection up "$connection_name"; then
        log_msg "✓ Successfully connected to $ssid on $INTERFACE"
        
        # Wait for IP assignment with better error handling
        local wait_count=0
        while [[ $wait_count -lt 15 ]]; do
            local ip_addr=$(ip addr show "$INTERFACE" | grep 'inet ' | awk '{print $2}' | head -n1)
            if [[ -n "$ip_addr" ]]; then
                log_msg "✓ IP address assigned: $ip_addr (hostname: $HOSTNAME)"
                return 0
            fi
            sleep 2
            ((wait_count++))
        done
        
        log_msg "⚠ Connected but no IP address assigned after 30 seconds"
        return 1
    else
        log_msg "✗ Failed to connect to $ssid on $INTERFACE"
        # CRITICAL: DO NOT delete the connection profile here!
        # Keep the password for next retry
        log_msg "Connection profile preserved for next retry"
        return 1
    fi
}

# UPDATED: Main loop with better connection profile management
main_loop() {
    log_msg "Starting Wi-Fi good client simulation (interface: $INTERFACE, hostname: $HOSTNAME)"
    
    local retry_count=0
    local last_config_check=0
    local consecutive_failures=0
    local last_password=""
    
    while true; do
        local current_time=$(date +%s)
        
        # Re-read config periodically (every 5 minutes)
        if [[ $((current_time - last_config_check)) -gt 300 ]]; then
            local old_password="$PASSWORD"
            if read_wifi_config; then
                last_config_check=$current_time
                log_msg "Config refreshed"
                
                # If password changed, delete old connection to force recreation
                if [[ "$PASSWORD" != "$old_password" && -n "$old_password" ]]; then
                    log_msg "Password changed, recreating connection profile..."
                    nmcli connection delete "wifi-good-$SSID" 2>/dev/null || true
                fi
            else
                log_msg "⚠ Config read failed, using previous values"
            fi
        fi
        
        if ! check_wifi_interface; then
            log_msg "✗ Wi-Fi interface $INTERFACE check failed"
            sleep $REFRESH_INTERVAL
            continue
        fi
        
        # Check if we're connected to the right network
        if is_connected_to_ssid "$SSID"; then
            log_msg "✓ Connected to target SSID: $SSID on $INTERFACE"
            get_connection_info
            
            # Test connectivity and generate traffic
            if test_connectivity_and_traffic; then
                retry_count=0
                consecutive_failures=0
                log_msg "✓ Wi-Fi good client operating normally on $INTERFACE"
            else
                ((consecutive_failures++))
                log_msg "✗ Connectivity issues detected on $INTERFACE (failures: $consecutive_failures/$MAX_RETRIES)"
                
                # Only disconnect after multiple failures to avoid unnecessary restarts
                if [[ $consecutive_failures -ge $MAX_RETRIES ]]; then
                    log_msg "Multiple connectivity failures, forcing reconnection on $INTERFACE"
                    # Disconnect but keep the connection profile
                    nmcli device disconnect "$INTERFACE" 2>/dev/null || true
                    sleep 5
                    consecutive_failures=0
                fi
            fi
        else
            log_msg "Not connected to target SSID, attempting connection on $INTERFACE..."
            
            if connect_to_wifi "$SSID" "$PASSWORD"; then
                retry_count=0
                consecutive_failures=0
                log_msg "✓ Successfully established Wi-Fi connection on $INTERFACE"
                sleep 10  # Allow connection to stabilize
            else
                ((retry_count++))
                log_msg "✗ Wi-Fi connection failed on $INTERFACE (attempt $retry_count/$MAX_RETRIES)"
                
                if [[ $retry_count -ge $MAX_RETRIES ]]; then
                    log_msg "Max connection retries reached, waiting longer before retry"
                    # After max retries, consider recreating the connection profile
                    log_msg "Recreating connection profile after max retries..."
                    nmcli connection delete "wifi-good-$SSID" 2>/dev/null || true
                    retry_count=0
                    sleep $((REFRESH_INTERVAL * 2))
                fi
            fi
        fi
        
        sleep $REFRESH_INTERVAL
    done
}

# UPDATED: Cleanup function - only delete on intentional exit
cleanup_and_exit() {
    log_msg "Cleaning up Wi-Fi good client simulation..."
    
    # Disconnect from Wi-Fi but preserve connection profile for next restart
    nmcli device disconnect "$INTERFACE" 2>/dev/null || true
    
    log_msg "Wi-Fi good client simulation stopped"
    exit 0
}

# Signal handlers - safer approach
trap cleanup_and_exit SIGTERM SIGINT

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

# Initial config read
if ! read_wifi_config; then
    log_msg "✗ Failed to read initial configuration, exiting"
    exit 1
fi

# Validate interface assignment
log_msg "Using interface: $INTERFACE for good client simulation"
log_msg "Target hostname: $HOSTNAME"

# Start main loop
main_loop