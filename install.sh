#!/bin/bash
set -euo pipefail
BASE="$(cd "$(dirname "$0")" && pwd)"
. "$BASE/installer.conf"
MODE="${1:---auto}"
HOTR=/userdata/system/hotr
HOTR_DATA=/userdata/system/hook-of-the-reaper
SINDEN_ENABLE_FILE="$HOTR/sinden-tcp.enabled"
SINDEN_PTY_BRIDGE_FILE="$HOTR/sinden-pty-bridge.enabled"
LOG=/userdata/system/logs/hotr-install.log
GENROOT="$(printf '%s\n' /usr/lib/python*/site-packages/configgen/generators | sort -V | while read -r candidate; do [ -d "$candidate" ] && printf '%s\n' "$candidate"; done | tail -n1)"

msg(){ printf '[HOTR] %s\n' "$*"; }
warn(){ printf '[HOTR WARNING] %s\n' "$*" >&2; }
die(){ printf '[HOTR ERROR] %s\n' "$*" >&2; exit 1; }

# Copy a directory tree without clobbering anything that is already there.
# Game files are user-editable content: a release must add the ones a machine is
# missing and leave existing ones alone (an operator may have tuned them, and a
# newer HOTR build ships its own set).
copy_missing_tree(){
  local src="$1" dst="$2"
  [ -d "$src" ] || return 0
  mkdir -p "$dst"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --ignore-existing "$src"/ "$dst"/ && return 0
  fi
  ( cd "$src" && find . -type d -exec mkdir -p "$dst/{}" \; ) || true
  ( cd "$src" && find . -type f ! -exec test -e "$dst/{}" \; -exec cp -a {} "$dst/{}" \; ) || true
}

# A Sinden gun that HOTR drives in ammo mode (its default recoil priority for a
# Sinden) can only recoil through the gun's own trigger recoil, which HOTR arms
# solely from the game file option Sinden_Trigger_Recoil. Add it to every
# ammo-mode game file that lacks it; the tool is idempotent and preserves each
# file's mix of line endings. Call this only after every step that writes game
# files - install-mame-msop.sh ships its own MAME copies - and verify the
# result: a game file that lost the option again is invisible until the gun
# simply does not kick.
configure_sinden_trigger_recoil(){
  local tool="$BASE/payload/system/hotr-sinden-trigger-recoil" summary
  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 is missing; Sinden trigger recoil was not configured in the game files."
    return 0
  fi
  if summary="$(python3 "$BASE/payload/system/hotr-sinden-trigger-recoil" --dir "$HOTR_DATA/defaultLG")"; then
    msg "Sinden trigger recoil in game files: $summary"
  else
    warn "Could not configure Sinden trigger recoil in the game files; run hotr-sinden-trigger-recoil to retry."
    return 0
  fi
  summary="$(python3 "$tool" --dir "$HOTR_DATA/defaultLG" --check --quiet)" && return 0
  warn "Game files still lacked the option after patching ($summary); retrying."
  python3 "$tool" --dir "$HOTR_DATA/defaultLG" >/dev/null || true
  if summary="$(python3 "$tool" --dir "$HOTR_DATA/defaultLG" --check --quiet)"; then
    msg "Sinden trigger recoil verified in game files: $summary"
  else
    warn "Ammo-mode game files still lack Sinden_Trigger_Recoil ($summary); run hotr-sinden-trigger-recoil."
  fi
}

# Fail fast with a readable message when the machine cannot run this
# installer. A missing tool used to surface much later (a failed download or an
# extraction error). This runs before the upgrade cleanup, so a broken
# precondition never removes a working install.
preflight(){
  [ "$(id -u)" -eq 0 ] || die "Run this installer as root."
  [ "$(uname -m)" = "x86_64" ] || die "This release targets x86_64 only."

  # python3 does the downloads and the config edits, tee duplicates the install
  # log, unzip validates patches.zip; tar is only needed for the emulator
  # archives, which --infrastructure-only does not install.
  local required="python3 tee unzip" tool optional="" missing=""
  case "$MODE" in
    --infrastructure-only) optional="tar" ;;
    *) required="$required tar" ;;
  esac
  for tool in $required; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
  done
  [ -z "$missing" ] || die "Missing required tool(s):$missing These ship with Batocera; repair the system image and re-run."
  for tool in rsync start-stop-daemon setsid batocera-save-overlay $optional; do
    command -v "$tool" >/dev/null 2>&1 || warn "Optional tool '$tool' is missing; the parts that use it fall back or are skipped."
  done

  [ -w /userdata ] || die "/userdata is not writable."
  local free_kb required_kb=1048576 warn_kb=2097152
  if [ "$MODE" = "--infrastructure-only" ]; then
    required_kb=307200
    warn_kb=786432
  fi
  free_kb="$(df -Pk /userdata 2>/dev/null | awk 'NR==2 {print $4}')"
  free_kb="${free_kb:-0}"
  [ "$free_kb" -ge "$required_kb" ] || die "/userdata has $((free_kb / 1024)) MiB free; this install needs at least $((required_kb / 1024)) MiB."
  [ "$free_kb" -ge "$warn_kb" ] || warn "/userdata has only $((free_kb / 1024)) MiB free; a later update or emulator install may run out of space."
  msg "Preflight OK: x86_64, required tools present, $((free_kb / 1024)) MiB free on /userdata."
}

