#!/bin/bash
# One-command installer for the latest normal HOTR Batocera release.
# Binary-only prereleases (for example binaries-v1) are intentionally ignored
# by GitHub's /releases/latest endpoint.
set -euo pipefail

REPO="GonkDroid99/HOTR-Batocera-Patch"
ASSET_REGEX='^HOTR-Batocera43-x86_64\.zip$'
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "HOTR Batocera bootstrap"
echo "Repository: $REPO"

python3 - "$REPO" "$ASSET_REGEX" "$TMP/hotr.zip" <<'PY'
import json, re, sys, urllib.request
repo, rx, out = sys.argv[1:]
req = urllib.request.Request(
    f"https://api.github.com/repos/{repo}/releases/latest",
    headers={"User-Agent": "HOTR-Batocera-Bootstrap"},
)
with urllib.request.urlopen(req, timeout=30) as response:
    data = json.load(response)
for asset in data.get("assets", []):
    if re.search(rx, asset.get("name", ""), re.I):
        print(f"Downloading {asset['name']} from release {data.get('tag_name', '?')}")
        urllib.request.urlretrieve(asset["browser_download_url"], out)
        break
else:
    raise SystemExit("No HOTR installer ZIP found in the latest normal GitHub release.")
PY

unzip -q "$TMP/hotr.zip" -d "$TMP/release"
ROOT=""
for candidate in "$TMP/release"/*/install.sh "$TMP/release"/install.sh; do
  if [ -f "$candidate" ]; then ROOT="${candidate%/install.sh}"; break; fi
done
[ -n "$ROOT" ] || { echo "ERROR: install.sh is missing from the release ZIP." >&2; exit 3; }
chmod +x "$ROOT/install.sh"
exec "$ROOT/install.sh" --auto
