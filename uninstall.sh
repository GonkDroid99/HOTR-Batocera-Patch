#!/bin/bash
set -euo pipefail
BASE="$(cd "$(dirname "$0")" && pwd)"
HOTR=/userdata/system/hotr
GENROOT="$(printf '%s\n' /usr/lib/python*/site-packages/configgen/generators | sort -V | while read -r candidate; do [ -d "$candidate" ] && printf '%s\n' "$candidate"; done | tail -n1)"
[ "$(id -u)" -eq 0 ] || { echo 'Run as root.'; exit 1; }

command -v batocera-services >/dev/null && batocera-services disable hotr 2>/dev/null || true
/userdata/system/services/hotr stop 2>/dev/null || true

# Restore Batocera's native Sinden helper if the HOTR broker integration was
# enabled. This is separate from the optional Batocera detection workaround.
if [ -x "$HOTR/tools/patch-batocera-sinden-hotr.sh" ]; then
  "$HOTR/tools/patch-batocera-sinden-hotr.sh" remove >/dev/null 2>&1 || true
fi

# Restore stock Batocera Sinden helpers if the optional compatibility patch was
# applied. This is independent of the HOTR installation directory.
if [ -d /userdata/system/sinden-patch-backup ] && [ -x "$BASE/scripts/patch-batocera-sinden.sh" ]; then
  "$BASE/scripts/patch-batocera-sinden.sh" remove >/dev/null 2>&1 || true
fi

# Remove the small conditional logo include and generated branded images from
# installed themes before deleting the HOTR tools.
if [ -x "$HOTR/bin/hotr-theme-sync" ]; then
  "$HOTR/bin/hotr-theme-sync" --remove 2>/dev/null || true
fi

rm -f /userdata/system/services/hotr
rm -f /userdata/system/configs/emulationstation/es_systems_hotr.cfg /userdata/system/configs/emulationstation/es_features_hotr.cfg
rm -f /userdata/roms/hotr/HookOfTheReaper.sh /userdata/roms/hotr/HOTR-Rescan-Guns.sh \
  /userdata/roms/hotr/HOTR-Debug-Start.sh /userdata/roms/hotr/HOTR-Debug-Finish.sh \
  /userdata/roms/ports/HookOfTheReaper.sh /userdata/roms/ports/HOTR-Setup.sh \
  /userdata/roms/ports/HOTR-Rescan-Guns.sh /userdata/roms/ports/HOTR-Debug-Start.sh \
  /userdata/roms/ports/HOTR-Debug-Finish.sh

CONF=/userdata/system/batocera.conf
[ -f "$CONF" ] && sed -i -E '/^(psx-hotr|ps2-hotr)\./d' "$CONF"

if [ -d "$GENROOT" ]; then
  rm -rf "$GENROOT/duckstation_lightgun" "$GENROOT/pcsx2_lightgun" "$GENROOT/lightgun_rs3.py"
  [ -f "$HOTR/backups/importer.py.original" ] && cp -a "$HOTR/backups/importer.py.original" "$GENROOT/importer.py"
  [ -f "$HOTR/backups/mameGenerator.py.original" ] && cp -a "$HOTR/backups/mameGenerator.py.original" "$GENROOT/mame/mameGenerator.py"
fi

rm -rf /userdata/saves/mame/plugins/stateoutput
rm -f /etc/udev/rules.d/99-hotr.rules /etc/udev/rules.d/99-retroshooter-joystick-override.rules
rm -f /usr/bin/batocera-config-duckstation-hotr /usr/bin/batocera-config-pcsx2-hotr /usr/bin/batocera-config-hotr /usr/bin/hotr-gun-assignment
rm -f /usr/bin/hotr-sinden-check /usr/bin/hotr-sinden-disable /usr/bin/hotr-sinden-trigger-recoil
# Batocera 43 has no batocera_launch package; an empty lookup is normal.
LAUNCH_ROOT="$(printf '%s\n' /usr/lib/python*/site-packages/batocera_launch | sort -V | while read -r candidate; do [ -d "$candidate" ] && printf '%s\n' "$candidate"; done | tail -n1 || true)"
if [ -n "$LAUNCH_ROOT" ]; then
  rm -f "$LAUNCH_ROOT/emulators/duckstation_lightgun.py" "$LAUNCH_ROOT/emulators/pcsx2_lightgun.py"
  ENTRY="${LAUNCH_ROOT%/batocera_launch}/batocera_launch-44.0.dist-info/entry_points.txt"
  if [ -f "$HOTR/backups/batocera_launch_entry_points.txt.original" ]; then
    install -m 0644 "$HOTR/backups/batocera_launch_entry_points.txt.original" "$ENTRY"
  else
    sed -i '/^duckstation-lightgun = /d;/^pcsx2-lightgun = /d' "$ENTRY" 2>/dev/null || true
  fi
fi
if [ -e "$HOTR/backups/emulationstation-standalone.original" ]; then
  install -m 0755 "$HOTR/backups/emulationstation-standalone.original" /usr/bin/emulationstation-standalone
fi
if [ -e "$HOTR/backups/emulationstation.original" ]; then
  install -m 0755 "$HOTR/backups/emulationstation.original" /usr/bin/emulationstation
fi
rm -f /usr/share/applications/duckstation-hotr-config.desktop /usr/share/applications/pcsx2-hotr-config.desktop /usr/share/applications/hotr-config.desktop
rm -f /usr/share/duckstation-lightgun
rm -f "$HOTR/sinden-tcp.enabled" "$HOTR/sinden-pty-bridge.enabled"
command -v batocera-save-overlay >/dev/null && batocera-save-overlay || true
rm -rf "$HOTR"
echo 'HOTR integration removed. Persistent /userdata/system/hook-of-the-reaper data/defaultLG remains.'
