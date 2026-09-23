# HOTR for Batocera 43 (x86_64)

Drop-in add-on for **Batocera 43/43.1 x86_64**. It keeps Batocera's normal PlayStation and PlayStation 2 emulators intact and adds two additional systems:

- **PlayStation HOTR** — custom DuckStation light-gun build
- **PlayStation 2 HOTR** — `PCSX2-hotr.AppImage`

Both systems use the normal `/userdata/roms/psx` and `/userdata/roms/ps2` folders, so ROMs are not duplicated.

## What is included

The package contains the custom configgen generators from the supplied Batocera source tree, `MameOutputSender` for both emulators, Hook of the Reaper plus its `data` and `defaultLG` files, gun auto-detection, udev rules, a Batocera user service, ES systems/features, Ports launchers, F1/Desktop launchers, installer/updater/uninstaller/checker, and a GitHub Release bootstrap.

`MameOutputSender` is installed **beside each emulator**, as required.

## Emulator binaries

The uploaded material contained the Batocera integration/build definitions and HOTR executable, but not a complete distributable DuckStation binary tree or `PCSX2-hotr.AppImage`. The installer therefore supports both bundled binaries and GitHub downloads.

Before building a fully self-contained release, place:

```text
payload/emulators/duckstation/
  duckstation-qt                 # or duckstation-lightgun-qt
  resources/                     # if supplied by your build
  translations/                  # if supplied by your build
  MameOutputSender               # already included

payload/emulators/pcsx2/
  PCSX2-hotr.AppImage
  MameOutputSender               # already included
```

The installer normalizes DuckStation's executable name to `duckstation-lightgun-qt`.

Alternatively edit `installer.conf`, set the two GitHub repositories/asset patterns and change `ENABLE_GITHUB_EMULATOR_DOWNLOADS=1`.

## Install directly on Batocera

Copy/extract this repository onto the SHARE partition and run over SSH:

```bash
cd /userdata/path/to/HOTR-Batocera43
./install.sh --auto
```

Modes:

```bash
./install.sh --auto                 # bundled first; GitHub fallback if configured
./install.sh --bundled              # use payload/emulators only
./install.sh --github-emulators     # download emulator releases
./install.sh --infrastructure-only  # install integration; add emulators later
```

Then reboot or restart EmulationStation.

## One-command GitHub installation

1. Upload this repository to GitHub.
2. Edit `bootstrap.sh` and `installer.conf`, replacing `OWNER/...` placeholders.
3. Put the emulator files in `payload/emulators/` **or** configure their separate GitHub release repositories.
4. Run `./build-release.sh` and publish `dist/HOTR-Batocera43-x86_64.zip` as a release asset. The included GitHub Actions workflow can do this for tagged releases.

Users can then install with:

```bash
curl -fsSL https://raw.githubusercontent.com/YOURNAME/HOTR-Batocera/main/bootstrap.sh | bash
```

For public distribution, it is safer to download and inspect `bootstrap.sh` before running it as root.

## Installed layout

```text
/userdata/system/hotr/
  bin/
    hotr-configgen-launch
    hotr-autoconfig.py
    add-emulator-config.sh
  emulators/
    duckstation/
      duckstation-lightgun-qt
      resources/
      translations/
      MameOutputSender
    pcsx2/
      PCSX2-hotr.AppImage
      MameOutputSender
  software/hook-of-the-reaper/
    hook-of-the-reaper
    data -> /userdata/system/hook-of-the-reaper/data
    defaultLG -> /userdata/system/hook-of-the-reaper/defaultLG
  scripts/

/userdata/system/hook-of-the-reaper/
  data/
  defaultLG/

/userdata/system/configs/emulationstation/
  es_systems_hotr.cfg
  es_features_hotr.cfg

/userdata/system/services/hotr
/userdata/roms/ports/HookOfTheReaper.sh
/userdata/roms/ports/HOTR-Setup.sh
/userdata/roms/ports/HOTR-Rescan-Guns.sh
```

Small files that must live in Batocera's immutable root (configgen generator modules, udev rules, DuckStation resource symlink and F1 desktop launchers) are installed into the live root and persisted with `batocera-save-overlay`.

## Configgen

The custom PS1 system uses:

```text
emulator = duckstation
core     = duckstation-lightgun
```

The custom PS2 system uses:

```text
emulator = pcsx2-lightgun
core     = pcsx2-lightgun
```

The supplied custom generators inherit Batocera's standard DuckStation/PCSX2 generators, then add HOTR/MameHooker and gun handling. The launcher invokes configgen with:

```bash
python3 -m configgen.emulatorlauncher ...
```

rather than running `emulatorlauncher.py` directly.

`es_features_hotr.cfg` currently exposes the HOTR/MameHooker switch. Add additional custom options there later; the value names must match the keys read through `system.config` by the generator.

## Hook of the Reaper

HOTR starts as a Batocera user service and listens for the output bridge. Gun configuration is persistent under `/userdata/system/hook-of-the-reaper`.

Use the Ports menu entries:

- **HookOfTheReaper** — open/raise the configuration UI.
- **HOTR-Setup** — stop HOTR, force gun auto-detection, and open the UI.
- **HOTR-Rescan-Guns** — silently rescan and restart HOTR.

Add any extra light/feedback setup you still need to:

```text
/userdata/system/hotr/scripts/custom-boot.sh
```

and shutdown/reset commands to `custom-stop.sh`.

## Adding emulator configs later

```bash
/userdata/system/hotr/bin/add-emulator-config.sh duckstation /path/settings.ini
/userdata/system/hotr/bin/add-emulator-config.sh pcsx2 /path/PCSX2.ini
```

## Verify / update / remove

```bash
./check-install.sh
./update.sh
./uninstall.sh
```

`update.sh` requires `HOTR_INSTALLER_REPO` to be set in the installed `installer.conf`.

## Important test notes

This package is designed around the supplied Batocera 43 source customizations. Test it on a spare/copy of the target Batocera installation before distributing it widely. Batocera upgrades can replace/remove the saved root overlay; rerun the installer after an OS upgrade if the configgen/udev integration disappears.

The included HOTR executable is dynamically linked against Qt 6, Qt SerialPort, Qt Multimedia and hidapi. Batocera 43 builds containing those libraries should satisfy it; `check-install.sh` checks installed files, while `ldd` on the target can be used to diagnose a missing runtime library.

## GitHub binary/release model

Large binaries are **not committed to Git**. See `BINARY_RELEASES.md`.

For this repository (`GonkDroid99/HOTR-Batocera-Patch`), first publish the
binary prerelease:

```bash
./scripts/publish-binaries-release.sh binaries-v1 \
  /path/to/duckstation-runtime-directory \
  /path/to/PCSX2-hotr.AppImage \
  /path/to/Hook_of_the_Reaper-x86_64.AppImage
```

Then create a normal tag:

```bash
git tag v1.0.0
git push origin v1.0.0
```

GitHub Actions downloads `binaries-v1`, verifies `SHA256SUMS`, inserts the
binaries into the correct payload paths, builds the self-contained installer ZIP,
and publishes it on the normal release. `bootstrap.sh` always installs the latest
normal release, not the binary prerelease.
