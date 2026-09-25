#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CONF="${HOTR_BUILD_CONF:-$HERE/buildroot.conf}"
[ -f "$CONF" ] || { echo "ERROR: $CONF missing. Copy buildroot.conf.example to buildroot.conf and edit it." >&2; exit 2; }
# shellcheck disable=SC1090
. "$CONF"
: "${BATOCERA_TREE:?}" "${DUCKSTATION_SOURCE:?}" "${PCSX2_SOURCE:?}"
BATOCERA_TARGET="${BATOCERA_TARGET:-x86_64}"
AUTO_CLONE_BATOCERA="${AUTO_CLONE_BATOCERA:-0}"

need(){ command -v "$1" >/dev/null || { echo "ERROR: missing $1" >&2; exit 2; }; }
need git; need rsync; need tar; need make; need python3
[ -d "$DUCKSTATION_SOURCE" ] || { echo "ERROR: DuckStation source not found: $DUCKSTATION_SOURCE" >&2; exit 2; }
[ -d "$PCSX2_SOURCE" ] || { echo "ERROR: PCSX2 source not found: $PCSX2_SOURCE" >&2; exit 2; }

if [ ! -d "$BATOCERA_TREE/.git" ]; then
  [ "$AUTO_CLONE_BATOCERA" = 1 ] || { echo "ERROR: Batocera tree missing: $BATOCERA_TREE" >&2; exit 2; }
  mkdir -p "$(dirname "$BATOCERA_TREE")"
  git clone "${BATOCERA_REPO:-https://github.com/batocera-linux/batocera.linux.git}" "$BATOCERA_TREE"
fi
if [ -n "${BATOCERA_REF:-}" ]; then
  git -C "$BATOCERA_TREE" fetch --all --tags
  git -C "$BATOCERA_TREE" checkout "$BATOCERA_REF"
fi

echo "Batocera checkout: $(git -C "$BATOCERA_TREE" rev-parse --short HEAD)"
grep -q 'batocera.linux 43' "$BATOCERA_TREE/batocera-Changelog.md" || echo "WARNING: checkout does not obviously contain the Batocera 43 changelog."

# Stage custom source INSIDE the Batocera tree so its build Docker container can see it.
mkdir -p "$BATOCERA_TREE/.hotr-sources"
rsync -a --delete --exclude '.git' --exclude 'build*' "$DUCKSTATION_SOURCE/" "$BATOCERA_TREE/.hotr-sources/duckstation-lightgun-src/"
rsync -a --delete --exclude '.git' --exclude 'build*' "$PCSX2_SOURCE/" "$BATOCERA_TREE/.hotr-sources/pcsx2-lightgun-src/"

# Install the old known-working package recipes/patches into the Batocera tree.
mkdir -p "$BATOCERA_TREE/package/batocera/emulators" "$BATOCERA_TREE/package/batocera/libraries/rapidyaml"
rsync -a --delete "$HERE/recipes/package/batocera/emulators/duckstation-lightgun/" "$BATOCERA_TREE/package/batocera/emulators/duckstation-lightgun/"
rsync -a --delete "$HERE/recipes/package/batocera/emulators/pcsx2-lightgun/" "$BATOCERA_TREE/package/batocera/emulators/pcsx2-lightgun/"
rsync -a --delete "$HERE/recipes/package/batocera/libraries/rapidyaml/" "$BATOCERA_TREE/package/batocera/libraries/rapidyaml/"

# Buildroot external packages are picked up from their .mk files. Batocera's
# top-level Makefile exposes <target>-pkg specifically for individual packages.
# First invocation may still build/download the required toolchain + dependencies.
cd "$BATOCERA_TREE"
echo "=== Building DuckStation LightGun for $BATOCERA_TARGET ==="
make "${BATOCERA_TARGET}-pkg" PKG=duckstation-lightgun

echo "=== Building PCSX2 LightGun for $BATOCERA_TARGET ==="
make "${BATOCERA_TARGET}-pkg" PKG=pcsx2-lightgun

TARGET="$BATOCERA_TREE/output/$BATOCERA_TARGET/target"
DIST="$ROOT/dist/buildroot-binaries"
rm -rf "$DIST"
mkdir -p "$DIST/duckstation" "$DIST/pcsx2"

# Collect exactly the runtime files the bootstrap installer needs.
install -m 0755 "$TARGET/usr/bin/duckstation-lightgun-qt" "$DIST/duckstation/duckstation-lightgun-qt"
[ -f "$TARGET/usr/bin/duckstation-lightgun-nogui" ] && install -m 0755 "$TARGET/usr/bin/duckstation-lightgun-nogui" "$DIST/duckstation/duckstation-lightgun-nogui" || true
cp -a "$TARGET/usr/share/duckstation-lightgun/resources" "$DIST/duckstation/" 2>/dev/null || true
cp -a "$TARGET/usr/share/duckstation-lightgun/translations" "$DIST/duckstation/" 2>/dev/null || true
install -m 0755 "$HERE/recipes/package/batocera/emulators/duckstation-lightgun/MameOutputSender" "$DIST/duckstation/MameOutputSender"

PCSX2ROOT="$TARGET/usr/pcsx2-lightgun/bin"
install -m 0755 "$PCSX2ROOT/pcsx2-lightgun-qt" "$DIST/pcsx2/pcsx2-lightgun-qt"
[ -d "$PCSX2ROOT/resources" ] && cp -a "$PCSX2ROOT/resources" "$DIST/pcsx2/"
[ -d "$PCSX2ROOT/translations" ] && cp -a "$PCSX2ROOT/translations" "$DIST/pcsx2/"
# PCSX2 LightGun links against rapidyaml 0.12.1. Keep that library private to
# the HOTR build instead of installing/overriding it globally on Batocera.
mkdir -p "$DIST/pcsx2/lib"
cp -a "$TARGET/usr/lib/libryml.so"* "$DIST/pcsx2/lib/"
install -m 0755 "$HERE/recipes/package/batocera/emulators/pcsx2-lightgun/MameOutputSender" "$DIST/pcsx2/MameOutputSender"

# Native Batocera target binaries should naturally match the v43 runtime.
# Print requirements where host tools can inspect them; absence is not fatal.
abi_report(){
  local f="$1"
  echo "--- ABI: $f ---"
  if command -v objdump >/dev/null; then
    objdump -T "$f" 2>/dev/null | grep -oE 'GLIBC_[0-9.]+' | sort -Vu | tail -1 || true
  fi
}
abi_report "$DIST/duckstation/duckstation-lightgun-qt"
abi_report "$DIST/pcsx2/pcsx2-lightgun-qt"

tar -C "$DIST/duckstation" -czf "$DIST/duckstation-hotr.tar.gz" .
tar -C "$DIST/pcsx2" -czf "$DIST/pcsx2-hotr.tar.gz" .
sha256sum "$DIST/duckstation-hotr.tar.gz" "$DIST/pcsx2-hotr.tar.gz" > "$DIST/emulator-SHA256SUMS"

echo
echo "Built native Batocera runtime payloads:"
ls -lh "$DIST/duckstation-hotr.tar.gz" "$DIST/pcsx2-hotr.tar.gz"
