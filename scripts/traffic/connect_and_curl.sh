#!/usr/bin/env bash
# Wi-Fi Good Client: Auth + Roaming + Realistic Traffic (+ optional speedtest & yt-dlp)
# Safe, dependency-aware, service-friendly

set -uo pipefail

# --- Paths & defaults ---
export PATH="$PATH:/usr/local/bin:/usr/sbin:/sbin:/home/pi/.local/bin"
DASHBOARD_DIR="/home/pi/wifi_test_dashboard"
LOG_DIR="$DASHBOARD_DIR/logs"
LOG_FILE="$LOG_DIR/wifi-good.log"
CONFIG_FILE="$DASHBOARD_DIR/configs/ssid.conf"
SETTINGS="$DASHBOARD_DIR/configs/settings.conf"
ROTATE_UTIL="$DASHBOARD_DIR/scripts/log_rotation_utils.sh"

INTERFACE="${INTERFACE:-wlan0}"
HOSTNAME="${WIFI_GOOD_HOSTNAME:-${HOSTNAME:-CNXNMist-WiFiGood}}"
LOG_MAX_SIZE_BYTES="${LOG_MAX_SIZE_BYTES:-10485760}"   # 10MB default

# Ensure system hostname is set correctly (avoid inheriting wired hostname)
if command -v hostnamectl >/dev/null 2>&1; then
  sudo hostnamectl set-hostname "$HOSTNAME" 2>/dev/null || true
fi

# Trap errors but DO NOT exit service
trap 'ec=$?; echo "[$(date "+%F %T")] TRAP-ERR: cmd=\"$BASH_COMMAND\" ec=$ec line=$LINENO" | tee -a "$LOG_FILE"' ERR

# --- Privilege helper for nmcli ---
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  SUDO="sudo"
else
  SUDO=""
fi

# --- Rotation helpers ---
[[ -f "$ROTATE_UTIL" ]] && source "$ROTATE_UTIL" || true
rotate_basic() {
  if command -v rotate_log >/dev/null 2>&1; then
    rotate_log "$LOG_FILE" "${LOG_MAX_SIZE_MB:-5}"
    return 0
  fi
  local max="${LOG_MAX_SIZE_BYTES:-10485760}"
  if [[ -f "$LOG_FILE" ]]; then
    local size
    size=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
    (( size >= max )) && { mv -f "$LOG_FILE" "$LOG_FILE.$(date +%s).1" 2>/dev/null || true; : > "$LOG_FILE"; }
  fi
}
log_msg() {
  local msg="[$(date '+%F %T')] WIFI-GOOD: $1"
  if declare -F log_msg_with_rotation >/dev/null; then
    echo "$msg"
    log_msg_with_rotation "$LOG_FILE" "$msg" "WIFI-GOOD"
  else
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    rotate_basic
    echo "$msg" | tee -a "$LOG_FILE"
  fi
}

# --- tiny helpers for state / ip / ssid ---
nm_state() {
  nmcli -t -f GENERAL.STATE device show "$INTERFACE" 2>/dev/null \
    | cut -d: -f2 | awk '{print $1}' || echo "unknown"
}

current_ip() {
  ip -4 -o addr show dev "$INTERFACE" 2>/dev/null \
    | awk '{print $4}' | head -n1
}

current_ssid() {
  nmcli -t -f active,ssid dev wifi 2>/dev/null \
    | awk -F: '$1=="yes"{print $2; exit}'
}

ensure_connected() {
  local st ip ss
  st="$(nm_state)"
  ip="$(current_ip)"
  ss="$(current_ssid)"

  if [[ "$st" == "100" && -n "$ip" && "$ss" == "$SSID" ]]; then
    return 0
  fi

  log_msg "ensure_connected: re-attaching to $SSID..."
  if connect_to_wifi_with_roaming "$SSID" "$PASSWORD"; then
    log_msg "ensure_connected: OK"
    return 0
  fi

  log_msg "ensure_connected: failed to re-attach"
  return 1
}

