from __future__ import annotations

from pathlib import Path

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
