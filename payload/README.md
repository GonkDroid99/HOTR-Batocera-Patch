# Runtime payload

Normal Git intentionally excludes the large runtime binaries. The release workflow fills these directories from the `binaries-v1` prerelease:

- `emulators/duckstation/` from `duckstation-hotr.tar.gz`
- `emulators/pcsx2/` from `pcsx2-hotr.tar.gz`
- `hotr/HookOfTheReaper-x86-64.AppImage` from the bundled HOTR AppImage

PCSX2 cheat files are bundled under `emulators/pcsx2/cheats/` and seeded into
`/userdata/cheats/ps2` by the installer without overwriting existing files.

Build the emulator archives with `buildroot/build-emulators.sh`.
