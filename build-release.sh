#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SERIES="${HOTR_RELEASE_SERIES:-43}"
case "$SERIES" in 43|44) ;; *) echo "ERROR: HOTR_RELEASE_SERIES must be 43 or 44" >&2; exit 2;; esac
NAME="HOTR-Batocera${SERIES}-x86_64.zip"
OUTDIR="$ROOT/dist"

need_exec() {
  [ -x "$1" ] || { echo "ERROR: required executable missing: $1" >&2; exit 2; }
}

HOTR=""
for candidate in "$ROOT/payload/hotr/hook-of-the-reaper" "$ROOT/payload/hotr/HookOfTheReaper-x86_64.AppImage"; do
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

# Never package whichever emulator binaries happened to be left in payload/.
# Inject the archives for the requested Batocera series into the staged release.
ARCHIVE_DIR="$ROOT/dist/buildroot-binaries/v$SERIES"
DUCK_ARCHIVE="$ARCHIVE_DIR/duckstation-hotr-v$SERIES.tar.gz"
PCSX2_ARCHIVE="$ARCHIVE_DIR/pcsx2-hotr-v$SERIES.tar.gz"
ES_ARCHIVE="$ARCHIVE_DIR/emulationstation-hotr-v$SERIES.tar.gz"
if [ "$SERIES" = 43 ] && [ ! -f "$DUCK_ARCHIVE" ]; then
  ARCHIVE_DIR="$ROOT/dist/buildroot-binaries"
  DUCK_ARCHIVE="$ARCHIVE_DIR/duckstation-hotr.tar.gz"
  PCSX2_ARCHIVE="$ARCHIVE_DIR/pcsx2-hotr.tar.gz"
  ES_ARCHIVE="$ARCHIVE_DIR/emulationstation-hotr.tar.gz"
fi
for archive in "$DUCK_ARCHIVE" "$PCSX2_ARCHIVE" "$ES_ARCHIVE"; do
  [ -f "$archive" ] || { echo "ERROR: required v$SERIES runtime archive missing: $archive" >&2; exit 2; }
  tar -tzf "$archive" >/dev/null || { echo "ERROR: invalid runtime archive: $archive" >&2; exit 2; }
done

STAGED_ROOT="$STAGE/$(basename "$ROOT")"
rm -rf "$STAGED_ROOT/payload/emulators/duckstation" \
       "$STAGED_ROOT/payload/emulators/pcsx2" \
       "$STAGED_ROOT/payload/emulationstation"
mkdir -p "$STAGED_ROOT/payload/emulators/duckstation" \
         "$STAGED_ROOT/payload/emulators/pcsx2" \
         "$STAGED_ROOT/payload/emulationstation"
tar -xzf "$DUCK_ARCHIVE" -C "$STAGED_ROOT/payload/emulators/duckstation"
tar -xzf "$PCSX2_ARCHIVE" -C "$STAGED_ROOT/payload/emulators/pcsx2"
tar -xzf "$ES_ARCHIVE" -C "$STAGED_ROOT/payload/emulationstation"
printf '%s\n' "$SERIES" > "$STAGED_ROOT/payload/.hotr-batocera-series"
need_exec "$STAGED_ROOT/payload/emulators/duckstation/duckstation-lightgun-qt"
need_exec "$STAGED_ROOT/payload/emulators/duckstation/MameOutputSender"
need_exec "$STAGED_ROOT/payload/emulators/pcsx2/pcsx2-lightgun-qt"
need_exec "$STAGED_ROOT/payload/emulators/pcsx2/MameOutputSender"
need_exec "$STAGED_ROOT/payload/emulationstation/emulationstation"
need_exec "$STAGED_ROOT/payload/emulationstation/emulationstation-standalone"
[ -s "$STAGED_ROOT/payload/emulators/pcsx2/resources/patches.zip" ] || {
  echo "ERROR: PCSX2 patches archive is missing from the v$SERIES runtime payload." >&2; exit 2;
}
unzip -t "$STAGED_ROOT/payload/emulators/pcsx2/resources/patches.zip" >/dev/null
(
  cd "$STAGE"
  zip -qr "$OUTDIR/$NAME" "$(basename "$ROOT")"
)
echo "$OUTDIR/$NAME"
