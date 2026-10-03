"""Batocera 44+ launcher for HOTR's separate PCSX2 build."""

from pathlib import Path
from typing import Final

from batocera_common.configparser import CaseSensitiveConfigParser
from batocera_common.dataclasses import cached_dataclass, cached_property
from batocera_common.paths import CONFIGS
from batocera_launch import Command, HotkeysContext
from batocera_launch_pcsx2 import Pcsx2

_HOTR_DIR: Final = Path('/userdata/system/hotr/emulators/pcsx2')
_HOTR_BINARY: Final = _HOTR_DIR / 'pcsx2-lightgun-qt'
_HOTR_CONFIG_HOME: Final = CONFIGS / 'pcsx2-lightgun-xdg'
_SYSTEM: Final = CONFIGS.parent
_USERDATA: Final = _SYSTEM.parent


@cached_dataclass
class Pcsx2Lightgun(Pcsx2):
    """Stock PS2 PCSX2 setup with HOTR's binary and private config root."""

    @cached_property
    def config_dir(self) -> Path:
        # Match stock PS2 PCSX2's historical directory name.  PCSX2x6 is a
        # separate Namco arcade emulator and must never be used for PS2 HOTR.
        return _HOTR_CONFIG_HOME / 'PCSX2'

    @cached_property
    def hotkeygen_context(self) -> HotkeysContext:
        context = super().hotkeygen_context.copy()
        context['name'] = 'pcsx2-lightgun'
        return context

    def _configure_reg(self) -> None:
        """Write the private registry with the HOTR executable's resources."""
        self.config_dir.mkdir(parents=True, exist_ok=True)
        with (self.config_dir / 'PCSX2-reg.ini').open('w') as registry:
            registry.write('DocumentsFolderMode=User\n')
            registry.write(f'CustomDocumentsFolder={_HOTR_DIR}\n')
            registry.write('UseDefaultSettingsFolder=enabled\n')
            registry.write(f'SettingsFolder={self.config_dir / "inis"}\n')
            registry.write(f'Install_Dir={_HOTR_DIR}\n')
            registry.write('RunWizard=0\n')

    def _configure_private_paths(self) -> None:
        """Fix stock paths whose relative base changed under HOTR's XDG root."""
        ini_path = self.config_dir / 'inis' / 'PCSX2.ini'
        if not ini_path.exists():
            return
        settings = CaseSensitiveConfigParser(interpolation=None)
        settings.read(ini_path)
        if settings.has_section('Folders'):
            for key, value in {
                'Bios': _USERDATA / 'bios' / 'ps2',
                'Snapshots': _USERDATA / 'screenshots',
                'Savestates': _USERDATA / 'saves' / 'ps2' / 'pcsx2' / 'sstates',
                'MemoryCards': _USERDATA / 'saves' / 'ps2' / 'pcsx2',
                'Logs': _SYSTEM / 'logs',
                'Cheats': _USERDATA / 'cheats' / 'ps2',
                'CheatsWS': _USERDATA / 'cheats' / 'ps2' / 'cheats_ws',
                'CheatsNI': _USERDATA / 'cheats' / 'ps2' / 'cheats_ni',
                'Cache': _SYSTEM / 'cache' / 'ps2',
                'Videos': _USERDATA / 'saves' / 'ps2' / 'pcsx2' / 'videos',
            }.items():
                settings.set('Folders', key, str(value))

        # The stock writer targets its own resource tree for GunCon cursors
        # and fog fixes. This independent build must use its bundled assets.
        with ini_path.open('w') as config_file:
            settings.write(config_file)
        ini_path.write_text(
            ini_path.read_text().replace('/usr/pcsx2/bin/resources', str(_HOTR_DIR / 'resources')),
        )

    async def configure(self) -> Command:
        command = await super().configure()
        self._configure_private_paths()
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
