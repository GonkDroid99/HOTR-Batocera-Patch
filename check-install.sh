#!/bin/bash
set -u
ok=1
GENROOT="$(printf '%s\n' /usr/lib/python*/site-packages/configgen/generators | sort -V | while read -r candidate; do [ -d "$candidate" ] && printf '%s\n' "$candidate"; done | tail -n1)"
check(){ if [ -e "$1" ] || [ -L "$1" ]; then echo "[OK] $1"; else echo "[MISSING] $1"; ok=0; fi; }
check_exec(){ if [ -x "$1" ]; then echo "[OK] executable $1"; else echo "[MISSING] executable $1"; ok=0; fi; }

echo "HOTR Batocera 43 installation check"
check /userdata/system/configs/emulationstation/es_systems_hotr.cfg
check /userdata/system/configs/emulationstation/es_features_hotr.cfg
check_exec /userdata/roms/hotr/HookOfTheReaper.sh
check_exec /userdata/system/services/hotr
check_exec /userdata/system/hotr/software/hook-of-the-reaper/hook-of-the-reaper
check_exec /userdata/system/hotr/bin/hotr-configgen-launch
check_exec /userdata/system/hotr/bin/hotr-sinden-broker.py
check_exec /userdata/system/hotr/bin/hotr-sinden-check
check_exec /userdata/system/hotr/bin/hotr-sinden-disable
check_exec /userdata/system/hotr/bin/hotr-sinden-trigger-recoil
check_exec /usr/bin/hotr-sinden-check
check_exec /usr/bin/hotr-sinden-disable
check_exec /usr/bin/hotr-sinden-trigger-recoil
check_exec /userdata/system/hotr/tools/hotr-debug-report.sh
check_exec /userdata/system/hotr/tools/hotr-monitor
check_exec /userdata/system/hotr/tools/hotr-sinden-full-selftest.sh
check_exec /userdata/system/hotr/tools/hotr-sinden-fakegun-selftest.sh
check_exec /userdata/system/hotr/tools/hotr-sinden-tools-selftest.sh
check_exec /userdata/system/hotr/bin/hotr-theme-sync
check_exec /usr/bin/hotr-gun-assignment
check_exec /userdata/system/hotr/emulators/duckstation/MameOutputSender
check_exec /userdata/system/hotr/emulators/pcsx2/MameOutputSender
check_exec /userdata/system/hotr/emulators/duckstation/duckstation-lightgun-qt
check_exec /userdata/system/hotr/emulators/pcsx2/pcsx2-lightgun-qt
check /userdata/system/hotr/emulators/pcsx2/resources/patches.zip
check "$GENROOT/duckstation_lightgun/duckstationLightgunGenerator.py"
check "$GENROOT/pcsx2_lightgun/pcsx2LightgunGenerator.py"
check /etc/udev/rules.d/99-hotr.rules
check /userdata/saves/mame/plugins/stateoutput/plugin.json

if [ -f /userdata/system/hotr/sinden-tcp.enabled ]; then
  check /userdata/system/hotr/tools/patch-batocera-sinden-hotr.sh
  if [ -f /userdata/system/hotr/sinden-pty-bridge.enabled ]; then
    check_exec /userdata/system/hotr/bin/hotr-sinden-worker-launch
    if grep -q 'HOTR SINDEN BROKER INTEGRATION' /usr/bin/virtual-sindenlightgun-add 2>/dev/null; then
      echo '[OK] Batocera Sinden helper is connected to the legacy HOTR PTY bridge'
    else
      echo '[MISSING] Batocera Sinden helper PTY bridge hook'; ok=0
    fi
  elif grep -q 'HOTR SINDEN BROKER INTEGRATION' /usr/bin/virtual-sindenlightgun-add 2>/dev/null; then
    echo '[MISSING] Batocera Sinden helper still carries the retired PTY bridge hook; rerun install.sh to revert it'; ok=0
  else
    echo '[OK] Batocera Sinden helper is unpatched; the broker writes the gun directly'
  fi
  # A Sinden gun that HOTR drives in ammo mode only recoils when its game file
  # sets Sinden_Trigger_Recoil, which install.sh adds to every ammo-mode file.
  if [ -x /userdata/system/hotr/bin/hotr-sinden-trigger-recoil ]; then
    TR_SUMMARY="$(/userdata/system/hotr/bin/hotr-sinden-trigger-recoil --check --quiet 2>/dev/null || true)"
    case "$TR_SUMMARY" in
      *"missing=0"*) echo "[OK] Sinden trigger recoil configured in game files ($TR_SUMMARY)" ;;
      *) echo "[MISSING] ammo-mode game files without Sinden_Trigger_Recoil ($TR_SUMMARY); run hotr-sinden-trigger-recoil"; ok=0 ;;
    esac
  fi
else
  echo '[INFO] Sinden HOTR recoil broker is disabled'
fi

grep -q 'pluginsToLoad += \[ "stateoutput" \]' "$GENROOT/mame/mameGenerator.py" 2>/dev/null && echo '[OK] MAME stateoutput enabled in configgen' || { echo '[MISSING] MAME stateoutput configgen patch'; ok=0; }
grep -Eq '^[[:space:]]*output[[:space:]]+network' /userdata/system/configs/mame/mame.ini 2>/dev/null && echo '[OK] MAME output network' || { echo '[MISSING] MAME output network'; ok=0; }

for k in 'psx-hotr.core=duckstation-lightgun' 'ps2-hotr.core=pcsx2-lightgun'; do
  grep -qx "$k" /userdata/system/batocera.conf 2>/dev/null && echo "[OK] $k" || { echo "[MISSING] $k"; ok=0; }
done

/userdata/system/services/hotr status >/dev/null 2>&1 && echo '[OK] HOTR payload running' || echo '[INFO] HOTR service installed but payload is not currently running.'
exit $((1-ok))
