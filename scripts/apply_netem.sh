#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# NETEM CONFIGURATION HELPER
# =============================================================================
# Purpose: Apply network emulation (latency/packet loss) to any interface
# Usage: ./apply_netem.sh <interface> <latency_ms> <loss_percent> [jitter_ms] [bandwidth_mbit]
# Examples:
#   ./apply_netem.sh wlan0 50 5           # 50ms latency, 5% loss
#   ./apply_netem.sh wlan0 50 5 10        # + 10ms jitter
#   ./apply_netem.sh wlan0 50 5 10 100    # + 100Mbit bandwidth limit
#   ./apply_netem.sh wlan0 0 0            # Remove netem (clean interface)
# =============================================================================

INTERFACE="${1:-}"
LATENCY="${2:-0}"
LOSS="${3:-0}"
JITTER="${4:-0}"
BANDWIDTH="${5:-0}"

LOG_FILE="/home/pi/wifi_test_dashboard/logs/netem.log"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

log_msg() {
    echo "[$(date '+%F %T')] NETEM: $1" | tee -a "$LOG_FILE"
}

# =============================================================================
# VALIDATION
# =============================================================================
if [[ -z "$INTERFACE" ]]; then
    echo "Usage: $0 <interface> <latency_ms> <loss_percent> [jitter_ms] [bandwidth_mbit]"
    echo ""
    echo "Examples:"
    echo "  $0 wlan0 50 5           # 50ms latency, 5% loss"
    echo "  $0 wlan0 50 5 10        # + 10ms jitter"
    echo "  $0 wlan0 50 5 10 100    # + 100Mbit bandwidth limit"
    echo "  $0 wlan0 0 0            # Remove netem (clean interface)"
    exit 1
fi

if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
    log_msg "❌ Interface $INTERFACE not found"
    exit 1
fi

# Validate numeric parameters
if ! [[ "$LATENCY" =~ ^[0-9]+$ ]]; then
    log_msg "❌ Invalid latency value: $LATENCY (must be integer)"
    exit 1
fi

if ! [[ "$LOSS" =~ ^[0-9.]+$ ]]; then
    log_msg "❌ Invalid loss value: $LOSS (must be number)"
    exit 1
fi

if ! [[ "$JITTER" =~ ^[0-9]+$ ]]; then
    log_msg "❌ Invalid jitter value: $JITTER (must be integer)"
    exit 1
fi

if ! [[ "$BANDWIDTH" =~ ^[0-9]+$ ]]; then
    log_msg "❌ Invalid bandwidth value: $BANDWIDTH (must be integer)"
    exit 1
fi

# =============================================================================
# NETEM REMOVAL
# =============================================================================
remove_netem() {
    local iface="$1"
    log_msg "🧹 Removing netem from $iface..."
    
    # Try to remove existing qdisc
    if sudo tc qdisc del dev "$iface" root 2>/dev/null; then
        log_msg "✅ Removed existing netem configuration"
    else
        log_msg "ℹ️ No existing netem configuration found (or already clean)"
    fi
    
    # Verify clean state
    local current_qdisc
    current_qdisc=$(sudo tc qdisc show dev "$iface" 2>/dev/null | head -n1)
    log_msg "Current qdisc: $current_qdisc"
}

# =============================================================================
# NETEM APPLICATION
# =============================================================================
apply_netem() {
    local iface="$1"
    local latency_ms="$2"
    local loss_pct="$3"
    local jitter_ms="$4"
    local bw_mbit="$5"
    
    log_msg "🔧 Applying netem to $iface..."
    log_msg "   Latency: ${latency_ms}ms"
    [[ $jitter_ms -gt 0 ]] && log_msg "   Jitter: ${jitter_ms}ms"
    log_msg "   Loss: ${loss_pct}%"
    [[ $bw_mbit -gt 0 ]] && log_msg "   Bandwidth limit: ${bw_mbit}Mbit/s"
    
    # Build netem command
    local cmd="sudo tc qdisc add dev $iface root netem"
    
    # Add latency (with optional jitter)
    if [[ $latency_ms -gt 0 ]]; then
        if [[ $jitter_ms -gt 0 ]]; then
            cmd="$cmd delay ${latency_ms}ms ${jitter_ms}ms"
        else
            cmd="$cmd delay ${latency_ms}ms"
        fi
    fi
    
    # Add packet loss
    if (( $(echo "$loss_pct > 0" | bc -l) )); then
        cmd="$cmd loss ${loss_pct}%"
    fi
    
    # Add bandwidth limit if specified
    if [[ $bw_mbit -gt 0 ]]; then
        cmd="$cmd rate ${bw_mbit}mbit"
    fi
    
    # Execute command
    log_msg "Executing: $cmd"
    if eval "$cmd" 2>&1 | tee -a "$LOG_FILE"; then
        log_msg "✅ Netem configuration applied successfully"
    else
        log_msg "❌ Failed to apply netem configuration"
        return 1
    fi
    
    # Verify application
    local current_qdisc
    current_qdisc=$(sudo tc qdisc show dev "$iface" 2>/dev/null)
    log_msg "Current configuration:"
    echo "$current_qdisc" | while read -r line; do
        log_msg "   $line"
    done
}

# =============================================================================
# MAIN LOGIC
# =============================================================================
log_msg "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_msg "NETEM CONFIGURATION FOR $INTERFACE"
log_msg "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# First, remove any existing netem configuration
remove_netem "$INTERFACE"

# If both latency and loss are 0, we're done (clean interface)
if [[ $LATENCY -eq 0 && $(echo "$LOSS == 0" | bc -l) -eq 1 ]]; then
    log_msg "✅ Interface $INTERFACE is clean (no netem applied)"
    exit 0
fi

# Apply new netem configuration
if apply_netem "$INTERFACE" "$LATENCY" "$LOSS" "$JITTER" "$BANDWIDTH"; then
    log_msg "✅ Successfully configured netem on $INTERFACE"
    exit 0
else
    log_msg "❌ Failed to configure netem on $INTERFACE"
    exit 1
fi