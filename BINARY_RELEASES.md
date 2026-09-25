# Binary release workflow

Large runtime binaries are stored in the `binaries-v1` GitHub prerelease and are not committed to the normal repository history.

Required assets:

```text
duckstation-hotr.tar.gz
pcsx2-hotr.tar.gz
Hook_of_the_Reaper-x86_64.AppImage
SHA256SUMS
```

The emulator archives must be the Batocera 43.1 Buildroot-native outputs. PCSX2 must include its private `lib/` directory (including `libryml.so.0.12.1`) beside the executable tree.

Publish/update the prerelease with:

```bash
./scripts/publish-binaries-release.sh \
  binaries-v1 \
  dist/buildroot-binaries/duckstation-hotr.tar.gz \
  dist/buildroot-binaries/pcsx2-hotr.tar.gz \
  /path/to/Hook_of_the_Reaper-x86_64.AppImage
```

Then push a normal `v*` tag. `.github/workflows/release.yml` verifies `SHA256SUMS`, assembles the runtime payload, runs `build-release.sh`, and publishes `HOTR-Batocera43-x86_64.zip` plus its checksum.
