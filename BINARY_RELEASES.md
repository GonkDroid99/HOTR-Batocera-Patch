# Binary payload release

The Git repo intentionally excludes large binaries. Create/update the prerelease `binaries-v1` with:

- `duckstation-hotr.tar.gz` — native Batocera 43 Buildroot output
- `pcsx2-hotr.tar.gz` — native Batocera 43 Buildroot output
- `Hook_of_the_Reaper-x86_64.AppImage` — HOTR AppImage built on the compatible Ubuntu baseline
- `SHA256SUMS`

Build the two emulator archives with `./buildroot/build-emulators.sh`, then publish them with `./scripts/publish-binaries-release.sh`. A normal `v*` tag triggers GitHub Actions to download `binaries-v1`, assemble the complete installer ZIP, and publish it.
