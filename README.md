# HOTR Batocera 43 Patch

Drop-in light-gun add-on for **Batocera 43/43.1 x86_64**. It keeps the stock PlayStation and PlayStation 2 systems intact and adds separate **PlayStation HOTR** and **PlayStation 2 HOTR** systems using the normal `/userdata/roms/psx` and `/userdata/roms/ps2` folders.

## Runtime architecture

- DuckStation LightGun: native binary built with the Batocera 43.1 Buildroot/toolchain.
- PCSX2 LightGun: native binary built with the Batocera 43.1 Buildroot/toolchain, with private `libryml` under its own `lib/` directory.
- Hook of the Reaper: x86_64 AppImage, started as a Batocera service.
- `MameOutputSender`: installed beside each custom emulator.
- RS3 mode lifecycle: HOTR owns joystick/mouse switching (`ZJ` on game start, `ZM` on game exit).
- Native MAME: network output plus MSOP `stateoutput` for games whose MAME drivers do not expose recoil themselves.

The custom systems share the stock ROM directories; no ROM duplication is required.

## Confirmed Batocera 43.1 behaviour

The current integration has been tested with an RS3 Reaper through clean boot, automatic gun detection, PlayStation/PlayStation 2 game launch and exit, HOTR service restart/rescan, and MAME/MSOP recoil. The RS3 returns to mouse mode when games exit through HOTR's normal lifecycle.

PCSX2 uses isolated configuration under:

```text
/userdata/system/configs/pcsx2-lightgun-xdg/PCSX2/
```

The generator seeds that configuration from stock PCSX2 only once. It does **not** overwrite the custom INI every launch, so the GunCon2 SDL mappings remain persistent. PCSX2 is always launched with `-fastboot`, its private library directory is prepended to `LD_LIBRARY_PATH`, and a PS2-only X11 helper performs the tested Alt+Enter-twice workaround against the real large PCSX2 game window.

DuckStation dynamically maps detected guns to `SDL-0`, `SDL-1`, etc. and keeps Batocera's stock DuckStation feature set through the generated ES feature configuration.

## MAME + MSOP

Batocera MAME 0.285 was verified to expose only `mame_start`/`mame_stop` for Alien 3 without the plugin. MSOP 8.4.0 adds the required state signals, including `MSOP_P1_Recoil`, and the MSOP-supplied HOTR profile maps those signals to recoil successfully.

The installer therefore:

1. keeps/sets `output network` in `/userdata/system/configs/mame/mame.ini` without replacing the rest of the file;
2. installs pinned MSOP 8.4.0 to `/userdata/saves/mame/plugins/stateoutput`;
3. adds `stateoutput` to Batocera configgen's existing MAME plugin list, preserving `hiscore`, `coindrop`, `data`, etc.;
4. merges MSOP's matching HOTR `defaultLG` profiles into the persistent HOTR profile directory.

## Repository vs binary prerelease

The Git repository contains scripts, configgen modules, Buildroot recipes and small data/config files. Large runtime binaries live in the GitHub prerelease tag configured by `HOTR_BINARY_RELEASE_TAG` (currently `binaries-v1`):

```text
duckstation-hotr.tar.gz
pcsx2-hotr.tar.gz
Hook_of_the_Reaper-x86_64.AppImage
SHA256SUMS
```

A normal `v*` tag runs `.github/workflows/release.yml`, downloads those binary assets, assembles the self-contained installer and publishes:

```text
HOTR-Batocera43-x86_64.zip
HOTR-Batocera43-x86_64.zip.sha256
```

## Build the native emulators

The Buildroot package recipes are under `buildroot/recipes/`. Configure the Batocera 43.1 source path in `buildroot/buildroot.conf` and run:

```bash
./buildroot/build-emulators.sh
```

Expected publishable outputs are:

```text
dist/buildroot-binaries/duckstation-hotr.tar.gz
dist/buildroot-binaries/pcsx2-hotr.tar.gz
```

These builds intentionally target Batocera's ABI instead of a rolling Linux distribution.

## Update `binaries-v1`

After rebuilding both emulator archives and the HOTR AppImage:

```bash
./scripts/publish-binaries-release.sh \
  binaries-v1 \
  dist/buildroot-binaries/duckstation-hotr.tar.gz \
  dist/buildroot-binaries/pcsx2-hotr.tar.gz \
  /path/to/Hook_of_the_Reaper-x86_64.AppImage
```

The HOTR AppImage used for this release should include the tested Linux fixes: XCB AppRun default, `QApplication` for `--no-ui`, `HOTR_DATA_DIR` support, and the RS3 `Close_COM_InitOnly` handling that does not suppress the final mouse-mode restore.

## Publish a normal release

After pushing the updated repository and refreshing `binaries-v1`:

```bash
git tag v1.1.0
git push origin main
git push origin v1.1.0
```

Or run the **Build HOTR Batocera release** workflow manually and choose the desired normal release tag plus `binaries-v1`.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/GonkDroid99/HOTR-Batocera-Patch/main/bootstrap.sh | bash
```

Reboot after installation.

## Installed layout

```text
/userdata/system/hotr/
  bin/
  emulators/duckstation/
  emulators/pcsx2/
  software/hook-of-the-reaper/
    hook-of-the-reaper
    data -> /userdata/system/hook-of-the-reaper/data
    defaultLG -> /userdata/system/hook-of-the-reaper/defaultLG
  tools/

/userdata/system/hook-of-the-reaper/
  data/
  defaultLG/

/userdata/system/configs/emulationstation/
  es_systems_hotr.cfg
  es_features_hotr.cfg

/userdata/system/services/hotr
/userdata/saves/mame/plugins/stateoutput/
/userdata/roms/ports/HookOfTheReaper.sh
/userdata/roms/ports/HOTR-Rescan-Guns.sh
```

`HOTR-Setup.sh` is intentionally no longer installed. The rescan entry stops the service, performs forced auto-detection and restarts the service. The normal HOTR Ports entry temporarily stops service mode, opens the GUI, and returns to service mode when the GUI exits.

## Notes

- The package does not replace Batocera's stock DuckStation, PCSX2, MAME, gun calibration scripts, or `retroshooter-guns-add`.
- The small configgen/udev/desktop changes under Batocera's root filesystem are persisted with `batocera-save-overlay`.
- Do not add an emulator-side direct `ZM` reset. HOTR is responsible for RS3 mode switching.
- Minimal Batocera installations do not provide `find`; runtime installer scripts avoid depending on it.
