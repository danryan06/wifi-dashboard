#!/usr/bin/env bash
# scripts/install/06-traffic-scripts.sh
# Install traffic generation and utility scripts from the source checkout.
# Traffic scripts are installed flat into <dashboard>/scripts/ (the systemd
# units reference them there).

set -euo pipefail

: "${PI_USER:=pi}"
: "${PI_HOME:=/home/${PI_USER}}"
: "${SRC_DIR:?SRC_DIR must point at the repository checkout}"

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }

DEST="$PI_HOME/wifi_test_dashboard/scripts"
mkdir -p "$DEST" "$DEST/utils" "$DEST/install"

log_info "Installing traffic generation scripts..."

# Client / traffic scripts (flat layout expected by the service units)
for f in connect_and_curl.sh fail_auth_loop.sh wired_simulation.sh \
         interface_traffic_generator.sh wifi_client.sh; do
    install -m 755 "$SRC_DIR/scripts/traffic/$f" "$DEST/$f"
    log_info "✓ Installed $f"
done

# Shared helpers and operational tools
install -m 755 "$SRC_DIR/scripts/apply_netem.sh"        "$DEST/apply_netem.sh"
install -m 755 "$SRC_DIR/scripts/log_rotation_utils.sh" "$DEST/log_rotation_utils.sh"
install -m 755 "$SRC_DIR/scripts/diagnose-dashboard.sh" "$DEST/diagnose-dashboard.sh"
install -m 755 "$SRC_DIR/scripts/fix-services.sh"       "$DEST/fix-services.sh"
install -m 755 "$SRC_DIR/scripts/verify-hostnames.sh"   "$DEST/verify-hostnames.sh"

# Utility scripts
if [[ -d "$SRC_DIR/scripts/utils" ]]; then
    for f in "$SRC_DIR/scripts/utils/"*.sh; do
        [[ -f "$f" ]] && install -m 755 "$f" "$DEST/utils/$(basename "$f")"
    done
fi

# Install-time scripts are kept on the device so interface re-assignment and
# service regeneration can be re-run after adding USB adapters.
for f in "$SRC_DIR/scripts/install/"*.sh; do
    [[ -f "$f" ]] && install -m 755 "$f" "$DEST/install/$(basename "$f")"
done

# startup-check lives under utils/ on the installed system (08-finalize runs it there)
install -m 755 "$SRC_DIR/scripts/install/startup-check.sh" "$DEST/utils/startup-check.sh"

chown -R "$PI_USER:$PI_USER" "$DEST"

log_info "✓ All traffic and utility scripts installed"
