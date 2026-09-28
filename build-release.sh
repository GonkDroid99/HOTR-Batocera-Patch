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
need_exec "$ROOT/payload/emulators/pcsx2/pcsx2-lightgun-qt"
need_exec "$ROOT/payload/emulators/pcsx2/MameOutputSender"
[ -s "$ROOT/payload/bios/ps2/patches.zip" ] || {
  echo "ERROR: PCSX2 patches archive is missing from payload/bios/ps2." >&2
  exit 2
}
unzip -t "$ROOT/payload/bios/ps2/patches.zip" >/dev/null || {
  echo "ERROR: PCSX2 patches archive is invalid." >&2
  exit 2
}
HOTR=""
for candidate in "$ROOT/payload/hotr/hook-of-the-reaper" "$ROOT/payload/hotr/Hook_of_the_Reaper-x86_64.AppImage"; do
  if [ -x "$candidate" ]; then HOTR="$candidate"; break; fi
done
[ -n "$HOTR" ] || { echo "ERROR: HOTR AppImage is missing from payload/hotr." >&2; exit 2; }

mkdir -p "$OUTDIR"
rm -f "$OUTDIR/$NAME"
command -v rsync >/dev/null || { echo "ERROR: rsync is required to stage the release package." >&2; exit 2; }
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/$(basename "$ROOT")"
rsync -a "$ROOT/" "$STAGE/$(basename "$ROOT")/" \
  --exclude '/.git/' \
  --exclude '/.github/' \
  --exclude '/buildroot/' \
  --exclude '/dist/' \
  --exclude '/.binary-staging/' \
  --exclude '/binaries/' \
  --exclude '/__pycache__/' \
  --exclude '*.pyc' \
  --exclude '/reference/bin/' \
  --exclude '/scripts/publish-binaries-release.sh'
(
  cd "$STAGE"
  zip -qr "$OUTDIR/$NAME" "$(basename "$ROOT")"
)
echo "$OUTDIR/$NAME"
