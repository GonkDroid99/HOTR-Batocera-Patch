#!/bin/bash
# Hardware-free detector test. It creates fake /dev/serial trees and verifies
# that the real production detector identifies a simulated RS3 Reaper.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/../../payload/system/hotr-autoconfig.py" ]; then
  BASE="$(cd "$SCRIPT_DIR/../.." && pwd)"
else
  BASE="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/by-id" "$TMP/by-path" "$TMP/hotr" "$TMP/data" \
         "$TMP/hidraw/hidraw0/device"
touch "$TMP/ttyUSB-simulated"
touch "$TMP/hidraw0"
cat > "$TMP/hidraw/hidraw0/device/uevent" <<'EOF'
HID_ID=0003:0000D209:00001601
HID_NAME=AimTrak Light Gun
EOF
ln -s "$TMP/ttyUSB-simulated" "$TMP/by-id/usb-3AGAME_3A-3H_Retro_Shooter_1_SIM-if02-port0"
ln -s "$TMP/ttyUSB-simulated" "$TMP/by-path/pci-sim-usb-0:3:1.2-port0"
cat > "$TMP/data/lightguns.hor" <<'EOF'
Light Gun Data File V3
1
Light Gun #0
0
Sinden P1
1
99
END_GENERAL_SETTINGS
0
127.0.0.1:3333
END_OF_FILE
EOF

HOTR_DATA_DIR="$TMP/data" \
HOTR_SERIAL_BY_ID="$TMP/by-id" \
HOTR_SERIAL_BY_PATH="$TMP/by-path" \
HOTR_DEVICE_DIR="$TMP/hotr" \
HOTR_HIDRAW_DIR="$TMP" \
HOTR_HID_SYSFS="$TMP/hidraw" \
python3 - "$BASE/payload/system/hotr-autoconfig.py" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("hotr_autoconfig", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

guns = mod.detect_guns()
assert guns == [("rs3reaper", mod.SERIAL_BY_ID_DIR.rsplit("/", 1)[0] + "/ttyUSB-simulated")], guns
hid = mod.detect_hid_guns()
assert hid == [("AimTrak", mod.HIDRAW_DIR + "/hidraw0", "d209", "1601")], hid
mod.write_lightguns_hor(guns, mod._read_existing_blocks())
config = open(mod.LIGHTGUNS_FILE).read()
assert "ttyUSB-simulated" in config
assert "Sinden P1" in config
assert "127.0.0.1:3333" in config
assert config.splitlines()[1] == "2"
print("HOTR simulated serial detection: PASS")
PY
