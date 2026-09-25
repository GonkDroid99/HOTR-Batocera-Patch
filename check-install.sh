#!/bin/bash
set -u
ok=1
GENROOT=/usr/lib/python3.12/site-packages/configgen/generators
check(){ if [ -e "$1" ] || [ -L "$1" ]; then echo "[OK] $1"; else echo "[MISSING] $1"; ok=0; fi; }
check_exec(){ if [ -x "$1" ]; then echo "[OK] executable $1"; else echo "[MISSING] executable $1"; ok=0; fi; }

echo "HOTR Batocera 43 installation check"
check /userdata/system/configs/emulationstation/es_systems_hotr.cfg
check /userdata/system/configs/emulationstation/es_features_hotr.cfg
check_exec /userdata/system/services/hotr
check_exec /userdata/system/hotr/software/hook-of-the-reaper/hook-of-the-reaper
check_exec /userdata/system/hotr/bin/hotr-configgen-launch
check_exec /userdata/system/hotr/emulators/duckstation/MameOutputSender
check_exec /userdata/system/hotr/emulators/pcsx2/MameOutputSender
check_exec /userdata/system/hotr/emulators/duckstation/duckstation-lightgun-qt
check_exec /userdata/system/hotr/emulators/pcsx2/pcsx2-lightgun-qt
check "$GENROOT/duckstation_lightgun/duckstationLightgunGenerator.py"
check "$GENROOT/pcsx2_lightgun/pcsx2LightgunGenerator.py"
check "$GENROOT/lightgun_rs3.py"
check /etc/udev/rules.d/99-hotr.rules
check /etc/udev/rules.d/99-retroshooter-joystick-override.rules
check /userdata/saves/mame/plugins/stateoutput/plugin.json

grep -q 'pluginsToLoad += \[ "stateoutput" \]' "$GENROOT/mame/mameGenerator.py" 2>/dev/null && echo '[OK] MAME stateoutput enabled in configgen' || { echo '[MISSING] MAME stateoutput configgen patch'; ok=0; }
grep -Eq '^[[:space:]]*output[[:space:]]+network' /userdata/system/configs/mame/mame.ini 2>/dev/null && echo '[OK] MAME output network' || { echo '[MISSING] MAME output network'; ok=0; }

for k in 'psx-hotr.core=duckstation-lightgun' 'ps2-hotr.core=pcsx2-lightgun'; do
  grep -qx "$k" /userdata/system/batocera.conf 2>/dev/null && echo "[OK] $k" || { echo "[MISSING] $k"; ok=0; }
done

/userdata/system/services/hotr status >/dev/null 2>&1 && echo '[OK] HOTR payload running' || echo '[INFO] HOTR service installed but payload is not currently running.'
exit $((1-ok))
