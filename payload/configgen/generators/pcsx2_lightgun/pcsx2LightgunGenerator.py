from __future__ import annotations

from pathlib import Path
from typing import Final

from ...batoceraPaths import CONFIGS
try:
    from ...utils.configparser import CaseSensitiveConfigParser
except ImportError:  # Batocera 44 moved the helper out of configgen.utils.
    from configparser import ConfigParser

    class CaseSensitiveConfigParser(ConfigParser):
        def optionxform(self, optionstr):
            return optionstr
try:
    from ..pcsx2.pcsx2Generator import Pcsx2Generator
    _LEGACY_CONFIGGEN = True
except ImportError:  # Batocera 44 uses batocera_launch.emulators.pcsx2x6.
    from configgen.Command import Command
    from ..Generator import Generator as Pcsx2Generator
    _LEGACY_CONFIGGEN = False

_PCSX2_LIGHTGUN_BIN_DIR: Final = Path("/userdata/system/hotr/emulators/pcsx2")
_PCSX2_LIGHTGUN_BIN: Final = _PCSX2_LIGHTGUN_BIN_DIR / "pcsx2-lightgun-qt"
_PCSX2_LIGHTGUN_XDG_HOME: Final = CONFIGS / "pcsx2-lightgun-xdg"
_PCSX2_LIGHTGUN_CONFIG_DIR: Final = _PCSX2_LIGHTGUN_XDG_HOME / "PCSX2"
_PCSX2_LIGHTGUN_LIB_DIR: Final = _PCSX2_LIGHTGUN_BIN_DIR / "lib"


class Pcsx2LightgunGenerator(Pcsx2Generator):
    """Stock Batocera PCSX2 config + isolated native HOTR light-gun build."""

    def executionDirectory(self, config, rom):
        return _PCSX2_LIGHTGUN_BIN_DIR

    def getHotkeysContext(self):
        return {'name': 'pcsx2-lightgun', 'keys': {}}

    async def configure(self):
        """Adapt the Batocera 44 Emulator API to the private HOTR binary."""
        if _LEGACY_CONFIGGEN:
            return await super().configure()
        command = await super().configure()
        command.array[0] = str(_PCSX2_LIGHTGUN_BIN)
        command.env['XDG_CONFIG_HOME'] = str(_PCSX2_LIGHTGUN_XDG_HOME)
        command.env['LD_LIBRARY_PATH'] = str(_PCSX2_LIGHTGUN_LIB_DIR)
        if '-fastboot' not in command.array:
            command.array.insert(1, '-fastboot')
        return command

    def generate(self, system, rom, playersControllers, metadata, guns, wheels, gameResolution):
        if not _LEGACY_CONFIGGEN:
            return Command(
                [str(_PCSX2_LIGHTGUN_BIN), '-nogui', '-fastboot', str(rom)],
                {
                    'XDG_CONFIG_HOME': str(_PCSX2_LIGHTGUN_XDG_HOME),
                    'LD_LIBRARY_PATH': str(_PCSX2_LIGHTGUN_LIB_DIR),
                    'DISPLAY': ':0',
                    'QT_QPA_PLATFORM': 'xcb',
                },
            )
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
        cmd.env["DISPLAY"] = ":0"
        cmd.env["QT_QPA_PLATFORM"] = "xcb"

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

        # Seed once from stock PCSX2 as an initial baseline. After that, the
        # HOTR config remains independent; Batocera options for ps2-hotr are
        # applied directly below instead of replacing this file from stock.
        # Seed the separate HOTR configuration once from normal PCSX2. After
        # that, preserve settings changed directly in the HOTR emulator.
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

        # Keep display, emulation and UI choices isolated.  The two USB
        # sections alone are refreshed from the just-generated stock config,
        # which preserves Batocera's exact current gun detection and mapping.
        if parent_config.exists():
            stock_config = CaseSensitiveConfigParser(interpolation=None)
            stock_config.read(parent_config, encoding="latin-1")
            for usb_section in ("USB1", "USB2"):
                if not stock_config.has_section(usb_section):
                    continue
                if pcsx2_config.has_section(usb_section):
                    pcsx2_config.remove_section(usb_section)
                pcsx2_config.add_section(usb_section)
                for key, value in stock_config.items(usb_section):
                    pcsx2_config.set(usb_section, key, value)

        with config_path.open("w", encoding="latin-1") as f:
            pcsx2_config.write(f)

        return cmd
