# HOTR Batocera 43 Patch

Drop-in light-gun add-on for **Batocera 43/43.1 x86_64**. It keeps the stock PlayStation and PlayStation 2 systems intact and adds separate **PlayStation HOTR** and **PlayStation 2 HOTR** systems using the normal `/userdata/roms/psx` and `/userdata/roms/ps2` folders.

Features

Automatic install, uninstall and update commands
HOTR, scripts and services specifically for Batocera
Custom versions of PCSX2 and Duckstation for use with HOTR.
Custom Emulation Station Entries and settings for my emulators.
Custom Python scripts to add configgens and configurations for easy setup.


## Install

New to this? The [setup guide](openwiki/setup-guide.md) walks through the whole
thing from a fresh Batocera machine, including the gun-assignment step and
turning on Sinden recoil.

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

Quick lookups live in [`openwiki/`](openwiki): start with the
[setup guide](openwiki/setup-guide.md), the [FAQ](openwiki/faq.md), the
[command reference](openwiki/reference-commands.md), the
[paths and ports cheat sheet](openwiki/reference-cheatsheet.md) or the
[symptom-to-fix table](openwiki/reference-troubleshooting.md).
[`openwiki/INSTRUCTIONS.md`](openwiki/INSTRUCTIONS.md) is the brief the
scheduled wiki refresh follows.


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
```


## Notes

- The package does not replace Batocera's stock DuckStation, PCSX2, MAME, gun calibration scripts, or `retroshooter-guns-add`.
- The small configgen/udev/desktop changes under Batocera's root filesystem are persisted with `batocera-save-overlay`.

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

For live HardwareManager and service tracking while testing guns, use:

```sh
/userdata/system/hotr/tools/hotr-monitor
```

It reports service transitions, registry changes, and new HOTR device/game
events. Stop it with Ctrl+C.

## Sinden recoil

HOTR talks to Sinden light guns in parallel with Batocera's own Sinden support:
`LightgunMono.exe` keeps the gun's tty for cameras and aiming, and a small
broker writes recoil frames to the same tty **write-only**. HOTR never reads the
gun, never changes the port's termios settings, and only sends the five
firmware-verified commands that make the gun stay silent (`A1` with value 1,
`A2`, `A3`, `A4`, `A8`). Commands that make the gun answer on the same link
(`A0`, `A7`, `AB`, `AC` and the diagnostics) are refused by a single choke point,
because those replies are what desynchronise LightgunMono and stop the gun
aiming.

The broker serves HOTR's own text protocol on TCP `:13000`: HOTR is the client,
it sends newline-terminated commands (`>Recoil`, `>Open_COM`, `1N8`, …) and the
socket a command arrives on identifies the player. Whether HOTR asks for recoil
at all is decided by two refreshed files: `data/sinden.hor` (the per-gun-type
vocabulary, shipped as `Open_COM=N8` and `Recoil=A`) and the game profiles in
`defaultLG/` (`:GunRecoil_P1 / *P1 / #Recoil`). With an empty `sinden.hor` a
Sinden gun never recoils, however well the broker works, so `install.sh`
refreshes `data/sinden.hor` on every upgrade and adds any missing game profile
to `defaultLG/` (existing profiles are never overwritten).

A third decision is not in those files: HOTR picks **one** recoil mode per gun by matching the
modes a game profile supports against the gun's own recoil priority list (the four numbers in
`lightguns.hor`). If the gun's list prefers ammo, HOTR registers the game's `PN_Ammo` signal instead
of `GunRecoil_PN` and a Sinden then recoils only through firmware trigger recoil, which needs the
per-game option `Sinden_Trigger_Recoil <0-3>` in the profile. `install.sh` therefore runs
`hotr-sinden-trigger-recoil` after copying the game files: it adds the option to every game profile
that counts ammo, leaving profiles without ammo mode and every other line untouched. The step is
idempotent, so an upgrade never rewrites a profile twice, and it composes with the add-only game
file install (a profile you already have is never overwritten - only missing files are added).
It runs at the **end** of the install, after the MSOP step: `scripts/install-mame-msop.sh` ships
its own copies of 18 MAME game files (Area 51, Time Crisis, Virtua Cop, House of the Dead, …) and
would otherwise overwrite the option again. `install.sh` therefore verifies the result with
`--check` afterwards and retries once if any profile still lacks it, and the MSOP step re-patches
its own copies too, so the install log always ends with the option confirmed present.
If a Sinden stays silent in an ammo-counting game such as Time Crisis while `hotr-sinden-check`
looks healthy, make `Recoil` the gun's first recoil priority**and** drop the option again, or run
`hotr-sinden-trigger-recoil --check` to see which profiles still lack it. Which signals HOTR
registered is logged as `Output signal filter:` in
`/userdata/system/logs/hook-of-the-reaper.log`, and the acceptance run asserts it.

