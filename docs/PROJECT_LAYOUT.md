# Project layout

This repository has three layers: release/install logic, Batocera runtime
payload, and the local Buildroot emulator toolchain.

## Active install path

| Path | Purpose |
| --- | --- |
| `bootstrap.sh` | Downloads/starts the installer on Batocera. |
| `install.sh` | Main installer and overlay persistence step. |
| `update.sh` / `uninstall.sh` | Update and removal operations. |
| `installer.conf` | Emulator source/release settings. |
| `payload/configgen/generators/` | Separate PCSX2/DuckStation configgen generators. |
| `payload/system/hotr-autoconfig.py` | Boot/rescan device discovery and HOTR config merge. |
| `payload/system/99-hotr.rules` | HOTR USB permissions and serial aliases. |
| `payload/emulators/pcsx2/resources/patches.zip` | PCSX2 game patch archive bundled with the emulator resources. |
| `scripts/hotr-service` | Background HOTR service. |
| `payload/system/hotr-sinden-broker.py` | Optional HOTR TCP-to-Sinden serial broker and per-gun PTY worker. |
| `payload/system/hotr-sinden-worker-launch` | Stable per-gun worker/PTY launcher used by Batocera's Sinden helper. |
| `scripts/patch-batocera-sinden-hotr.sh` | Optional broker hook; restores the stock helper with `remove`. |
| `scripts/hotr-configgen-launch` | Emulator launcher and temporary PCSX2 fullscreen workaround. |
| `scripts/patch-batocera-sinden.sh` | Optional Sinden patch: `apply` or `remove`; creates a backup. |
| `scripts/ports/HookOfTheReaper.sh` | Opens the HOTR configuration UI. |
| `scripts/ports/HOTR-Rescan-Guns.sh` | Stops, rescans, and restarts HOTR. |

## Testing

All repository tests live under `scripts/tests/`. The installer includes only
the two comprehensive Sinden tests; the smaller tests remain available for
development and regression checks.

| Path | Purpose |
| --- | --- |
| `scripts/tests/test-hotr-autoconfig.sh` | Simulated serial and HID discovery/config merge test. |
| `scripts/tests/test-sinden-pipeline.sh` | Sinden helper/static checks and loopback TCP test. |
| `scripts/tests/hotr-sinden-broker-selftest.sh` | Hardware-free TCP-to-serial-frame translation test. |
| `scripts/tests/hotr-sinden-worker-selftest.sh` | Hardware-free end-to-end TCP, worker, fake serial and Mono-PTY test. |
| `scripts/tests/hotr-sinden-integration-selftest.sh` | Installed-path test using a pseudo-terminal as an emulated Sinden gun. |
| `scripts/tests/hotr-sinden-full-selftest.sh` | Comprehensive multi-gun, protocol, PTY, mapping and v43/v44 helper-contract test with a full report. |
| `scripts/tests/hotr-sinden-native-helper-selftest.py` | Native-helper simulation with fake udev discovery, serial device, Mono launch and HOTR recoil. |
| `check-install.sh` | Inspect an installed Batocera system. |
| `buildroot/check-runtime-abi.py` | Check emulator runtime dependencies. |

## Buildroot

`buildroot/` is a compiler/package environment, not a full Batocera image
build. Use `buildroot/build-emulators.sh` to produce the PCSX2 and DuckStation
archives consumed by the release payload.

Runtime configgen paths are discovered from `/usr/lib/python*/site-packages`
at install/check/uninstall time; the project does not require a fixed Python
minor version.

