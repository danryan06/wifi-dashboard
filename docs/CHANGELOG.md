# 📝 Changelog

All notable changes to the Wi-Fi Test Dashboard project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [5.2.1] - 2026-09-24

### 🐛 Fixed
- **BSSID verification false negatives**: `get_current_bssid` normalizes to
  uppercase but the three verification checks in `connect_locked_bssid`
  compared against a lowercased target, so every successful BSSID-locked
  connection was declared a "mismatch" and torn down. Comparisons are now
  case-insensitive.
- **`key-mgmt: property is missing` on fallback connect**: when nmcli cannot
  infer the network's security type from a cold scan cache, the fallback
  connect now retries with an explicitly configured WPA-PSK profile.
- **Double log prefix**: `log_msg` no longer prefixes messages before handing
  them to `log_msg_with_rotation`, which adds its own prefix.
- **Phantom roam to current BSSID**: when no roam target was found, the
  target extraction in `manage_roaming` could pick up the current BSSID from
  the selector's log output and needlessly disconnect/reconnect to the AP the
  client was already on, every roaming interval. Roams to the current BSSID
  are now skipped.

## [5.2.0] - 2026-09-24

### 🎉 Major Release: Multi-Client Scaling

#### Added
- **Multi-adapter support**: every detected USB Wi-Fi adapter becomes an
  individual simulated client (unique MAC + DHCP hostname in Mist)
- `wifi-client@<iface>.service` systemd template for extra adapters, driven by
  `scripts/traffic/wifi_client.sh` dispatcher
- `configs/clients.conf`: auto-generated per-interface personas
  (`iface:role:hostname:intensity:roaming`), manually editable
- `scripts/apply_netem.sh`: latency/loss/jitter/bandwidth emulation for any
  interface (ported from the Optimizing-Code branch); dashboard netem tab now
  has an interface selector
- Multi-NIC sysctls (`arp_filter`, `arp_announce`, loose `rp_filter`) so many
  interfaces coexist on one subnet
- MIT `LICENSE` file and GitHub Actions CI (bash -n, ShellCheck errors,
  Python compile check)

#### Changed
- Installer installs from a single git revision (local checkout or shallow
  clone) instead of per-file raw.githubusercontent downloads; all stale
  embedded fallback copies of app.py/templates/scripts were removed
- `fix-services.sh` repairs by re-running the installed assignment/service
  scripts instead of embedding its own script copies (1147 → ~110 lines)
- Dashboard dynamically renders services, log tabs, throughput and netem
  options for however many clients are configured

#### Fixed
- `07-services.sh` ignored auto-detected interface assignments due to a
  variable-name mismatch with `04.5-auto-interface-assignment.sh`
- `get_current_bssid()` nmcli parsing broke on escaped colons in BSSIDs and
  always fell through to the `iw` fallback
- Unit-provided `INTERFACE`/roaming/intensity env vars were clobbered by
  `settings.conf` sourcing in the client scripts

#### Removed
- Hostname lock files and staggered service startup (15–25s sleeps): DHCP
  hostnames are per-interface, so clients start independently
- Unused `scripts/install/01-dependencies.sh` (enhanced variant is used)

### Added (earlier unreleased work)
- Complete troubleshooting documentation
- Enhanced installation guide

### Changed (earlier unreleased work)
- Improved error handling in traffic generation
- Enhanced service restart policies

## [5.0.0] - 2024-XX-XX

### 🎉 Major Release: Advanced Traffic Generation

#### Added
- **YouTube Traffic Simulation**: Realistic video streaming traffic using yt-dlp
- **Enhanced Speedtest Integration**: Official Ookla CLI and Python speedtest-cli support
- **Per-Interface Traffic Control**: Individual traffic types and intensities per interface
- **Authentication Failure Simulation**: Multiple attack patterns for security testing
- **Advanced Traffic Control Page**: Web interface for traffic management
- **Comprehensive Logging**: Detailed logs for all services and traffic types
- **Service Management Interface**: Start/stop/restart individual components
- **Network Emulation**: Built-in latency and packet loss simulation (netem)
- **System Controls**: Remote reboot/shutdown capabilities
- **Diagnostic Tools**: Built-in system health checks and troubleshooting

#### Enhanced
- **Traffic Generator Script**: Complete rewrite