preflight

# Refuse a versioned package for the wrong Batocera release before touching an
# existing HOTR install. Old packages without this marker remain supported.
VER=""
[ -r /usr/share/batocera/batocera.version ] && VER="$(cat /usr/share/batocera/batocera.version)"
[ -z "$VER" ] && VER="$(batocera-info 2>/dev/null | head -1 || true)"
RELEASE_SERIES=""
[ -r "$BASE/payload/.hotr-batocera-series" ] && RELEASE_SERIES="$(tr -d '[:space:]' < "$BASE/payload/.hotr-batocera-series")"
case "$VER" in *44*) TARGET_SERIES=44 ;; *43*) TARGET_SERIES=43 ;; *) TARGET_SERIES="" ;; esac
case "$RELEASE_SERIES" in
  43|44) [ "$RELEASE_SERIES" = "$TARGET_SERIES" ] || die "This is a Batocera $RELEASE_SERIES package, but this system is ${VER:-unknown}." ;;
  "") ;;
  *) die "Invalid release series marker: $RELEASE_SERIES" ;;
esac

# Cleanly remove an older HOTR integration before replacing files. This keeps
# stale generators, native EmulationStation backups, and old services from
# surviving an upgrade. The persistent HOTR data directory is preserved by
# uninstall.sh.
if [ -x "$BASE/uninstall.sh" ] && { [ -d "$HOTR" ] || [ -e /usr/bin/hotr-gun-assignment ] || [ -e /userdata/system/services/hotr ]; }; then
  msg "Removing previous HOTR installation before upgrade..."
  # Upgrade cleanup must not prevent a fresh install. In particular, older
  # Batocera 43 Sinden helper variants may not have a removable backup.
  if ! "$BASE/uninstall.sh"; then
    warn "Previous HOTR cleanup did not complete; continuing with the installation."
  fi
fi

mkdir -p /userdata/system/logs
exec > >(tee -a "$LOG") 2>&1

msg "Detected Batocera: ${VER:-unknown}"
echo "$VER" | grep -Eq '(^|[^0-9])(43|44)([.]|[^0-9]|$)' || warn "Designed/tested for Batocera 43/44; continuing."

mkdir -p "$HOTR"/{bin,emulators/duckstation,emulators/pcsx2,scripts,software/hook-of-the-reaper,backups,install,tools} \
         "$HOTR_DATA"/{data,defaultLG} /userdata/system/services /userdata/system/configs/emulationstation /userdata/roms/ports /userdata/roms/hotr

fetch_latest_asset(){
  local repo="$1" regex="$2" out="$3"
  python3 - "$repo" "$regex" "$out" <<'PY'
import json,re,sys,urllib.request
repo,rx,out=sys.argv[1:]
req=urllib.request.Request(f"https://api.github.com/repos/{repo}/releases/latest",headers={"User-Agent":"HOTR-Batocera43"})
with urllib.request.urlopen(req, timeout=30) as r: data=json.load(r)
for asset in data.get("assets",[]):
    if re.search(rx, asset.get("name",""), re.I):
        req=urllib.request.Request(asset["browser_download_url"],headers={"User-Agent":"HOTR-Batocera43"})
        with urllib.request.urlopen(req, timeout=120) as src, open(out,"wb") as dst:
            while chunk := src.read(1024*1024): dst.write(chunk)
        raise SystemExit(0)
raise SystemExit("No release asset matched: "+rx)
PY
}

