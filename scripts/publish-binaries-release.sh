#!/bin/bash
set -euo pipefail
REPO="GonkDroid99/HOTR-Batocera-Patch"
TAG="${1:-binaries-v1}"
DUCK="${2:-dist/buildroot-binaries/duckstation-hotr.tar.gz}"
PCSX2="${3:-dist/buildroot-binaries/pcsx2-hotr.tar.gz}"
HOTR="${4:-}"
[ -f "$DUCK" ] || { echo "ERROR: $DUCK missing" >&2; exit 2; }
[ -f "$PCSX2" ] || { echo "ERROR: $PCSX2 missing" >&2; exit 2; }
[ -n "$HOTR" ] && [ -f "$HOTR" ] || { echo "Usage: $0 [tag] [duck.tar.gz] [pcsx2.tar.gz] HOTR_APPIMAGE" >&2; exit 2; }
command -v gh >/dev/null || { echo "ERROR: gh is required" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp "$DUCK" "$TMP/duckstation-hotr.tar.gz"
cp "$PCSX2" "$TMP/pcsx2-hotr.tar.gz"
cp "$HOTR" "$TMP/Hook_of_the_Reaper-x86_64.AppImage"
( cd "$TMP"; sha256sum duckstation-hotr.tar.gz pcsx2-hotr.tar.gz Hook_of_the_Reaper-x86_64.AppImage > SHA256SUMS )
if ! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release create "$TAG" --repo "$REPO" --prerelease --title "HOTR binary payload $TAG" --notes "Batocera 43 native emulator payloads + HOTR AppImage."
fi
gh release upload "$TAG" --repo "$REPO" --clobber "$TMP"/*
echo "Updated $TAG"
