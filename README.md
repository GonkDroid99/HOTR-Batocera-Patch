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

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/GonkDroid99/HOTR-Batocera-Patch/main/uninstall.sh | bash
```

Reboot after installation.

## Update

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


## Notes

- The package does not replace Batocera's stock DuckStation, PCSX2, MAME, gun calibration scripts, or `retroshooter-guns-add`.
- The small configgen/udev/desktop changes under Batocera's root filesystem are persisted with `batocera-save-overlay`.