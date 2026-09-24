# Native Batocera 43 emulator builder

This uses the old working `duckstation-lightgun` and `pcsx2-lightgun` Buildroot recipes only as a **compiler/package environment**. It does not build or distribute a custom Batocera image.

1. Copy `buildroot.conf.example` to `buildroot.conf`.
2. Point `DUCKSTATION_SOURCE` and `PCSX2_SOURCE` at your current patched forks.
3. Point `BATOCERA_TREE` at a Batocera 43/43.1 source checkout (or allow the script to clone it) and set `BATOCERA_REF` to the exact 43/43.1 ref/commit you want.
4. Run `./buildroot/build-emulators.sh`.

Batocera exposes `make x86_64-pkg PKG=<package>` for individual package builds. The first run can still download/build the cross toolchain and dependencies, but it does not need to produce a Batocera image.

Outputs:

- `dist/buildroot-binaries/duckstation-hotr.tar.gz`
- `dist/buildroot-binaries/pcsx2-hotr.tar.gz`

Publish those two archives together with the HOTR AppImage using `scripts/publish-binaries-release.sh`.
