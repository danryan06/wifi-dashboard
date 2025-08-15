<!-- Add this as a new tab in dashboard.html -->

<!-- Add to the tabs section -->
<div class="tab" data-tab="interfaces">🔌 Interfaces</div>

<!-- Add this new tab content section -->
<div id="interfaces" class="card hidden">
    <h2>🔌 Interface Assignments</h2>
    <p style="color: var(--muted); margin-bottom: 24px;">
        Intelligent interface detection and assignment for optimal performance.
    </p>
    
    <div class="interface-assignment-grid" id="interface-assignment-grid">
        <div style="text-align: center; padding: 40px; color: var(--muted);">
            <span class="spinner"></span> Loading interface assignments...
        </div>
    </div>
    
    <div class="optimization-info" id="optimization-info" style="margin-top: 24px;">
        <!-- Optimization recommendations will be loaded here -->
    </div>
</div>

<style>
.interface-assignment-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(350px, 1fr));
    gap: 20px;
    margin-bottom: 24px;
}

.interface-assignment-card {
    background: rgba(255,255,255,0.05);
    border-radius: 12px;
    padding: 20px;
    border: 1px solid var(--border);
    transition: all 0.2s ease;
    position: relative;
}

.interface-assignment-card:hover {
    background: rgba(255,255,255,0.08);
    transform: translateY(-2px);
}

.interface-assignment-card.good-client {
    border-left: 4px solid var(--success);
}

.interface-assignment-card.bad-client {
    border-left: 4px solid var(--warning);
}

.interface-assignment-card.wired-client {
    border-left: 4px solid var(--info);
}

.interface-assignment-card.unassigned {
    border-left: 4px solid var(--muted);
    opacity: 0.7;
}

.interface-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 16px;
}

.interface-name {
    font-size: 1.3em;
    font-weight: 600;
    color: var(--fg);
}

.interface-assignment-badge {
    padding: 4px 12px;
    border-radius: 20px;
    font-size: 0.75em;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.5px;
}

.assignment-good {
    background: var(--success);
    color: white;
}

.assignment-bad {
    background: var(--warning);
    color: black;
}

.assignment-wired {
    background: var(--info);
    color: white;
}

.assignment-unassigned {
    background: var(--muted);
    color: white;
}

.interface-details {
    margin-bottom: 16px;
}

.detail-row {
    display: flex;
    justify-content: space-between;
    margin-bottom: 8px;
    font-size: 0.9em;
}

.detail-label {
    color: var(--muted);
    font-weight: 500;
}

.detail-value {
    color: var(--fg);
    font-family: monospace;
}

.capability-tags {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
    margin-top: 12px;
}

.capability-tag {
    padding: 3px 8px;
    border-radius: 12px;
    font-size: 0.7em;
    font-weight: 500;
    text-transform: uppercase;
    letter-spacing: 0.3px;
}

.tag-builtin {
    background: rgba(76, 175, 80, 0.2);
    color: var(--success);
}

.tag-dual-band {
    background: rgba(33, 150, 243, 0.2);
    color: var(--info);
}

.tag-usb {
    background: rgba(255, 152, 0, 0.2);
    color: var(--warning);
}

.tag-2ghz {
    background: rgba(158, 158, 158, 0.2);
    color: var(--muted);
}

.tag-ethernet {
    background: rgba(76, 175, 80, 0.2);
    color: var(--success);
}

.wireless-connection-info {
    background: rgba(255,255,255,0.03);
    padding: 12px;
    border-radius: 8px;
    margin-top: 12px;
    border: 1px dashed var(--border);
}

.connection-info-title {
    font-size: 0.8em;
    color: var(--muted);
    margin-bottom: 8px;
    text-transform: uppercase;
    letter-spacing: 0.5px;
}

.optimization-recommendations {
    background: rgba(76, 175, 80, 0.1);
    border-left: 4px solid var(--success);
    padding: 16px;
    border-radius: 8px;
    margin-top: 16px;
}

.optimization-title {
    font-size: 1.1em;
    font-weight: 600;
    color: var(--success);
    margin-bottom: 12px;
}

