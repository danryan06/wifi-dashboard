#!/usr/bin/env bash
# scripts/install/03-directories.sh
# Create directory structure and baseline configuration

set -euo pipefail

# --- defaults so set -u is safe ---
: "${PI_USER:=pi}"
: "${PI_HOME:=/home/${PI_USER}}"
: "${VERSION:=v5.1.0}"

DASHBOARD_DIR="${DASHBOARD_DIR:-${PI_HOME}/wifi_test_dashboard}"
CONFIG_DIR="${DASHBOARD_DIR}/configs"
LOG_DIR="${DASHBOARD_DIR}/logs"
SCRIPTS_DIR="${DASHBOARD_DIR}/scripts"

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }

log_info "Creating directory structure..."

# Main directories
mkdir -p \
  "${DASHBOARD_DIR}" \
  "${SCRIPTS_DIR}" \
  "${SCRIPTS_DIR}/traffic" \
  "${SCRIPTS_DIR}/install" \
  "${CONFIG_DIR}" \
  "${LOG_DIR}" \
  "${DASHBOARD_DIR}/templates"

# Permissions (best-effort if run as root)
chown -R "${PI_USER}:${PI_USER}" "${DASHBOARD_DIR}" 2>/dev/null || true

# --- default settings.conf (only if missing/empty) ---
SETTINGS="${CONFIG_DIR}/settings.conf"
if [[ ! -s "${SETTINGS}" ]]; then
  log_info "Creating default settings.conf..."
  if [[ -f "${CONFIG_DIR}/default_settings.conf" ]]; then
    cp "${CONFIG_DIR}/default_settings.conf" "${SETTINGS}"
  else
    # fallback minimal config if template missing
    cat >"${SETTINGS}" <<'EOF'
# General hostnames used by services
WIRED_HOSTNAME="CNXNMist-Wired"
WIFI_GOOD_HOSTNAME="CNXNMist-WiFiGood"
WIFI_BAD_HOSTNAME="CNXNMist-WiFiBad"

# Roaming
WIFI_ROAMING_ENABLED="true"
WIFI_ROAMING_INTERVAL="120"
WIFI_ROAMING_SCAN_INTERVAL="30"
WIFI_MIN_SIGNAL_THRESHOLD="-75"
WIFI_ROAMING_SIGNAL_DIFF="10"
WIFI_BAND_PREFERENCE="both"    # 2.4 | 5 | both
EOF
  fi
  chmod 600 "${SETTINGS}" 2>/dev/null || true
  chown "${PI_USER}:${PI_USER}" "${SETTINGS}" 2>/dev/null || true
fi

# --- default ssid.conf (only if missing/empty) ---
SSID_CONF="${CONFIG_DIR}/ssid.conf"
if [[ ! -s "${SSID_CONF}" ]]; then
  log_info "Creating placeholder ssid.conf..."
  cat >"${SSID_CONF}" <<'EOF'
YourSSID
YourPassword
EOF
  chmod 600 "${SSID_CONF}" 2>/dev/null || true
  chown "${PI_USER}:${PI_USER}" "${SSID_CONF}" 2>/dev/null || true
fi

# --- default interface assignments (only if missing/empty) ---
ASSIGN_CONF="${CONFIG_DIR}/interface-assignments.conf"
if [[ ! -s "${ASSIGN_CONF}" ]]; then
  log_info "Creating default interface-assignments.conf..."
  cat >"${ASSIGN_CONF}" <<'EOF'
good_interface="wlan0"
bad_interface="wlan1"
wired_interface="eth0"
EOF
  chmod 600 "${ASSIGN_CONF}" 2>/dev/null || true
  chown "${PI_USER}:${PI_USER}" "${ASSIGN_CONF}" 2>/dev/null || true
fi

# main log (append a one-liner so the UI shows something immediately)
MAIN_LOG="${LOG_DIR}/main.log"
if [[ ! -f "${MAIN_LOG}" ]]; then
  touch "${MAIN_LOG}"
fi
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Install/upgrade to ${VERSION}" >> "${MAIN_LOG}"
chown "${PI_USER}:${PI_USER}" "${MAIN_LOG}" 2>/dev/null || true

# make sure script files will be executable later steps
find "${SCRIPTS_DIR}" -type f -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

# --- patch /etc/hosts for hostname resolution ---
HOSTNAME_NOW="$(hostname)"
if ! grep -q "$HOSTNAME_NOW" /etc/hosts; then
  log_info "Patching /etc/hosts for hostname: $HOSTNAME_NOW"
  echo "127.0.1.1   $HOSTNAME_NOW" | sudo tee -a /etc/hosts >/dev/null
fi

log_info "✓ Directory structure and baseline configs ready"
