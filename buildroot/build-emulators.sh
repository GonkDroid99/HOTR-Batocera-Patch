#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CONF="${HOTR_BUILD_CONF:-$HERE/buildroot.conf}"

[ -f "$CONF" ] || {
  echo "ERROR: $CONF missing. Copy buildroot.conf.example to buildroot.conf and edit it." >&2
  exit 2
}

# shellcheck disable=SC1090
. "$CONF"

: "${BATOCERA_TREE:?}" "${DUCKSTATION_SOURCE:?}" "${PCSX2_SOURCE:?}"

BATOCERA_TARGET="${BATOCERA_TARGET:-x86_64}"
AUTO_CLONE_BATOCERA="${AUTO_CLONE_BATOCERA:-0}"
BATOCERA_DOCKER_IMAGE="${BATOCERA_DOCKER_IMAGE:-batoceralinux/batocera.linux-build:43.1-local}"

need() {
  command -v "$1" >/dev/null || {
    echo "ERROR: missing $1" >&2
    exit 2
  }
}

need git
need rsync
need tar
need make
need python3
need docker

[ -d "$DUCKSTATION_SOURCE" ] || {
  echo "ERROR: DuckStation source not found: $DUCKSTATION_SOURCE" >&2
  exit 2
}

[ -d "$PCSX2_SOURCE" ] || {
  echo "ERROR: PCSX2 source not found: $PCSX2_SOURCE" >&2
  exit 2
}

if [ ! -d "$BATOCERA_TREE/.git" ]; then
  [ "$AUTO_CLONE_BATOCERA" = 1 ] || {
    echo "ERROR: Batocera tree missing: $BATOCERA_TREE" >&2
    exit 2
  }

  mkdir -p "$(dirname "$BATOCERA_TREE")"

  git clone \
    "${BATOCERA_REPO:-https://github.com/batocera-linux/batocera.linux.git}" \
    "$BATOCERA_TREE"
fi

if [ -n "${BATOCERA_REF:-}" ]; then
  git -C "$BATOCERA_TREE" fetch --all --tags
  git -C "$BATOCERA_TREE" checkout "$BATOCERA_REF"
fi

echo "Synchronising Batocera submodules..."
git -C "$BATOCERA_TREE" submodule sync --recursive
git -C "$BATOCERA_TREE" submodule update --init --recursive --force

echo
echo "=== Checking Batocera build container ==="
echo "Docker image: $BATOCERA_DOCKER_IMAGE"

if ! docker image inspect "$BATOCERA_DOCKER_IMAGE" >/dev/null 2>&1; then
  echo "Building Batocera build image from this source checkout..."

  (
    cd "$BATOCERA_TREE"
    docker build \
      -t "$BATOCERA_DOCKER_IMAGE" \
      .
  )
else
  echo "Using existing local Docker image."
fi

DOCKER_IMAGE_NAME="${BATOCERA_DOCKER_IMAGE#*/}"

BATOCERA_MK="$BATOCERA_TREE/batocera.mk"
touch "$BATOCERA_MK"

if grep -q '^DOCKER_IMAGE_NAME[[:space:]]*=' "$BATOCERA_MK"; then
  sed -i \
    "s|^DOCKER_IMAGE_NAME[[:space:]]*=.*|DOCKER_IMAGE_NAME = $DOCKER_IMAGE_NAME|" \
    "$BATOCERA_MK"
else
  echo "DOCKER_IMAGE_NAME = $DOCKER_IMAGE_NAME" >> "$BATOCERA_MK"
fi

touch "$BATOCERA_TREE/.ba-docker-image-available"

BUILD_ENV_MARKER="$BATOCERA_TREE/output/.hotr-docker-image"

if [ -f "$BUILD_ENV_MARKER" ]; then
  PREVIOUS_BUILD_IMAGE="$(cat "$BUILD_ENV_MARKER")"

  if [ "$PREVIOUS_BUILD_IMAGE" != "$BATOCERA_DOCKER_IMAGE" ]; then
    echo
    echo "Build container changed."
    echo "Previous: $PREVIOUS_BUILD_IMAGE"
    echo "Current:  $BATOCERA_DOCKER_IMAGE"
    echo "Cleaning cached $BATOCERA_TARGET output..."

    rm -rf "$BATOCERA_TREE/output/$BATOCERA_TARGET"
  fi
fi

mkdir -p "$BATOCERA_TREE/output"
printf '%s\n' "$BATOCERA_DOCKER_IMAGE" > "$BUILD_ENV_MARKER"