# Remove any existing NM connections for this SSID to avoid NM preferring a different BSSID
prune_same_ssid_profiles() {
  local ssid="$1"
  $SUDO nmcli -t -f NAME,TYPE con show 2>/dev/null \
    | awk -F: '$2=="wifi"{print $1}' \
    | while read -r c; do
        local cs
        cs="$($SUDO nmcli -t -f 802-11-wireless.ssid con show "$c" 2>/dev/null | cut -d: -f2 || true)"
        [[ "$cs" == "$ssid" ]] && $SUDO nmcli con delete "$c" 2>/dev/null || true
      done
}

# Connect to a specific BSSID using a temporary, BSSID-locked profile; verify with iw
connect_locked_bssid() {
  local bssid="$1" ssid="$2" psk="$3"
  prune_same_ssid_profiles "$ssid"
  $SUDO nmcli dev disconnect "$INTERFACE" 2>/dev/null || true
  sleep 1
  local OUT
  if OUT="$($SUDO nmcli --wait 45 device wifi connect "$ssid" password "$psk" ifname "$INTERFACE" bssid "$bssid" 2>&1)"; then
    log_msg "BSSID connect success: ${OUT}"
  else
    log_msg "BSSID connect failed: ${OUT}"
    return 1
  fi
  sleep 3
  local new_bssid
  new_bssid="$(iw dev "$INTERFACE" link | awk '/Connected to/{print tolower($3)}')"
  [[ "$new_bssid" == "${bssid,,}" ]] || { log_msg "BSSID verify mismatch (${new_bssid:-unknown})"; return 1; }
  return 0
}


# --- Settings ---
[[ -f "$SETTINGS" ]] && source "$SETTINGS" || true
INTERFACE="${WIFI_GOOD_INTERFACE:-$INTERFACE}"
REFRESH_INTERVAL="${WIFI_GOOD_REFRESH_INTERVAL:-60}"
CONNECTION_TIMEOUT="${WIFI_CONNECTION_TIMEOUT:-30}"
MAX_RETRIES="${WIFI_MAX_RETRY_ATTEMPTS:-3}"

# Roaming config
ROAMING_ENABLED="${WIFI_ROAMING_ENABLED:-true}"
ROAMING_INTERVAL="${WIFI_ROAMING_INTERVAL:-120}"
ROAMING_SCAN_INTERVAL="${WIFI_ROAMING_SCAN_INTERVAL:-30}"
MIN_SIGNAL_THRESHOLD="${WIFI_MIN_SIGNAL_THRESHOLD:--75}"
ROAMING_SIGNAL_DIFF="${WIFI_ROAMING_SIGNAL_DIFF:-10}"
WIFI_BAND_PREFERENCE="${WIFI_BAND_PREFERENCE:-both}"

# Traffic config
TRAFFIC_INTENSITY="${WLAN0_TRAFFIC_INTENSITY:-medium}"
ENABLE_INTEGRATED_TRAFFIC="${WIFI_GOOD_INTEGRATED_TRAFFIC:-true}"

# Optional heavy features (opt-in)
ENABLE_SPEEDTEST="${ENABLE_SPEEDTEST:-false}"
SPEEDTEST_INTERVAL="${SPEEDTEST_INTERVAL:-900}"

ENABLE_YOUTUBE="${ENABLE_YOUTUBE:-false}"
YOUTUBE_INTERVAL="${YOUTUBE_INTERVAL:-900}"
YOUTUBE_URL="${YOUTUBE_URL:-https://www.youtube.com/watch?v=dQw4w9WgXcQ}"  # harmless default; metadata-only