configure_sinden_tcp() {
  local answer=""
  case "${HOTR_SINDEN_TCP:-}" in
    1|yes|YES|true|TRUE|on|ON) answer="y" ;;
    0|no|NO|false|FALSE|off|OFF) answer="n" ;;
    *)
      if [ -t 0 ] && [ -t 1 ]; then
        printf '[HOTR] Enable Sinden HOTR recoil broker? [y/N] '
        IFS= read -r answer || answer=""
      else
        # Release installs are often piped from curl and have no tty. Do not
        # silently turn off a previously selected optional component during an
        # update; a first non-interactive install remains disabled.
        [ -f "$SINDEN_ENABLE_FILE" ] && answer="y" || answer="n"
      fi
      ;;
  esac
  case "$answer" in
    y|Y|yes|YES)
      touch "$SINDEN_ENABLE_FILE"
      msg "Sinden HOTR recoil broker enabled."
      ;;
    *)
      rm -f "$SINDEN_ENABLE_FILE"
      msg "Sinden HOTR recoil broker disabled (can be enabled later with HOTR_SINDEN_TCP=1)."
      ;;
  esac
}

configure_sinden_tcp

# The PTY/worker bridge is retired (it is what made the gun stop aiming), but it
# stays available for troubleshooting guns the direct backend cannot drive.
configure_sinden_pty_bridge() {
  case "${HOTR_SINDEN_PTY_BRIDGE:-}" in
    1|yes|YES|true|TRUE|on|ON)
      touch "$SINDEN_PTY_BRIDGE_FILE"
      msg "Sinden PTY bridge enabled (legacy; the direct backend is preferred)."
      ;;
    0|no|NO|false|FALSE|off|OFF)
      rm -f "$SINDEN_PTY_BRIDGE_FILE"
      msg "Sinden PTY bridge disabled; guns are written directly."
      ;;
    *)
      # Keep whatever the previous install chose; the default is off.
      ;;
  esac
}

configure_sinden_pty_bridge

extract_any(){
  local file="$1" dest="$2"; mkdir -p "$dest"
  if unzip -t "$file" >/dev/null 2>&1; then unzip -q "$file" -d "$dest"; return; fi
  if tar -tf "$file" >/dev/null 2>&1; then tar -xf "$file" -C "$dest"; return; fi
  return 1
}

