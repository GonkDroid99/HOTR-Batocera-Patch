from __future__ import annotations

from ...batoceraPaths import CONFIGS
from ...utils.configparser import CaseSensitiveConfigParser
from ..duckstation.duckstationGenerator import DuckstationGenerator
from ..lightgun_rs3 import count_rs3_guns, wrap_with_gun_reset


class DuckstationLightgunGenerator(DuckstationGenerator):
    """
    DuckStation LightGun Edition — inherits all config logic from the upstream
    generator but substitutes the lightgun-specific binary and enables
    MameHooker output for recoil/light gun effects via Hook of the Reaper.
    """

    def generate(self, system, rom, playersControllers, metadata, guns, wheels, gameResolution):
        cmd = super().generate(system, rom, playersControllers, metadata, guns, wheels, gameResolution)

        if cmd.array:
            if cmd.array[0] == "duckstation-qt":
                cmd.array[0] = "/userdata/system/hotr/emulators/duckstation/duckstation-lightgun-qt"
                # Qt frontend doesn't get -fullscreen from the parent; add it so the
                # window is truly fullscreen (not just maximized) and Openbox can't drag it.
                if "-fullscreen" not in cmd.array:
                    cmd.array.insert(1, "-fullscreen")
            elif cmd.array[0] == "duckstation-nogui":
                cmd.array[0] = "/userdata/system/hotr/emulators/duckstation/duckstation-lightgun-nogui"

        settings_path = CONFIGS / "duckstation" / "settings.ini"
        settings = CaseSensitiveConfigParser(interpolation=None)
        if settings_path.exists():
            settings.read(settings_path)

        # Write EnableMameHooker — default on, user can toggle via ES LIGHT GUN menu
        if not settings.has_section("Main"):
            settings.add_section("Main")
        settings.set("Main", "EnableMameHooker",
                     system.config.get("duckstation_mamehooker", "true"))

        # Enhanced SDL mode reads evdev directly, bypassing udev's ID_INPUT_JOYSTICK=0
        # suppression that retroshooter-guns applies to the RS3 devices.
        if not settings.has_section("InputSources"):
            settings.add_section("InputSources")
        settings.set("InputSources", "SDLControllerEnhancedMode", "true")

        # Write SDL-based GunCon bindings for connected guns.
        # HOTR's DefaultLG game files switch guns into gamepad/SDL mode at game start,
        # enabling 2-player support. Relative aiming axes are required for this mode.
        gun_count = len(guns) if (system.config.use_guns and guns) else count_rs3_guns()
        if gun_count:
            for nplayer, _ in enumerate(guns[:8], start=1):
                pad_num = f"Pad{nplayer}"
                sdl    = f"SDL-{nplayer - 1}"
                if settings.has_option(pad_num, "Type") and settings.get(pad_num, "Type") == "GunCon":
                    settings.set(pad_num, "Trigger",       f"{sdl}/Button0")
                    settings.set(pad_num, "ShootOffscreen", f"{sdl}/Button1")
                    settings.set(pad_num, "A",             f"{sdl}/Button2")
                    settings.set(pad_num, "B",             f"{sdl}/Button5")
                    settings.set(pad_num, "RelativeLeft",  f"{sdl}/-Axis0")
                    settings.set(pad_num, "RelativeRight", f"{sdl}/+Axis0")
                    settings.set(pad_num, "RelativeUp",    f"{sdl}/-Axis1")
                    settings.set(pad_num, "RelativeDown",  f"{sdl}/+Axis1")

        # Disable pad slots with no gun connected so DuckStation doesn't wait for
        # a second controller that isn't there.
        for nplayer in range(gun_count + 1, 9):
            pad_num = f"Pad{nplayer}"
            if not settings.has_section(pad_num):
                settings.add_section(pad_num)
            settings.set(pad_num, "Type", "None")

        with open(settings_path, "w") as f:
            settings.write(f)

        wrap_with_gun_reset(cmd, gun_count)

        return cmd
