"""Batocera 44 launcher for HOTR's separate DuckStation build.

This module deliberately extends the stock DuckStation launcher instead of
changing it.  Normal PSX therefore remains completely unaware of HOTR.
"""

from __future__ import annotations

from pathlib import Path
from shutil import copyfile
from typing import Final

from batocera_common.configparser import CaseSensitiveConfigParser
from batocera_common.dataclasses import cached_dataclass, cached_property
from batocera_common.paths import CONFIGS
from batocera_launch import Command, HotkeysContext
from batocera_launch.emulators.duckstation import Duckstation

_HOTR_DIRECTORY: Final = Path('/userdata/system/hotr/emulators/duckstation')
_HOTR_BINARY: Final = _HOTR_DIRECTORY / 'duckstation-lightgun-qt'
_HOTR_CONFIG_HOME: Final = CONFIGS / 'duckstation-lightgun'
_SYSTEM: Final = CONFIGS.parent
_USERDATA: Final = _SYSTEM.parent


@cached_dataclass
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

    @cached_property
    def sdl_controller_db_path(self) -> Path:
        # The HOTR binary is compiled to load resources from its own symlinked
        # share directory.  Do not overwrite normal DuckStation's database.
        return _HOTR_DIRECTORY / 'resources' / 'gamecontrollerdb.txt'

    def _seed_settings(self) -> None:
        """Seed the isolated HOTR profile from normal DuckStation once."""
        settings_path = self.config_dir / 'settings.ini'
        stock_settings_path = CONFIGS / 'duckstation' / 'settings.ini'
        if settings_path.exists() or not stock_settings_path.is_file():
            return
        settings_path.parent.mkdir(parents=True, exist_ok=True)
        copyfile(stock_settings_path, settings_path)

    def _write_settings(self) -> None:
        self._seed_settings()
        super()._write_settings()

        # The custom DuckStation binary starts MameOutputSender when a game
        # boots only when this setting is enabled.
        settings_path = self.config_dir / 'settings.ini'
        settings = CaseSensitiveConfigParser(interpolation=None)
        settings.read(settings_path)
        if settings.has_section('MemoryCards'):
            settings.set('MemoryCards', 'Directory', str(_USERDATA / 'saves' / 'duckstation' / 'memcards'))
        if settings.has_section('Folders'):
            for key, value in {
                'Cache': _SYSTEM / 'cache' / 'duckstation',
                'Screenshots': _USERDATA / 'screenshots',
                'SaveStates': _USERDATA / 'saves' / 'duckstation',
                'Cheats': _USERDATA / 'cheats' / 'duckstation',
            }.items():
                settings.set('Folders', key, str(value))
        if not settings.has_section('Main'):
            settings.add_section('Main')
        settings.set('Main', 'EnableMameHooker', self.config.get('duckstation_mamehooker', 'true'))
        with settings_path.open('w') as config_file:
            settings.write(config_file)

    async def configure(self) -> Command:
        # Keep Batocera's stock configuration and per-game launch handling,
        # then substitute only the HOTR binary and private configuration root.
        command = await super().configure()
        command.args[0] = _HOTR_BINARY
        command.env['XDG_CONFIG_HOME'] = _HOTR_CONFIG_HOME

        # The HOTR Qt build needs a visible frontend rather than -nogui.
        if '-nogui' in command.args:
            command.args[command.args.index('-nogui')] = '-fullscreen'
        elif '-fullscreen' not in command.args:
            command.args.insert(1, '-fullscreen')
        return command