install_duck_from_tree(){
  local src="$1" bin=""
  for candidate in \
    "$src/duckstation-lightgun-qt" "$src/duckstation-qt" \
    "$src/usr/bin/duckstation-lightgun-qt" "$src/usr/bin/duckstation-qt"; do
    [ -f "$candidate" ] && { bin="$candidate"; break; }
  done
  [ -n "$bin" ] || return 1
  rm -rf "$HOTR/emulators/duckstation"/*
  if [[ "$bin" == */usr/bin/* ]] && [ -d "$src/usr/share/duckstation-lightgun" ]; then
    cp -a "$src/usr/share/duckstation-lightgun"/. "$HOTR/emulators/duckstation/"
    cp -a "$bin" "$HOTR/emulators/duckstation/duckstation-lightgun-qt"
    [ -f "${bin%/*}/duckstation-lightgun-nogui" ] && cp -a "${bin%/*}/duckstation-lightgun-nogui" "$HOTR/emulators/duckstation/"
  else
    cp -a "$(dirname "$bin")"/. "$HOTR/emulators/duckstation/"
    [ "$(basename "$bin")" = duckstation-lightgun-qt ] || mv "$HOTR/emulators/duckstation/$(basename "$bin")" "$HOTR/emulators/duckstation/duckstation-lightgun-qt"
  fi
  cp -a "$BASE/payload/emulators/duckstation/MameOutputSender" "$HOTR/emulators/duckstation/MameOutputSender"
  chmod +x "$HOTR/emulators/duckstation/duckstation-lightgun-qt" "$HOTR/emulators/duckstation/MameOutputSender"
  msg "DuckStation HOTR installed."
}

install_pcsx2_from_tree(){
  local src="$1" bin=""
  for candidate in "$src/pcsx2-lightgun-qt" "$src/usr/bin/pcsx2-lightgun-qt" "$src/usr/pcsx2-lightgun/bin/pcsx2-lightgun-qt"; do
    [ -f "$candidate" ] && { bin="$candidate"; break; }
  done
  [ -n "$bin" ] || return 1
  rm -rf "$HOTR/emulators/pcsx2"/*
  cp -a "$(dirname "$bin")"/. "$HOTR/emulators/pcsx2/"
  cp -a "$BASE/payload/emulators/pcsx2/MameOutputSender" "$HOTR/emulators/pcsx2/MameOutputSender"
  chmod +x "$HOTR/emulators/pcsx2/pcsx2-lightgun-qt" "$HOTR/emulators/pcsx2/MameOutputSender"
  msg "PCSX2 HOTR native Batocera build installed."
}

install_pcsx2_patches(){
  local tmp archive="" dest="$HOTR/emulators/pcsx2/resources/patches.zip"
  tmp="$(mktemp -d)"
  mkdir -p "${dest%/*}"

  # Prefer the current official release, but retain the bundled archive as an
  # offline fallback. PCSX2 reads this from its resources directory.
  if fetch_latest_asset "PCSX2/pcsx2_patches" '^patches\.zip$' "$tmp/patches.zip" \
      && unzip -t "$tmp/patches.zip" >/dev/null 2>&1; then
    archive="$tmp/patches.zip"
    msg "Downloaded current PCSX2 patches from the official release."
  elif [ -f "$BASE/payload/emulators/pcsx2/resources/patches.zip" ]; then
    archive="$BASE/payload/emulators/pcsx2/resources/patches.zip"
    warn "Could not download current PCSX2 patches; using bundled archive."
  else
    warn "PCSX2 patches archive unavailable online and no bundled fallback exists."
  fi
  [ -n "$archive" ] && install -m 0644 "$archive" "$dest"
  rm -rf "$tmp"
}

install_pcsx2_cheats(){
  local src="$HOTR/emulators/pcsx2/cheats"
  local dest=/userdata/cheats/ps2
  [ -d "$src" ] || return 0
  mkdir -p "$dest"
  # Seed bundled cheats without replacing files the user has edited or added.
  for cheat in "$src"/*.pnach; do
    [ -f "$cheat" ] || continue
    [ -e "$dest/$(basename "$cheat")" ] || cp -a "$cheat" "$dest/"
  done
}

install_bundled_emulators(){
  install_duck_from_tree "$BASE/payload/emulators/duckstation" || true
  install_pcsx2_from_tree "$BASE/payload/emulators/pcsx2" || true
}

install_github_emulators(){
  [ "${ENABLE_GITHUB_EMULATOR_DOWNLOADS:-0}" = 1 ] || return 1
  local tmp; tmp="$(mktemp -d)"
  if fetch_latest_asset "$DUCKSTATION_GITHUB_REPO" "$DUCKSTATION_ASSET_REGEX" "$tmp/duck.pkg"; then
    mkdir -p "$tmp/duck"; extract_any "$tmp/duck.pkg" "$tmp/duck" || die "Unsupported DuckStation archive."
    install_duck_from_tree "$tmp/duck" || die "DuckStation binary not found in downloaded archive."
  fi
  if fetch_latest_asset "$PCSX2_GITHUB_REPO" "$PCSX2_ASSET_REGEX" "$tmp/pcsx2.pkg"; then
    mkdir -p "$tmp/pcsx2"; extract_any "$tmp/pcsx2.pkg" "$tmp/pcsx2" || die "Unsupported PCSX2 archive."
    install_pcsx2_from_tree "$tmp/pcsx2" || die "PCSX2 binary not found in downloaded archive."
  fi
  rm -rf "$tmp"
}

case "$MODE" in
  --auto) install_bundled_emulators; if [ ! -x "$HOTR/emulators/duckstation/duckstation-lightgun-qt" ] || [ ! -x "$HOTR/emulators/pcsx2/pcsx2-lightgun-qt" ]; then install_github_emulators || true; fi ;;
  --bundled) install_bundled_emulators ;;
  --github-emulators) install_github_emulators || die "Enable GitHub emulator downloads in installer.conf." ;;
  --infrastructure-only) : ;;
  *) die "Usage: $0 [--auto|--bundled|--github-emulators|--infrastructure-only]" ;;
esac

install_pcsx2_patches
install_pcsx2_cheats

 # HOTR AppImage + persistent data. The payload intentionally has no nested
 # data/data directory. Accept both the release asset name and the normalized
 # runtime name used inside /userdata.
HOTR_ASSET=""
for candidate in \
  "$BASE/payload/hotr/hook-of-the-reaper" \
  "$BASE/payload/hotr/HookOfTheReaper-x86_64.AppImage"; do
  if [ -f "$candidate" ]; then HOTR_ASSET="$candidate"; break; fi
done
[ -n "$HOTR_ASSET" ] || die "HOTR AppImage missing from release payload."
cp -a "$HOTR_ASSET" "$HOTR/software/hook-of-the-reaper/hook-of-the-reaper"
chmod +x "$HOTR/software/hook-of-the-reaper/hook-of-the-reaper"
if [ ! -f "$HOTR_DATA/.seeded" ]; then
  cp -a "$BASE/payload/hotr/data"/. "$HOTR_DATA/data/"
  touch "$HOTR_DATA/.seeded"
fi
# Refresh versioned hardware command definitions without overwriting detected
# guns, player assignments or user settings.
for profile in alienUSB.hor blamcon.hor customUSB.hor fusion.hor iniDefault.hor jbgun4ir.hor lgDefault.hor mx24.hor nonDefaultLG.hor openFire.hor rs3Reaper.hor sinden.hor xGunner.hor xenas.hor; do
  [ -f "$BASE/payload/hotr/data/$profile" ] && cp -a "$BASE/payload/hotr/data/$profile" "$HOTR_DATA/data/$profile"
done
# Game profiles: add-only, so a release never overwrites a game file this
# machine already has.
copy_missing_tree "$BASE/payload/hotr/defaultLG" "$HOTR_DATA/defaultLG"
# The Sinden trigger-recoil option is added at the end of the install, after
# install-mame-msop.sh, which writes its own copies of the MAME game files:
# see configure_sinden_trigger_recoil().
rm -rf "$HOTR/software/hook-of-the-reaper/data" "$HOTR/software/hook-of-the-reaper/defaultLG"
ln -s "$HOTR_DATA/data" "$HOTR/software/hook-of-the-reaper/data"
ln -s "$HOTR_DATA/defaultLG" "$HOTR/software/hook-of-the-reaper/defaultLG"

# Userdata scripts/config.
cp -a "$BASE/payload/system/hotr-sinden-broker.py" "$HOTR/bin/hotr-sinden-broker.py"
cp -a "$BASE/payload/system/hotr-sinden-trigger-recoil" "$HOTR/bin/hotr-sinden-trigger-recoil"
chmod +x "$HOTR/bin/hotr-sinden-trigger-recoil"
# Operator tools: a read-only report (with an opt-in one-frame fire test) and a
# kill switch. They live next to the broker so they can import it directly.
cp -a "$BASE/scripts/hotr-sinden-check" "$HOTR/bin/hotr-sinden-check"
cp -a "$BASE/scripts/hotr-sinden-disable" "$HOTR/bin/hotr-sinden-disable"
# The worker launcher belongs to the retired PTY bridge; ship it only for the
# explicit opt-in so a default install carries no worker/PTY path at all.
if [ -f "$SINDEN_PTY_BRIDGE_FILE" ]; then
  cp -a "$BASE/payload/system/hotr-sinden-worker-launch" "$HOTR/bin/hotr-sinden-worker-launch"
else
  rm -f "$HOTR/bin/hotr-sinden-worker-launch"
fi
cp -a "$BASE/scripts/hotr-configgen-launch" "$BASE/scripts/add-emulator-config.sh" \
  "$BASE/scripts/hotr-theme-sync" "$HOTR/bin/"
cp -a "$BASE/payload/hotr/emulationstation" "$HOTR/"
cp -a "$BASE/scripts/custom-boot.sh" "$BASE/scripts/custom-stop.sh" "$HOTR/scripts/"
cp -a "$BASE/scripts/hotr-monitor" "$HOTR/tools/hotr-monitor"
cp -a "$BASE/scripts/hotr-service" /userdata/system/services/hotr
cp -a "$BASE/emulationstation/es_systems_hotr.cfg" /userdata/system/configs/emulationstation/es_systems_hotr.cfg
cp -a "$BASE/emulationstation/pcsx2_legacy_features.xml" "$HOTR/install/pcsx2_legacy_features.xml"
cp -a "$BASE/scripts/generate-es-features-hotr.py" "$HOTR/bin/generate-es-features-hotr.py"
chmod +x "$HOTR/bin/generate-es-features-hotr.py" "$HOTR/bin/hotr-theme-sync" "$HOTR/tools/hotr-monitor"
"$HOTR/bin/generate-es-features-hotr.py" "$HOTR/install/pcsx2_legacy_features.xml"

# Batocera 44 discovers emulators through package entry points. Register the
# HOTR DuckStation launcher separately so normal PSX remains stock.
# An empty result is expected on Batocera 43. Do not let pipefail turn that
# normal absence of the Batocera 44 launcher into an installer failure.
BATO_LAUNCH_ROOT="$(printf '%s\n' /usr/lib/python*/site-packages/batocera_launch | sort -V | while read -r candidate; do [ -d "$candidate" ] && printf '%s\n' "$candidate"; done | tail -n1 || true)"
if [ -n "$BATO_LAUNCH_ROOT" ]; then
  BATO_SITE="${BATO_LAUNCH_ROOT%/batocera_launch}"
  BATO_ENTRY="$BATO_SITE/batocera_launch-44.0.dist-info/entry_points.txt"
  install -m 0644 "$BASE/payload/batocera_launch/emulators/duckstation_lightgun.py" \
    "$BATO_LAUNCH_ROOT/emulators/duckstation_lightgun.py"
  install -m 0644 "$BASE/payload/batocera_launch/emulators/pcsx2_lightgun.py" \
    "$BATO_LAUNCH_ROOT/emulators/pcsx2_lightgun.py"
  if [ -f "$BATO_ENTRY" ]; then
    [ -f "$HOTR/backups/batocera_launch_entry_points.txt.original" ] || cp -a "$BATO_ENTRY" "$HOTR/backups/batocera_launch_entry_points.txt.original"
    grep -qx "duckstation-lightgun = batocera_launch.emulators.duckstation_lightgun:DuckstationLightgun" "$BATO_ENTRY" || \
      sed -i "/^duckstation-legacy =/a duckstation-lightgun = batocera_launch.emulators.duckstation_lightgun:DuckstationLightgun" "$BATO_ENTRY"
    grep -qx "pcsx2-lightgun = batocera_launch.emulators.pcsx2_lightgun:Pcsx2Lightgun" "$BATO_ENTRY" || \
      printf '%s\n' "pcsx2-lightgun = batocera_launch.emulators.pcsx2_lightgun:Pcsx2Lightgun" >> "$BATO_ENTRY"
  fi
