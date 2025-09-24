#!/usr/bin/env bash
# scripts/install/05-templates.sh
# Download and install web interface templates

set -euo pipefail

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }

log_info "Installing web interface templates..."

# Create templates directory
mkdir -p "$PI_HOME/wifi_test_dashboard/templates"

# Download templates with fallback creation
log_info "Installing dashboard template..."
if curl -sSL --max-time 30 --retry 3 "${REPO_URL}/templates/dashboard.html" -o "$PI_HOME/wifi_test_dashboard/templates/dashboard.html"; then
    log_info "✓ Downloaded dashboard.html"
else
    log_warn "✗ Failed to download dashboard.html, creating locally..."
    
    # Create dashboard template locally
    cat > "$PI_HOME/wifi_test_dashboard/templates/dashboard.html" <<'DASHBOARD_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8"/>
    <title>Wi-Fi Test Dashboard v5.0</title>
    <meta name="viewport" content="width=device-width,initial-scale=1"/>
    <style>
        :root {
            --bg: #0f1014;
            --card: #1e2230;
            --fg: #e8e8e8;
            --muted: #777;
            --accent: #4caf50;
            --warning: #ff9800;
            --error: #f44336;
            --success: #4caf50;
            --info: #2196f3;
            --border: rgba(255,255,255,0.1);
        }
        
        * { box-sizing: border-box; }
        
        body {
            margin: 0; 
            background: var(--bg); 
            color: var(--fg);
            font-family: system-ui, -apple-system, BlinkMacSystemFont, sans-serif; 
            line-height: 1.5;
        }
        
        .topbar {
            display: flex; 
            align-items: center; 
            padding: 12px 16px;
            border-bottom: 1px solid var(--border); 
            background: rgba(0,0,0,0.2);
        }
        
        .logo { 
            font-weight: bold; 
            font-size: 1.1em; 
            margin-right: 24px; 
            color: var(--accent);
        }
        
        .tabs { 
            display: flex; 
            gap: 8px; 
            flex: 1; 
        }
        
        .tab {
            padding: 8px 16px; 
            cursor: pointer; 
            border-radius: 6px;
            background: rgba(255,255,255,0.05); 
            transition: all 0.2s ease;
            border: 1px solid transparent;
        }
        
        .tab:hover { 
            background: rgba(255,255,255,0.1); 
            border-color: var(--accent);
        }
        
        .tab.active { 
            background: var(--accent); 
            color: #fff; 
        }
        
        .status-pill {
            padding: 6px 12px; 
            border-radius: 999px; 
            background: rgba(255,255,255,0.1);
            font-size: 0.9em; 
            margin-left: 16px;
        }
        
        .content { 
            padding: 20px; 
            max-width: 1400px; 
            margin: 0 auto; 
        }
        
        .card {
            background: var(--card); 
            border-radius: 12px; 
            padding: 24px; 
            margin-bottom: 24px;
            border: 1px solid var(--border); 
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
        }
        
        .card h2 { 
            margin-top: 0; 
            margin-bottom: 20px; 
            color: var(--accent); 
            font-size: 1.4em;
            display: flex;
            align-items: center;
            gap: 8px;
        }
        
        .form-group { 
            margin-bottom: 20px; 
        }
        
        .form-group label { 
            display: block; 
            margin-bottom: 8px; 
            font-weight: 500; 
            color: var(--fg);
        }
        
        input, select, textarea {
            width: 100%; 
            padding: 12px 16px; 
            border: 1px solid var(--border);
            border-radius: 8px; 
            background: #0f172a; 
            color: #fff; 
            font-size: 14px;
            transition: border-color 0.2s ease;
        }
        
        input:focus, select:focus, textarea:focus {
            outline: none;
            border-color: var(--accent);
        }
        
        button {
            padding: 12px 20px; 
            border: none; 
            border-radius: 8px; 
            background: var(--accent);
            color: #fff; 
            cursor: pointer; 
            font-weight: 500; 
            margin: 4px;
            transition: all 0.2s ease;
            display: inline-flex;
            align-items: center;
            gap: 8px;
        }
        
        button:hover { 
            background: #45a049; 
            transform: translateY(-1px);
        }
        
        button.secondary { 
            background: #666; 
        }
        
        button.secondary:hover { 
            background: #777; 
        }
        
        button.danger { 
            background: var(--error); 
        }
        
        button.danger:hover { 
            background: #d32f2f; 
        }
        
        .status-grid {
            display: grid; 
            grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
            gap: 20px; 
            margin-bottom: 24px;
        }
        
        .status-item {
            background: rgba(255,255,255,0.05); 
            padding: 20px; 
            border-radius: 12px;
            border-left: 4px solid var(--accent);
            transition: all 0.2s ease;
        }
        
        .status-item:hover {
            background: rgba(255,255,255,0.08);
        }
        
        .status-item h3 {
            margin: 0 0 12px 0; 
            font-size: 0.9em; 
            color: var(--muted);
            text-transform: uppercase; 
            letter-spacing: 0.5px;
        }
        
        .status-value { 
            font-size: 1.2em; 
            font-weight: 600; 
            color: var(--fg);
        }
        
        pre {
            background: #0a0f1f; 
            padding: 16px; 
            border-radius: 8px; 
            overflow: auto;
            max-height: 300px; 
            font-size: 13px; 
            border: 1px solid var(--border);
            font-family: 'JetBrains Mono', 'Fira Code', 'Courier New', monospace;
        }
        
        .log-container {
            max-height: 500px; 
            overflow-y: auto; 
            border: 1px solid var(--border);
            border-radius: 12px; 
            background: #0a0f1f;
        }
        
        .log-tabs {
            display: flex;
            background: rgba(255,255,255,0.05);
            border-bottom: 1px solid var(--border);
        }
        
        .log-tab {
            display: inline-block; 
            padding: 12px 16px; 
            background: transparent;
            border: none; 
            color: var(--muted); 
            cursor: pointer; 
            margin: 0;
            transition: all 0.2s ease;
            border-bottom: 2px solid transparent;
        }
        
        .log-tab:hover {
            background: rgba(255,255,255,0.1);
            color: var(--fg);
        }
        
        .log-tab.active { 
            background: var(--accent); 
            color: white;
            border-bottom-color: var(--accent);
        }
        
        .log-content {
            padding: 16px; 
            white-space: pre-wrap; 
            font-family: 'JetBrains Mono', 'Fira Code', 'Courier New', monospace;
            font-size: 12px; 
            line-height: 1.5;
            color: var(--fg);
        }
        
        .service-controls {
            display: grid; 
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); 
            gap: 20px;
        }
        
        .service-item {
            background: rgba(255,255,255,0.05); 
            padding: 20px; 
            border-radius: 12px; 
            text-align: center;
            border: 1px solid var(--border);
            transition: all 0.2s ease;
        }
        
        .service-item:hover {
            background: rgba(255,255,255,0.08);
            transform: translateY(-2px);
        }
        
        .service-name {
            font-size: 1.1em;
            font-weight: 600;
            margin-bottom: 12px;
            color: var(--fg);
        }
        
        .service-status {
            display: inline-block; 
            padding: 6px 12px; 
            border-radius: 20px;
            font-size: 0.85em; 
            font-weight: 600; 
            margin-bottom: 16px;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }
        
        .service-status.active { 
            background: var(--success); 
            color: white; 
        }
        
        .service-status.inactive { 
            background: var(--error); 
            color: white; 
        }
        
        .service-status.unknown { 
            background: var(--warning); 
            color: black; 
        }
        
        .service-buttons {
            display: flex;
            gap: 8px;
            flex-wrap: wrap;
            justify-content: center;
        }
        
        .service-buttons button {
            font-size: 0.8em;
            padding: 8px 12px;
            margin: 2px;
        }
        
        .flash-messages { 
            position: fixed; 
            top: 20px; 
            right: 20px; 
            z-index: 1000; 
            max-width: 400px; 
        }
        
        .flash-message {
            padding: 16px 20px; 
            margin-bottom: 12px; 
            border-radius: 8px; 
            border-left: 4px solid;
            background: rgba(0,0,0,0.95); 
            color: white; 
            animation: slideIn 0.3s ease;
            box-shadow: 0 4px 12px rgba(0,0,0,0.3);
        }
        
        .flash-message.success { 
            border-left-color: var(--success); 
        }
        
        .flash-message.error { 
            border-left-color: var(--error); 
        }
        
        .flash-message.warning { 
            border-left-color: var(--warning); 
        }
        
        .flash-message.info { 
            border-left-color: var(--info); 
        }
        
        @keyframes slideIn { 
            from { 
                transform: translateX(100%); 
                opacity: 0; 
            } 
            to { 
                transform: translateX(0); 
                opacity: 1; 
            } 
        }
        
        .hidden { 
            display: none !important; 
        }
        
        .spinner {
            display: inline-block; 
            width: 16px; 
            height: 16px; 
            border: 2px solid rgba(255,255,255,0.3);
            border-radius: 50%; 
            border-top-color: var(--accent); 
            animation: spin 1s ease-in-out infinite;
        }
        
        @keyframes spin { 
            to { 
                transform: rotate(360deg); 
            } 
        }
        
        .two-column {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 20px;
        }
        
        @media (max-width: 768px) {
            .two-column {
                grid-template-columns: 1fr;
            }
            
            .tabs {
                flex-wrap: wrap;
            }
            
            .content {
                padding: 16px;
            }
        }
        
        .network-info {
            background: rgba(255,255,255,0.03);
            padding: 16px;
            border-radius: 8px;
            margin-bottom: 16px;
        }
        
        .network-info h4 {
            margin: 0 0 12px 0;
            color: var(--accent);
            font-size: 1em;
        }
        
        .interface-list {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 12px;
        }
        
        .interface-item {
            background: rgba(255,255,255,0.05);
            padding: 12px;
            border-radius: 6px;
            font-size: 0.9em;
        }
        
        .interface-name {
            font-weight: 600;
            color: var(--accent);
            margin-bottom: 4px;
        }
        
        .interface-ip {
            color: var(--muted);
            font-family: monospace;
        }
    </style>
