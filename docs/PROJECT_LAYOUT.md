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
| `payload/bios/ps2/patches.zip` | PCSX2 game patch archive bundled from the Buildroot output. |
| `scripts/hotr-service` | Background HOTR service. |
| `scripts/hotr-configgen-launch` | Emulator launcher and temporary PCSX2 fullscreen workaround. |
| `scripts/patch-batocera-sinden.sh` | Optional Sinden patch: `apply` or `remove`; creates a backup. |
| `scripts/ports/HookOfTheReaper.sh` | Opens the HOTR configuration UI. |
| `scripts/ports/HOTR-Rescan-Guns.sh` | Stops, rescans, and restarts HOTR. |

## Testing

| Path | Purpose |
| --- | --- |
| `scripts/test-hotr-autoconfig.sh` | Simulated serial and HID discovery/config merge test. |
| `scripts/test-sinden-pipeline.sh` | Sinden helper/static checks and loopback TCP test. |
| `check-install.sh` | Inspect an installed Batocera system. |
| `buildroot/check-runtime-abi.py` | Check emulator runtime dependencies. |

## Buildroot

`buildroot/` is a compiler/package environment, not a full Batocera image
build. Use `buildroot/build-emulators.sh` to produce the PCSX2 and DuckStation
archives consumed by the release payload.

## Legacy files

The following are retained as historical references but are not installed by
the current installer:

- `payload/system/HookOfTheReaper.sh`
- `payload/system/HookOfTheReaperSetup.sh`
- `payload/system/HookOfTheReaperRescan.sh`
- `scripts/ports/HOTR-Setup.sh`

Do not use those scripts for current testing; they reference the old `/usr/bin`
HOTR layout and predate the managed `/userdata/system/hotr` service.
