from __future__ import annotations

from pathlib import Path
from typing import Final

from ...batoceraPaths import CONFIGS
from ...utils.configparser import CaseSensitiveConfigParser
from ..lightgun_rs3 import count_rs3_guns, wrap_with_gun_reset
from ..pcsx2.pcsx2Generator import Pcsx2Generator

_PCSX2_LIGHTGUN_BIN_DIR: Final = Path("/userdata/system/hotr/emulators/pcsx2")
_PCSX2_LIGHTGUN_BIN: Final = _PCSX2_LIGHTGUN_BIN_DIR / "pcsx2-lightgun-qt"
_PCSX2_LIGHTGUN_LIB_DIR: Final = _PCSX2_LIGHTGUN_BIN_DIR / "lib"
_PCSX2_LIGHTGUN_CONFIG_DIR: Final = CONFIGS / "PCSX2-lightgun"
_PCSX2_LIGHTGUN_XDG_HOME: Final = CONFIGS / "pcsx2-lightgun-xdg"


class Pcsx2LightgunGenerator(Pcsx2Generator):
    """Stock Batocera PCSX2 config + native HOTR binary/output/gun changes."""

    def executionDirectory(self, config, rom):
        # Keep MameOutputSender and any relative resources beside PCSX2 HOTR.
        return _PCSX2_LIGHTGUN_BIN_DIR

    def generate(self, system, rom, playersControllers, metadata, guns, wheels, gameResolution):
        cmd = super().generate(system, rom, playersControllers, metadata, guns, wheels, gameResolution)

        if cmd.array:
            cmd.array[0] = str(_PCSX2_LIGHTGUN_BIN)

        # PCSX2 HOTR ships private runtime libraries beside the emulator.
        # Preserve Batocera's existing library search path while putting our
        # bundled libraries first.
        existing_ld_library_path = cmd.env.get("LD_LIBRARY_PATH", "")
        cmd.env["LD_LIBRARY_PATH"] = (
            f"{_PCSX2_LIGHTGUN_LIB_DIR}:{existing_ld_library_path}"
            if existing_ld_library_path
            else str(_PCSX2_LIGHTGUN_LIB_DIR)
        )

        cmd.env["XDG_CONFIG_HOME"] = str(_PCSX2_LIGHTGUN_XDG_HOME)

        reg_dir = _PCSX2_LIGHTGUN_XDG_HOME / "PCSX2"
        reg_dir.mkdir(parents=True, exist_ok=True)
        with (reg_dir / "PCSX2-reg.ini").open("w") as f:
            f.write("DocumentsFolderMode=User\n")
            f.write(f"CustomDocumentsFolder={_PCSX2_LIGHTGUN_BIN_DIR}\n")
            f.write("UseDefaultSettingsFolder=enabled\n")
            f.write(f"SettingsFolder={_PCSX2_LIGHTGUN_CONFIG_DIR / 'inis'}\n")
            f.write(f"Install_Dir={_PCSX2_LIGHTGUN_BIN_DIR}\n")
            f.write("RunWizard=0\n")

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

        sdl_keys = [
            "guncon2_Trigger", "guncon2_A", "guncon2_B", "guncon2_Recalibrate",
            "guncon2_Up", "guncon2_Down", "guncon2_Left", "guncon2_Right",
            "guncon2_RelativeUp", "guncon2_RelativeDown",
            "guncon2_RelativeLeft", "guncon2_RelativeRight",
        ]
        for section in ("USB1", "USB2"):
            for key in sdl_keys:
                if pcsx2_config.has_option(section, key):
                    pcsx2_config.remove_option(section, key)

        if not pcsx2_config.has_section("EmuCore"):
            pcsx2_config.add_section("EmuCore")
        pcsx2_config.set(
            "EmuCore",
            "EnableMameHooker",
            system.config.get("pcsx2_mamehooker", "true"),
        )

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
                pcsx2_config.set(usb_section, "guncon2_numdevice", str(mouse_indices[gun_idx]))

        unused = "USB2" if not gun1onport2 and gun_count < 2 else None
        if unused:
            if not pcsx2_config.has_section(unused):
                pcsx2_config.add_section(unused)
            pcsx2_config.set(unused, "Type", "None")

        with config_path.open("w") as f:
            pcsx2_config.write(f)

        wrap_with_gun_reset(cmd, gun_count)
        return cmd
