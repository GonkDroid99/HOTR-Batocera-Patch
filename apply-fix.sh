#!/bin/bash
set -euo pipefail
BASE="$(cd "$(dirname "$0")" && pwd)"
HOTR=/userdata/system/hotr

[ "$(id -u)" -eq 0 ] || { echo "Run as root on Batocera" >&2; exit 1; }
GENROOT="$(find /usr/lib/python* -type d -path '*/site-packages/configgen/generators' -print -quit 2>/dev/null || true)"
[ -n "$GENROOT" ] || { echo "Could not locate configgen generators" >&2; exit 1; }

install -m755 "$BASE/scripts/hotr-configgen-launch" "$HOTR/bin/hotr-configgen-launch"
install -m644 "$BASE/emulationstation/es_systems_hotr.cfg" /userdata/system/configs/emulationstation/es_systems_hotr.cfg
install -m644 "$BASE/payload/configgen/generators/duckstation_lightgun/duckstationLightgunGenerator.py" "$GENROOT/duckstation_lightgun/duckstationLightgunGenerator.py"
install -m644 "$BASE/payload/configgen/generators/pcsx2_lightgun/pcsx2LightgunGenerator.py" "$GENROOT/pcsx2_lightgun/pcsx2LightgunGenerator.py"

python3 "$BASE/scripts/generate-es-features-hotr.py"

# Ensure AppImage and DuckStation are executable.
chmod +x "$HOTR/emulators/duckstation/duckstation-lightgun-qt" 2>/dev/null || true
chmod +x "$HOTR/emulators/pcsx2/PCSX2-hotr.AppImage" 2>/dev/null || true

batocera-save-overlay

echo
echo "HOTR launch/config fixes installed. Restart EmulationStation or reboot."
echo "If launch still fails, inspect /userdata/system/logs/es_launch_stderr.log"
