#!/bin/bash
set -euo pipefail
BASE="$(cd "$(dirname "$0")" && pwd)"
. "$BASE/installer.conf"
MODE="${1:---auto}"
HOTR=/userdata/system/hotr
HOTR_DATA=/userdata/system/hook-of-the-reaper
LOG=/userdata/system/logs/hotr-install.log

msg(){ printf '[HOTR] %s\n' "$*"; }
warn(){ printf '[HOTR WARNING] %s\n' "$*" >&2; }
die(){ printf '[HOTR ERROR] %s\n' "$*" >&2; exit 1; }
need_root(){ [ "$(id -u)" -eq 0 ] || die "Run this installer as root (Batocera SSH normally logs in as root)."; }

need_root
[ "$(uname -m)" = "x86_64" ] || die "This release targets x86_64 only."
mkdir -p /userdata/system/logs
exec > >(tee -a "$LOG") 2>&1

VER=""
[ -r /usr/share/batocera/batocera.version ] && VER="$(cat /usr/share/batocera/batocera.version)"
[ -z "$VER" ] && VER="$(batocera-info 2>/dev/null | head -1 || true)"
msg "Detected Batocera: ${VER:-unknown}"
echo "$VER" | grep -Eq '(^|[^0-9])43([.]|[^0-9]|$)' || warn "Designed/tested for Batocera 43/43.1; continuing because version detection was '${VER:-unknown}'."

mkdir -p "$HOTR"/{bin,emulators/duckstation,emulators/pcsx2,scripts,software/hook-of-the-reaper,backups,install,tools} \
         "$HOTR_DATA"/{data,defaultLG} /userdata/system/services /userdata/system/configs/emulationstation /userdata/roms/ports

