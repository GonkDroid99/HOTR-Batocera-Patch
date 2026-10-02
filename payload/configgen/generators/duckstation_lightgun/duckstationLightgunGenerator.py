from __future__ import annotations

from pathlib import Path

from ...batoceraPaths import CONFIGS
try:
    from ...utils.configparser import CaseSensitiveConfigParser
except ImportError:  # Batocera 44 moved the helper out of configgen.utils.
    from configparser import ConfigParser

    class CaseSensitiveConfigParser(ConfigParser):
        def optionxform(self, optionstr):
            return optionstr
try:
    from ..duckstation.duckstationGenerator import DuckstationGenerator
    _LEGACY_CONFIGGEN = True
except ImportError:  # Batocera 44 keeps DuckStation in batocera-launch.
    from configgen.Command import Command
    from ..Generator import Generator as DuckstationGenerator
    _LEGACY_CONFIGGEN = False
_DUCK_HOTR_DIR = Path("/userdata/system/hotr/emulators/duckstation")
_DUCK_HOTR_QT = _DUCK_HOTR_DIR / "duckstation-lightgun-qt"
# DuckStation stores its files in a ``duckstation`` child directory below
# XDG_CONFIG_HOME.  This must be a private XDG root; using CONFIGS here made
# the V43 launch read the normal PSX configuration instead of HOTR's copy.
_DUCK_HOTR_XDG_HOME = CONFIGS / "duckstation-lightgun"
_DUCK_HOTR_CONFIG_DIR = _DUCK_HOTR_XDG_HOME / "duckstation"


class DuckstationLightgunGenerator(DuckstationGenerator):
    """Stock Batocera DuckStation config with HOTR binary and output support."""

    def executionDirectory(self, config, rom):
        # MameOutputSender/resources live beside the HOTR build.
        return _DUCK_HOTR_DIR

    def getHotkeysContext(self):
        return {'name': 'duckstation-lightgun', 'keys': {}}

    def generate(self, system, rom, playersControllers, metadata, guns, wheels, gameResolution):
        if not _LEGACY_CONFIGGEN:
            return Command(
                [str(_DUCK_HOTR_QT), '-batch', '-fullscreen', str(rom)],
                {
                    'XDG_CONFIG_HOME': str(_DUCK_HOTR_XDG_HOME),
                    'DISPLAY': ':0',
                    'QT_QPA_PLATFORM': 'xcb',
                },
            )
        cmd = super().generate(system, rom, playersControllers, metadata, guns, wheels, gameResolution)

        # This generator exists only for the HOTR core, so always replace the
        # executable. The old exact-name comparison failed whenever Batocera's
        # parent generator returned an absolute path such as /usr/bin/duckstation-qt.
        if cmd.array:
            cmd.array[0] = str(_DUCK_HOTR_QT)
            if "-fullscreen" not in cmd.array:
                cmd.array.insert(1, "-fullscreen")

        # Keep the HOTR build independent from stock DuckStation. The custom
        # build follows XDG_CONFIG_HOME for its settings file; its patched
        # absolute data directories remain shared only for resources/saves.
        cmd.env["XDG_CONFIG_HOME"] = str(_DUCK_HOTR_XDG_HOME)
        cmd.env["DISPLAY"] = ":0"
        cmd.env["QT_QPA_PLATFORM"] = "xcb"
        settings_path = _DUCK_HOTR_CONFIG_DIR / "settings.ini"
        stock_settings_path = CONFIGS / "duckstation" / "settings.ini"
        settings = CaseSensitiveConfigParser(interpolation=None)
        if settings_path.exists():
            settings.read(settings_path)
        elif stock_settings_path.exists():
            # Seed the isolated HOTR configuration once from normal
            # DuckStation, then preserve HOTR-specific changes.
            settings.read(stock_settings_path)

        if stock_settings_path.exists():
            stock_settings = CaseSensitiveConfigParser(interpolation=None)
            stock_settings.read(stock_settings_path)
            for nplayer in range(1, 9):
                pad_num = f"Pad{nplayer}"
                stock_gun = (
                    stock_settings.has_option(pad_num, "Type")
                    and stock_settings.get(pad_num, "Type") in ("GunCon", "Justifier")
                )
                previous_gun = (
                    settings.has_option(pad_num, "Type")
                    and settings.get(pad_num, "Type") in ("GunCon", "Justifier")
                )
                if not stock_gun and not previous_gun:
                    continue

                # Refresh only active or previously active light-gun pads.
                # All other HOTR controller and emulator settings stay private.
                if settings.has_section(pad_num):
                    settings.remove_section(pad_num)
                if stock_settings.has_section(pad_num):
                    settings.add_section(pad_num)
                    for key, value in stock_settings.items(pad_num):
                        settings.set(pad_num, key, value)

        if not settings.has_section("Main"):
            settings.add_section("Main")
        settings.set(
            "Main",
            "EnableMameHooker",
            system.config.get("duckstation_mamehooker", "true"),
        )

        settings_path.parent.mkdir(parents=True, exist_ok=True)
        with settings_path.open("w") as f:
            settings.write(f)

        return cmd
