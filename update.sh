#!/bin/bash
set -euo pipefail
CONF=/userdata/system/hotr/install/installer.conf
[ -f "$CONF" ] || { echo "Missing $CONF"; exit 1; }
. "$CONF"
[[ "$HOTR_INSTALLER_REPO" != OWNER/* ]] || { echo 'Set HOTR_INSTALLER_REPO in installer.conf first.'; exit 2; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
python3 - "$HOTR_INSTALLER_REPO" "$HOTR_RELEASE_ASSET_REGEX" "$TMP/release.zip" <<'PY'
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
ROOT=$(find "$TMP/release" -maxdepth 2 -type f -name install.sh -printf '%h\n' | head -1)
[ -n "$ROOT" ] || { echo 'Release has no install.sh'; exit 3; }
exec "$ROOT/install.sh" --auto
