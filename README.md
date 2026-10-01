# HOTR Batocera 43 Patch

Drop-in light-gun add-on for **Batocera 43/43.1 x86_64**. It keeps the stock PlayStation and PlayStation 2 systems intact and adds separate **PlayStation HOTR** and **PlayStation 2 HOTR** systems using the normal `/userdata/roms/psx` and `/userdata/roms/ps2` folders.

Features

Automatic install, uninstall and update commands
HOTR, scripts and services specifically for Batocera
Custom versions of PCSX2 and Duckstation for use with HOTR.
Custom Emulation Station Entries and settings for my emulators.
Custom Python scripts to add configgens and configurations for easy setup.


## Install

```bash
curl -fsSL https://raw.githubusercontent.com/GonkDroid99/HOTR-Batocera-Patch/main/bootstrap.sh | bash
```

Reboot after installation.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/GonkDroid99/HOTR-Batocera-Patch/main/uninstall.sh | bash
```

Reboot after installation.

## Update

```bash
curl -fsSL https://raw.githubusercontent.com/GonkDroid99/HOTR-Batocera-Patch/main/bootstrap.sh | bash
```

Reboot after installation.

## Development layout

See [`docs/PROJECT_LAYOUT.md`](docs/PROJECT_LAYOUT.md) for the active install,
runtime, testing, and Buildroot paths. The current project deliberately keeps
the stock Batocera emulators untouched and installs separate HOTR emulator
configurations.


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
/userdata/roms/hotr/HookOfTheReaper.sh
/userdata/roms/hotr/HOTR-Rescan-Guns.sh
```


## Notes

- The package does not replace Batocera's stock DuckStation, PCSX2, MAME, gun calibration scripts, or `retroshooter-guns-add`.

## HOTR diagnostic capture

For a failure that only occurs after a game starts, launch the `HOTR Debug Start`
port, start the game normally, then launch `HOTR Debug Finish`. The second port
collects the HOTR daemon log, game-launch arguments, saved gun paths, serial
device/udev state, process ownership, kernel USB/TTY messages, and (when
available) an `strace` of HOTR's serial `open(2)` calls. It attempts to upload
the report to `https://paste.rs` and leaves a local copy under
`/userdata/system/logs/hotr-debug/` if upload fails.

From SSH, the equivalent commands are:

```sh
/userdata/system/hotr/tools/hotr-debug-report.sh start
# launch the failing game, then:
/userdata/system/hotr/tools/hotr-debug-report.sh finish
```
- The small configgen/udev/desktop changes under Batocera's root filesystem are persisted with `batocera-save-overlay`.
