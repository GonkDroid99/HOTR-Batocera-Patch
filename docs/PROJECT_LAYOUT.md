# Project layout

This repository has three layers: release/install logic, Batocera runtime
payload, and the local Buildroot emulator toolchain.

## Active install path

| Path | Purpose |
| --- | --- |
| `bootstrap.sh` | Downloads/starts the installer on Batocera. |
| `install.sh` | Main installer: preflight (root, x86_64, required tools, free space), install and overlay persistence step. |
| `update.sh` / `uninstall.sh` | Update and removal operations. |
| `installer.conf` | Emulator source/release settings. |
| `payload/configgen/generators/` | Separate PCSX2/DuckStation configgen generators. |
| `payload/system/99-hotr.rules` | RS3/Reaper serial-driver workaround and stable serial aliases; normal gun input remains Batocera-owned. |
| `payload/emulators/pcsx2/resources/patches.zip` | PCSX2 game patch archive bundled with the emulator resources. |
| `scripts/hotr-service` | Background HOTR service. |
| `scripts/hotr-monitor` | Live service, HardwareManager, and event monitor. |
| `payload/system/hotr-sinden-broker.py` | HOTR TCP-to-Sinden serial broker: direct write-only serial backend by default, per-gun PTY worker only under `--pty-bridge`. It accepts HOTR's newline-terminated text commands (`>Recoil`, `>Open_COM`, `1N8`, …) on `:13000`; the player is the socket the command arrived on, not a text prefix. |
| `payload/hotr/data/sinden.hor` | Per-gun-type command vocabulary HOTR reads for a Sinden gun (`Open_COM=N8`, `Recoil=A`). With these lines empty HOTR never asks for recoil at all, so `install.sh` refreshes this file on every install. |
| `payload/hotr/defaultLG/<game>.txt` | HOTR game profiles; `[Signals]` entries such as `:GunRecoil_P1 / *P1 / #Recoil` map a game's recoil signal onto the gun's `Recoil` command from `sinden.hor`. `install.sh` adds missing profiles only (`copy_missing_tree`) so a tuned profile is never overwritten. |
| `payload/system/hotr-sinden-trigger-recoil` | Adds `Sinden_Trigger_Recoil <0-3>` to the game profiles that count ammo (idempotent, `--check`/`--dry-run`/`--value`, preserves every other line and its ending). Without it HOTR picks the ammo mode for a Sinden gun, registers `PN_Ammo` instead of `GunRecoil_PN`, and the gun never recoils. |
| `payload/system/hotr-sinden-worker-launch` | Legacy `--pty-bridge` per-gun worker/PTY launcher, shipped only for the explicit opt-in. |
| `scripts/hotr-sinden-check` | Read-only report of guns, USB ids, LightgunMono, broker counters; `--fire` sends one `A8` pulse. |
| `scripts/hotr-sinden-disable` | Kill switch: stops the broker and removes the enable file; `--revert` also removes the legacy helper patch. |
| `scripts/patch-batocera-sinden-hotr.sh` | Legacy PTY-bridge hook for Batocera's Sinden helper; `remove` restores the stock helper. |
| `scripts/hotr-configgen-launch` | Emulator launcher and temporary PCSX2 fullscreen workaround. |
| `scripts/patch-batocera-sinden.sh` | Optional Sinden patch: `apply` or `remove`; creates a backup. |
| `scripts/ports/HookOfTheReaper.sh` | Opens the HOTR configuration UI. |

## Testing

All repository tests live under `scripts/tests/`. `install.sh` copies the
hardware-free Sinden suites (`hotr-sinden-full-selftest.sh` plus the four it
drives, `fake-gun-firmware-faithful.py` and
`hotr-sinden-native-helper-selftest.py`) into `/userdata/system/hotr/tools/`, so
the same run is available on a Batocera install. `hotr-sinden-vm-e2e.sh` is a
machine-side acceptance run and is intentionally not part of the installer.

| Path | Purpose |
| --- | --- |
| `scripts/tests/test-sinden-pipeline.sh` | Sinden helper/static checks and loopback TCP test. |
| `scripts/tests/fake-gun-firmware-faithful.py` | Firmware-faithful Sinden fake gun; `--verify-firmware` re-derives the decoded image's command table. |
| `scripts/tests/hotr-sinden-fakegun-selftest.sh` | Firmware table, handshake, whitelist silence, direct backend, gunless warning, port/termios/queue discipline, syscall log (section A), tracker gate, USB ids, chokepoint refusal and reply-leak checks. |
| `scripts/tests/hotr-sinden-broker-selftest.sh` | Hardware-free TCP-to-serial-frame translation test. |
| `scripts/tests/hotr-sinden-worker-selftest.sh` | Hardware-free end-to-end TCP, worker, fake serial and Mono-PTY test. |
| `scripts/tests/hotr-sinden-integration-selftest.sh` | Installed-path test using a pseudo-terminal as an emulated Sinden gun. |
| `scripts/tests/hotr-sinden-full-selftest.sh` | Runs sections A and B together: the four hardware-free suites above, then the legacy PTY bridge integration when it runs as root on a Batocera install. |
| `scripts/tests/hotr-sinden-native-helper-selftest.py` | Native-helper simulation with fake udev discovery, serial device, Mono launch and HOTR recoil. |
| `scripts/tests/hotr-sinden-tools-selftest.sh` | `hotr-sinden-check`/`hotr-sinden-disable` behaviour, device overrides, `hotr-status` counters, the trigger-recoil game-file patcher, helper-patch revert, the `install.sh` preflight branches plus their install/check/uninstall/README wiring. |
| `scripts/tests/hotr-sinden-vm-e2e.sh` | Acceptance run on a real Batocera machine (or over SSH): fake gun, ES game launch, chain assertions, evidence bundle; `--self-test` for its parsers. |
| `check-install.sh` | Inspect an installed Batocera system. |
| `buildroot/check-runtime-abi.py` | Check emulator runtime dependencies. |

## Buildroot

`buildroot/` is a compiler/package environment, not a full Batocera image
build. Use `buildroot/build-emulators.sh` to produce the PCSX2 and DuckStation
archives consumed by the release payload.

Runtime configgen paths are discovered from `/usr/lib/python*/site-packages`
at install/check/uninstall time; the project does not require a fixed Python
minor version.

## OpenWiki documentation

`openwiki/` is a generated, evidence-linked wiki kept in the repository. It is
good for orientation, but the source tree and `scripts/tests/` remain
authoritative, and `README.md` plus this file are the maintained prose maps.

How it is maintained:

- `openwiki/INSTRUCTIONS.md` is the durable brief the OpenWiki generator
  preserves across runs (scope, relative link style, grounding rules).
- `.github/workflows/openwiki-update.yml` refreshes the wiki on a daily cron
  (`0 8 * * *`) or on demand and opens a pull request with the result.
- `.openwikiignore` keeps the generator out of private, generated and
  irrelevant trees: the Buildroot working checkout, local build config and
  logs, release output, local caches and acceptance-run evidence bundles.

Pages with claim files under `openwiki/.claims/` are generated - edit the brief
or the source, not the page. The `openwiki/reference-*.md` quick lookups,
`openwiki/faq.md` and `openwiki/setup-guide.md` are hand-written and have no
claim files.
