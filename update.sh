#!/bin/bash
set -euo pipefail

# The download and extraction below need these; fail with one readable line
# instead of a shell error halfway through an update.
for tool in python3 unzip; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "ERROR: '$tool' is required but missing; repair the Batocera system image and retry." >&2
    exit 1
  }
done

CONF=/userdata/system/hotr/install/installer.conf
[ -f "$CONF" ] || { echo "Missing $CONF"; exit 1; }
. "$CONF"
[[ "$HOTR_INSTALLER_REPO" != OWNER/* ]] || { echo 'Set HOTR_INSTALLER_REPO in installer.conf first.'; exit 2; }
VER="$(cat /usr/share/batocera/batocera.version 2>/dev/null || true)"
case "$VER" in *44*) RX="$HOTR_RELEASE_ASSET_REGEX_V44" ;; *) RX="$HOTR_RELEASE_ASSET_REGEX_V43" ;; esac
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
python3 - "$HOTR_INSTALLER_REPO" "$RX" "$TMP/release.zip" <<'PY'
import json,re,sys,urllib.request
repo,rx,out=sys.argv[1:]
req=urllib.request.Request(f'https://api.github.com/repos/{repo}/releases/latest',headers={'User-Agent':'HOTR-Updater'})
with urllib.request.urlopen(req) as r: d=json.load(r)
for a in d.get('assets',[]):
    if re.search(rx,a['name'],re.I):
        urllib.request.urlretrieve(a['browser_download_url'],out); break
else: raise SystemExit('No matching release asset')
PY
unzip -q "$TMP/release.zip" -d "$TMP/release"
ROOT=""
for candidate in "$TMP/release"/*/install.sh "$TMP/release"/install.sh; do
  if [ -f "$candidate" ]; then ROOT="${candidate%/install.sh}"; break; fi
done
[ -n "$ROOT" ] || { echo 'Release has no install.sh'; exit 3; }

# Run the installer here instead of exec'ing it: the EXIT trap above still has to
# clean up the extracted release, and an update should end with a recoil health
# report from the tool that was just refreshed.
"$ROOT/install.sh" --auto
status=$?
if [ "$status" -eq 0 ] && [ -x /usr/bin/hotr-sinden-check ]; then
  echo
  echo 'Sinden recoil status after the update:'
  /usr/bin/hotr-sinden-check || true
fi
exit "$status"
