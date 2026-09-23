# Binary payload release

This repository intentionally does **not** commit the three large runtime binaries.
They are stored as assets on a GitHub **prerelease** (default tag `binaries-v1`).

The prerelease must contain exactly:

- `duckstation-qt.tar.gz`
- `PCSX2-hotr.AppImage`
- `Hook_of_the_Reaper-x86_64.AppImage`
- `SHA256SUMS`

`duckstation-qt.tar.gz` must have the contents of the DuckStation runtime folder
at the archive root, including `duckstation-qt` (or `duckstation-lightgun-qt`) and
any resources/libraries the custom build requires.

## First upload

Authenticate GitHub CLI once:

```bash
gh auth login
```

Then run:

```bash
./scripts/publish-binaries-release.sh binaries-v1 \
  /path/to/duckstation-runtime-directory \
  /path/to/PCSX2-hotr.AppImage \
  /path/to/Hook_of_the_Reaper-x86_64.AppImage
```

The helper creates/updates `binaries-v1` as a prerelease and uploads checksums.
Because it is a prerelease, it will not replace the normal `latest` HOTR installer
release used by `bootstrap.sh`.

## Create the normal installer release

Either push a normal tag:

```bash
git tag v1.0.0
git push origin v1.0.0
```

or open **Actions → Build HOTR Batocera release → Run workflow** and enter a
normal release tag such as `v1.0.0` and the binary tag `binaries-v1`.

The workflow downloads and verifies the binary prerelease, assembles the payload,
creates `HOTR-Batocera43-x86_64.zip`, and publishes that ZIP on the normal release.
