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
from ..lightgun_rs3 import count_rs3_guns

_DUCK_HOTR_DIR = Path("/userdata/system/hotr/emulators/duckstation")
_DUCK_HOTR_QT = _DUCK_HOTR_DIR / "duckstation-lightgun-qt"
_DUCK_HOTR_CONFIG_DIR = CONFIGS / "duckstation-lightgun"


class DuckstationLightgunGenerator(DuckstationGenerator):
    """Stock Batocera DuckStation config + HOTR binary/output/gun changes."""

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
                    'XDG_CONFIG_HOME': str(_DUCK_HOTR_CONFIG_DIR.parent),
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
        cmd.env["XDG_CONFIG_HOME"] = str(_DUCK_HOTR_CONFIG_DIR.parent)
        cmd.env["DISPLAY"] = ":0"
        cmd.env["QT_QPA_PLATFORM"] = "xcb"
        settings_path = _DUCK_HOTR_CONFIG_DIR / "settings.ini"
        stock_settings_path = CONFIGS / "duckstation" / "settings.ini"
        settings = CaseSensitiveConfigParser(interpolation=None)
        if settings_path.exists():
            settings.read(settings_path)
        elif stock_settings_path.exists():
            # Initial baseline only. Later launches preserve the HOTR file.
            settings.read(stock_settings_path)

        # super().generate() writes the current psx-hotr options to stock
        # DuckStation's file. Copy only Batocera-controlled options into the
        # isolated HOTR file, preserving HOTR-only and GUI settings.
        stock_settings = CaseSensitiveConfigParser(interpolation=None)
        if stock_settings_path.exists():
            stock_settings.read(stock_settings_path)
            managed_options = {
                "Main": (
                    "EmulationSpeed", "SyncToHostRefreshRate", "RewindEnable",
                    "RewindFrequency", "RewindSaveSlots",
                ),
                "Console": ("Region", "EnableCheats"),
                "BIOS": ("PatchFastBoot",),
                "CPU": ("ExecutionMode",),
                "GPU": (
                    "Renderer", "ThreadedPresentation", "ResolutionScale",
                    "WidescreenHack", "ForceNTSCTimings", "TextureFilter",
                    "PGXPEnable", "PGXPCulling", "PGXPTextureCorrection",
                    "PGXPPreserveProjFP", "TrueColor", "ScaledDithering",
                    "DisableInterlacing", "Multisamples",
                ),
                "Display": (
                    "AspectRatio", "VSync", "CropMode", "ShowOSDMessages",
                    "DisplayAllFrames", "IntegerScaling", "LinearFiltering",
                    "Stretch",
                ),
                "Audio": ("StretchMode",),
                "InputSources": ("SDLControllerEnhancedMode",),
            }
            for section, keys in managed_options.items():
                if not stock_settings.has_section(section):
                    continue
                if not settings.has_section(section):
                    settings.add_section(section)
                for key in keys:
                    if stock_settings.has_option(section, key):
                        settings.set(section, key, stock_settings.get(section, key))

        if not settings.has_section("Main"):
            settings.add_section("Main")
        settings.set(
            "Main",
            "EnableMameHooker",
            system.config.get("duckstation_mamehooker", "true"),
        )

        if not settings.has_section("InputSources"):
            settings.add_section("InputSources")
        settings.set("InputSources", "SDLControllerEnhancedMode", "true")

        gun_count = len(guns) if (system.config.use_guns and guns) else 0  # HOTR mouse-mode test: only Batocera-detected guns

        if guns:
            managed = (
                "Trigger", "ShootOffscreen", "A", "B",
                "RelativeLeft", "RelativeRight", "RelativeUp", "RelativeDown",
            )
            for nplayer in range(1, min(len(guns), 8) + 1):
                pad_num = f"Pad{nplayer}"
                if settings.has_option(pad_num, "Type") and settings.get(pad_num, "Type") == "GunCon":
                    for key in managed:
                        if settings.has_option(pad_num, key):
                            settings.remove_option(pad_num, key)

        for nplayer in range(gun_count + 1, 9):
            pad_num = f"Pad{nplayer}"
            if not settings.has_section(pad_num):
                settings.add_section(pad_num)
            settings.set(pad_num, "Type", "None")

        # Keep the pause/overlay menu easy to reach from a keyboard. The stock
        # generator can rewrite settings.ini on every ES launch, so enforce this
        # here immediately before saving the HOTR configuration.
        if not settings.has_section("Hotkeys"):
            settings.add_section("Hotkeys")
        settings.set("Hotkeys", "OpenPauseMenu", "Keyboard/Escape")

        settings_path.parent.mkdir(parents=True, exist_ok=True)
        with settings_path.open("w") as f:
            settings.write(f)

        # HOTR owns RS3 ZJ/ZM lifecycle. Do not send direct serial resets here.
        return cmd