</head>
<body>
    <div class="topbar">
        <div class="logo">🌐 Wi-Fi Test Dashboard v5.0</div>
        <div class="tabs">
            <div class="tab active" data-tab="status">📊 Status</div>
            <div class="tab" data-tab="wifi">📶 Wi-Fi Config</div>
            <div class="tab" data-tab="netem">🌐 Network Emulation</div>
            <div class="tab" data-tab="services">⚙️ Services</div>
            <div class="tab" data-tab="logs">📋 Logs</div>
            <div class="tab" data-tab="controls">🔧 System</div>
        </div>
        <div class="status-pill" id="status-pill"><span class="spinner"></span> Loading...</div>
    </div>

    <div class="flash-messages" id="flash-messages">
        {% with messages = get_flashed_messages(with_categories=true) %}
            {% if messages %}
                {% for category, message in messages %}
                    <div class="flash-message {{ category }}">{{ message }}</div>
                {% endfor %}
            {% endif %}
        {% endwith %}
    </div>

    <div class="content">
        <!-- Status Tab -->
        <div id="status" class="card">
            <h2>📊 System Status</h2>
            <div class="status-grid">
                <div class="status-item">
                    <h3>Current SSID</h3>
                    <div class="status-value" id="current-ssid">Loading...</div>
                </div>
                <div class="status-item">
                    <h3>Primary IP Address</h3>
                    <div class="status-value" id="ip-address">Loading...</div>
                </div>
                <div class="status-item">
                    <h3>System Time</h3>
                    <div class="status-value" id="system-time">Loading...</div>
                </div>
                <div class="status-item">
                    <h3>Active Services</h3>
                    <div class="status-value" id="active-services">Loading...</div>
                </div>
            </div>
            
            <div class="network-info">
                <h4>📊 Real-Time Throughput</h4>
                <div class="throughput-grid" id="throughput-grid">Loading...</div>
            </div>
            
            <div class="two-column">
                <div>
                    <h3>Active Connections</h3>
                    <pre id="active-connections">Loading...</pre>
                </div>
                <div>
                    <h3>Network Emulation Status</h3>
                    <pre id="netem-status">Loading...</pre>
                </div>
            </div>
        </div>

        <!-- Wi-Fi Config Tab -->
        <div id="wifi" class="card hidden">
            <h2>📶 Wi-Fi Configuration</h2>
            <form method="POST" action="/update_wifi">
                <div class="form-group">
                    <label for="ssid">🏷️ SSID (Network Name)</label>
                    <input id="ssid" name="ssid" type="text" placeholder="Enter Wi-Fi network name" required>
                    <small style="color: var(--muted); font-size: 0.85em;">This will be used for both good and bad client simulations</small>
                </div>
                <div class="form-group">
                    <label for="password">🔐 Password</label>
                    <input id="password" name="password" type="password" placeholder="Enter Wi-Fi password" required>
                    <small style="color: var(--muted); font-size: 0.85em;">Used only for successful authentication testing</small>
                </div>
                <button type="submit">💾 Save Configuration</button>
                <button type="button" onclick="testConnection()" class="secondary">🔍 Test Connection</button>
            </form>
        </div>

        <!-- Network Emulation Tab -->
        <div id="netem" class="card hidden">
            <h2>🌐 Network Emulation (Netem)</h2>
            <p style="color: var(--muted); margin-bottom: 24px;">
                Simulate real-world network conditions for testing. Changes apply to wlan0 interface.
            </p>
            <form method="POST" action="/set_netem">
                <div class="two-column">
                    <div class="form-group">
                        <label>⏱️ Latency (milliseconds)</label>
                        <input name="latency" type="number" min="0" max="5000" placeholder="0" id="latency-input">
                        <small style="color: var(--muted); font-size: 0.85em;">Add delay to simulate distance/processing time</small>
                    </div>
                    <div class="form-group">
                        <label>📉 Packet Loss (%)</label>
                        <input name="loss" type="number" step="0.1" min="0" max="100" placeholder="0.0" id="loss-input">
                        <small style="color: var(--muted); font-size: 0.85em;">Simulate unreliable connections</small>
                    </div>
                </div>
                <button type="submit">🌐 Apply Network Conditions</button>
                <button type="button" onclick="clearNetem()" class="secondary">🗑️ Clear All Conditions</button>
                <button type="button" onclick="presetNetem('poor')" class="secondary">📶 Poor Connection</button>
                <button type="button" onclick="presetNetem('mobile')" class="secondary">📱 Mobile Network</button>
            </form>
        </div>

        <!-- Services Tab -->
        <div id="services" class="card hidden">
            <h2>⚙️ Service Management</h2>
            <p style="color: var(--muted); margin-bottom: 24px;">
                Control individual testing services. Changes take effect immediately.
            </p>
            <div class="service-controls" id="service-controls">Loading...</div>
        </div>

        <!-- Logs Tab -->
        <div id="logs" class="card hidden">
            <h2>📋 System Logs</h2>
            <div class="log-container">
                <div class="log-tabs">
                    <button class="log-tab active" data-log="main">📄 Main</button>
                    <button class="log-tab" data-log="wired">🔌 Wired</button>
                    <button class="log-tab" data-log="wifi-good">✅ Wi-Fi Good</button>
                    <button class="log-tab" data-log="wifi-bad">❌ Wi-Fi Bad</button>
                </div>
                <div class="log-content" id="log-content">Loading logs...</div>
            </div>
            <button onclick="refreshLogs()" class="secondary" style="margin-top: 16px;">🔄 Refresh Logs</button>
            <button onclick="downloadLogs()" class="secondary">💾 Download All Logs</button>
        </div>

        <!-- System Controls Tab -->
        <div id="controls" class="card hidden">
            <h2>🔧 System Controls</h2>
            <p style="color: var(--muted); margin-bottom: 24px;">
                ⚠️ These actions will immediately affect the system. Use with caution.
            </p>
            <div style="display: flex; gap: 16px; flex-wrap: wrap;">
                <button onclick="confirmReboot()" class="secondary">🔄 Reboot System</button>
                <button onclick="confirmShutdown()" class="danger">⏻ Shutdown System</button>
                <button onclick="restartNetworking()" class="secondary">🌐 Restart Networking</button>
                <button onclick="restartAllServices()" class="secondary">⚙️ Restart All Services</button>
            </div>
        </div>
    </div>

    <script>
        let currentData = {};
        let refreshInterval;
        
        // Tab switching
        document.querySelectorAll(".tab").forEach(tab => {
            tab.onclick = () => switchTab(tab.dataset.tab);
        });
        
        function switchTab(tabName) {
            document.querySelectorAll(".tab").forEach(t => t.classList.remove("active"));
            document.querySelector(`[data-tab="${tabName}"]`).classList.add("active");
            const sections = ["status", "wifi", "netem", "services", "logs", "controls"];
            sections.forEach(section => {
                document.getElementById(section).classList.toggle("hidden", section !== tabName);
            });
        }
        
        // FIXED: Real-time throughput monitoring
        function updateThroughputDisplay(throughputData) {
            const container = document.getElementById('throughput-grid');
            if (!container) return;

            let html = '';
            
            // Filter out loopback and virtual interfaces  
            const filteredInterfaces = Object.keys(throughputData).filter(iface => 
                !iface.includes('lo') && !iface.includes('docker') && !iface.includes('veth')
            );

            if (filteredInterfaces.length === 0) {
                html = '<div class="throughput-item"><h4>No network interfaces detected</h4></div>';
            } else {
                filteredInterfaces.forEach(iface => {
                    const data = throughputData[iface];
                    const downloadMbps = (data.download || 0).toFixed(2);
                    const uploadMbps = (data.upload || 0).toFixed(2);
                    const totalDownloadMB = (data.total_download || 0).toFixed(1);
                    const totalUploadMB = (data.total_upload || 0).toFixed(1);
                    
                    // Get interface display name
                    let displayName = iface;
                    if (iface === 'eth0') displayName = '🔌 Ethernet';
                    else if (iface === 'wlan0') displayName = '📶 Wi-Fi Primary';  
                    else if (iface === 'wlan1') displayName = '📡 Wi-Fi Secondary';
                    
                    // Status indicator
                    const statusClass = data.active ? 'active' : 'inactive';
                    const statusText = data.active ? 'ACTIVE' : 'INACTIVE';
                    
                    html += `
                        <div class="throughput-item">
                            <div class="throughput-header">
                                <h4>${displayName}</h4>
                                <span class="throughput-status ${statusClass}">${statusText}</span>
                            </div>
                            <div class="throughput-stats">
                                <div class="stat-row">
                                    <span class="stat-label">Download:</span>
                                    <span class="stat-value">${downloadMbps} Mbps</span>
                                </div>
                                <div class="stat-row">
                                    <span class="stat-label">Upload:</span>  
                                    <span class="stat-value">${uploadMbps} Mbps</span>
                                </div>
                                <div class="stat-row">
                                    <span class="stat-label">Total Down:</span>
                                    <span class="stat-value">${totalDownloadMB} MB</span>
                                </div>
                                <div class="stat-row">
                                    <span class="stat-label">Total Up:</span>
                                    <span class="stat-value">${totalUploadMB} MB</span>
                                </div>
                                <div class="stat-row">
                                    <span class="stat-label">Packets:</span>
                                    <span class="stat-value">↓${data.rx_packets || 0} ↑${data.tx_packets || 0}</span>
                                </div>
                            </div>
                        </div>
                    `;
                });
            }
            
            container.innerHTML = html;
        }
        
        // FIXED: Enhanced data refresh with throughput
        async function refreshData() {
            try {
                // Fetch both status and throughput data in parallel
                const [statusResponse, throughputResponse] = await Promise.all([
                    fetch('/status').catch(() => null),
                    fetch('/api/throughput').catch(() => null)
                ]);
                
                let hasData = false;
                
                if (statusResponse && statusResponse.ok) {
                    currentData = await statusResponse.json();
                    updateUI(currentData);
                    hasData = true;
                }
                
                if (throughputResponse && throughputResponse.ok) {
                    const throughputData = await throughputResponse.json();
                    if (throughputData.success) {
                        updateThroughputDisplay(throughputData.throughput);
                        hasData = true;
                    }
                }
                
                if (hasData) {
                    updateStatusPill('✅ Connected', 'var(--success)');
                } else {
                    updateStatusPill('❌ API Error', 'var(--error)');
                }
                
            } catch (error) {
                console.error('Error refreshing data:', error);
                updateStatusPill('❌ Connection Error', 'var(--error)');
                
                // Show fallback in throughput display
                const container = document.getElementById('throughput-grid');
                if (container) {
                    container.innerHTML = `
                        <div class="throughput-item">
                            <div class="throughput-header">
                                <h4>⚠️ Connection Error</h4>
                            </div>
                            <div class="throughput-stats">
                                <div class="stat-row">Unable to fetch throughput data</div>
                                <div class="stat-row">Check if services are running</div>
                            </div>
                        </div>
                    `;
                }
            }
        }
        
        function updateUI(data) {
            // Update status items
            document.getElementById('current-ssid').textContent = data.ssid || '(not configured)';
            document.getElementById('ip-address').textContent = data.system_info?.ip_address || 'Unknown';
            document.getElementById('system-time').textContent = data.system_info?.timestamp || 'Unknown';
            
            // Count active services
            const activeCount = Object.values(data.service_status || {}).filter(s => s === 'active').length;
            const totalCount = Object.keys(data.service_status || {}).length;
            document.getElementById('active-services').textContent = `${activeCount}/${totalCount}`;
            
            // Update network interfaces (filter out loopback)
            updateNetworkInterfaces(data.system_info?.interfaces || {});
            
            // Update text areas
            document.getElementById('active-connections').textContent = data.system_info?.active_connections || 'Unknown';
            document.getElementById('netem-status').textContent = data.system_info?.netem_status || 'Not configured';
            
            // Update form if not focused
            const ssidInput = document.getElementById('ssid');
            if (document.activeElement !== ssidInput) {
                ssidInput.value = data.ssid || '';
            }
            
            // Update services
            updateServiceControls(data.service_status || {});
            
            // Update logs
            const activeLogTab = document.querySelector('.log-tab.active');
            if (activeLogTab) {
                updateLogContent(activeLogTab.dataset.log);
            }
        }
        
        function updateNetworkInterfaces(interfaces) {
            const container = document.getElementById('interface-list');
            if (!container) return;
            
            // FIXED: Filter out loopback and virtual interfaces
            const filteredInterfaces = Object.entries(interfaces).filter(([iface, addrs]) => 
                !iface.includes('lo') && !iface.includes('docker') && !iface.includes('veth')
            );
            
            if (filteredInterfaces.length === 0) {
                container.innerHTML = '<div class="interface-item">No interfaces detected</div>';
                return;
            }
            
            container.innerHTML = filteredInterfaces.map(([iface, addrs]) => {
                const cleanAddrs = addrs.filter(addr => !addr.includes('127.0.0.1') && !addr.includes('::1'));
                const displayAddr = cleanAddrs.length > 0 ? cleanAddrs[0].split('/')[0] : 'No IP';
                
                return `
                    <div class="interface-item">
                        <div class="interface-name">${iface}</div>
                        <div class="interface-ip">${displayAddr}</div>
                    </div>
                `;
            }).join('');
        }
        
        function updateStatusPill(text, color) {
            const pill = document.getElementById('status-pill');
            pill.innerHTML = text;
            pill.style.backgroundColor = color;
        }
        
        function updateServiceControls(serviceStatus) {
            const container = document.getElementById('service-controls');
            const services = ['wifi-dashboard', 'wired-test', 'wifi-good', 'wifi-bad'];
            
            container.innerHTML = services.map(service => {
                const status = serviceStatus[service] || 'unknown';
                const statusClass = status === 'active' ? 'active' : 
                                  status === 'inactive' ? 'inactive' : 'unknown';
                
                const serviceName = service.replace(/-/g, ' ').replace(/\b\w/g, l => l.toUpperCase());
                
                return `
                    <div class="service-item">
                        <div class="service-name">${serviceName}</div>
                        <div class="service-status ${statusClass}">${status}</div>
                        <div class="service-buttons">
                            <button onclick="serviceAction('${service}', 'start')" class="secondary">▶️ Start</button>
                            <button onclick="serviceAction('${service}', 'restart')" class="secondary">🔄 Restart</button>
                            <button onclick="serviceAction('${service}', 'stop')" class="danger">⏹️ Stop</button>
                        </div>
                    </div>
                `;
            }).join('');
        }

        // Log tab switching
        document.addEventListener('click', function(e) {
            if (e.target.classList.contains('log-tab')) {
                document.querySelectorAll('.log-tab').forEach(t => t.classList.remove('active'));
                e.target.classList.add('active');
                updateLogContent(e.target.dataset.log);
            }
        });
        
        function updateLogContent(logType) {
            const logContent = document.getElementById('log-content');
            if (currentData.logs && currentData.logs[logType]) {
                logContent.textContent = currentData.logs[logType].join('');
                logContent.scrollTop = logContent.scrollHeight;
            } else {
                logContent.textContent = 'No logs available for ' + logType;
            }
        }
        
        // Service actions and other functions from your existing dashboard...
        async function serviceAction(service, action) {
            if (!confirm(`Are you sure you want to ${action} the ${service} service?`)) return;
            
            try {
                const formData = new FormData();
                formData.append('service', service);
                formData.append('action', action);
                
                const response = await fetch('/service_action', { method: 'POST', body: formData });
                
                if (response.ok) {
                    showMessage(`Service ${service} ${action}ed successfully`, 'success');
                    setTimeout(refreshData, 2000);
                } else {
                    showMessage(`Failed to ${action} service ${service}`, 'error');
                }
            } catch (error) {
                showMessage(`Error: ${error.message}`, 'error');
            }
        }
        
        // Other existing functions...
        function showMessage(message, type = 'info') {
            // Your existing showMessage implementation
            console.log(`[${type}] ${message}`);
        }
        
        // Initialize with enhanced throughput monitoring
        refreshData();
        refreshInterval = setInterval(refreshData, 5000); // Update every 5 seconds
        
        console.log('✅ Dashboard with throughput monitoring initialized');
    </script>
