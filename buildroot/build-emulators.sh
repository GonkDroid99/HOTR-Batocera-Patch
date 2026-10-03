#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CONF="${HOTR_BUILD_CONF:-$HERE/buildroot.conf}"

BUILD_EMULATOR="both"
BUILD_SERIES=""
usage(){
  cat <<EOF
Usage: $0 [--pcsx2|--duckstation|--emulationstation|--both|--emulator NAME] [--series 43|44]

Build one emulator or both (default).
The series selects an independent Batocera checkout/cache and labels the
resulting archives. It defaults to BATOCERA_SERIES from the build config, or 43.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --pcsx2) BUILD_EMULATOR="pcsx2"; shift ;;
    --duckstation) BUILD_EMULATOR="duckstation"; shift ;;
    --emulationstation) BUILD_EMULATOR="emulationstation"; shift ;;
    --both) BUILD_EMULATOR="both"; shift ;;
    --emulator)
      [ "$#" -ge 2 ] || { echo "ERROR: --emulator needs pcsx2, duckstation, or both." >&2; usage >&2; exit 2; }
      BUILD_EMULATOR="$2"
      shift 2
      ;;
    --series)
      [ "$#" -ge 2 ] || { echo "ERROR: --series needs 43 or 44." >&2; usage >&2; exit 2; }
      BUILD_SERIES="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$BUILD_EMULATOR" in
  pcsx2|duckstation|emulationstation|both) ;;
  *) echo "ERROR: emulator must be pcsx2, duckstation, or both: $BUILD_EMULATOR" >&2; exit 2 ;;
esac

[ -f "$CONF" ] || { echo "ERROR: $CONF missing. Copy buildroot.conf.example to buildroot.conf and edit it." >&2; exit 2; }
# shellcheck disable=SC1090
. "$CONF"
: "${BATOCERA_TREE:?}" "${DUCKSTATION_SOURCE:?}" "${PCSX2_SOURCE:?}"
BATOCERA_TARGET="${BATOCERA_TARGET:-x86_64}"
AUTO_CLONE_BATOCERA="${AUTO_CLONE_BATOCERA:-0}"
BUILD_SERIES="${BUILD_SERIES:-${BATOCERA_SERIES:-43}}"
case "$BUILD_SERIES" in
  43|44) ;;
  *) echo "ERROR: Batocera series must be 43 or 44: $BUILD_SERIES" >&2; exit 2 ;;
esac

need(){ command -v "$1" >/dev/null || { echo "ERROR: missing $1" >&2; exit 2; }; }
need git; need rsync; need tar; need make; need python3
if [ "$BUILD_EMULATOR" = "both" ] || [ "$BUILD_EMULATOR" = "duckstation" ]; then
  [ -d "$DUCKSTATION_SOURCE" ] || { echo "ERROR: DuckStation source not found: $DUCKSTATION_SOURCE" >&2; exit 2; }
fi
if [ "$BUILD_EMULATOR" = "both" ] || [ "$BUILD_EMULATOR" = "pcsx2" ]; then
  [ -d "$PCSX2_SOURCE" ] || { echo "ERROR: PCSX2 source not found: $PCSX2_SOURCE" >&2; exit 2; }
fi

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
if ! grep -q "batocera.linux $BUILD_SERIES" "$BATOCERA_TREE/batocera-Changelog.md"; then
  echo "WARNING: checkout does not obviously contain the Batocera $BUILD_SERIES changelog."
fi