fetch_latest_asset(){
  local repo="$1" regex="$2" out="$3"
  [[ "$repo" != OWNER/* && "$repo" != "" ]] || return 2
  python3 - "$repo" "$regex" "$out" <<'PY'
import json,re,sys,urllib.request
repo,rx,out=sys.argv[1:]
req=urllib.request.Request(f"https://api.github.com/repos/{repo}/releases/latest",headers={"User-Agent":"HOTR-Batocera43"})
with urllib.request.urlopen(req, timeout=30) as r: data=json.load(r)
for asset in data.get("assets",[]):
    if re.search(rx, asset.get("name",""), re.I):
        print("Downloading", asset["name"])
        req=urllib.request.Request(asset["browser_download_url"],headers={"User-Agent":"HOTR-Batocera43"})
        with urllib.request.urlopen(req, timeout=120) as src, open(out,"wb") as dst:
            while True:
                chunk=src.read(1024*1024)
                if not chunk: break
                dst.write(chunk)
        raise SystemExit(0)
raise SystemExit("No release asset matched: "+rx)
PY
}

extract_any(){
  local file="$1" dest="$2"; mkdir -p "$dest"
  if unzip -t "$file" >/dev/null 2>&1; then unzip -q "$file" -d "$dest"; return; fi
  if tar -tf "$file" >/dev/null 2>&1; then tar -xf "$file" -C "$dest"; return; fi
  return 1
}

install_duck_from_tree(){
  local src="$1" bin=""
  bin="$(find "$src" -type f \( -name duckstation-lightgun-qt -o -name duckstation-qt \) -print -quit 2>/dev/null || true)"
  [ -n "$bin" ] || return 1
  rm -rf "$HOTR/emulators/duckstation"/*
  # Rootfs-style archive: binary under usr/bin, resources under usr/share/duckstation-lightgun.
  if [[ "$bin" == */usr/bin/* ]] && [ -d "$src/usr/share/duckstation-lightgun" ]; then
    cp -a "$src/usr/share/duckstation-lightgun"/. "$HOTR/emulators/duckstation/"
    cp -a "$bin" "$HOTR/emulators/duckstation/duckstation-lightgun-qt"
    local ng="${bin%/*}/duckstation-lightgun-nogui"; [ -f "$ng" ] && cp -a "$ng" "$HOTR/emulators/duckstation/duckstation-lightgun-nogui"
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
  bin="$(find "$src" -type f -name pcsx2-lightgun-qt -print -quit 2>/dev/null || true)"
  [ -n "$bin" ] || return 1
  rm -rf "$HOTR/emulators/pcsx2"/*
  cp -a "$(dirname "$bin")"/. "$HOTR/emulators/pcsx2/"
  [ -f "$HOTR/emulators/pcsx2/MameOutputSender" ] || cp -a "$BASE/payload/emulators/pcsx2/MameOutputSender" "$HOTR/emulators/pcsx2/MameOutputSender"
  chmod +x "$HOTR/emulators/pcsx2/pcsx2-lightgun-qt" "$HOTR/emulators/pcsx2/MameOutputSender"
  msg "PCSX2 HOTR native Batocera build installed."
}

install_bundled_emulators(){
  local dsrc="$BASE/payload/emulators/duckstation" psrc="$BASE/payload/emulators/pcsx2"
  install_duck_from_tree "$dsrc" || true
  install_pcsx2_from_tree "$psrc" || true
}

install_github_emulators(){
  [ "${ENABLE_GITHUB_EMULATOR_DOWNLOADS:-0}" = 1 ] || return 1
  local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  if fetch_latest_asset "$DUCKSTATION_GITHUB_REPO" "$DUCKSTATION_ASSET_REGEX" "$tmp/duck.pkg"; then
    mkdir -p "$tmp/duck"; extract_any "$tmp/duck.pkg" "$tmp/duck" || die "DuckStation GitHub asset is not a supported archive."
    install_duck_from_tree "$tmp/duck" || die "Downloaded DuckStation asset contains no duckstation-qt binary."
  fi
  if fetch_latest_asset "$PCSX2_GITHUB_REPO" "$PCSX2_ASSET_REGEX" "$tmp/pcsx2.pkg"; then
    mkdir -p "$tmp/pcsx2"; extract_any "$tmp/pcsx2.pkg" "$tmp/pcsx2" || die "PCSX2 GitHub asset is not a supported archive."
    install_pcsx2_from_tree "$tmp/pcsx2" || die "Downloaded PCSX2 archive contains no pcsx2-lightgun-qt binary."
  fi
}

case "$MODE" in
  --auto) install_bundled_emulators; if [ ! -x "$HOTR/emulators/duckstation/duckstation-lightgun-qt" ] || [ ! -x "$HOTR/emulators/pcsx2/pcsx2-lightgun-qt" ]; then install_github_emulators || true; fi ;;
  --bundled) install_bundled_emulators ;;
  --github-emulators) install_github_emulators || die "Enable/configure GitHub emulator downloads in installer.conf." ;;
  --infrastructure-only) : ;;
  *) die "Usage: $0 [--auto|--bundled|--github-emulators|--infrastructure-only]" ;;
esac

# Persistent HOTR application + user data.
cp -a "$BASE/payload/hotr/hook-of-the-reaper" "$HOTR/software/hook-of-the-reaper/hook-of-the-reaper"
chmod +x "$HOTR/software/hook-of-the-reaper/hook-of-the-reaper"
[ -f "$HOTR_DATA/.seeded" ] || {
  cp -a "$BASE/payload/hotr/data"/. "$HOTR_DATA/data/"
  cp -a "$BASE/payload/hotr/defaultLG"/. "$HOTR_DATA/defaultLG/"
  touch "$HOTR_DATA/.seeded"
}
rm -rf "$HOTR/software/hook-of-the-reaper/data" "$HOTR/software/hook-of-the-reaper/defaultLG"
ln -s "$HOTR_DATA/data" "$HOTR/software/hook-of-the-reaper/data"
ln -s "$HOTR_DATA/defaultLG" "$HOTR/software/hook-of-the-reaper/defaultLG"

# Userdata scripts/config.
cp -a "$BASE/payload/system/hotr-autoconfig.py" "$HOTR/bin/hotr-autoconfig.py"
cp -a "$BASE/scripts/hotr-configgen-launch" "$BASE/scripts/add-emulator-config.sh" "$HOTR/bin/"
cp -a "$BASE/scripts/custom-boot.sh" "$BASE/scripts/custom-stop.sh" "$HOTR/scripts/"
cp -a "$BASE/scripts/hotr-service" /userdata/system/services/hotr
cp -a "$BASE/emulationstation/es_systems_hotr.cfg" /userdata/system/configs/emulationstation/es_systems_hotr.cfg
cp -a "$BASE/emulationstation/pcsx2_legacy_features.xml" "$HOTR/install/pcsx2_legacy_features.xml"
cp -a "$BASE/scripts/generate-es-features-hotr.py" "$HOTR/bin/generate-es-features-hotr.py"
chmod +x "$HOTR/bin/generate-es-features-hotr.py"
"$HOTR/bin/generate-es-features-hotr.py" "$HOTR/install/pcsx2_legacy_features.xml"
cp -a "$BASE/installer.conf" "$HOTR/install/installer.conf"
cp -a "$BASE/uninstall.sh" "$BASE/update.sh" "$BASE/check-install.sh" "$HOTR/tools/"
chmod +x "$HOTR/tools/"*.sh
chmod +x "$HOTR/bin/"* "$HOTR/scripts/"*.sh /userdata/system/services/hotr

# Adapted Ports launchers.
cp -a "$BASE/scripts/ports/"*.sh /userdata/roms/ports/
chmod +x /userdata/roms/ports/HookOfTheReaper.sh /userdata/roms/ports/HOTR-Setup.sh /userdata/roms/ports/HOTR-Rescan-Guns.sh

# Set default emulator/core for only the custom HOTR systems.
CONF=/userdata/system/batocera.conf; touch "$CONF"
set_conf(){ local k="$1" v="$2"; sed -i "/^${k//./\\.}=/d" "$CONF"; printf '%s=%s\n' "$k" "$v" >>"$CONF"; }
set_conf psx-hotr.emulator duckstation
set_conf psx-hotr.core duckstation-lightgun
set_conf psx-hotr.use_guns 1
set_conf psx-hotr.duckstation_mamehooker true
set_conf ps2-hotr.emulator pcsx2-lightgun
set_conf ps2-hotr.core pcsx2-lightgun
set_conf ps2-hotr.use_guns 1
set_conf ps2-hotr.pcsx2_mamehooker true

# Patch the live root. Batocera-save-overlay persists these small integration files.
GENROOT="$(find /usr/lib/python* -type d -path '*/site-packages/configgen/generators' -print -quit 2>/dev/null || true)"
[ -n "$GENROOT" ] || die "Could not locate Batocera configgen generators directory."
IMPORTER="$GENROOT/importer.py"; [ -f "$IMPORTER" ] || die "configgen importer.py not found."
[ -f "$HOTR/backups/importer.py.original" ] || cp -a "$IMPORTER" "$HOTR/backups/importer.py.original"
cp -a "$BASE/payload/configgen/generators/duckstation_lightgun" "$GENROOT/"
cp -a "$BASE/payload/configgen/generators/pcsx2_lightgun" "$GENROOT/"
cp -a "$BASE/payload/configgen/generators/lightgun_rs3.py" "$GENROOT/"
python3 - "$IMPORTER" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
duck="        'duckstation-lightgun': ('duckstation_lightgun.duckstationLightgunGenerator', 'DuckstationLightgunGenerator'),\n"
if "'duckstation-lightgun': ('duckstation_lightgun.duckstationLightgunGenerator'" not in s:
    marker="'duckstation': {"
    i=s.find(marker)
    if i < 0: raise SystemExit("Cannot find duckstation legacy map in importer.py")
    brace=s.find("{",i)+1
    s=s[:brace]+"\n"+duck+s[brace:]
if "'pcsx2-lightgun': {" not in s:
    marker="    'supermodel': {"
    i=s.find(marker)
    if i < 0: raise SystemExit("Cannot find insertion point in legacy generator map")
    block="    'pcsx2-lightgun': {\n        'pcsx2-lightgun': ('pcsx2_lightgun.pcsx2LightgunGenerator', 'Pcsx2LightgunGenerator'),\n    },\n"
    s=s[:i]+block+s[i:]
p.write_text(s)
PY

mkdir -p /etc/udev/rules.d /usr/share/duckstation-lightgun
cp -a "$BASE/payload/system/99-hotr.rules" /etc/udev/rules.d/99-hotr.rules
cp -a "$BASE/payload/system/99-retroshooter-joystick-override.rules" /etc/udev/rules.d/99-retroshooter-joystick-override.rules
# DuckStation Batocera build has resource paths patched to /usr/share/duckstation-lightgun.
rm -rf /usr/share/duckstation-lightgun
ln -s "$HOTR/emulators/duckstation" /usr/share/duckstation-lightgun

# Optional desktop/F1 launchers.
mkdir -p /usr/share/applications /usr/bin
cp -a "$BASE/scripts/batocera-config-duckstation-hotr" /usr/bin/
cp -a "$BASE/scripts/batocera-config-pcsx2-hotr" /usr/bin/
cp -a "$BASE/scripts/batocera-config-hotr" /usr/bin/
chmod +x /usr/bin/batocera-config-*-hotr /usr/bin/batocera-config-hotr
cp -a "$BASE/scripts/desktop/"*.desktop /usr/share/applications/

udevadm control --reload-rules 2>/dev/null || true
udevadm trigger 2>/dev/null || true
command -v batocera-save-overlay >/dev/null || die "batocera-save-overlay not found."
msg "Saving Batocera overlay (configgen, udev, resource symlink and desktop launchers)..."
batocera-save-overlay

if command -v batocera-services >/dev/null; then batocera-services enable hotr || true; fi
/userdata/system/services/hotr restart || true

msg "Installation complete."
[ -x "$HOTR/emulators/duckstation/duckstation-lightgun-qt" ] || warn "DuckStation HOTR binary is not installed yet. Add it or configure GitHub downloads."
[ -x "$HOTR/emulators/pcsx2/pcsx2-lightgun-qt" ] || warn "pcsx2-lightgun-qt is not installed yet. Build/publish the native Batocera payload."
msg "Restart EmulationStation or reboot. Systems: PlayStation HOTR and PlayStation 2 HOTR."
