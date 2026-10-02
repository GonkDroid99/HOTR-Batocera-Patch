"""Batocera 44 launcher for HOTR's separate DuckStation build.

This module deliberately extends the stock DuckStation launcher instead of
changing it.  Normal PSX therefore remains completely unaware of HOTR.
"""

from __future__ import annotations

from pathlib import Path
from typing import Final

from batocera_common.configparser import CaseSensitiveConfigParser
from batocera_common.dataclasses import cached_property
from batocera_common.paths import CONFIGS
from batocera_launch import Command, HotkeysContext
from batocera_launch.emulators.duckstation import Duckstation

_HOTR_DIRECTORY: Final = Path('/userdata/system/hotr/emulators/duckstation')
_HOTR_BINARY: Final = _HOTR_DIRECTORY / 'duckstation-lightgun-qt'
_HOTR_CONFIG_HOME: Final = CONFIGS / 'duckstation-lightgun'


class DuckstationLightgun(Duckstation):
    """Stock DuckStation configuration with HOTR's binary and output bridge."""

    @cached_property
    def config_dir(self) -> Path:
        # DuckStation places its settings in a ``duckstation`` child directory
        # below XDG_CONFIG_HOME. Keep this independent from normal PSX.
        return _HOTR_CONFIG_HOME / 'duckstation'

    @cached_property
    def hotkeygen_context(self) -> HotkeysContext:
        context = super().hotkeygen_context.copy()
        context['name'] = 'duckstation-lightgun'
        return context

    def _write_settings(self) -> None:
        super()._write_settings()

        # The custom DuckStation binary starts MameOutputSender when a game
        # boots only when this setting is enabled.
        settings_path = self.config_dir / 'settings.ini'
        settings = CaseSensitiveConfigParser(interpolation=None)
        settings.read(settings_path)
        if not settings.has_section('Main'):
            settings.add_section('Main')
        settings.set('Main', 'EnableMameHooker', self.config.get('duckstation_mamehooker', 'true'))
        with settings_path.open('w') as config_file:
            settings.write(config_file)

    async def configure(self) -> Command:
        self._write_settings()

        # Keep the Qt frontend available: Batocera's fullscreen session can
        # fail to display the patched build when -nogui is used.
        return Command(
            [_HOTR_BINARY, '-batch', '-fullscreen', '--', self.rom],
            env={
                'XDG_CONFIG_HOME': _HOTR_CONFIG_HOME,
                'QT_QPA_PLATFORM': 'xcb',
                'SDL_JOYSTICK_HIDAPI': '0',
                'LD_LIBRARY_PATH': '/usr/stenzek-shaderc/lib:/usr/lib',
            },
        )