# The v44 checkout currently pins Rust 1.95 while cargo-c 0.10.19 requires
# Rust 1.97. Keep this narrowly scoped compatibility update tracked here.
if [ "$BUILD_SERIES" = 44 ]; then
  RUST_PATCH="$HERE/patches/v44/0001-rust-1.97-for-cargo-c.patch"
  [ -f "$RUST_PATCH" ] || { echo "ERROR: missing v44 Rust compatibility patch: $RUST_PATCH" >&2; exit 2; }
  if git -C "$BATOCERA_TREE/buildroot" apply --reverse --check "$RUST_PATCH" >/dev/null 2>&1; then
    echo "v44 Rust 1.97 compatibility patch already applied."
  elif git -C "$BATOCERA_TREE/buildroot" apply --check "$RUST_PATCH"; then
    git -C "$BATOCERA_TREE/buildroot" apply "$RUST_PATCH"
    echo "Applied v44 Rust 1.97 compatibility patch."
  else
    echo "ERROR: unable to apply the v44 Rust compatibility patch." >&2
    exit 2
  fi
  RUSTC="$BATOCERA_TREE/output/$BATOCERA_TARGET/host/bin/rustc"
  if [ -x "$RUSTC" ] && ! "$RUSTC" --version | grep -q 'rustc 1\.97\.'; then
    echo "Removing stale host Rust 1.95 build state so Buildroot installs Rust 1.97."
    rm -rf "$BATOCERA_TREE/output/$BATOCERA_TARGET/build/host-rustc" \
           "$BATOCERA_TREE/output/$BATOCERA_TARGET/build/host-rust-bin-1.95.0"
  fi
fi

# Stage custom source INSIDE the Batocera tree so its build Docker container can see it.
mkdir -p "$BATOCERA_TREE/.hotr-sources"
if [ "$BUILD_EMULATOR" = "both" ] || [ "$BUILD_EMULATOR" = "duckstation" ]; then
  rsync -a --delete --exclude '.git/' --exclude 'build*/' "$DUCKSTATION_SOURCE/" "$BATOCERA_TREE/.hotr-sources/duckstation-lightgun-src/"
fi
if [ "$BUILD_EMULATOR" = "both" ] || [ "$BUILD_EMULATOR" = "pcsx2" ]; then
  rsync -a --delete --exclude '.git/' --exclude 'build*/' "$PCSX2_SOURCE/" "$BATOCERA_TREE/.hotr-sources/pcsx2-lightgun-src/"
fi

# Install the old known-working package recipes/patches into the Batocera tree.
mkdir -p "$BATOCERA_TREE/package/batocera/emulators" "$BATOCERA_TREE/package/batocera/libraries/rapidyaml"
if [ "$BUILD_EMULATOR" = "both" ] || [ "$BUILD_EMULATOR" = "duckstation" ]; then
  rsync -a --delete "$HERE/recipes/package/batocera/emulators/duckstation-lightgun/" "$BATOCERA_TREE/package/batocera/emulators/duckstation-lightgun/"
fi
if [ "$BUILD_EMULATOR" = "both" ] || [ "$BUILD_EMULATOR" = "pcsx2" ]; then
  rsync -a --delete "$HERE/recipes/package/batocera/emulators/pcsx2-lightgun/" "$BATOCERA_TREE/package/batocera/emulators/pcsx2-lightgun/"
fi
rsync -a --delete "$HERE/recipes/package/batocera/libraries/rapidyaml/" "$BATOCERA_TREE/package/batocera/libraries/rapidyaml/"
if [ "$BUILD_EMULATOR" = "emulationstation" ]; then
  ES_RECIPE="$BATOCERA_TREE/package/batocera/emulationstation/batocera-emulationstation"
  mkdir -p "$ES_RECIPE"
  rm -f "$ES_RECIPE/004-hotr-gun-assignment.patch" "$ES_RECIPE/004-hotr-gun-assignment-v43.patch"
  ES_VERSION="$(sed -n 's/^BATOCERA_EMULATIONSTATION_VERSION = //p' "$ES_RECIPE/batocera-emulationstation.mk")"
  case "$ES_VERSION" in
    ddc8255253252b7400d4c1dc0a313fe604f38f05)
      cp -a "$HERE/recipes/package/batocera/emulationstation/004-hotr-gun-assignment.patch" "$ES_RECIPE/" ;;
    *)
      cp -a "$HERE/recipes/package/batocera/emulationstation/004-hotr-gun-assignment-v43.patch" "$ES_RECIPE/004-hotr-gun-assignment.patch" ;;
  esac
fi

# Buildroot external packages are picked up from their .mk files. Batocera's
# top-level Makefile exposes <target>-pkg specifically for individual packages.
# First invocation may still build/download the required toolchain + dependencies.
cd "$BATOCERA_TREE"

