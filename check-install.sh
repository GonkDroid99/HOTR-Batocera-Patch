#!/bin/bash
set -u
ok=1
check(){ if [ -e "$1" ] || [ -L "$1" ]; then echo "[OK] $1"; else echo "[MISSING] $1"; ok=0; fi; }
check_exec(){ if [ -x "$1" ]; then echo "[OK] executable $1"; else echo "[MISSING] executable $1"; ok=0; fi; }
echo "HOTR Batocera 43 installation check"
check /userdata/system/configs/emulationstation/es_systems_hotr.cfg
check /userdata/system/configs/emulationstation/es_features_hotr.cfg
check /userdata/system/services/hotr
check_exec /userdata/system/hotr/software/hook-of-the-reaper/hook-of-the-reaper
check_exec /userdata/system/hotr/bin/hotr-configgen-launch
check_exec /userdata/system/hotr/emulators/duckstation/MameOutputSender
check_exec /userdata/system/hotr/emulators/pcsx2/MameOutputSender
[ -x /userdata/system/hotr/emulators/duckstation/duckstation-lightgun-qt ] && echo '[OK] DuckStation HOTR binary' || echo '[OPTIONAL/MISSING] DuckStation HOTR binary'
[ -x /userdata/system/hotr/emulators/pcsx2/pcsx2-lightgun-qt ] && echo '[OK] PCSX2 HOTR native binary' || echo '[MISSING] PCSX2 HOTR native binary'
GENROOT=$(find /usr/lib/python* -type d -path '*/site-packages/configgen/generators' -print -quit 2>/dev/null || true)
if [ -n "$GENROOT" ]; then check "$GENROOT/duckstation_lightgun/duckstationLightgunGenerator.py"; check "$GENROOT/pcsx2_lightgun/pcsx2LightgunGenerator.py"; check "$GENROOT/lightgun_rs3.py"; else echo '[MISSING] configgen generators root'; ok=0; fi
check /etc/udev/rules.d/99-hotr.rules
check /etc/udev/rules.d/99-retroshooter-joystick-override.rules
for k in 'psx-hotr.core=duckstation-lightgun' 'ps2-hotr.core=pcsx2-lightgun'; do grep -qx "$k" /userdata/system/batocera.conf 2>/dev/null && echo "[OK] $k" || { echo "[MISSING] $k"; ok=0; }; done
if command -v batocera-services >/dev/null; then batocera-services list 2>/dev/null | grep -q hotr && echo '[OK] HOTR service registered' || echo '[INFO] Service file exists; verify enabled with batocera-services.'; fi
exit $((1-ok))
