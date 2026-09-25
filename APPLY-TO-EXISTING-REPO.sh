#!/bin/bash
# Overlay this update onto an existing clone while preserving that clone's
# current HOTR game profiles. Useful when local defaultLG files are newer than
# the public repo snapshot used to build this update.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="${1:-}"
[ -n "$DEST" ] && [ -d "$DEST/.git" ] || {
  echo "Usage: $0 /path/to/existing/HOTR-Batocera-Patch" >&2
  exit 2
}
command -v rsync >/dev/null || { echo "rsync is required on the development host." >&2; exit 2; }

mkdir -p "$DEST/payload/hotr/defaultLG"
rsync -a --delete \
  --exclude '.git/' \
  --exclude 'payload/hotr/defaultLG/' \
  "$SRC/" "$DEST/"

# Add profiles that are new in this update, but let existing local profiles win.
cp -an "$SRC/payload/hotr/defaultLG"/. "$DEST/payload/hotr/defaultLG/"

echo "Repo update applied. Existing payload/hotr/defaultLG files were preserved."
echo "Review with: git status --short && git diff"