</body>
</html>
DASHBOARD_EOF
fi

log_info "Installing traffic control template..."
if curl -sSL --max-time 30 --retry 3 "${REPO_URL}/templates/traffic_control.html" -o "$PI_HOME/wifi_test_dashboard/templates/traffic_control.html"; then
    log_info "✓ Downloaded traffic_control.html"
else
    log_warn "✗ Failed to download traffic_control.html, creating basic template..."
    
    # Create basic traffic control template
    cat > "$PI_HOME/wifi_test_dashboard/templates/traffic_control.html" <<'TRAFFIC_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8"/>
    <title>Traffic Control - Wi-Fi Test Dashboard</title>
    <meta name="viewport" content="width=device-width,initial-scale=1"/>
    <style>
        body { 
            font-family: system-ui, sans-serif; 
            margin: 0; 
            padding: 20px; 
            background: #0f1014; 
            color: #e8e8e8; 
        }
        .container { max-width: 1200px; margin: 0 auto; }
        .card { 
            background: #1e2230; 
            border-radius: 12px; 
            padding: 24px; 
            margin-bottom: 24px; 
            border: 1px solid rgba(255,255,255,0.1); 
        }
        h1, h2 { color: #4caf50; margin-top: 0; }
        .nav { margin-bottom: 24px; }
        .nav a { 
            color: #4caf50; 
            text-decoration: none; 
            margin-right: 16px; 
            padding: 8px 16px; 
            border-radius: 6px; 
            background: rgba(255,255,255,0.05); 
        }
        .nav a:hover { background: rgba(255,255,255,0.1); }
        .interface-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 20px; }
        .interface-card { 
            background: rgba(255,255,255,0.05); 
            padding: 20px; 
            border-radius: 8px; 
            text-align: center; 
        }
        .status { 
            padding: 4px 12px; 
            border-radius: 20px; 
            font-size: 0.8em; 
            margin-bottom: 16px; 
            display: inline-block; 
        }
        .status.active { background: #4caf50; color: white; }
        .status.inactive { background: #f44336; color: white; }
        button { 
            padding: 8px 16px; 
            border: none; 
            border-radius: 6px; 
            background: #4caf50; 
            color: white; 
            cursor: pointer; 
            margin: 4px; 
        }
        button:hover { background: #45a049; }
        button.danger { background: #f44336; }
        button.secondary { background: #666; }
        .throughput-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 16px; }
        .throughput-item { background: rgba(255,255,255,0.05); padding: 20px; border-radius: 12px; border-left: 4px solid var(--accent); transition: all 0.2s ease; }
        .throughput-item:hover { background: rgba(255,255,255,0.08); transform: translateY(-2px); }
        .throughput-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px; }
        .throughput-header h4 { margin: 0; color: var(--accent); font-size: 1.1em; }
        .throughput-status { padding: 4px 12px; border-radius: 20px; font-size: 0.8em; font-weight: 600; text-transform: uppercase; letter-spacing: 0.5px; }
        .throughput-status.active { background: var(--success); color: white; }
        .throughput-status.inactive { background: var(--error); color: white; }
        .throughput-stats { display: flex; flex-direction: column; gap: 8px; }
        .stat-row { display: flex; justify-content: space-between; align-items: center; padding: 6px 0; border-bottom: 1px solid rgba(255,255,255,0.1); }
        .stat-row:last-child { border-bottom: none; }
        .stat-label { color: var(--muted); font-size: 0.9em; }
        .stat-value { font-weight: 600; color: var(--fg); font-family: monospace; }
    </style>
</head>
<body>
    <div class="container">
        <div class="nav">
            <a href="/">← Back to Dashboard</a>
        </div>
        
        <div class="card">
            <h1>🚦 Traffic Control</h1>
            <p>Monitor and control traffic generation across network interfaces.</p>
            
            <div class="interface-grid">
                <div class="interface-card">
                    <h3>ETH0 (Ethernet)</h3>
                    <div class="status inactive">Loading...</div>
                    <br>
                    <button onclick="alert('Traffic control functionality will be implemented')">Start Traffic</button>
                    <button class="danger">Stop Traffic</button>
                </div>
                
                <div class="interface-card">
                    <h3>WLAN0 (Wi-Fi 1)</h3>
                    <div class="status inactive">Loading...</div>
                    <br>
                    <button onclick="alert('Traffic control functionality will be implemented')">Start Traffic</button>
                    <button class="danger">Stop Traffic</button>
                </div>
                
                <div class="interface-card">
                    <h3>WLAN1 (Wi-Fi 2)</h3>
                    <div class="status inactive">Loading...</div>
                    <br>
                    <button onclick="alert('Traffic control functionality will be implemented')">Start Traffic</button>
                    <button class="danger">Stop Traffic</button>
                </div>
            </div>
        </div>
    </div>
</body>
</html>
TRAFFIC_EOF
fi

# Set proper ownership
chown -R "$PI_USER:$PI_USER" "$PI_HOME/wifi_test_dashboard/templates"

log_info "✓ Web interface templates installed"