echo
echo "Batocera checkout: $(git -C "$BATOCERA_TREE" rev-parse --short HEAD)"

grep -q 'batocera.linux 43' \
  "$BATOCERA_TREE/batocera-Changelog.md" ||
  echo "WARNING: checkout does not obviously contain the Batocera 43 changelog."

# Stage custom source INSIDE the Batocera tree so its build Docker container can see it.
mkdir -p "$BATOCERA_TREE/.hotr-sources"
rsync -a --delete --exclude '.git' --exclude 'build*' "$DUCKSTATION_SOURCE/" "$BATOCERA_TREE/.hotr-sources/duckstation-lightgun-src/"
rsync -a --delete --exclude '.git' --exclude 'build*' "$PCSX2_SOURCE/" "$BATOCERA_TREE/.hotr-sources/pcsx2-lightgun-src/"

# Install the old known-working package recipes/patches into the Batocera tree.
mkdir -p "$BATOCERA_TREE/package/batocera/emulators"
rsync -a --delete --exclude '.git' --exclude 'build*' \
    "$DUCKSTATION_SOURCE/" \
    "$BATOCERA_TREE/.hotr-sources/duckstation-lightgun-src/"

# Remove stale reference to nonexistent build_timestamp.h.
sed -i '/^[[:space:]]*build_timestamp\.h[[:space:]]*$/d' \
    "$BATOCERA_TREE/.hotr-sources/duckstation-lightgun-src/src/common/CMakeLists.txt"

rsync -a --delete --exclude '.git' --exclude 'build*' \
    "$PCSX2_SOURCE/" \
    "$BATOCERA_TREE/.hotr-sources/pcsx2-lightgun-src/"
# Stage rapidyaml v0.12.1 package required by PCSX2
mkdir -p "$BATOCERA_TREE/package/batocera/libraries/rapidyaml"

rsync -a --delete \
    "$HERE/recipes/package/batocera/libraries/rapidyaml/" \
    "$BATOCERA_TREE/package/batocera/libraries/rapidyaml/"
    
# Buildroot external packages are picked up from their .mk files. Batocera's
# top-level Makefile exposes <target>-pkg specifically for individual packages.
# First invocation may still build/download the required toolchain + dependencies.
cd "$BATOCERA_TREE"

echo
echo "=== Batocera build environment ==="
echo "Target: $BATOCERA_TARGET"
echo "Ref:    $(git describe --tags --always)"
echo "Commit: $(git rev-parse --short HEAD)"
echo

echo "Buildroot submodule:"
git submodule status buildroot
echo

echo "=== Building DuckStation LightGun for $BATOCERA_TARGET ==="

make DIRECT_BUILD= \
    "${BATOCERA_TARGET}-pkg" \
    PKG=duckstation-lightgun

echo
echo "=== Building PCSX2 LightGun for $BATOCERA_TARGET ==="

make DIRECT_BUILD= \
    "${BATOCERA_TARGET}-pkg" \
    PKG=pcsx2-lightgun

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

install -m 0755 \
    "$PCSX2ROOT/pcsx2-lightgun-qt" \
    "$DIST/pcsx2/pcsx2-lightgun-qt"

[ -d "$PCSX2ROOT/resources" ] && \
    cp -a "$PCSX2ROOT/resources" "$DIST/pcsx2/"

[ -d "$PCSX2ROOT/translations" ] && \
    cp -a "$PCSX2ROOT/translations" "$DIST/pcsx2/"

install -m 0755 \
    "$HERE/recipes/package/batocera/emulators/pcsx2-lightgun/MameOutputSender" \
    "$DIST/pcsx2/MameOutputSender"

# PCSX2 uses our external rapidyaml v0.12.1 build. Keep this dependency
# private to the HOTR PCSX2 runtime rather than modifying Batocera /usr/lib.
mkdir -p "$DIST/pcsx2/lib"

install -m 0755 \
    "$TARGET/usr/lib/libryml.so.0.12.1" \
    "$DIST/pcsx2/lib/libryml.so.0.12.1"


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
(
    cd "$DIST"
    sha256sum \
        duckstation-hotr.tar.gz \
        pcsx2-hotr.tar.gz \
        > emulator-SHA256SUMS
)

echo
echo "Built native Batocera runtime payloads:"
ls -lh "$DIST/duckstation-hotr.tar.gz" "$DIST/pcsx2-hotr.tar.gz"
