#!/bin/bash
set -euo pipefail
BASE="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$BASE/installer.conf"
HOTR=/userdata/system/hotr
HOTR_DATA=/userdata/system/hook-of-the-reaper
MAME_CONFIG=/userdata/system/configs/mame
MAME_SAVES=/userdata/saves/mame
GENROOT=/usr/lib/python3.12/site-packages/configgen/generators
MAME_GEN="$GENROOT/mame/mameGenerator.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$MAME_CONFIG" "$MAME_SAVES/plugins" "$HOTR_DATA/defaultLG" "$HOTR/backups"

# Keep MAME's own config intact; only force its output provider to network.
MAME_INI="$MAME_CONFIG/mame.ini"
touch "$MAME_INI"
if grep -Eq '^[[:space:]]*output[[:space:]]+' "$MAME_INI"; then
  sed -i -E 's/^[[:space:]]*output[[:space:]]+.*/output network/' "$MAME_INI"
else
  printf '\noutput network\n' >>"$MAME_INI"
fi

# Download the pinned MSOP version used for the Batocera 43.1/MAME 0.285 test.
ZIP="$TMP/msop.zip"
curl -fL --retry 3 --connect-timeout 20 "$MSOP_ASSET_URL" -o "$ZIP"
unzip -q "$ZIP" -d "$TMP/extract"

MSOP_ROOT="$TMP/extract/MAME/plugins/stateoutput"
[ -f "$MSOP_ROOT/plugin.json" ] || { echo "HOTR: MSOP archive missing stateoutput/plugin.json" >&2; exit 1; }
rm -rf "$MAME_SAVES/plugins/stateoutput"
cp -a "$MSOP_ROOT" "$MAME_SAVES/plugins/stateoutput"

# MSOP ships HOTR profiles matching its MSOP_* signal names. These are needed
# for games such as alien3, where MSOP_P1_Recoil was verified at runtime.
if [ -d "$TMP/extract/Hook Of The Reaper/defaultLG" ]; then
  cp -a "$TMP/extract/Hook Of The Reaper/defaultLG"/. "$HOTR_DATA/defaultLG/"
fi

# Batocera already builds a plugin list (hiscore/coindrop/data). Add stateoutput
# to that list rather than replacing the other selected plugins.
[ -f "$MAME_GEN" ] || { echo "HOTR: MAME configgen generator not found: $MAME_GEN" >&2; exit 1; }
[ -f "$HOTR/backups/mameGenerator.py.original" ] || cp -a "$MAME_GEN" "$HOTR/backups/mameGenerator.py.original"
python3 - "$MAME_GEN" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
if 'pluginsToLoad += [ "stateoutput" ]' not in s:
    marker = '    pluginsToLoad = []\n'
    if marker not in s:
        raise SystemExit('HOTR: could not locate MAME pluginsToLoad initialization')
    s = s.replace(marker, marker + '    pluginsToLoad += [ "stateoutput" ]\n', 1)
    p.write_text(s)
PY

echo "HOTR: installed MSOP ${MSOP_VERSION} and enabled MAME network/stateoutput."
