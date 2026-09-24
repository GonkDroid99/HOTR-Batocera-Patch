# Runtime payload

Normal Git intentionally excludes the large runtime binaries. The release workflow fills these directories from the `binaries-v1` prerelease:

- `emulators/duckstation/` from `duckstation-hotr.tar.gz`
- `emulators/pcsx2/` from `pcsx2-hotr.tar.gz`
- `hotr/hook-of-the-reaper` from `Hook_of_the_Reaper-x86_64.AppImage`

Build the emulator archives with `buildroot/build-emulators.sh`.
