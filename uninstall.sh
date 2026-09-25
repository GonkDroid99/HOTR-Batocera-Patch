#!/bin/bash
set -euo pipefail
HOTR=/userdata/system/hotr
GENROOT=/usr/lib/python3.12/site-packages/configgen/generators
[ "$(id -u)" -eq 0 ] || { echo 'Run as root.'; exit 1; }

command -v batocera-services >/dev/null && batocera-services disable hotr 2>/dev/null || true
/userdata/system/services/hotr stop 2>/dev/null || true
rm -f /userdata/system/services/hotr
rm -f /userdata/system/configs/emulationstation/es_systems_hotr.cfg /userdata/system/configs/emulationstation/es_features_hotr.cfg
rm -f /userdata/roms/ports/HookOfTheReaper.sh /userdata/roms/ports/HOTR-Setup.sh /userdata/roms/ports/HOTR-Rescan-Guns.sh

CONF=/userdata/system/batocera.conf
[ -f "$CONF" ] && sed -i -E '/^(psx-hotr|ps2-hotr)\./d' "$CONF"

if [ -d "$GENROOT" ]; then
  rm -rf "$GENROOT/duckstation_lightgun" "$GENROOT/pcsx2_lightgun" "$GENROOT/lightgun_rs3.py"
  [ -f "$HOTR/backups/importer.py.original" ] && cp -a "$HOTR/backups/importer.py.original" "$GENROOT/importer.py"
  [ -f "$HOTR/backups/mameGenerator.py.original" ] && cp -a "$HOTR/backups/mameGenerator.py.original" "$GENROOT/mame/mameGenerator.py"
fi

rm -rf /userdata/saves/mame/plugins/stateoutput
rm -f /etc/udev/rules.d/99-hotr.rules /etc/udev/rules.d/99-retroshooter-joystick-override.rules
rm -f /usr/bin/batocera-config-duckstation-hotr /usr/bin/batocera-config-pcsx2-hotr /usr/bin/batocera-config-hotr
rm -f /usr/share/applications/duckstation-hotr-config.desktop /usr/share/applications/pcsx2-hotr-config.desktop /usr/share/applications/hotr-config.desktop
rm -f /usr/share/duckstation-lightgun
command -v batocera-save-overlay >/dev/null && batocera-save-overlay || true
rm -rf "$HOTR"
echo 'HOTR integration removed. Persistent /userdata/system/hook-of-the-reaper data/defaultLG remains.'
