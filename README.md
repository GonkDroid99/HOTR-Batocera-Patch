# HOTR Batocera 43 Patch

A drop-in add-on for stock Batocera 43/43.1 x86_64. It adds **PlayStation HOTR** and **PlayStation 2 HOTR** alongside the stock systems, Hook of the Reaper, MameOutputSender, gun auto-configuration, custom configgen generators, and full EmulationStation settings. It does not require distributing a custom Batocera image.

## Why this revision is different

The old Batocera 42 setup compiled DuckStation LightGun and PCSX2 LightGun inside Batocera Buildroot. Recent binaries compiled on rolling Linux required GLIBC 2.42/2.43 and newer C++ ABI symbols, while Batocera 43 provides GLIBC 2.40 / GLIBCXX 3.4.32 / CXXABI 1.3.14. This revision restores the old Buildroot recipes so the emulator binaries are compiled against Batocera's own runtime.

## Repository vs release assets

The Git repo contains scripts/configuration only. Large runtime files live in a prerelease named `binaries-v1`:

```text
duckstation-hotr.tar.gz
pcsx2-hotr.tar.gz
Hook_of_the_Reaper-x86_64.AppImage
SHA256SUMS
```

A normal `v*` GitHub tag runs `.github/workflows/release.yml`, downloads those assets, and publishes `HOTR-Batocera43-x86_64.zip`. `bootstrap.sh` installs the latest normal release.

## Build the two emulators

See `buildroot/README.md`. In short:

```bash
cp buildroot/buildroot.conf.example buildroot/buildroot.conf
# edit source paths and exact Batocera 43/43.1 ref
./buildroot/build-emulators.sh
```

This uses Batocera's supported package-build entry point (`make x86_64-pkg PKG=...`) and collects only the runtime outputs. The first build may still build/download the toolchain and dependencies; it does not need to create a Batocera image.

## Publish binary payloads

After building the emulator archives and your compatible HOTR AppImage:

```bash
./scripts/publish-binaries-release.sh binaries-v1 \
  dist/buildroot-binaries/duckstation-hotr.tar.gz \
  dist/buildroot-binaries/pcsx2-hotr.tar.gz \
  /path/to/Hook_of_the_Reaper-x86_64.AppImage
```

Then publish a normal release:

```bash
git tag v1.1.0
git push origin v1.1.0
```

## Install on Batocera

```bash
curl -fsSL https://raw.githubusercontent.com/GonkDroid99/HOTR-Batocera-Patch/main/bootstrap.sh | bash
```

Reboot after installation. The two HOTR systems share `/userdata/roms/psx` and `/userdata/roms/ps2` with the stock systems.

Management scripts are retained after install under:

```text
/userdata/system/hotr/tools/check-install.sh
/userdata/system/hotr/tools/update.sh
/userdata/system/hotr/tools/uninstall.sh
```

## PCSX2 HOTR settings

At install time `generate-es-features-hotr.py` clones Batocera 43's current stock PCSX2 settings and merges the 31 custom settings from the old working `pcsx2-lightgun.emulator.yml`. This avoids the earlier reduced settings menu while preserving current Batocera options. DuckStation HOTR similarly clones the stock DuckStation feature set and adds the HOTR output switch.

## Runtime layout

```text
/userdata/system/hotr/emulators/duckstation/
  duckstation-lightgun-qt
  resources/
  translations/
  MameOutputSender

/userdata/system/hotr/emulators/pcsx2/
  pcsx2-lightgun-qt
  resources/
  translations/
  MameOutputSender

/userdata/system/hotr/software/hook-of-the-reaper/
  hook-of-the-reaper
```
