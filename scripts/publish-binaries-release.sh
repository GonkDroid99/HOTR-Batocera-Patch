#!/bin/bash
set -euo pipefail
REPO="GonkDroid99/HOTR-Batocera-Patch"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${1:-binaries-v1}"
DUCK="${2:-$ROOT/dist/buildroot-binaries/duckstation-hotr.tar.gz}"
PCSX2="${3:-$ROOT/dist/buildroot-binaries/pcsx2-hotr.tar.gz}"
HOTR="${4:-$ROOT/payload/hotr/HookOfTheReaper-x86_64.AppImage}"
[ -f "$DUCK" ] || { echo "ERROR: $DUCK missing" >&2; exit 2; }
[ -f "$PCSX2" ] || { echo "ERROR: $PCSX2 missing" >&2; exit 2; }
[ -f "$HOTR" ] || { echo "ERROR: HOTR AppImage missing: $HOTR" >&2; exit 2; }
command -v gh >/dev/null || { echo "ERROR: gh is required" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp "$DUCK" "$TMP/duckstation-hotr.tar.gz"
cp "$PCSX2" "$TMP/pcsx2-hotr.tar.gz"
cp "$HOTR" "$TMP/HookOfTheReaper-x86_64.AppImage"
( cd "$TMP"; sha256sum duckstation-hotr.tar.gz pcsx2-hotr.tar.gz HookOfTheReaper-x86_64.AppImage > SHA256SUMS )
if ! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release create "$TAG" --repo "$REPO" --prerelease --title "HOTR binary payload $TAG" --notes "Batocera 43 native emulator payloads + HOTR AppImage."
fi
gh release upload "$TAG" --repo "$REPO" --clobber "$TMP"/*
echo "Updated $TAG"
