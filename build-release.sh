#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
NAME="HOTR-Batocera43-x86_64.zip"
OUTDIR="$ROOT/dist"

need_exec() {
  [ -x "$1" ] || { echo "ERROR: required executable missing: $1" >&2; exit 2; }
}

DUCK=""
for candidate in "$ROOT/payload/emulators/duckstation/duckstation-qt" "$ROOT/payload/emulators/duckstation/duckstation-lightgun-qt"; do
  if [ -x "$candidate" ]; then DUCK="$candidate"; break; fi
done
[ -n "$DUCK" ] || { echo "ERROR: DuckStation binary is missing from payload/emulators/duckstation." >&2; exit 2; }
need_exec "$ROOT/payload/emulators/duckstation/MameOutputSender"
need_exec "$ROOT/payload/emulators/pcsx2/PCSX2-hotr.AppImage"
need_exec "$ROOT/payload/emulators/pcsx2/MameOutputSender"
need_exec "$ROOT/payload/hotr/hook-of-the-reaper"

mkdir -p "$OUTDIR"
rm -f "$OUTDIR/$NAME"
(
  cd "$(dirname "$ROOT")"
  zip -qr "$OUTDIR/$NAME" "$(basename "$ROOT")" \
    -x '*/dist/*' '*/.git/*' '*/.github/*' '*/__pycache__/*' '*.pyc' \
       '*/reference/bin/*' '*/scripts/publish-binaries-release.sh'
)
echo "$OUTDIR/$NAME"
