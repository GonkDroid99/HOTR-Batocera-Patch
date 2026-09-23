from __future__ import annotations

import shlex
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from ..Command import Command

_HOTR_GUN_SYMLINK_PATTERN = "/dev/hotr/rs3reaper-gun{n}"


def count_rs3_guns() -> int:
    """Count connected RS3 guns via HOTR udev symlinks. Returns at least 1."""
    count = 0
    for n in range(1, 9):
        if Path(_HOTR_GUN_SYMLINK_PATTERN.format(n=n)).exists():
            count += 1
        else:
            break
    return max(count, 1)


def wrap_with_gun_reset(cmd: Command, gun_count: int) -> None:
    """Wrap cmd so that after the emulator exits, connected RS3 guns are sent
    the 'ZM' serial command to return them to mouse mode."""
    resets = [
        f"printf ZM > {_HOTR_GUN_SYMLINK_PATTERN.format(n=n)} 2>/dev/null"
        for n in range(1, gun_count + 1)
        if Path(_HOTR_GUN_SYMLINK_PATTERN.format(n=n)).exists()
    ]
    if resets:
        cmd.array = ["sh", "-c", f'{shlex.join(str(a) for a in cmd.array)}; {"; ".join(resets)}']