fi
cp -a "$BASE/installer.conf" "$HOTR/install/installer.conf"
cp -a "$BASE/uninstall.sh" "$BASE/update.sh" "$BASE/check-install.sh" \
  "$BASE/scripts/hotr-debug-report.sh" "$BASE/scripts/hotr-status" \
  "$BASE/scripts/tests/hotr-sinden-full-selftest.sh" \
  "$BASE/scripts/tests/hotr-sinden-fakegun-selftest.sh" \
  "$BASE/scripts/tests/hotr-sinden-tools-selftest.sh" \
  "$BASE/scripts/tests/hotr-sinden-broker-selftest.sh" \
  "$BASE/scripts/tests/hotr-sinden-worker-selftest.sh" \
  "$BASE/scripts/tests/fake-gun-firmware-faithful.py" \
  "$BASE/scripts/tests/hotr-sinden-lab-mono.sh" \
  "$BASE/scripts/tests/hotr-sinden-native-helper-selftest.py" \
  "$BASE/scripts/patch-batocera-sinden-hotr.sh" "$HOTR/tools/"
chmod +x "$HOTR/tools/"*.sh "$HOTR/tools/"*.py "$HOTR/bin/"* "$HOTR/scripts/"*.sh /userdata/system/services/hotr

# Option A never patches the stock helper: LightgunMono keeps the real tty, the
# broker writes that tty write-only, and the aim/camera handshake is untouched.
# An install upgrading from an older release may still carry the retired worker
# patch; remove it here. The legacy bridge needs both the broker and the
# explicit opt-in.
if [ -f "$SINDEN_ENABLE_FILE" ] && [ -f "$SINDEN_PTY_BRIDGE_FILE" ]; then
  "$HOTR/tools/patch-batocera-sinden-hotr.sh" apply
