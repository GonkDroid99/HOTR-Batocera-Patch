"""Batocera 44 launcher for HOTR's separate PCSX2 build."""

from pathlib import Path
from typing import Final

from batocera_common.paths import CONFIGS
from batocera_launch import Command
from batocera_launch.emulators.pcsx2x6 import Pcsx2x6

_HOTR_DIR: Final = Path('/userdata/system/hotr/emulators/pcsx2')
_HOTR_BINARY: Final = _HOTR_DIR / 'pcsx2-lightgun-qt'
_HOTR_CONFIG_HOME: Final = CONFIGS / 'pcsx2-lightgun-xdg'


class Pcsx2Lightgun(Pcsx2x6):
    """Stock PCSX2x6 setup with HOTR's binary and private config root."""

    async def configure(self) -> Command:
        command = await super().configure()
        command.array[0] = _HOTR_BINARY
        command.env['XDG_CONFIG_HOME'] = str(_HOTR_CONFIG_HOME)
        command.env['LD_LIBRARY_PATH'] = str(_HOTR_DIR / 'lib')
        if '-fastboot' not in command.array:
            command.array.insert(1, '-fastboot')
        return command
