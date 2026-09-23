from __future__ import annotations

from pathlib import Path

from ...batoceraPaths import CONFIGS
from ...utils.configparser import CaseSensitiveConfigParser
from ..duckstation.duckstationGenerator import DuckstationGenerator
from ..lightgun_rs3 import count_rs3_guns, wrap_with_gun_reset

_DUCK_HOTR_DIR = Path("/userdata/system/hotr/emulators/duckstation")
_DUCK_HOTR_QT = _DUCK_HOTR_DIR / "duckstation-lightgun-qt"


class DuckstationLightgunGenerator(DuckstationGenerator):
    """Stock Batocera DuckStation config + HOTR binary/output/gun changes."""

    def executionDirectory(self, config, rom):
        # MameOutputSender/resources live beside the HOTR build.
        return _DUCK_HOTR_DIR

    def generate(self, system, rom, playersControllers, metadata, guns, wheels, gameResolution):
        cmd = super().generate(system, rom, playersControllers, metadata, guns, wheels, gameResolution)

        # This generator exists only for the HOTR core, so always replace the
        # executable. The old exact-name comparison failed whenever Batocera's
        # parent generator returned an absolute path such as /usr/bin/duckstation-qt.
        if cmd.array:
            cmd.array[0] = str(_DUCK_HOTR_QT)
            if "-fullscreen" not in cmd.array:
                cmd.array.insert(1, "-fullscreen")

        settings_path = CONFIGS / "duckstation" / "settings.ini"
        settings = CaseSensitiveConfigParser(interpolation=None)
        if settings_path.exists():
            settings.read(settings_path)

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

        gun_count = len(guns) if (system.config.use_guns and guns) else count_rs3_guns()

        if guns:
            for nplayer, _ in enumerate(guns[:8], start=1):
                pad_num = f"Pad{nplayer}"
                sdl = f"SDL-{nplayer - 1}"
                if settings.has_option(pad_num, "Type") and settings.get(pad_num, "Type") == "GunCon":
                    settings.set(pad_num, "Trigger", f"{sdl}/Button0")
                    settings.set(pad_num, "ShootOffscreen", f"{sdl}/Button1")
                    settings.set(pad_num, "A", f"{sdl}/Button2")
                    settings.set(pad_num, "B", f"{sdl}/Button5")
                    settings.set(pad_num, "RelativeLeft", f"{sdl}/-Axis0")
                    settings.set(pad_num, "RelativeRight", f"{sdl}/+Axis0")
                    settings.set(pad_num, "RelativeUp", f"{sdl}/-Axis1")
                    settings.set(pad_num, "RelativeDown", f"{sdl}/+Axis1")

        for nplayer in range(gun_count + 1, 9):
            pad_num = f"Pad{nplayer}"
            if not settings.has_section(pad_num):
                settings.add_section(pad_num)
            settings.set(pad_num, "Type", "None")

        settings_path.parent.mkdir(parents=True, exist_ok=True)
        with settings_path.open("w") as f:
            settings.write(f)

        wrap_with_gun_reset(cmd, gun_count)
        return cmd