echo "=== Cleaning previous HOTR emulator builds ==="
if [ "$BUILD_EMULATOR" = "both" ] || [ "$BUILD_EMULATOR" = "duckstation" ]; then
  rm -rf "$BATOCERA_TREE/output/$BATOCERA_TARGET/build/duckstation-lightgun-"*
fi
if [ "$BUILD_EMULATOR" = "both" ] || [ "$BUILD_EMULATOR" = "pcsx2" ]; then
  rm -rf "$BATOCERA_TREE/output/$BATOCERA_TARGET/build/pcsx2-lightgun-"*
fi
if [ "$BUILD_EMULATOR" = "emulationstation" ]; then
  rm -rf "$BATOCERA_TREE/output/$BATOCERA_TARGET/build/batocera-emulationstation-"*
fi

if [ "$BUILD_EMULATOR" = "both" ] || [ "$BUILD_EMULATOR" = "pcsx2" ]; then
  echo "=== Building PCSX2 LightGun for $BATOCERA_TARGET ==="
  make BATCH_MODE=1 "${BATOCERA_TARGET}-pkg" PKG=pcsx2-lightgun
fi
if [ "$BUILD_EMULATOR" = "both" ] || [ "$BUILD_EMULATOR" = "duckstation" ]; then
  echo "=== Building DuckStation LightGun for $BATOCERA_TARGET ==="
  make BATCH_MODE=1 "${BATOCERA_TARGET}-pkg" PKG=duckstation-lightgun
fi
if [ "$BUILD_EMULATOR" = "emulationstation" ]; then
  echo "=== Building native EmulationStation with HOTR gun assignment menu for $BATOCERA_TARGET ==="
  make BATCH_MODE=1 "${BATOCERA_TARGET}-pkg" PKG=batocera-emulationstation
fi


TARGET="$BATOCERA_TREE/output/$BATOCERA_TARGET/target"
DIST="$ROOT/dist/buildroot-binaries/v$BUILD_SERIES"
mkdir -p "$DIST"

if [ "$BUILD_EMULATOR" = "emulationstation" ]; then
  rm -rf "$DIST/emulationstation" "$DIST/emulationstation-hotr.tar.gz"
  mkdir -p "$DIST/emulationstation"
  install -m 0755 "$TARGET/usr/bin/emulationstation" "$DIST/emulationstation/emulationstation"
  install -m 0755 "$TARGET/usr/bin/emulationstation-standalone" "$DIST/emulationstation/emulationstation-standalone"
  tar -C "$DIST/emulationstation" -czf "$DIST/emulationstation-hotr-v$BUILD_SERIES.tar.gz" .
  sha256sum "$DIST/emulationstation-hotr-v$BUILD_SERIES.tar.gz" > "$DIST/emulationstation-SHA256SUMS"
  echo "Built native EmulationStation runtime payload:"
  ls -lh "$DIST/emulationstation-hotr-v$BUILD_SERIES.tar.gz"
  exit 0
fi

# Keep the other emulator's existing payload when building only one target.
# Clear just the selected target so stale files cannot remain inside its archive.
if [ "$BUILD_EMULATOR" = "both" ] || [ "$BUILD_EMULATOR" = "duckstation" ]; then
  rm -rf "$DIST/duckstation" "$DIST/duckstation-hotr-v$BUILD_SERIES.tar.gz"
fi
if [ "$BUILD_EMULATOR" = "both" ] || [ "$BUILD_EMULATOR" = "pcsx2" ]; then
  rm -rf "$DIST/pcsx2" "$DIST/pcsx2-hotr-v$BUILD_SERIES.tar.gz"
fi

# Collect exactly the runtime files the bootstrap installer needs.
if [ "$BUILD_EMULATOR" = "both" ] || [ "$BUILD_EMULATOR" = "duckstation" ]; then
  mkdir -p "$DIST/duckstation"
  install -m 0755 "$TARGET/usr/bin/duckstation-lightgun-qt" "$DIST/duckstation/duckstation-lightgun-qt"
  [ -f "$TARGET/usr/bin/duckstation-lightgun-nogui" ] && install -m 0755 "$TARGET/usr/bin/duckstation-lightgun-nogui" "$DIST/duckstation/duckstation-lightgun-nogui" || true
  cp -a "$TARGET/usr/share/duckstation-lightgun/resources" "$DIST/duckstation/" 2>/dev/null || true
  cp -a "$TARGET/usr/share/duckstation-lightgun/translations" "$DIST/duckstation/" 2>/dev/null || true
  install -m 0755 "$HERE/recipes/package/batocera/emulators/duckstation-lightgun/MameOutputSender" "$DIST/duckstation/MameOutputSender"
