"""Batocera 44 launcher for HOTR's separate PCSX2 build."""

from pathlib import Path
from typing import Final

from batocera_common.dataclasses import cached_property
from batocera_common.paths import CONFIGS
from batocera_launch import Command
from batocera_launch.emulators.pcsx2x6 import Pcsx2x6

_HOTR_DIR: Final = Path('/userdata/system/hotr/emulators/pcsx2')
_HOTR_BINARY: Final = _HOTR_DIR / 'pcsx2-lightgun-qt'
_HOTR_CONFIG_HOME: Final = CONFIGS / 'pcsx2-lightgun-xdg'


class Pcsx2Lightgun(Pcsx2x6):
    """Stock PCSX2x6 setup with HOTR's binary and private config root."""

    @cached_property
    def config_dir(self) -> Path:
        # Match the stock PCSX2x6 directory name below HOTR's private XDG
        # root, so the stock writer and custom executable use one config.
        return _HOTR_CONFIG_HOME / 'PCSX2x6'

    async def configure(self) -> Command:
        command = await super().configure()
        # Batocera 44's launcher Command stores the executable in ``args``.
        command.args[0] = _HOTR_BINARY
        command.env['XDG_CONFIG_HOME'] = str(_HOTR_CONFIG_HOME)
        existing_library_path = str(command.env.get('LD_LIBRARY_PATH', ''))
        command.env['LD_LIBRARY_PATH'] = (
            f"{_HOTR_DIR / 'lib'}:{existing_library_path}"
            if existing_library_path else str(_HOTR_DIR / 'lib')
        )
        if '-fastboot' not in command.args:
            command.args.insert(1, '-fastboot')
        return command
