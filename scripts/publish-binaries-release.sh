#!/bin/bash
set -euo pipefail
REPO="GonkDroid99/HOTR-Batocera-Patch"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${1:-binaries-v1}"
SERIES="${2:-44}"
case "$SERIES" in 43|44) ;; *) echo "ERROR: series must be 43 or 44" >&2; exit 2;; esac
BASE="$ROOT/dist/buildroot-binaries/v$SERIES"
DUCK="${3:-$BASE/duckstation-hotr-v$SERIES.tar.gz}"
PCSX2="${4:-$BASE/pcsx2-hotr-v$SERIES.tar.gz}"
HOTR="${5:-$ROOT/payload/hotr/HookOfTheReaper-x86_64.AppImage}"
ES="${6:-$BASE/emulationstation-hotr-v$SERIES.tar.gz}"
[ -f "$DUCK" ] || { echo "ERROR: $DUCK missing" >&2; exit 2; }
[ -f "$PCSX2" ] || { echo "ERROR: $PCSX2 missing" >&2; exit 2; }
[ -f "$HOTR" ] || { echo "ERROR: HOTR AppImage missing: $HOTR" >&2; exit 2; }
[ -f "$ES" ] || { echo "ERROR: $ES missing" >&2; exit 2; }
command -v gh >/dev/null || { echo "ERROR: gh is required" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp "$DUCK" "$TMP/duckstation-hotr-v$SERIES.tar.gz"
cp "$PCSX2" "$TMP/pcsx2-hotr-v$SERIES.tar.gz"
cp "$HOTR" "$TMP/HookOfTheReaper-x86_64.AppImage"
cp "$ES" "$TMP/emulationstation-hotr-v$SERIES.tar.gz"
( cd "$TMP"; sha256sum duckstation-hotr-v$SERIES.tar.gz pcsx2-hotr-v$SERIES.tar.gz HookOfTheReaper-x86_64.AppImage > SHA256SUMS-v$SERIES; [ ! -f emulationstation-hotr-v$SERIES.tar.gz ] || sha256sum emulationstation-hotr-v$SERIES.tar.gz >> SHA256SUMS-v$SERIES )
if ! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release create "$TAG" --repo "$REPO" --prerelease --title "HOTR binary payload $TAG" --notes "Versioned Batocera native emulator payloads + HOTR AppImage."
fi
gh release upload "$TAG" --repo "$REPO" --clobber "$TMP"/*
echo "Updated $TAG"
