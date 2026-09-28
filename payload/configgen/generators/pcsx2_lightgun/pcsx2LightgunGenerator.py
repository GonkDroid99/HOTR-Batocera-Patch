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
from ..lightgun_rs3 import count_rs3_guns
from ..hotr_lightgun_mapping import (
    axis_mode, detected_layout_name, logical_for, pcsx2_button, pcsx2_relative_axes,
)
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
        if not config_path.exists() and parent_config.exists():
            content = parent_config.read_bytes().decode("latin-1")
            content = content.replace("/usr/pcsx2/bin", str(_PCSX2_LIGHTGUN_BIN_DIR))
            config_path.write_bytes(content.encode("latin-1"))

        pcsx2_config = CaseSensitiveConfigParser(interpolation=None)
        if config_path.exists():
            pcsx2_config.read(config_path, encoding="latin-1")

        # super().generate() applies the ps2-hotr options to the stock
        # generator's file. Copy only those option keys into the isolated HOTR
        # file; never replace the whole file, since the HOTR build has its own
        # UI, input and emulator settings.
        if parent_config.exists():
            stock_config = CaseSensitiveConfigParser(interpolation=None)
            stock_config.read(parent_config, encoding="latin-1")
            managed_options = {
                "EmuCore": (
                    "EnableCheats", "EnableWideScreenPatches",
                    "EnableNoInterlacingPatches", "TVShader",
                ),
                "EmuCore/GS": (
                    "AspectRatio", "VsyncEnable", "upscale_multiplier",
                    "fxaa", "FMVAspectRatioSwitch", "mipmap_hw",
                    "TriFilter", "MaxAnisotropy", "dithering_ps2",
                    "texture_preloading", "deinterlace_mode", "pcrtc_antiblur",
                    "IntegerScaling", "accurate_blending_unit", "filter",
                    "linear_present_mode", "LoadTextureReplacements",
                ),
            }
            for section, keys in managed_options.items():
                if not stock_config.has_section(section):
                    continue
                if not pcsx2_config.has_section(section):
                    pcsx2_config.add_section(section)
                for key in keys:
                    if stock_config.has_option(section, key):
                        pcsx2_config.set(section, key, stock_config.get(section, key))

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

        # HOTR uses Batocera logical light-gun controls, translated to the
        # SDL device exposed while the gun is in HOTR joystick mode. ES options
        # can override each GunCon2 action per player/per game.
        managed_keys = (
            "guncon2_C", "guncon2_A", "guncon2_B", "guncon2_Trigger",
            "guncon2_Up", "guncon2_Left", "guncon2_Right", "guncon2_Down",
            "guncon2_ShootOffscreen", "guncon2_RelativeDown",
            "guncon2_RelativeLeft", "guncon2_RelativeRight",
            "guncon2_RelativeUp", "guncon2_Recalibrate", "guncon2_Start",
            "guncon2_Select",
        )
        # Defaults mirror Batocera's global light-gun semantics: trigger,
        # action, start/select, SUB buttons and d-pad. In particular PCSX2's
        # stock mapping uses Action for C/pedal, Start for A, Select for B,
        # SUB1 for recalibration and SUB2 for GunCon Start.
        action_defaults = {
            "Trigger": "trigger",
            # Time Crisis II needs rear/thumb exclusively for GunCon C/pedal.
            # Sharing it with ShootOffscreen makes menu shooting work but breaks
            # normal gameplay, so offscreen shooting is opt-in for PCSX2.
            "ShootOffscreen": "disabled",
            "C": "action",
            "A": "start",
            "B": "select",
            "Recalibrate": "sub1",
            "Start": "sub2",
            "Select": "select",
            "Up": "up",
            "Down": "down",
            "Left": "left",
            "Right": "right",
        }

        for usb_section, gun_idx in port_map:
            # completely rebuild USB section so no
            # stale guncon2_numdevice/button/SDL mappings survive.
            if pcsx2_config.has_section(usb_section):
                pcsx2_config.remove_section(usb_section)
            pcsx2_config.add_section(usb_section)

            player = gun_idx + 1
            gun = guns[gun_idx] if guns and gun_idx < len(guns) else None
            layout = detected_layout_name(gun)

            pcsx2_config.set(usb_section, "Type", "guncon2")
            pcsx2_config.set(usb_section, "guncon2_cursor_path", "")
            pcsx2_config.set(usb_section, "guncon2_cursor_color", "#0000ff" if player == 1 else "#ff0000")


            # leave guncon2_numdevice unset; Batocera evdev selects by USB port
            # Remove only keys owned by this HOTR mapping layer, then rebuild
            # them from the selected semantic controls.
            for key in managed_keys:
                if pcsx2_config.has_option(usb_section, key):
                    pcsx2_config.remove_option(usb_section, key)

            for action, default in action_defaults.items():
                logical = logical_for(system, "pcsx2", player, action.lower(), default)
                value = pcsx2_button(layout, gun_idx, logical)
                if value is not None:
                    pass  # Native PCSX2/Batocera GunCon2 handling owns normal gun controls

            # Match stock Batocera PCSX2: configgen explicitly supplies only
            # the GunCon2 C/pedal key here. Other gun controls use PCSX2's
            # native lightgun/pointer defaults.
            pedal_keys = {1: "c", 2: "v", 3: "b", 4: "n"}
            pedal_key = system.config.get(
                f"controllers.pedals{player}",
                pedal_keys.get(player, "c")
            )
            pcsx2_config.set(
                usb_section,
                "guncon2_C",
                f"Keyboard/{pedal_key.upper()}"
            )
            # Native Batocera/PCSX2 GunCon2 path owns aiming.
            # Do not create HOTR SDL Relative* mappings.

        active_sections = {section for section, _ in port_map}
        for usb_section in ("USB1", "USB2"):
            if usb_section not in active_sections:
                # also clear stale mappings on inactive ports.
                if pcsx2_config.has_section(usb_section):
                    pcsx2_config.remove_section(usb_section)
                pcsx2_config.add_section(usb_section)
                pcsx2_config.set(usb_section, "Type", "None")

        with config_path.open("w", encoding="latin-1") as f:
            pcsx2_config.write(f)

        # HOTR owns RS3 ZJ/ZM lifecycle. Do not send direct serial resets here.
        return cmd
