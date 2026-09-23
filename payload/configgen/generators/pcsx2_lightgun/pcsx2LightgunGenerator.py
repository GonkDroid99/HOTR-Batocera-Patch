from __future__ import annotations

from pathlib import Path
from typing import Final

from ...batoceraPaths import CONFIGS
from ...utils.configparser import CaseSensitiveConfigParser
from ..lightgun_rs3 import count_rs3_guns, wrap_with_gun_reset
from ..pcsx2.pcsx2Generator import Pcsx2Generator

_PCSX2_LIGHTGUN_BIN_DIR: Final = Path("/userdata/system/hotr/emulators/pcsx2")
_PCSX2_LIGHTGUN_CONFIG_DIR: Final = CONFIGS / "PCSX2-lightgun"
# PCSX2 looks for PCSX2-reg.ini at XDG_CONFIG_HOME/PCSX2/PCSX2-reg.ini.
# Using a separate XDG home keeps our reg.ini from clashing with mainline pcsx2.
_PCSX2_LIGHTGUN_XDG_HOME: Final = CONFIGS / "pcsx2-lightgun-xdg"


class Pcsx2LightgunGenerator(Pcsx2Generator):
    """
    PCSX2 LightGun Edition — inherits all config logic from the upstream
    generator but substitutes the lightgun-specific binary, isolates config
    files from mainline PCSX2, enables MameHooker output, and sets
    guncon2_numdevice so PCSX2 tracks the correct physical mouse for each
    USB port.
    """

    def generate(self, system, rom, playersControllers, metadata, guns, wheels, gameResolution):
        cmd = super().generate(system, rom, playersControllers, metadata, guns, wheels, gameResolution)

        # Swap binary path to the lightgun edition binary
        if cmd.array:
            cmd.array[0] = "/userdata/system/hotr/emulators/pcsx2/PCSX2-hotr.AppImage"

        # Redirect PCSX2 to our own XDG home so it reads a separate reg.ini
        # and never touches CONFIGS/PCSX2/ at runtime — keeps mainline pcsx2
        # config isolated from the lightgun edition config
        cmd.env["XDG_CONFIG_HOME"] = _PCSX2_LIGHTGUN_XDG_HOME

        # Write our own reg.ini — PCSX2 finds it at XDG_CONFIG_HOME/PCSX2/PCSX2-reg.ini.
        # SettingsFolder tells PCSX2 where to load PCSX2.ini from.
        reg_dir = _PCSX2_LIGHTGUN_XDG_HOME / "PCSX2"
        reg_dir.mkdir(parents=True, exist_ok=True)
        with (reg_dir / "PCSX2-reg.ini").open("w") as f:
            f.write("DocumentsFolderMode=User\n")
            f.write(f"CustomDocumentsFolder={_PCSX2_LIGHTGUN_BIN_DIR}\n")
            f.write("UseDefaultSettingsFolder=enabled\n")
            f.write(f"SettingsFolder={_PCSX2_LIGHTGUN_CONFIG_DIR / 'inis'}\n")
            f.write(f"Install_Dir={_PCSX2_LIGHTGUN_BIN_DIR}\n")
            f.write("RunWizard=0\n")

        # Read PCSX2.ini that the parent generator wrote, fix any resource paths
        # that still point to the mainline binary directory, then write it to
        # our own config directory so the two versions stay independent
        parent_config = CONFIGS / "PCSX2" / "inis" / "PCSX2.ini"
        config_path = _PCSX2_LIGHTGUN_CONFIG_DIR / "inis" / "PCSX2.ini"
        config_path.parent.mkdir(parents=True, exist_ok=True)
        if parent_config.exists():
            content = parent_config.read_text()
            content = content.replace("/usr/pcsx2/bin", str(_PCSX2_LIGHTGUN_BIN_DIR))
            config_path.write_text(content)

        pcsx2_config = CaseSensitiveConfigParser(interpolation=None)
        if config_path.exists():
            pcsx2_config.read(config_path)

        # Remove any stale SDL bindings written by older versions of this generator.
        # These are no longer used — gun input now goes through SDL relative axes.
        _SDL_KEYS = [
            "guncon2_Trigger", "guncon2_A", "guncon2_B",
            "guncon2_Recalibrate",
            "guncon2_Up", "guncon2_Down", "guncon2_Left", "guncon2_Right",
            "guncon2_RelativeUp", "guncon2_RelativeDown",
            "guncon2_RelativeLeft", "guncon2_RelativeRight",
        ]
        for section in ("USB1", "USB2"):
            for key in _SDL_KEYS:
                if pcsx2_config.has_option(section, key):
                    pcsx2_config.remove_option(section, key)

        # EnableMameHooker — default on, user can toggle via ES LIGHT GUN menu.
        # When enabled PCSX2 launches MameOutputSender which bridges game state
        # signals to Hook of the Reaper over TCP for recoil/effects.
        if not pcsx2_config.has_section("EmuCore"):
            pcsx2_config.add_section("EmuCore")
        pcsx2_config.set("EmuCore", "EnableMameHooker",
                         system.config.get("pcsx2_mamehooker", "true"))

        # Use the evdev-detected gun list (works for all gun types).
        # Fall back to RS3 udev symlink count when guns haven't been detected
        # yet as evdev devices (e.g. still in joystick mode before HOTR init).
        if guns:
            gun_count = len(guns)
            mouse_indices = [gun.mouse_index for gun in guns]
        else:
            gun_count = count_rs3_guns()
            mouse_indices = []

        gun1onport2 = (
            gun_count == 1
            and "gun_gun1port" in metadata
            and metadata["gun_gun1port"] == "2"
        )

        port_map = []
        if not gun1onport2:
            port_map.append(("USB1", 0))
        if gun_count >= 2 or gun1onport2:
            port_map.append(("USB2", 0 if gun1onport2 else 1))

        for usb_section, gun_idx in port_map:
            if not pcsx2_config.has_section(usb_section):
                pcsx2_config.add_section(usb_section)
            pcsx2_config.set(usb_section, "Type", "guncon2")
            if gun_idx < len(mouse_indices):
                pcsx2_config.set(usb_section, "guncon2_numdevice",
                                 str(mouse_indices[gun_idx]))

        # Disable the unused port so PCSX2 doesn't wait for a missing gun
        unused = "USB2" if not gun1onport2 and gun_count < 2 else None
        if unused:
            if not pcsx2_config.has_section(unused):
                pcsx2_config.add_section(unused)
            pcsx2_config.set(unused, "Type", "None")

        with open(config_path, "w") as f:
            pcsx2_config.write(f)

        wrap_with_gun_reset(cmd, gun_count)

        return cmd