# Intensity presets
case "$TRAFFIC_INTENSITY" in
  heavy)  DL_SIZE=104857600; PING_COUNT=20; DOWNLOAD_INTERVAL=60;  CONCURRENT_DOWNLOADS=5 ;;
  medium) DL_SIZE=52428800;  PING_COUNT=10; DOWNLOAD_INTERVAL=120; CONCURRENT_DOWNLOADS=3 ;;
  *)      DL_SIZE=10485760;  PING_COUNT=5;  DOWNLOAD_INTERVAL=300; CONCURRENT_DOWNLOADS=2 ;;
esac

# Targets
TEST_URLS=("https://www.google.com" "https://www.cloudflare.com" "https://httpbin.org/ip" "https://www.github.com")
DOWNLOAD_URLS=("https://ash-speed.hetzner.com/100MB.bin" "https://proof.ovh.net/files/100Mb.dat" "http://ipv4.download.thinkbroadband.com/50MB.zip" "https://speed.hetzner.de/100MB.bin")
PING_TARGETS=("8.8.8.8" "1.1.1.1" "208.67.222.222" "9.9.9.9")

# Global roaming state
declare -A DISCOVERED_BSSIDS
declare -A BSSID_SIGNALS
CURRENT_BSSID=""
LAST_ROAM_TIME=0
LAST_SCAN_TIME=0

# --- Safe getters ---
nm_state() {
  nmcli -t -f GENERAL.STATE device show "$INTERFACE" 2>/dev/null | cut -d: -f2 | awk '{print $1}' || echo ""
}
current_ip() {
  ip -o -4 addr show dev "$INTERFACE" 2>/dev/null | awk '{print $4}' | head -n1
}
current_ssid() {
  nmcli -t -f active,ssid dev wifi 2>/dev/null | awk -F: '$1=="yes"{print $2; exit}'
}

# --- Config ---
read_wifi_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then log_msg "Config file not found: $CONFIG_FILE"; return 1; fi
  mapfile -t lines < "$CONFIG_FILE"
  [[ ${#lines[@]} -lt 2 ]] && { log_msg "Config incomplete (need SSID + password)"; return 1; }
  SSID="${lines[0]}"
  PASSWORD="${lines[1]}"
  if [[ -z "$SSID" || -z "$PASSWORD" ]]; then log_msg "SSID or password empty"; return 1; fi
  log_msg "Wi-Fi config loaded (SSID: $SSID)"; return 0
}

# --- Interface mgmt ---
check_wifi_interface() {
  ip link show "$INTERFACE" >/dev/null 2>&1 || { log_msg "Interface $INTERFACE not found"; return 1; }
  if ! ip link show "$INTERFACE" | grep -q "state UP"; then
    log_msg "Bringing $INTERFACE up..."; $SUDO ip link set "$INTERFACE" up || true; sleep 2
  fi
  if ! $SUDO nmcli device show "$INTERFACE" >/dev/null 2>&1; then
    log_msg "Setting $INTERFACE to managed yes"; $SUDO nmcli device set "$INTERFACE" managed yes || true; sleep 2
    $SUDO nmcli device wifi rescan ifname "$INTERFACE" 2>/dev/null || true
  fi
  local st; st="$(nm_state)"; log_msg "Interface $INTERFACE state: ${st:-unknown}"
  return 0
}

# --- Band helper ---
freqs_for_band() {
  case "${1:-2.4}" in
    2.4) echo "2412 2417 2422 2427 2432 2437 2442 2447 2452 2457 2462 2467 2472" ;;
    5)   echo "5180 5200 5220 5240 5260 5280 5300 5320 5500 5520 5540 5560 5580 5600 5620 5640 5660 5680 5700 5720 5745 5765 5785 5805 5825" ;;
    both) freqs_for_band 2.4; freqs_for_band 5 ;;
    *) freqs_for_band 2.4 ;;
  esac
}