Check the setup at any time (read-only, safe to run while playing):

```sh
hotr-sinden-check              # report: broker, guns, USB ids, LightgunMono, counters
hotr-sinden-check --fire       # the same report, plus one recoil pulse (A8) for player 1
hotr-sinden-check --fire --player 2 --json
```

The game files that decide whether HOTR asks for recoil at all are maintained by
`hotr-sinden-trigger-recoil`:

```sh
hotr-sinden-trigger-recoil --check     # list ammo-mode profiles without Sinden_Trigger_Recoil (exit 1)
hotr-sinden-trigger-recoil --dry-run   # show what would change, change nothing
hotr-sinden-trigger-recoil             # add "Sinden_Trigger_Recoil 2" where it is missing (idempotent)
hotr-sinden-trigger-recoil --value 1   # a different kick style: 0 single, 1 auto normal, 2 auto fast, 3 auto strong
```

It writes only into game files that count ammo (`Ammo_Value 1`), inserts the option before
`[States]` (the option is ignored by HOTR if it comes later), keeps every line ending as it found
it, and prints a one-line summary (`profiles= ammo= updated= already= value= mode= …`) as its last
line. `--dir` points it at another game-file directory. `check-install.sh` runs it with `--check`, so
a machine whose profiles still lack the option is reported as incomplete.

Turn recoil off again (aiming is unaffected either way):

```sh
hotr-sinden-disable            # stop the broker now and keep it off after a reboot
hotr-sinden-disable --revert   # also remove the retired PTY bridge hook if present
```

Re-enable it by creating `/userdata/system/hotr/sinden-tcp.enabled` and starting
the service, or by reinstalling with `HOTR_SINDEN_TCP=1`. The counters behind the
report are also in `/userdata/system/hotr/sinden-broker-state.json` and in the
`HOTR Debug Finish` report.

Guns that do not show up as `/dev/ttyACM*` (or a virtual gun used for testing)
can be assigned by hand: put one `PLAYER=/dev/path` line per gun into
`/userdata/system/hotr/sinden-devices.conf` and restart the service. Those
devices are used instead of the USB-id scan, and `hotr-sinden-check` reports
them. Delete the file to go back to automatic detection.

### Multiple guns

This setup covers **one or two** Sinden guns, because HOTR itself stops at two: its TCP client
layer has two write slots and two ports only (`Global.h:447 #define MAXTCPSERVERS 2`), and a game
light-gun file that declares a third distinct port is rejected at load time with
"Three or more TCP Server ports cannot be used." (`HookerEngine/HookerEngine.cpp:5276-5283`).
A Sinden gun in HOTR is always a TCP client (`COMDeviceList/LightGun.cpp:1214 outputConnection = TCP;`),
so there is no serial fallback that would lift the limit.

What that means in practice:

* Batocera's own layer is not the limit - it already starts one `LightgunMono.exe` per gun, each
  with its own config and its own tty.
* The broker matches HOTR: it serves players 1 and 2, and `sinden-devices.conf` assigns one device
  per player. The recoil fix itself is gun-count agnostic (game profiles and `sinden.hor` do not
  mention a player count), so nothing about aiming or recoil breaks with more guns attached - HOTR
  simply has nowhere to send recoil for a third one.
* Making three or more guns recoil needs an upstream HOTR change (more TCP server slots), not a
  change here. A **fan-out** variant - two physical guns serving the same game player - could be
  done entirely in the broker (one device list per player instead of one device), but it is not
  implemented.

### Acceptance run on a Batocera machine

`scripts/tests/hotr-sinden-vm-e2e.sh` walks the real stack through normal use
and writes an evidence bundle. On the machine itself (as root):

