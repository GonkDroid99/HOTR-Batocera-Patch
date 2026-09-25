from __future__ import annotations

from pathlib import Path
from typing import Final

from ...batoceraPaths import CONFIGS
from ...utils.configparser import CaseSensitiveConfigParser
from ..lightgun_rs3 import count_rs3_guns
from ..pcsx2.pcsx2Generator import Pcsx2Generator

_PCSX2_LIGHTGUN_BIN_DIR: Final = Path("/userdata/system/hotr/emulators/pcsx2")
_PCSX2_LIGHTGUN_BIN: Final = _PCSX2_LIGHTGUN_BIN_DIR / "pcsx2-lightgun-qt"
_PCSX2_LIGHTGUN_XDG_HOME: Final = CONFIGS / "pcsx2-lightgun-xdg"
_PCSX2_LIGHTGUN_CONFIG_DIR: Final = _PCSX2_LIGHTGUN_XDG_HOME / "PCSX2"
_PCSX2_LIGHTGUN_LIB_DIR: Final = _PCSX2_LIGHTGUN_BIN_DIR / "lib"


class Pcsx2LightgunGenerator(Pcsx2Generator):
    """Stock Batocera PCSX2 config + isolated native HOTR light-gun build."""

    def executionDirectory(self, config, rom):
        return _PCSX2_LIGHTGUN_BIN_DIR

    def generate(self, system, rom, playersControllers, metadata, guns, wheels, gameResolution):
        cmd = super().generate(system, rom, playersControllers, metadata, guns, wheels, gameResolution)

        if cmd.array:
            cmd.array[0] = str(_PCSX2_LIGHTGUN_BIN)
            # Required by this PCSX2 light-gun build. Keep it on every launch.
            if "-fastboot" not in cmd.array:
                cmd.array.insert(1, "-fastboot")

        # Keep the custom build isolated from stock PCSX2 and make its private
        # rapidyaml library visible without changing Batocera's global linker path.
        cmd.env["XDG_CONFIG_HOME"] = str(_PCSX2_LIGHTGUN_XDG_HOME)
        existing_ld_library_path = cmd.env.get("LD_LIBRARY_PATH", "")
        cmd.env["LD_LIBRARY_PATH"] = (
            f"{_PCSX2_LIGHTGUN_LIB_DIR}:{existing_ld_library_path}"
            if existing_ld_library_path
            else str(_PCSX2_LIGHTGUN_LIB_DIR)
        )

        reg_dir = _PCSX2_LIGHTGUN_CONFIG_DIR
        reg_dir.mkdir(parents=True, exist_ok=True)
        with (reg_dir / "PCSX2-reg.ini").open("w", encoding="utf-8") as f:
            f.write("DocumentsFolderMode=User\n")
            f.write(f"CustomDocumentsFolder={_PCSX2_LIGHTGUN_BIN_DIR}\n")
            f.write("UseDefaultSettingsFolder=enabled\n")
            f.write(f"SettingsFolder={_PCSX2_LIGHTGUN_CONFIG_DIR / 'inis'}\n")
            f.write(f"Install_Dir={_PCSX2_LIGHTGUN_BIN_DIR}\n")
            f.write("RunWizard=0\n")

        parent_config = CONFIGS / "PCSX2" / "inis" / "PCSX2.ini"
        config_path = _PCSX2_LIGHTGUN_CONFIG_DIR / "inis" / "PCSX2.ini"
        config_path.parent.mkdir(parents=True, exist_ok=True)

        # Seed once from stock PCSX2. Do NOT overwrite this file every launch:
        # HOTR-specific SDL/GunCon2 bindings and user changes must persist.
        if not config_path.exists() and parent_config.exists():
            content = parent_config.read_bytes().decode("latin-1")
            content = content.replace("/usr/pcsx2/bin", str(_PCSX2_LIGHTGUN_BIN_DIR))
            config_path.write_bytes(content.encode("latin-1"))

        pcsx2_config = CaseSensitiveConfigParser(interpolation=None)
        if config_path.exists():
            pcsx2_config.read(config_path, encoding="latin-1")

        if not pcsx2_config.has_section("Folders"):
            pcsx2_config.add_section("Folders")
        for key, value in {
            "Bios": "/userdata/bios/ps2",
            "Snapshots": "/userdata/screenshots",
            "Savestates": "/userdata/saves/ps2/pcsx2/sstates",
            "MemoryCards": "/userdata/saves/ps2/pcsx2",
            "Logs": "/userdata/system/logs",
            "Cheats": "/userdata/cheats/ps2",
            "CheatsWS": "/userdata/cheats/ps2/cheats_ws",
            "CheatsNI": "/userdata/cheats/ps2/cheats_ni",
            "Cache": "/userdata/system/cache/ps2",
            "Videos": "/userdata/saves/ps2/pcsx2/videos",
        }.items():
            pcsx2_config.set("Folders", key, value)

        if not pcsx2_config.has_section("UI"):
            pcsx2_config.add_section("UI")
        pcsx2_config.set("UI", "SetupWizardIncomplete", "false")

        if not pcsx2_config.has_section("EmuCore"):
            pcsx2_config.add_section("EmuCore")
        pcsx2_config.set(
            "EmuCore",
            "EnableMameHooker",
            system.config.get("pcsx2_mamehooker", "true"),
        )

        gun_count = len(guns) if guns else count_rs3_guns()
        gun1onport2 = (
            gun_count == 1
            and "gun_gun1port" in metadata
            and metadata["gun_gun1port"] == "2"
        )

        port_map: list[tuple[str, int]] = []
        if not gun1onport2 and gun_count >= 1:
            port_map.append(("USB1", 0))
        if gun_count >= 2 or gun1onport2:
            port_map.append(("USB2", 0 if gun1onport2 else 1))

        # RS3 joystick-mode mapping verified on Batocera 43.1.
        # P1 -> SDL-0, P2 -> SDL-1. Relative axes provide accurate aiming.
        for usb_section, gun_idx in port_map:
            if not pcsx2_config.has_section(usb_section):
                pcsx2_config.add_section(usb_section)
            sdl = f"SDL-{gun_idx}"
            bindings = {
                "Type": "guncon2",
                "guncon2_cursor_path": "",
                "guncon2_cursor_color": "#0000ff",
                "guncon2_C": f"{sdl}/JoyButton3",
                "guncon2_numdevice": "2",
                "guncon2_A": f"{sdl}/JoyButton2",
                "guncon2_B": f"{sdl}/JoyButton5",
                "guncon2_Trigger": f"{sdl}/JoyButton0",
                "guncon2_Up": f"{sdl}/Hat0North",
                "guncon2_Left": f"{sdl}/Hat0West",
                "guncon2_Right": f"{sdl}/Hat0East",
                "guncon2_Down": f"{sdl}/Hat0South",
                "guncon2_ShootOffscreen": f"{sdl}/JoyButton1",
                "guncon2_RelativeDown": f"{sdl}/+JoyAxis1",
                "guncon2_RelativeLeft": f"{sdl}/-JoyAxis0",
                "guncon2_RelativeRight": f"{sdl}/+JoyAxis0",
                "guncon2_RelativeUp": f"{sdl}/-JoyAxis1",
                "guncon2_Recalibrate": f"{sdl}/JoyButton2",
                "guncon2_Start": f"{sdl}/JoyButton2",
                "guncon2_Select": f"{sdl}/JoyButton5",
            }
            for key, value in bindings.items():
                pcsx2_config.set(usb_section, key, value)

        active_sections = {section for section, _ in port_map}
        for usb_section in ("USB1", "USB2"):
            if usb_section not in active_sections:
                if not pcsx2_config.has_section(usb_section):
                    pcsx2_config.add_section(usb_section)
                pcsx2_config.set(usb_section, "Type", "None")

        with config_path.open("w", encoding="latin-1") as f:
            pcsx2_config.write(f)

        # HOTR owns RS3 ZJ/ZM lifecycle. Do not send direct serial resets here.
        return cmd
