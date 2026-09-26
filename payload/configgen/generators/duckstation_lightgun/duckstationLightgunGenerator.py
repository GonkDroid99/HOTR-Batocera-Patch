from __future__ import annotations

from pathlib import Path

from ...batoceraPaths import CONFIGS
from ...utils.configparser import CaseSensitiveConfigParser
from ..duckstation.duckstationGenerator import DuckstationGenerator
from ..lightgun_rs3 import count_rs3_guns
from ..hotr_lightgun_mapping import (
    axis_mode, detected_layout_name, duckstation_button, duckstation_relative_axes, logical_for,
)

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
            # DuckStation GunCon exposes Trigger, ShootOffscreen, A and B.
            # Keep Batocera's logical meanings but emit DuckStation SDL syntax.
            # Confirmed RS3 defaults: trigger, rear/thumb offscreen reload,
            # front-left A and front-right B.
            defaults = {
                "Trigger": "trigger",
                "ShootOffscreen": "action",
                "A": "start",
                "B": "select",
            }
            managed = (
                "Trigger", "ShootOffscreen", "A", "B",
                "RelativeLeft", "RelativeRight", "RelativeUp", "RelativeDown",
            )
            for nplayer, gun in enumerate(guns[:8], start=1):
                pad_num = f"Pad{nplayer}"
                sdl_index = nplayer - 1
                if settings.has_option(pad_num, "Type") and settings.get(pad_num, "Type") == "GunCon":
                    layout = detected_layout_name(gun)
                    for key in managed:
                        if settings.has_option(pad_num, key):
                            settings.remove_option(pad_num, key)
                    for action, default in defaults.items():
                        logical = logical_for(system, "duckstation", nplayer, action.lower(), default)
                        value = duckstation_button(layout, sdl_index, logical)
                        if value is not None:
                            settings.set(pad_num, action, value)
                    for key, value in duckstation_relative_axes(
                        sdl_index,
                        axis_mode(system, "duckstation", nplayer, "x"),
                        axis_mode(system, "duckstation", nplayer, "y"),
                    ).items():
                        settings.set(pad_num, key, value)

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