.recommendation-list {
    list-style: none;
    padding: 0;
    margin: 0;
}

.recommendation-list li {
    padding: 4px 0;
    color: var(--fg);
}

.recommendation-list li:before {
    content: "✓ ";
    color: var(--success);
    font-weight: bold;
}

.auto-detection-info {
    background: rgba(33, 150, 243, 0.1);
    border-left: 4px solid var(--info);
    padding: 16px;
    border-radius: 8px;
    margin-bottom: 16px;
}
</style>

<script>
// JavaScript functions for interface display

async function updateInterfaceAssignments() {
    try {
        const response = await fetch('/api/interfaces');
        if (response.ok) {
            const data = await response.json();
            if (data.success) {
                displayInterfaceAssignments(data);
            } else {
                showInterfaceError('Failed to load interface data');
            }
        } else {
            showInterfaceError('Interface API not available');
        }
    } catch (error) {
        console.error('Error loading interface assignments:', error);
        showInterfaceError('Error loading interface assignments');
    }
}

function displayInterfaceAssignments(data) {
    const container = document.getElementById('interface-assignment-grid');
    const optimizationContainer = document.getElementById('optimization-info');
    
    if (!data.interfaces || Object.keys(data.interfaces).length === 0) {
        container.innerHTML = '<div style="text-align: center; padding: 40px; color: var(--muted);">No network interfaces detected</div>';
        return;
    }
    
    // Show auto-detection info
    if (data.auto_detected) {
        optimizationContainer.innerHTML = `
            <div class="auto-detection-info">
                <div style="font-weight: 600; margin-bottom: 8px;">🤖 Automatic Interface Detection</div>
                <div>Interfaces were automatically detected and optimally assigned based on capabilities and hardware type.</div>
            </div>
        `;
    }
    
    // Sort interfaces by assignment priority
    const sortedInterfaces = Object.entries(data.interfaces).sort(([,a], [,b]) => {
        const priority = { 'good_client': 3, 'bad_client': 2, 'wired_client': 1, 'unassigned': 0 };
        return (priority[b.assignment] || 0) - (priority[a.assignment] || 0);
    });
    
    container.innerHTML = sortedInterfaces.map(([iface, info]) => {
        const assignmentClass = info.assignment.replace('_', '-');
        const assignmentName = info.assignment.replace('_', ' ').toUpperCase();
        
        // Generate capability tags
        const capabilityTags = (info.capabilities || []).map(cap => {
            const tagClass = cap.replace('_', '-');
            const tagText = cap.replace('_', ' ').toUpperCase();
            return `<span class="capability-tag tag-${tagClass}">${tagText}</span>`;
        }).join('');
        
        // Wireless connection info
        let connectionInfo = '';
        if (info.wireless_info && Object.keys(info.wireless_info).length > 0) {
            const { ssid, signal, frequency } = info.wireless_info;
            if (ssid) {
                connectionInfo = `
                    <div class="wireless-connection-info">
                        <div class="connection-info-title">Current Connection</div>
                        <div class="detail-row">
                            <span class="detail-label">SSID:</span>
                            <span class="detail-value">${ssid}</span>
                        </div>
                        ${signal ? `
                        <div class="detail-row">
                            <span class="detail-label">Signal:</span>
                            <span class="detail-value">${signal}%</span>
                        </div>` : ''}
                        ${frequency ? `
                        <div class="detail-row">
                            <span class="detail-label">Frequency:</span>
                            <span class="detail-value">${frequency}</span>
                        </div>` : ''}
                    </div>
                `;
            }
        }
        
        return `
            <div class="interface-assignment-card ${assignmentClass}">
                <div class="interface-header">
                    <div class="interface-name">${iface.toUpperCase()}</div>
                    <div class="interface-assignment-badge assignment-${assignmentClass.replace('-client', '')}">${assignmentName}</div>
                </div>
                
                <div class="interface-details">
                    <div class="detail-row">
                        <span class="detail-label">Type:</span>
                        <span class="detail-value">${info.type}</span>
                    </div>
                    <div class="detail-row">
                        <span class="detail-label">State:</span>
                        <span class="detail-value">${info.state}</span>
                    </div>
                    <div class="detail-row">
                        <span class="detail-label">IP Address:</span>
                        <span class="detail-value">${info.ip_address || 'Not assigned'}</span>
                    </div>
                    <div class="detail-row">
                        <span class="detail-label">Assignment:</span>
                        <span class="detail-value">${info.description}</span>
                    </div>
                </div>
                
                ${capabilityTags ? `
                <div class="capability-tags">
                    ${capabilityTags}
                </div>` : ''}
                
                ${connectionInfo}
            </div>
        `;
    }).join('');
    
    // Add optimization recommendations
    generateOptimizationRecommendations(data, optimizationContainer);
}

