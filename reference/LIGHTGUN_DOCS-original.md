# Light Gun System — Scripts, Configs & Code Reference

This document covers every custom script, config file, and generator added to this Batocera fork for light gun support. Organised by component.

---

## Overview: How it all fits together

```
RS3 Gun (USB serial)
    │
    ├─ udev: 99-hotr.rules          → /dev/hotr/rs3reaper-gun1 symlink
    │                                  modprobe option; serial port access
    └─ udev: 99-retroshooter-joystick-override.rules
                                    → re-enables ID_INPUT_JOYSTICK=1 for SDL

S35hookofthereaper (boot init)
    └─ hotr-autoconfig.py           → writes lightguns.hor + playersAss.hor
    └─ hook-of-the-reaper --no-ui   → engine starts, window hidden

EmulationStation → Ports → Hook of the Reaper
    └─ HookOfTheReaper.sh           → raises existing HOTR window, waits for minimize

EmulationStation → PS1 game → duckstation-lightgun
    └─ DuckstationLightgunGenerator.py
           └─ writes settings.ini (MameHooker=true, SDL GunCon bindings)
           └─ launches duckstation-lightgun-qt
           └─ MameOutputSender (Python)
                   ├─ DuckStation connects via Unix pipes
                   │     /tmp/CoreFxPipe_MameHookerProxyControl
                   │     /tmp/CoreFxPipe_MameHookerProxyRecoilGun[ABCD]
                   └─ forwards "key = value\r\n" to Hook of the Reaper via TCP 8000

EmulationStation → PS2 game → pcsx2-lightgun
    └─ Pcsx2LightgunGenerator.py
           └─ writes PCSX2-lightgun/inis/PCSX2.ini (isolated from mainline pcsx2)
           └─ writes pcsx2-lightgun-xdg/PCSX2/PCSX2-reg.ini (separate XDG home)
           └─ launches pcsx2-lightgun-qt
           └─ same MameOutputSender as above
```

---

## 1. Hook of the Reaper Package

**Directory:** `package/batocera/controllers/guns/hook-of-the-reaper/`

### `hook-of-the-reaper.mk` — Buildroot package definition

Builds the HOTR Qt6 binary from local source (`/home/matt/hook-of-the-reaper-src`).

| What it installs | Where |
|---|---|
| `hook-of-the-reaper` binary | `/usr/bin/hook-of-the-reaper` |
| `data/` directory (gun profiles) | `/usr/bin/data/` |
| `defaultLG/` directory (per-game signal configs) | `/usr/bin/defaultLG/` |
| `99-hotr.rules` | `/etc/udev/rules.d/` |
| `99-retroshooter-joystick-override.rules` | `/etc/udev/rules.d/` |
| `hotr-autoconfig` | `/usr/bin/hotr-autoconfig` |
| `S35hookofthereaper` | `/etc/init.d/S35hookofthereaper` |
| `HookOfTheReaper.sh` | `/usr/share/batocera/datainit/roms/ports/HookOfTheReaper.sh` |

**Dependencies:** `qt6base qt6serialport qt6multimedia hidapi`

---

### `99-hotr.rules` — USB device access rules

Grants `MODE=0666` to all supported light gun USB devices so HOTR can open them without root.

**Supported guns:**

| Gun | VID | PID | Notes |
|---|---|---|---|
| Alien USB Light Gun | `04b4` | `6870` | USB + hidraw |
| AimTrak Light Gun | `d209` | `1601` | USB + hidraw |
| Custom USB Light Gun | `1b4f` | `9206` | USB + hidraw |
| ALED Strip Controller | `cafe` | `6920` | USB + hidraw |
| 3A-3H Retro Shooter 1 (RS1) | `0483` | `5750` | USB + hidraw + tty + input + loads `option` kernel module |
| 3A-3H Retro Shooter 2 (RS2) | `0483` | `5751` | USB + hidraw + tty + input + loads `option` kernel module |

**RS3-specific extras:**