fi

if [ "$BUILD_EMULATOR" = "both" ] || [ "$BUILD_EMULATOR" = "pcsx2" ]; then
  mkdir -p "$DIST/pcsx2"
  PCSX2ROOT="$TARGET/usr/pcsx2-lightgun/bin"
  install -m 0755 "$PCSX2ROOT/pcsx2-lightgun-qt" "$DIST/pcsx2/pcsx2-lightgun-qt"
  [ -d "$PCSX2ROOT/resources" ] && cp -a "$PCSX2ROOT/resources" "$DIST/pcsx2/"
  [ -d "$PCSX2ROOT/translations" ] && cp -a "$PCSX2ROOT/translations" "$DIST/pcsx2/"
  [ -d "$ROOT/payload/emulators/pcsx2/cheats" ] && \
    cp -a "$ROOT/payload/emulators/pcsx2/cheats" "$DIST/pcsx2/"
fi

# Promote the PCSX2 resource archive into the payload and runtime archive.
if [ "$BUILD_EMULATOR" = "both" ] || [ "$BUILD_EMULATOR" = "pcsx2" ]; then
  PATCHES="$TARGET/usr/pcsx2-lightgun/bin/resources/patches.zip"
  [ -s "$PATCHES" ] || { echo "ERROR: PCSX2 patches archive missing: $PATCHES" >&2; exit 3; }
  unzip -t "$PATCHES" >/dev/null || { echo "ERROR: Invalid PCSX2 patches archive: $PATCHES" >&2; exit 3; }
  install -m 0644 "$PATCHES" "$ROOT/payload/emulators/pcsx2/resources/patches.zip"
fi

# PCSX2 LightGun links against rapidyaml 0.12.1. Keep that library private to
# the HOTR build instead of installing/overriding it globally on Batocera.
if [ "$BUILD_EMULATOR" = "both" ] || [ "$BUILD_EMULATOR" = "pcsx2" ]; then
  mkdir -p "$DIST/pcsx2/lib"
  cp -a "$TARGET/usr/lib/libryml.so"* "$DIST/pcsx2/lib/"
  install -m 0755 "$HERE/recipes/package/batocera/emulators/pcsx2-lightgun/MameOutputSender" "$DIST/pcsx2/MameOutputSender"
fi

# Native Batocera target binaries should naturally match the v43 runtime.
# Print requirements where host tools can inspect them; absence is not fatal.
abi_report(){
  local f="$1"
  echo "--- ABI: $f ---"
  if command -v objdump >/dev/null; then
    objdump -T "$f" 2>/dev/null | grep -oE 'GLIBC_[0-9.]+' | sort -Vu | tail -1 || true
  fi
}
if [ "$BUILD_EMULATOR" = "both" ] || [ "$BUILD_EMULATOR" = "duckstation" ]; then
  abi_report "$DIST/duckstation/duckstation-lightgun-qt"
  tar -C "$DIST/duckstation" -czf "$DIST/duckstation-hotr-v$BUILD_SERIES.tar.gz" .
fi
if [ "$BUILD_EMULATOR" = "both" ] || [ "$BUILD_EMULATOR" = "pcsx2" ]; then
  abi_report "$DIST/pcsx2/pcsx2-lightgun-qt"
  tar -C "$DIST/pcsx2" -czf "$DIST/pcsx2-hotr-v$BUILD_SERIES.tar.gz" .
fi
sha256sum "$DIST"/*-hotr-v"$BUILD_SERIES".tar.gz > "$DIST/emulator-SHA256SUMS"

echo
echo "Built native Batocera runtime payloads:"
ls -lh "$DIST"/*-hotr.tar.gz