```sh
scripts/tests/hotr-sinden-vm-e2e.sh --dry-run     # show every step, change nothing
scripts/tests/hotr-sinden-vm-e2e.sh               # attach the lab fake gun, then follow the prompts
```

From a desktop with SSH access to the machine:

```sh
scripts/tests/hotr-sinden-vm-e2e.sh --ssh root@batocera.local
```

It launches the game from EmulationStation (you drive the menus), asserts that
only whitelisted frames reach the gun, that LightgunMono survives the session
and that the broker is never restarted behind the game's back, then collects
`hotr-sinden-check`, the debug report, the broker log, the state file and the
frame log into `hotr-sinden-vm-<date>.tar.gz`. Bundles are ignored by Git
(`hotr-sinden-vm-*/` in `.gitignore`); the accepted runs are kept next to the
repository instead of inside it. Everything it changes - including
the fake gun's device override - is restored when it exits.

`--fake-gun-required` makes the lab fake gun mandatory: with the flag a missing
fake gun, or a real serial gun standing in for it, is a `FAIL` instead of a
`SKIP`, so a CI or lab run cannot quietly pass without exercising the gun path.

For an unattended run it can fire the game's recoil signal itself
(`--fire '<command>'`, else by connecting to MameOutputSender's control socket at
`/tmp/CoreFxPipe_MameHookerProxyControl` and writing `GunRecoil_P1: 1`, which is what the emulator
does when a player shoots). It refuses to run when `data/sinden.hor` has no `Recoil=` command,
because then no frame could ever be sent, and it writes a recoil-mode lab profile for
`HOTR_SINDEN_VM_GAME_ID` (the id HOTR logs as `GameStart game=`) so the test asserts the recoil
path rather than whatever mode the machine's gun priority happens to select; the machine's own
profile, device override and lab files are all restored on exit. Where no Sinden USB device exists
(a VM) the "LightgunMono stays alive" assertion is reported as `SKIP` and the real-gun run has to
cover it.

The ammo path gets its own launch: with an ammo-mode lab profile (`Ammo_Value 1` plus
`Sinden_Trigger_Recoil`) HOTR must register the game's `P1_Ammo` signal instead of `GunRecoil_P1`,
and an ammo reload (`P1_Ammo: 7` on the same control socket) must put a quiet `A4` frame on the
wire - the gun's firmware trigger recoil. On a machine whose gun priority list puts recoil first
that mode is never selected, so the step reports `SKIP` with the filter it saw instead of
inventing a result; a launch that never reaches HOTR is a `FAIL`, because the step only trusts a
signal-filter line written after its own launch. Accepted on the Batocera 44-dev VM: HOTR registered
`P1_Ammo`, and the reload produced exactly one `A4` frame (`aa a4 01 00 00 00 bb`, broker reason `K1`).

### Tests

The hardware-free suites cover the mechanical guarantees and the lab behaviour,
and need no gun, no root and no Batocera install:

```sh
bash scripts/tests/hotr-sinden-full-selftest.sh   # sections A and B together
```

That runner drives `hotr-sinden-fakegun-selftest.sh` (firmware command table,
handshake, whitelist silence, direct backend, port/termios/queue discipline,
syscall log when `strace` is installed, tracker gate, USB ids, chokepoint
refusals), `hotr-sinden-tools-selftest.sh` (`hotr-sinden-check`,
`hotr-sinden-disable`, `hotr-status`, the trigger-recoil game-file patcher,
helper-patch revert, the install wiring and the acceptance runner's
option-parity check), `hotr-sinden-broker-selftest.sh` and
`hotr-sinden-worker-selftest.sh`.
On a root Batocera install it also runs the legacy PTY bridge integration; when
the worker launcher is absent that part is reported as skipped. The helper-patch
revert and the install-wiring checks need the repository sources, so they report
`[SKIP]` on an installed system, where the same suites live in
`/userdata/system/hotr/tools/`:

```sh
bash /userdata/system/hotr/tools/hotr-sinden-full-selftest.sh
```

The acceptance run on a real machine is `scripts/tests/hotr-sinden-vm-e2e.sh`
(see above); `--self-test` exercises its parsers without touching the system.