else
  "$HOTR/tools/patch-batocera-sinden-hotr.sh" remove
fi

cp -a "$BASE/scripts/ports/HookOfTheReaper.sh" \
  "$BASE/scripts/ports/HOTR-Debug-Start.sh" "$BASE/scripts/ports/HOTR-Debug-Finish.sh" /userdata/roms/hotr/
chmod +x /userdata/roms/hotr/HookOfTheReaper.sh \
  /userdata/roms/hotr/HOTR-Debug-Start.sh /userdata/roms/hotr/HOTR-Debug-Finish.sh
# These were previously exposed as unrelated Ports entries. Remove only the
# old HOTR-owned files so an upgrade leaves the normal Ports collection intact.
rm -f /userdata/roms/ports/HookOfTheReaper.sh /userdata/roms/ports/HOTR-Setup.sh \
  /userdata/roms/ports/HOTR-Rescan-Guns.sh /userdata/roms/ports/HOTR-Debug-Start.sh \
  /userdata/roms/ports/HOTR-Debug-Finish.sh

"$HOTR/bin/hotr-theme-sync" --all
msg "Applied theme-native HOTR logos to installed themes."

CONF=/userdata/system/batocera.conf; touch "$CONF"
set_conf(){ local k="$1" v="$2"; sed -i "/^${k//./\\.}=/d" "$CONF"; printf '%s=%s\n' "$k" "$v" >>"$CONF"; }
set_conf psx-hotr.emulator duckstation-lightgun
set_conf psx-hotr.core duckstation-lightgun
set_conf psx-hotr.use_guns 1
set_conf psx-hotr.duckstation_mamehooker true
set_conf ps2-hotr.emulator pcsx2-lightgun
set_conf ps2-hotr.core pcsx2-lightgun
set_conf ps2-hotr.use_guns 1
set_conf ps2-hotr.pcsx2_mamehooker true