- Loads the `option` GSM serial driver on plug-in (RS1/RS2 use non-compliant CDC ACM descriptors that the standard `cdc_acm` driver won't bind).
- Creates stable TTY symlinks `/dev/hotr/rs3reaper-gun1` … `rs3reaper-gun4` keyed on the gun serial number embedded in `ID_SERIAL`, matching interface 02 (the data interface).

---

### `99-retroshooter-joystick-override.rules` — SDL joystick re-enable

```
SUBSYSTEM=="input", KERNEL=="event*", ACTION=="add",
ATTRS{name}=="3AGAME 3A-3H Retro Shooter [1-4]",
ENV{ID_INPUT_JOYSTICK}="1"
```

!!!!!!!!!
Maybe change this, we might not need SDL / Releative input if we patch mouse input. Needs investigating
!!!!!!!!!

**Why this exists:** Batocera's `retroshooter-guns` udev rules set `ID_INPUT_JOYSTICK=0` on all RS3 event nodes so SDL doesn't see duplicate axes (the separate mouse and joystick interfaces from the same gun). When HOTR switches a gun to gamepad/SDL mode (needed for 2-player DuckStation), the joystick interface needs to be visible to SDL. This file sorts alphabetically after `99-retroshooter-guns.rules` (`j > g`) so it wins.

---

### `S35hookofthereaper` — Boot init script

Runs at runlevel S35 (after EmulationStation at S31). Sequence:

1. Sets `HOME` and `XDG_CONFIG_HOME` for HOTR.
2. **First boot:** copies `data/` and `defaultLG/` from squashfs (`/usr/bin/`) to `/userdata/system/hook-of-the-reaper/` so user settings persist across OS updates.
3. Bind-mounts the userdata copies back over `/usr/bin/data` and `/usr/bin/defaultLG` so HOTR's relative-path lookups work.

Maybe change auto configs? what about other guns

4. Runs `hotr-autoconfig` to detect guns and write `lightguns.hor` / `playersAss.hor`.
5. Starts `hook-of-the-reaper --no-ui` in the background; saves PID to `/var/run/hook-of-the-reaper.pid`.

**Supports:** `start | stop | restart | status`

**Log:** `/var/log/hook-of-the-reaper.log`

---



This probably needs changing as we have a no UI. I also don't know if we want user to config or auto config 
### `HookOfTheReaper.sh` — EmulationStation Ports launcher

Placed in `/userdata/roms/ports/` via Buildroot datainit. Opens the HOTR configuration GUI from ES → Ports

**Logic:**

- If HOTR is **already running**: finds the window with `xdotool search --name "Hook"`, raises it to front, then polls every second. Returns to ES when the window is minimized (`WM_STATE=Iconic`) or closed. The engine keeps running in the background after return.
- If HOTR is **not running**: starts it fresh and waits for the process to exit.

---


This defo needs looking at. Maybe change how this works for all gun detections or get user to manually config
### `hotr-autoconfig.py` — Gun auto-detection script

Detects connected light guns at boot and writes the HOTR config files HOTR needs to communicate with them.

**Writes:**
- `/userdata/system/hook-of-the-reaper/data/lightguns.hor` — gun hardware definitions
- `/userdata/system/hook-of-the-reaper/data/playersAss.hor` — player slot assignments

**Detection order:**
1. **Primary:** `/dev/hotr/<type>-gun<N>` symlinks created by udev rules.
2. **Fallback:** `/dev/serial/by-id/` scan using regex patterns when udev symlinks aren't deployed yet.

**Currently supports:** RS3 Reaper (`rs3reaper`) — gun type number `1`, 115200 baud, 8N1.

**To add a new gun type:** add an entry to `GUN_DEFINITIONS` in this file, and a `SYMLINK+=` rule in `99-hotr.rules`.

---

## 2. MameOutputSender — Signal bridge (Python) Works fine no need to change

**File:** `package/batocera/emulators/duckstation-lightgun/MameOutputSender` (same copy in `package/batocera/emulators/pcsx2-lightgun/MameOutputSender`)

Replaces the original .NET `MameOutputSender.exe` which cannot run on Batocera Linux.

**What it does:** Acts as a socket relay between the emulator (DuckStation or PCSX2 lightgun fork) and Hook of the Reaper.

**Connections it manages:**

| Socket | Direction | Purpose |
|---|---|---|
| `/tmp/CoreFxPipe_MameHookerProxyControl` | Unix stream server | Emulator connects here to send game state signals (`mame_start`, `mame_stop`, arbitrary `key:val` pairs) |
| `/tmp/CoreFxPipe_MameHookerProxyRecoilGun[ABCD]` | Unix stream servers (×4) | Each gun's recoil trigger line — any data received fires `GunRecoil_P1` etc. to HOTR |
| `127.0.0.1:8000` | TCP server | Hook of the Reaper connects here as a client |

**Protocol to HOTR:** MAME network output format — `"key = value\r\n"` text messages.

**Gun signals forwarded:** `GunRecoil_P1`, `GunRecoil_P2`, `TriggerPress_P1`, `TriggerPress_P2`

**Lifecycle:** Runs for up to 3 hours (covers the longest gaming session), then exits cleanly. Launched by the emulator via `EnableMameHooker=true` in config.

---

## 3. DuckStation LightGun Generator



Do we need to set it's own config like pcsx2?



**File:** `package/batocera/core/batocera-configgen/configgen/configgen/generators/duckstation_lightgun/duckstationLightgunGenerator.py`

**Class:** `DuckstationLightgunGenerator` extends `DuckstationGenerator`

Inherits the full DuckStation config logic from the upstream generator. Only overrides `generate()`.

**What it changes vs mainline DuckStation:**

| Setting | Value | Why |
|---|---|---|
| Binary | `duckstation-lightgun-qt` / `duckstation-lightgun-nogui` | Lightgun fork has MameHooker hooks in source |
| `-fullscreen` flag | Added when Qt frontend used | Prevents Openbox from dragging the window |
| `Main/EnableMameHooker` | `true` (default, user-toggleable via ES menu) | Starts MameOutputSender for recoil/effects |


Maybe change below need to look at mouse support instead of sdl

| `InputSources/SDLControllerEnhancedMode` | `true` | Reads evdev directly, bypassing udev's `ID_INPUT_JOYSTICK=0` suppression on RS3 devices |
| `Pad{N}` GunCon SDL bindings | Button0/1/2/5 + Axis0/1 relative | SDL-based aiming; HOTR's DefaultLG files switch guns to gamepad mode at game start |
| Extra pads beyond gun count | `Type=None` | Stops DuckStation waiting for a missing second controller |


Agin needs changing
**Gun count detection:**
- If `guns` list is populated (evdev detected): uses that.
- Fallback: counts `/dev/hotr/rs3reaper-gun*` symlinks via `count_rs3_guns()`.


Useful for reapers but not needed if I get mouse mode working
**Post-launch:** Calls `wrap_with_gun_reset(cmd, gun_count)` — wraps the command so RS3 guns receive the `ZM` serial command (returning to mouse mode) after the emulator exits.

---

## 4. PCSX2 LightGun Generator

**File:** `package/batocera/core/batocera-configgen/configgen/configgen/generators/pcsx2_lightgun/pcsx2LightgunGenerator.py`

**Class:** `Pcsx2LightgunGenerator` extends `Pcsx2Generator`

Inherits the full PCSX2 config logic from the upstream Batocera generator. Config files are fully isolated from mainline PCSX2.

### Config isolation design

Mainline PCSX2 and the lightgun edition previously shared `CONFIGS/PCSX2/` — last writer wins. The fix uses a separate XDG home:

| Path | Used by | Purpose |
|---|---|---|
| `CONFIGS/PCSX2/` | Mainline pcsx2 | Upstream config; untouched by lightgun generator |
| `CONFIGS/PCSX2-lightgun/inis/PCSX2.ini` | pcsx2-lightgun | Lightgun edition's own config file |
| `CONFIGS/pcsx2-lightgun-xdg/PCSX2/PCSX2-reg.ini` | pcsx2-lightgun | Separate XDG home; `SettingsFolder` points to `PCSX2-lightgun/inis` |

**How PCSX2 finds its config:** PCSX2 appends `/PCSX2/` to `XDG_CONFIG_HOME` to find `PCSX2-reg.ini`. The reg.ini contains `SettingsFolder` which tells PCSX2 where to load `PCSX2.ini` from. Setting `XDG_CONFIG_HOME` to our own directory means PCSX2 never touches the mainline reg.ini.

### What the generator does

1. **Swaps the binary** — replaces `/usr/pcsx2/bin/pcsx2-qt` → `/usr/pcsx2-lightgun/bin/pcsx2-lightgun-qt` in `cmd.array`. ??????????

2. **Sets XDG home** — `cmd.env["XDG_CONFIG_HOME"] = CONFIGS / "pcsx2-lightgun-xdg"`.

3. **Writes reg.ini** — creates `pcsx2-lightgun-xdg/PCSX2/PCSX2-reg.ini` pointing `SettingsFolder` at `CONFIGS/PCSX2-lightgun/inis`.

4. **Copies and fixes PCSX2.ini** — reads the parent generator's output at `CONFIGS/PCSX2/inis/PCSX2.ini`, replaces `/usr/pcsx2/bin` with `/usr/pcsx2-lightgun/bin` in resource paths, writes to `CONFIGS/PCSX2-lightgun/inis/PCSX2.ini`.

5. **Removes stale SDL bindings** — strips old `guncon2_*` SDL keys from USB1/USB2 sections (written by older generator versions; no longer used).  Maybe change this

6. **EnableMameHooker** — sets `EmuCore/EnableMameHooker` (default `true`, user-toggleable via ES LIGHT GUN menu). Works



This is good but may neeed changing.  NEed to work out more mouse stuff
7. **Sets guncon2 device assignments** — writes `USB1/Type=guncon2`, `USB2/Type=guncon2` and `guncon2_numdevice=<mouse_index>` so PCSX2 tracks the correct physical mouse for each USB port. Uses `gun.mouse_index` from evdev detection, or `count_rs3_guns()` as fallback.

8. **Handles gun1 on port 2** — if metadata `gun_gun1port=2`, maps the single gun to USB2 instead of USB1. not sure aabout this

9. **Disables unused port** — sets `Type=None` on the unused USB section so PCSX2 doesn't wait for a missing gun. USEFUL

10. **Wraps with gun reset** — same `wrap_with_gun_reset()` as DuckStation.

---

## 5. RS3 Shared Utilities  hmmmmmmm maybe change or tidy

**File:** `package/batocera/core/batocera-configgen/configgen/configgen/generators/lightgun_rs3.py`

Used by both `DuckstationLightgunGenerator` and `Pcsx2LightgunGenerator`.

### `count_rs3_guns() -> int`

Counts connected RS3 guns by checking `/dev/hotr/rs3reaper-gun1` … `rs3reaper-gun8` symlinks. Returns at least `1` (assumes at least one gun when anything is detected).

### `wrap_with_gun_reset(cmd, gun_count)`

Wraps `cmd.array` in a shell one-liner that runs the emulator, then sends `ZM` (reset-to-mouse-mode command) to each connected RS3 gun's serial TTY after exit:

```sh
sh -c '<emulator command>; printf ZM > /dev/hotr/rs3reaper-gun1 2>/dev/null; ...'
```

This returns the guns from SDL/gamepad mode back to mouse mode so the Batocera UI can use them after exiting a game.

---

## 6. DuckStation LightGun Package

**Directory:** `package/batocera/emulators/duckstation-lightgun/`

**Build file:** `duckstation-lightgun.mk`

Builds from local source (`/home/matt/duckstation-lightgun-src` — symlink to the fork with MameHooker source additions).

**Installs to:**

| File | Target path |
|---|---|
| `duckstation-lightgun-qt` | `/usr/bin/duckstation-lightgun-qt` |
| `duckstation-lightgun-nogui` | `/usr/bin/duckstation-lightgun-nogui` |
| Resources | `/usr/share/duckstation-lightgun/resources/` |
| Translations | `/usr/share/duckstation-lightgun/translations/` |
| `MameOutputSender` | `/usr/bin/MameOutputSender` |

**Build flags:** Uses `clang` (same as upstream DuckStation); `-DBATOCERA=ON` enables Batocera path overrides; links with `-no-pie -lm -lstdc++`.

hmmm do we need to update duckstation then
**Patches applied** (`001`–`015`): Path redirections, no-Discord, SDL binding fix, various compiler fixes. The lightgun-specific MameHooker additions (`MameHookerProxy.h`, `_lnx.cpp`, `_win.cpp`) live in the fork source, not as patches.

---

## 7. PCSX2 LightGun Package

**Directory:** `package/batocera/emulators/pcsx2-lightgun/`

**Build file:** `pcsx2-lightgun.mk`

Builds from local source (`/home/matt/pcsx2-lightgun-src` — symlink to the PCSX2 lightgun fork).

**Installs to:**

| File | Target path |
|---|---|
| `pcsx2-lightgun-qt` | `/usr/pcsx2-lightgun/bin/pcsx2-lightgun-qt` |
| Resources | `/usr/pcsx2-lightgun/bin/resources/` |
| Translations | `/usr/pcsx2-lightgun/bin/translations/` |
| `MameOutputSender` | `/usr/pcsx2-lightgun/bin/MameOutputSender` + `/usr/bin/MameOutputSender` |
| PCSX2 texture packs | `/usr/pcsx2-lightgun/bin/resources/textures/` |
| PS2 game patches zip | `/usr/share/batocera/datainit/bios/ps2/patches.zip` |
| Crosshair images | `/usr/pcsx2-lightgun/bin/resources/crosshairs/` |

**Build flags:** Uses `clang`; `-DDISABLE_ADVANCE_SIMD=ON` prevents `-march=native` (required for cross-compile); X11/Wayland/OpenGL/Vulkan enabled conditionally based on board config.

**Note:** The SDL `game_controller_db.txt` is removed after install so PCSX2 uses the Batocera-managed SDL controller database instead.

---

## 8. importer.py — Generator registration

**File:** `package/batocera/core/batocera-configgen/configgen/configgen/generators/importer.py`

Two entries added to `_LEGACY_GENERATOR_MAP`:

```python
_LEGACY_GENERATOR_MAP['duckstation']['duckstation-lightgun'] = \
    'generators.duckstation_lightgun.duckstationLightgunGenerator.DuckstationLightgunGenerator'

_LEGACY_GENERATOR_MAP['pcsx2']['pcsx2-lightgun'] = \
    'generators.pcsx2_lightgun.pcsx2LightgunGenerator.Pcsx2LightgunGenerator'
```

These map the EmulationStation emulator/core selection (`duckstation → duckstation-lightgun`, `pcsx2 → pcsx2-lightgun`) to the correct Python generator class.

---

## Data paths reference

| Data | Path |
|---|---|
| HOTR user data (persistent) | `/userdata/system/hook-of-the-reaper/data/` |
| HOTR DefaultLG configs | `/userdata/system/hook-of-the-reaper/defaultLG/` |
| HOTR squashfs defaults | `/usr/bin/data/` + `/usr/bin/defaultLG/` |
| HOTR logs | `/var/log/hook-of-the-reaper.log` |
| MameOutputSender log | `/tmp/MameOutputSender.log` |
| DuckStation lightgun config | `/userdata/system/configs/duckstation/settings.ini` |
| PCSX2 lightgun config | `/userdata/system/configs/PCSX2-lightgun/inis/PCSX2.ini` |
| PCSX2 lightgun XDG home | `/userdata/system/configs/pcsx2-lightgun-xdg/` |
| Mainline PCSX2 config | `/userdata/system/configs/PCSX2/` *(untouched by lightgun)* |
| RS3 serial TTYs | `/dev/hotr/rs3reaper-gun1` … `gun4` |
| HOTR PID file | `/var/run/hook-of-the-reaper.pid` |
