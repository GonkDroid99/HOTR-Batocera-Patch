#!/bin/bash
# Upload the three large runtime payloads to a GitHub *prerelease* named
# binaries-v1 (or another tag supplied as argument 1).
#
# Requirements on the machine running this script:
#   - gh (GitHub CLI), authenticated with `gh auth login`
#   - tar, sha256sum
#
# Usage:
#   ./scripts/publish-binaries-release.sh [tag] \
#       /path/to/duckstation-directory \
#       /path/to/PCSX2-hotr.AppImage \
#       /path/to/Hook_of_the_Reaper-x86_64.AppImage
set -euo pipefail

REPO="GonkDroid99/HOTR-Batocera-Patch"
TAG="${1:-binaries-v1}"
DUCK_DIR="${2:-}"
PCSX2_FILE="${3:-}"
HOTR_FILE="${4:-}"

usage() {
  cat <<USAGE
Usage:
  $0 [tag] DUCKSTATION_DIR PCSX2_APPIMAGE HOTR_APPIMAGE

Example:
  $0 binaries-v1 ./duckstation-build ./PCSX2-hotr.AppImage ./Hook_of_the_Reaper-x86_64.AppImage

DUCKSTATION_DIR must contain duckstation-qt (or duckstation-lightgun-qt)
and all runtime resources/libraries it needs. The archive is created with the
contents of that directory at the archive root.
USAGE
}

[ -n "$DUCK_DIR" ] && [ -n "$PCSX2_FILE" ] && [ -n "$HOTR_FILE" ] || { usage; exit 2; }
command -v gh >/dev/null || { echo "ERROR: GitHub CLI (gh) is required." >&2; exit 2; }
command -v tar >/dev/null || { echo "ERROR: tar is required." >&2; exit 2; }
command -v sha256sum >/dev/null || { echo "ERROR: sha256sum is required." >&2; exit 2; }
[ -d "$DUCK_DIR" ] || { echo "ERROR: DuckStation directory not found: $DUCK_DIR" >&2; exit 2; }
[ -f "$PCSX2_FILE" ] || { echo "ERROR: PCSX2 AppImage not found: $PCSX2_FILE" >&2; exit 2; }
[ -f "$HOTR_FILE" ] || { echo "ERROR: HOTR AppImage not found: $HOTR_FILE" >&2; exit 2; }

if [ ! -f "$DUCK_DIR/duckstation-qt" ] && [ ! -f "$DUCK_DIR/duckstation-lightgun-qt" ]; then
  echo "ERROR: $DUCK_DIR does not contain duckstation-qt or duckstation-lightgun-qt." >&2
  exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

tar -C "$DUCK_DIR" -czf "$TMP/duckstation-qt.tar.gz" .
cp -f "$PCSX2_FILE" "$TMP/PCSX2-hotr.AppImage"
cp -f "$HOTR_FILE" "$TMP/Hook_of_the_Reaper-x86_64.AppImage"
(
  cd "$TMP"
  sha256sum duckstation-qt.tar.gz PCSX2-hotr.AppImage Hook_of_the_Reaper-x86_64.AppImage > SHA256SUMS
)

echo "Prepared binary payloads:"
ls -lh "$TMP/duckstation-qt.tar.gz" "$TMP/PCSX2-hotr.AppImage" "$TMP/Hook_of_the_Reaper-x86_64.AppImage" "$TMP/SHA256SUMS"

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "Updating existing prerelease $TAG ..."
else
  echo "Creating prerelease $TAG ..."
  gh release create "$TAG" --repo "$REPO" --prerelease \
    --title "HOTR binary payload $TAG" \
    --notes "Large runtime binaries used by the HOTR Batocera release workflow. Do not install this prerelease directly."
fi

gh release upload "$TAG" --repo "$REPO" --clobber \
  "$TMP/duckstation-qt.tar.gz" \
  "$TMP/PCSX2-hotr.AppImage" \
  "$TMP/Hook_of_the_Reaper-x86_64.AppImage" \
  "$TMP/SHA256SUMS"

echo
echo "Uploaded $TAG to https://github.com/$REPO/releases/tag/$TAG"