# Patch Batocera 43.1 configgen. These small rootfs changes are persisted by overlay.
[ -n "$GENROOT" ] || die "Batocera configgen generators directory not found under /usr/lib/python*/site-packages"
IMPORTER="$GENROOT/importer.py"; [ -f "$IMPORTER" ] || die "configgen importer.py not found."
[ -f "$HOTR/backups/importer.py.original" ] || cp -a "$IMPORTER" "$HOTR/backups/importer.py.original"
cp -a "$BASE/payload/configgen/generators/duckstation_lightgun" "$GENROOT/"
cp -a "$BASE/payload/configgen/generators/pcsx2_lightgun" "$GENROOT/"
# Removed in favor of Batocera's native `guns` discovery.
rm -f "$GENROOT/lightgun_rs3.py"
python3 - "$IMPORTER" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
duck_line="        'duckstation-lightgun': ('duckstation_lightgun.duckstationLightgunGenerator', 'DuckstationLightgunGenerator'),\n"
legacy_start=s.find('_LEGACY_GENERATOR_MAP')
generator_start=s.find('_GENERATOR_MAP')
if legacy_start < 0 and generator_start < 0:
    raise SystemExit('Cannot find configgen generator map in importer.py')
if legacy_start < 0:
    # Newer Batocera uses one flat map and falls back to conventional module names.
    # Add both custom emulator names directly to that map.
    entries = (
        "    'duckstation-lightgun': ('duckstation_lightgun.duckstationLightgunGenerator', 'DuckstationLightgunGenerator'),\n"
        "    'pcsx2-lightgun': ('pcsx2_lightgun.pcsx2LightgunGenerator', 'Pcsx2LightgunGenerator'),\n"
    )
    if "'duckstation-lightgun': ('duckstation_lightgun.duckstationLightgunGenerator'" not in s:
        map_end=s.find('\n}', generator_start)
        if map_end < 0:
            raise SystemExit('Cannot locate end of configgen generator map in importer.py')
        s=s[:map_end]+"\n"+entries.rstrip('\n')+s[map_end:]
else:
    if "'duckstation-lightgun': ('duckstation_lightgun.duckstationLightgunGenerator'" not in s:
        duck_marker="'duckstation': {"
        duck_pos=s.find(duck_marker, legacy_start)
        if duck_pos >= 0:
            brace=s.find('{', duck_pos)+1
            s=s[:brace]+"\n"+duck_line+s[brace:]
        else:
            map_brace=s.find('{', legacy_start)+1
            entry="\n    'duckstation': {\n"+duck_line+"    },\n"
            s=s[:map_brace]+entry+s[map_brace:]
    if "'pcsx2-lightgun': {" not in s:
        legacy_end=s.find('\n}\n\n_GENERATOR_MAP', legacy_start)
        if legacy_end < 0:
            raise SystemExit('Cannot locate end of configgen legacy generator map in importer.py')
        block=",\n    'pcsx2-lightgun': {\n        'pcsx2-lightgun': ('pcsx2_lightgun.pcsx2LightgunGenerator', 'Pcsx2LightgunGenerator'),\n    },"
        s=s[:legacy_end]+block+s[legacy_end:]
p.write_text(s)
PY
python3 -m py_compile "$IMPORTER" || {
  cp -a "$HOTR/backups/importer.py.original" "$IMPORTER"
  die "HOTR configgen importer update was invalid; original importer restored."
}

mkdir -p /etc/udev/rules.d /usr/share/duckstation-lightgun
cp -a "$BASE/payload/system/99-hotr.rules" /etc/udev/rules.d/99-hotr.rules
rm -rf /usr/share/duckstation-lightgun
ln -s "$HOTR/emulators/duckstation" /usr/share/duckstation-lightgun