get_current_bssid() {
  local b; b=$(iwconfig "$INTERFACE" 2>/dev/null | awk '/Access Point:/ {print $6; exit}')
  b=$(echo "$b" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
  [[ "$b" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] && echo "$b" || echo ""
}

# Enhanced BSSID discovery with nmcli + iw fallback
discover_bssids_for_ssid() {
  local ss="$1" now; now=$(date +%s)
  (( now - LAST_SCAN_TIME < ROAMING_SCAN_INTERVAL )) && return 0
  log_msg "🔍 Scanning (${WIFI_BAND_PREFERENCE}) for BSSIDs broadcasting SSID: $ss"

  DISCOVERED_BSSIDS=(); BSSID_SIGNALS=()

  # Explicit rescan on chosen band(s)
  case "$WIFI_BAND_PREFERENCE" in
    2.4) nmcli device wifi rescan ifname "$INTERFACE" freq $(freqs_for_band 2.4) >/dev/null 2>&1 ;;
    5)   nmcli device wifi rescan ifname "$INTERFACE" freq $(freqs_for_band 5)   >/dev/null 2>&1 ;;
    both) nmcli device wifi rescan ifname "$INTERFACE" >/dev/null 2>&1 ;;  # full-band scan
    *)   nmcli device wifi rescan ifname "$INTERFACE" >/dev/null 2>&1 ;;
  esac
  sleep 2

  # --- Primary: nmcli ---
  while IFS=: read -r bssid ssid signal; do
    [[ "$ssid" != "$ss" ]] && continue
    [[ -z "$bssid" || -z "$signal" ]] && continue
    local signal_dbm=$(( signal / 2 - 100 ))
    (( signal_dbm >= MIN_SIGNAL_THRESHOLD )) || continue
    DISCOVERED_BSSIDS["$bssid"]="$ssid"
    BSSID_SIGNALS["$bssid"]="$signal_dbm"
    log_msg "📡 Found BSSID (nmcli): $bssid (Signal: ${signal_dbm} dBm, ${signal}%)"
  done < <(nmcli -t -f BSSID,SSID,SIGNAL device wifi list ifname "$INTERFACE" 2>/dev/null)

  # --- Fallback: iw (if nmcli gave nothing) ---
  if (( ${#DISCOVERED_BSSIDS[@]} == 0 )); then
    log_msg "⚠️  nmcli found nothing, falling back to iw scan"
    iw dev "$INTERFACE" scan 2>/dev/null | awk -v target="$ss" '
      /^BSS/ { bssid=$2 }
      /SSID:/ { ssid=$2 }
      /signal:/ { sig=$2 }
      bssid && ssid==target {
        printf "%s %s %s\n", bssid, ssid, sig
        bssid=""; ssid=""; sig=""
      }
    ' | while read -r bssid ssid sig; do
      [[ -z "$bssid" || -z "$sig" ]] && continue
      local signal_dbm="${sig%.*}"   # iw already gives dBm
      (( signal_dbm >= MIN_SIGNAL_THRESHOLD )) || continue
      DISCOVERED_BSSIDS["$bssid"]="$ssid"
      BSSID_SIGNALS["$bssid"]="$signal_dbm"
      log_msg "📡 Found BSSID (iw): $bssid (Signal: ${signal_dbm} dBm)"
    done
  fi

  LAST_SCAN_TIME="$now"
  local count=${#DISCOVERED_BSSIDS[@]}

  if (( count == 0 )); then
    log_msg "❌ No BSSIDs found for SSID: $ss"
    return 1
  elif (( count == 1 )); then
    log_msg "ℹ️ Single BSSID found - roaming not possible"
  else
    log_msg "✅ Multiple BSSIDs found ($count) - roaming enabled!"
    for b in "${!DISCOVERED_BSSIDS[@]}"; do
      log_msg "   Available: $b (${BSSID_SIGNALS[$b]} dBm)"
    done
  fi
  return 0
}



select_roaming_target() {
  local cur="$1" best="" best_sig=-100
  for b in "${!DISCOVERED_BSSIDS[@]}"; do
    [[ "$b" == "$cur" ]] && continue
    local s="${BSSID_SIGNALS[$b]}"
    (( s > MIN_SIGNAL_THRESHOLD )) || continue
    if (( s > best_sig )); then best_sig=$s; best="$b"; fi
  done
  [[ -n "$best" ]] && echo "$best" || echo ""
}

perform_roaming() {
  local target_bssid="$1" target_ssid="$2" target_password="$3"
  local tmp_name="wifi-roam-$(echo $target_bssid | tr ':' '-')-$$"
  log_msg "🔄 Initiating roaming to BSSID: $target_bssid (SSID: $target_ssid)"

  # DON'T delete existing connections - this was the problem!
  # prune_same_ssid_profiles "$target_ssid"  # <-- This line causes issues

  # Fresh scan to ensure BSSID visibility
  nmcli device wifi rescan ifname "$INTERFACE" >/dev/null 2>&1
  sleep 3

  # Verify target BSSID is visible
  if ! nmcli device wifi list ifname "$INTERFACE" | grep -qi "$target_bssid"; then
    log_msg "❌ Target BSSID $target_bssid not currently visible"
    return 1
  fi

  # Create BSSID-locked roaming profile (using exact case from scan)
  log_msg "Creating roaming profile for $target_bssid"
  if ! nmcli con add type wifi ifname "$INTERFACE" con-name "$tmp_name" ssid "$target_ssid" \
       802-11-wireless.bssid "$target_bssid" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$target_password" \
       ipv4.method auto ipv6.method ignore connection.autoconnect no >/dev/null 2>&1; then
    log_msg "❌ Failed to create roaming profile for $target_bssid"
    return 1
  fi

  # Activate the new connection
  log_msg "Activating roaming connection..."
  if ! nmcli --wait 45 con up "$tmp_name" ifname "$INTERFACE" >/dev/null 2>&1; then
    log_msg "❌ Roaming activation failed"
    nmcli con delete "$tmp_name" 2>/dev/null || true
    return 1
  fi

  # Verify we're actually connected to the target BSSID
  sleep 5
  local new_bssid
  new_bssid="$(iw dev "$INTERFACE" link | awk '/Connected to/{print toupper($3)}')"
  local target_upper=$(echo "$target_bssid" | tr '[:lower:]' '[:upper:]')
  
  # Clean up the temporary profile
  nmcli con delete "$tmp_name" 2>/dev/null || true

  if [[ "$new_bssid" == "$target_upper" ]]; then
    log_msg "✅ Roaming successful! Connected to: $new_bssid"
    CURRENT_BSSID="$new_bssid"
    LAST_ROAM_TIME="$(date +%s)"
    return 0
  else
    log_msg "❌ Roaming verification failed (connected to: ${new_bssid:-unknown}, expected: $target_upper)"
    return 1
  fi
}

connect_to_wifi_with_roaming() {
  local ssid="$1" password="$2"
  log_msg "Connecting to Wi-Fi (roaming enabled=${ROAMING_ENABLED}) for SSID '$ssid'"

  # Discover candidates
  discover_bssids_for_ssid "$ssid" || true

  # Pick strongest if we have any
  local target_bssid="" best_signal=-100
  for b in "${!DISCOVERED_BSSIDS[@]}"; do
    local s="${BSSID_SIGNALS[$b]}"
    [[ -n "$s" && "$s" -gt "$best_signal" ]] && best_signal="$s" && target_bssid="$b"
  done

  # Try BSSID-locked first if we have one
  if [[ -n "$target_bssid" ]]; then
    log_msg "Connecting via specific BSSID $target_bssid ($best_signal dBm)"
    if connect_locked_bssid "$target_bssid" "$ssid" "$password"; then
      :
    else
      log_msg "Locked connect failed; falling back to direct connect"
    fi
  fi

  # Fallback: standard “connect by SSID”
  local state
  state="$(nmcli -t -f GENERAL.STATE device show "$INTERFACE" 2>/dev/null | cut -d: -f2 | awk '{print $1}' || echo "0")"
  if [[ "$state" != "100" ]]; then
    $SUDO nmcli dev disconnect "$INTERFACE" 2>/dev/null || true
    sleep 1
    local OUT
    if ! OUT="$($SUDO nmcli --wait 45 device wifi connect "$ssid" password "$password" ifname "$INTERFACE" 2>&1)"; then
      log_msg "Direct connect failed: ${OUT}"
      return 1
    else
      log_msg "Direct connect success: ${OUT}"
    fi
  fi

  # Verify IP
  log_msg "Waiting for IP address..."
  for _ in {1..20}; do
    local ip
    ip="$(ip addr show "$INTERFACE" | awk '/inet /{print $2; exit}')"
    if [[ -n "$ip" ]]; then
      log_msg "IP address: $ip"
      break
    fi
    sleep 2
  done

  # Record current BSSID for status/roam decisions
  CURRENT_BSSID="$(iw dev "$INTERFACE" link | awk '/Connected to/{print tolower($3)}')"

  # If we don't have its signal in the map (e.g., discovery failed earlier), stash it
  if [[ -n "$CURRENT_BSSID" && -z "${BSSID_SIGNALS[$CURRENT_BSSID]:-}" ]]; then
    local sig="$(iw dev "$INTERFACE" link | awk '/signal:/{print $2}')"
    [[ -n "$sig" ]] && BSSID_SIGNALS["$CURRENT_BSSID"]="$sig"
  fi

  log_msg "Successfully connected to $ssid (BSSID=${CURRENT_BSSID:-unknown})"
  return 0
}

should_perform_roaming() {
  [[ "$ROAMING_ENABLED" != "true" ]] && return 1
  local now; now=$(date +%s)
  (( now - LAST_ROAM_TIME < ROAMING_INTERVAL )) && return 1
  (( ${#DISCOVERED_BSSIDS[@]} < 2 )) && return 1
  return 0
}

manage_roaming() {
    if [[ "$ROAMING_ENABLED" != "true" ]]; then
        return 0
    fi

    # Keep the candidate list fresh
    discover_bssids_for_ssid "$SSID" || return 0

    if should_perform_roaming; then
        log_msg "Roaming interval reached; evaluating..."
        CURRENT_BSSID="$(iwconfig "$INTERFACE" 2>/dev/null | awk '/Access Point/ {print $6}' | tr '[:upper:]' '[:lower:]')"

        local target
        target="$(select_roaming_target "$CURRENT_BSSID")"
        if [[ -n "$target" ]]; then
            if perform_roaming "$target" "$SSID" "$PASSWORD"; then
                log_msg "Roaming completed"
            else
                log_msg "Roaming attempt failed"
            fi

            # --- NEW: re-validate connection and recover if needed
            if ! ensure_connected; then
                log_msg "Post-roam: no usable connection; deferring traffic this cycle"
                return 1
            fi

            # short settle time
            sleep 5
        else
            log_msg "No better BSSID found; staying on $CURRENT_BSSID"
        fi
    fi
}


# --- Traffic ---
test_basic_connectivity() {
    log_msg "Testing connectivity on $INTERFACE..."

    # --- DNS sanity check (informational only) ---
    if getent hosts google.com >/dev/null 2>&1; then
        log_msg "DNS resolution OK"
    else
        log_msg "DNS resolution appears broken"
    fi

    local success_count=0
    local test_count=0

    # HTTPS reachability tests
    for url in "${TEST_URLS[@]}"; do
        ((test_count++))
        if timeout 15 curl --interface "$INTERFACE" --max-time 10 -fsSL -o /dev/null "$url" 2>/dev/null; then
            log_msg "Connectivity test passed: $url"
            ((success_count++))
        else
            log_msg "Connectivity test failed: $url"
        fi
        sleep 1
    done

    # ICMP sanity
    ((test_count++))
    if timeout 10 ping -I "$INTERFACE" -c 3 -W 2 8.8.8.8 >/dev/null 2>&1; then
        log_msg "Ping connectivity test passed"
        ((success_count++))
    else
        log_msg "Ping connectivity test failed"
    fi

    log_msg "Connectivity: $success_count/$test_count tests passed"
    if (( success_count > 0 )); then
        return 0
    else
        return 1
    fi
}


generate_ping_traffic() {
  log_msg "Generating ping traffic (${PING_COUNT} per target)"
  for t in "${PING_TARGETS[@]}"; do
    timeout 30 ping -I "$INTERFACE" -c "$PING_COUNT" -i 0.5 "$t" >/dev/null 2>&1 && \
      log_msg "Ping successful: $t" || log_msg "Ping failed: $t"
  done
}

generate_download_traffic() {
  log_msg "Starting download traffic (${CONCURRENT_DOWNLOADS} concurrent, ${DL_SIZE} bytes each)"
  local pids=() ok=0
  for ((i=0; i<CONCURRENT_DOWNLOADS; i++)); do
    {
      local url="${DOWNLOAD_URLS[$((RANDOM % ${#DOWNLOAD_URLS[@]}))]}"
      local st=$(date +%s)
      if timeout 180 curl --interface "$INTERFACE" --max-time 120 --range "0-$DL_SIZE" -sSL -o /dev/null "$url"; then
        local dur=$(( $(date +%s) - st ))
        echo "[$(date '+%F %T')] WIFI-GOOD: Download completed: $(basename "$url") (${dur}s)" >>"$LOG_FILE"
      else
        echo "[$(date '+%F %T')] WIFI-GOOD: Download failed: $(basename "$url")" >>"$LOG_FILE"
      fi
    } & pids+=($!)
  done
  for pid in "${pids[@]}"; do if wait "$pid" 2>/dev/null; then ((ok++)); fi; done
  log_msg "Download traffic completed: $ok/$CONCURRENT_DOWNLOADS successful"
}

maybe_speedtest() {
  [[ "$ENABLE_SPEEDTEST" == "true" ]] || return 0
  command -v speedtest >/dev/null 2>&1 || command -v speedtest-cli >/dev/null 2>&1 || { log_msg "speedtest not installed; skipping"; return 0; }
  local stamp="/tmp/wifi_good_speedtest.last" now last=0
  now=$(date +%s); [[ -f "$stamp" ]] && last="$(cat "$stamp" 2>/dev/null || echo 0)"
  (( now - last < SPEEDTEST_INTERVAL )) && return 0
  log_msg "Running speedtest..."
  if command -v speedtest >/dev/null 2>&1; then
    speedtest --accept-license --accept-gdpr --progress=no >>"$LOG_FILE" 2>&1 || log_msg "speedtest failed"
  else
    speedtest-cli --simple >>"$LOG_FILE" 2>&1 || log_msg "speedtest-cli failed"
  fi
  echo "$now" > "$stamp"
}

maybe_youtube_pull() {
  [[ "$ENABLE_YOUTUBE" == "true" ]] || return 0
  command -v yt-dlp >/dev/null 2>&1 || { log_msg "yt-dlp not installed; skipping"; return 0; }
  local stamp="/tmp/wifi_good_yt.last" now last=0
  now=$(date +%s); [[ -f "$stamp" ]] && last="$(cat "$stamp" 2>/dev/null || echo 0)"
  (( now - last < YOUTUBE_INTERVAL )) && return 0
  log_msg "YouTube metadata fetch via yt-dlp"
  yt-dlp --skip-download --no-warnings --quiet --no-call-home "$YOUTUBE_URL" >>"$LOG_FILE" 2>&1 || log_msg "yt-dlp failed"
  echo "$now" > "$stamp"
}

generate_realistic_traffic() {
    if [[ "$ENABLE_INTEGRATED_TRAFFIC" != "true" ]]; then
        log_msg "Integrated traffic generation disabled"
        return 0
    fi

    # --- Health gate: don't run traffic unless link is healthy ---
    local st ip ss
    st="$(nm_state)"
    ip="$(current_ip)"
    ss="$(current_ssid)"
    if [[ "$st" != "100" || -z "$ip" || "$ss" != "$SSID" ]]; then
        log_msg "Traffic suppressed: link not healthy (state=$st, ip=${ip:-none}, ssid=${ss:-none})"
        return 1
    fi

    log_msg "Starting realistic traffic generation (intensity: $TRAFFIC_INTENSITY)..."

    # Basic connectivity check (HTTPS + ping)
    if ! test_basic_connectivity; then
        log_msg "Basic connectivity failed; skipping traffic"
        return 1
    fi

    # Light/continuous traffic
    generate_ping_traffic

    # Periodic heavier downloads
    local now stamp last
    now=$(date +%s)
    stamp="/tmp/wifi_good_download.last"
    last=0
    [[ -f "$stamp" ]] && last="$(cat "$stamp" 2>/dev/null || echo 0)"

    if (( now - last >= DOWNLOAD_INTERVAL )); then
        generate_download_traffic
        echo "$now" > "$stamp"
    fi

    log_msg "Realistic traffic generation cycle completed"
    return 0
}


# --- Main loop ---
main_loop() {
  log_msg "Starting enhanced good client"
  local last_cfg=0 last_traffic=0
  while true; do
    local now=$(date +%s)
    (( now - last_cfg > 600 )) && { read_wifi_config && log_msg "Config refreshed"; last_cfg=$now; }
    check_wifi_interface || { sleep "$REFRESH_INTERVAL"; continue; }

    local st ip ss; st="$(nm_state)"; ip="$(current_ip)"; ss="$(current_ssid)"
    if [[ "$st" == "100" && -n "$ip" && "$ss" == "${SSID:-}" ]]; then
      log_msg "Connection healthy: SSID=$ss, IP=$ip"
    else
      log_msg "Connection issue: state=${st:-?} ip=${ip:-none} current=${ss:-none} expected=${SSID:-unset}"
      if connect_to_wifi_with_roaming "${SSID:-}" "${PASSWORD:-}"; then
        log_msg "Wi-Fi connection (re)established"; sleep 5
      else
        log_msg "Reconnect failed; retrying later"; sleep "$REFRESH_INTERVAL"; continue
      fi
    fi

    # Roaming + traffic
    manage_roaming
    (( now - last_traffic > 30 )) && { generate_realistic_traffic && last_traffic=$now; }

    # Current BSSID status
    CURRENT_BSSID=$(get_current_bssid)
    [[ -n "$CURRENT_BSSID" ]] && log_msg "Current BSSID $CURRENT_BSSID (${BSSID_SIGNALS[$CURRENT_BSSID]:-unknown} dBm) | Seen: ${#DISCOVERED_BSSIDS[@]}"

    log_msg "Good client operating normally"
    sleep "$REFRESH_INTERVAL"
  done
}

cleanup_and_exit() {
  log_msg "Cleaning up good client..."
  $SUDO nmcli device disconnect "$INTERFACE" 2>/dev/null || true
  log_msg "Stopped"
  exit 0
}
trap cleanup_and_exit SIGTERM SIGINT

# --- Init ---
mkdir -p "$LOG_DIR" 2>/dev/null || true
log_msg "Enhanced Wi-Fi Good Client Starting..."
log_msg "Interface: $INTERFACE | Hostname: $HOSTNAME"
log_msg "Roaming: ${ROAMING_ENABLED} (interval ${ROAMING_INTERVAL}s; scan ${ROAMING_SCAN_INTERVAL}s; min ${MIN_SIGNAL_THRESHOLD}dBm)"
read_wifi_config || true

main_loop