function generateOptimizationRecommendations(data, container) {
    const interfaces = data.interfaces;
    const recommendations = [];
    
    // Find good client interface
    const goodClient = Object.entries(interfaces).find(([,info]) => info.assignment === 'good_client');
    if (goodClient) {
        const [iface, info] = goodClient;
        
        if (info.capabilities && info.capabilities.includes('dual_band')) {
            recommendations.push('Built-in dual-band adapter assigned to good client for optimal 5GHz performance');
        }
        
        if (info.capabilities && info.capabilities.includes('builtin')) {
            recommendations.push('Built-in adapter provides better antenna positioning and reliability');
        }
        
        if (info.state === 'UP' && info.ip_address) {
            recommendations.push(`Good client (${iface}) is connected and ready for traffic generation`);
        }
    }
    
    // Check bad client
    const badClient = Object.entries(interfaces).find(([,info]) => info.assignment === 'bad_client');
    if (badClient) {
        const [iface, info] = badClient;
        recommendations.push(`Bad client (${iface}) will generate authentication failures for security testing`);
        
        if (info.capabilities && info.capabilities.includes('usb')) {
            recommendations.push('USB adapter used for bad client to isolate authentication failures');
        }
    } else {
        recommendations.push('Consider adding a USB Wi-Fi adapter for bad client simulation');
    }
    
    // Check for dual-band capability
    const dualBandInterfaces = Object.entries(interfaces).filter(([,info]) => 
        info.capabilities && info.capabilities.includes('dual_band')
    );
    
    if (dualBandInterfaces.length > 0) {
        recommendations.push('5GHz bands available for reduced interference and better performance');
    }
    
    if (recommendations.length > 0) {
        const optimizationHtml = `
            <div class="optimization-recommendations">
                <div class="optimization-title">🚀 Optimization Benefits</div>
                <ul class="recommendation-list">
                    ${recommendations.map(rec => `<li>${rec}</li>`).join('')}
                </ul>
            </div>
        `;
        
        container.innerHTML += optimizationHtml;
    }
}

function showInterfaceError(message) {
    const container = document.getElementById('interface-assignment-grid');
    container.innerHTML = `
        <div style="text-align: center; padding: 40px; color: var(--error);">
            ⚠️ ${message}
        </div>
    `;
}

// Add interface tab to the main update function
function updateUI(data) {
    // ... existing updateUI code ...
    
    // Update interface assignments if on interfaces tab
    const interfacesTab = document.getElementById('interfaces');
    if (interfacesTab && !interfacesTab.classList.contains('hidden')) {
        updateInterfaceAssignments();
    }
}

// Update tab switching to load interface data when tab is opened
function switchTab(tabName) {
    document.querySelectorAll(".tab").forEach(t => t.classList.remove("active"));
    document.querySelector(`[data-tab="${tabName}"]`).classList.add("active");
    const sections = ["status", "wifi", "netem", "services", "logs", "controls", "interfaces"];
    sections.forEach(section => {
        document.getElementById(section).classList.toggle("hidden", section !== tabName);
    });
    
    // Load interface data when interfaces tab is opened
    if (tabName === 'interfaces') {
        updateInterfaceAssignments();
    }
}
</script>