# Create the private configuration roots used by the HOTR generators. The
# generators populate settings files on first launch.
mkdir -p /userdata/system/configs/duckstation-lightgun \
         /userdata/system/configs/pcsx2-lightgun-xdg/PCSX2/inis

mkdir -p /usr/share/applications /usr/bin
cp -a "$BASE/scripts/batocera-config-duckstation-hotr" "$BASE/scripts/batocera-config-pcsx2-hotr" "$BASE/scripts/batocera-config-hotr" /usr/bin/
cp -a "$BASE/scripts/hotr-status" /usr/bin/hotr-status
cp -a "$BASE/scripts/hotr-sinden-check" /usr/bin/hotr-sinden-check
cp -a "$BASE/scripts/hotr-sinden-disable" /usr/bin/hotr-sinden-disable
cp -a "$BASE/payload/system/hotr-sinden-trigger-recoil" /usr/bin/hotr-sinden-trigger-recoil
cp -a "$BASE/scripts/hotr-gun-assignment" /usr/bin/hotr-gun-assignment
chmod +x /usr/bin/batocera-config-*-hotr /usr/bin/batocera-config-hotr
chmod +x /usr/bin/hotr-status /usr/bin/hotr-gun-assignment
chmod +x /usr/bin/hotr-sinden-check /usr/bin/hotr-sinden-disable /usr/bin/hotr-sinden-trigger-recoil
cp -a "$BASE/scripts/desktop/"*.desktop /usr/share/applications/

# The release must include a matching native EmulationStation package. The
# main binary is too large for Batocera's persistent overlay, so retain it in
# /userdata and put only tiny launch wrappers in /usr/bin.
NATIVE_ES="$BASE/payload/emulationstation/emulationstation-standalone"
NATIVE_ES_BIN="$BASE/payload/emulationstation/emulationstation"
[ -x "$NATIVE_ES" ] || die "Native EmulationStation launcher missing from this release."
[ -x "$NATIVE_ES_BIN" ] || die "Native EmulationStation binary missing from this release."
ES_BIN_BACKUP="$HOTR/backups/emulationstation.original"
[ -e "$ES_BIN_BACKUP" ] || cp -a /usr/bin/emulationstation "$ES_BIN_BACKUP"
ES_BACKUP="$HOTR/backups/emulationstation-standalone.original"
[ -e "$ES_BACKUP" ] || cp -a /usr/bin/emulationstation-standalone "$ES_BACKUP"
install -m 0755 "$NATIVE_ES_BIN" "$HOTR/bin/emulationstation"
install -m 0755 "$NATIVE_ES" "$HOTR/bin/emulationstation-standalone"
printf '%s\n' '#!/bin/sh' 'exec /userdata/system/hotr/bin/emulationstation "$@"' > /usr/bin/emulationstation
printf '%s\n' '#!/bin/sh' 'exec /userdata/system/hotr/bin/emulationstation-standalone "$@"' > /usr/bin/emulationstation-standalone
chmod 0755 /usr/bin/emulationstation /usr/bin/emulationstation-standalone
msg "Native EmulationStation HOTR gun-assignment menu installed from /userdata."

# Native MAME recoil/output support: output network + MSOP stateoutput + matching HOTR profiles.
"$BASE/scripts/install-mame-msop.sh" "$BASE"

# Must run after the MSOP step: that archive ships its own HOTR game files for
# the MAME light-gun games (area51, timecris, vcop, ...), which overwrite the
# machine's copies and would otherwise silently drop the option again.
configure_sinden_trigger_recoil

udevadm control --reload-rules 2>/dev/null || true
udevadm trigger 2>/dev/null || true
command -v batocera-save-overlay >/dev/null || die "batocera-save-overlay not found."
msg "Saving Batocera overlay..."
batocera-save-overlay

if command -v batocera-services >/dev/null; then batocera-services enable hotr || true; fi
/userdata/system/services/hotr restart || true

msg "Installation complete."
if [ -f "$SINDEN_ENABLE_FILE" ]; then
  msg "Sinden recoil is enabled; run hotr-sinden-check (add --fire to pulse one recoil), or hotr-sinden-disable to switch it off."
fi
[ -x "$HOTR/emulators/duckstation/duckstation-lightgun-qt" ] || warn "DuckStation HOTR binary is missing."
[ -x "$HOTR/emulators/pcsx2/pcsx2-lightgun-qt" ] || warn "PCSX2 HOTR native binary is missing."
msg "Restart EmulationStation or reboot. Systems: PlayStation HOTR and PlayStation 2 HOTR."
