# Native Batocera 43/44 emulator builder

This uses the old working `duckstation-lightgun` and `pcsx2-lightgun` Buildroot recipes only as a **compiler/package environment**. It does not build or distribute a custom Batocera image.

1. Copy `buildroot.conf.example` to `buildroot.conf`.
2. Point `DUCKSTATION_SOURCE` and `PCSX2_SOURCE` at your current patched forks.
3. Point `BATOCERA_TREE` at an exact Batocera 43 or 44 source checkout (or allow the script to clone it), set `BATOCERA_REF`, and set `BATOCERA_SERIES` to `43` or `44`.
4. Run `./buildroot/build-emulators.sh` to build both emulators, or select one:
   - `./buildroot/build-emulators.sh --pcsx2`
   - `./buildroot/build-emulators.sh --duckstation`
   - `./buildroot/build-emulators.sh --both --series 44`

   The equivalent generic form is `--emulator pcsx2`, `--emulator duckstation`,
   or `--emulator both`.

Batocera exposes `make x86_64-pkg PKG=<package>` for individual package builds. The first run for each series can still download/build the matching cross toolchain and dependencies, but it does not need to produce a Batocera image or unrelated packages. Keep separate Batocera checkouts for v43 and v44; each retains its own reusable cache.

Outputs:

- `dist/buildroot-binaries/v43/duckstation-hotr-v43.tar.gz`
- `dist/buildroot-binaries/v43/pcsx2-hotr-v43.tar.gz`
- `dist/buildroot-binaries/v44/duckstation-hotr-v44.tar.gz`
- `dist/buildroot-binaries/v44/pcsx2-hotr-v44.tar.gz`

Do not mix artifacts between series or transplant a Vulkan renderer into an
older binary: each archive must be installed only on the Batocera series it was
built against.

The HOTR player-assignment screen is a native EmulationStation settings page,
not a port or Qt launcher. Build the matching Batocera EmulationStation
package with:

```sh
./buildroot/build-emulators.sh --emulationstation
```

This produces `dist/buildroot-binaries/emulationstation-hotr.tar.gz`. It must
be built from the same Batocera revision as the target image; the build helper
selects the Batocera 43 or 44 source patch automatically. The release
installer only installs the HOTR helper (`/usr/bin/hotr-gun-assignment`), so a
stock EmulationStation binary remains untouched until the matching native
package is installed.

Publish those two archives together with the HOTR AppImage using `scripts/publish-binaries-release.sh`.
