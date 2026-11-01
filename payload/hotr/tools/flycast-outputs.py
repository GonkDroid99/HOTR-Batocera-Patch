#!/usr/bin/env python3
"""Publish DemulShooter-shaped outputs for a native Linux Flycast.

Reads the emulated Naomi RAM out of the Flycast process (the standalone build or
the libretro core inside RetroArch) using DemulShooter's per-title offsets, and
serves MAME network-output lines on TCP 127.0.0.1:8000 so Hook of the Reaper
binds it exactly as it binds DemulShooter:

    mame_start = ___empty        when a client connects and no game is hooked
    mame_stop = 1 + mame_start = <rom>   once the player block is live
    P1_CtmRecoil = 1             a 10 ms pulse, 30 ms before it can re-fire
                                 (DemulShooter's AsyncGameOutput)

Coverage (one reader class per DemulShooter handler):
  hotd2, hotd2o, hotd2p   confmiss   deathcox   deathcoxo   lupinsho   mok
  ninjaslt, ninjaslta, ninjasltj, ninjasltu
Atomiswave titles (claychal, rangrmsn, sprtshot, xtrmhunt, xtrmhnt2) have no
DemulShooter handler at all, and manicpnc/pokasuka were never finished there, so
this reader cannot serve them.

Flycast's own network output must be OFF while this runs - it listens on the
same port.  `--print` keeps the daemon off and just prints the state.

Usage:
  flycast-outputs.py [--port 8000] [--poll 0.005] [--print] [--verbose]
                     [--rom NAME] [--list-blocks] [--log FILE]
"""
from __future__ import annotations

import abc
import argparse
import contextlib
import os
import re
import socket
import struct
import sys
import threading
import time

PORT = 8000
POLL = 0.005
MASK = 0x01FFFFFF
MIN_BLOCK = 16 * 1024 * 1024
RECOIL_ON, RECOIL_OFF = 10, 30
RELOCATE_SECONDS = 2.0
DAMAGED_ON, DAMAGED_OFF = 200, 100
ROM_RE = re.compile(r"\.(zip|7z|chd|lst|dat|bin|cue|gdi)$", re.I)

OUTPUT_NAMES = (
    "P1_LmpStart", "P2_LmpStart", "P1_Ammo", "P2_Ammo", "P1_Clip", "P2_Clip",
    "P1_Life", "P2_Life", "Credits", "P1_CtmRecoil", "P2_CtmRecoil",
    "P1_Damaged", "P2_Damaged", "P1_GunRecoil", "P2_GunRecoil",
)


def log(msg: str, path: str | None = None) -> None:
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} [flycast-outputs] {msg}"
    if path:
        try:
            with open(path, "a", encoding="utf-8") as fh:
                fh.write(line + "\n")
        except OSError:
            pass
    print(line, file=sys.stderr, flush=True)


# ---------------------------------------------------------------- reading

def read_u8(mem, addr: int) -> int:
    mem.seek(addr)
    raw = mem.read(1)
    return raw[0] if raw else 0


def read_u32(mem, addr: int) -> int:
    mem.seek(addr)
    raw = mem.read(4)
    return struct.unpack("<I", raw)[0] if len(raw) == 4 else 0


def read_i16(mem, addr: int) -> int:
    mem.seek(addr)
    raw = mem.read(2)
    return struct.unpack("<h", raw)[0] if len(raw) == 2 else 0


def read_f32(mem, addr: int) -> float:
    mem.seek(addr)
    raw = mem.read(4)
    return struct.unpack("<f", raw)[0] if len(raw) == 4 else 0.0


def ptr(mem, lo: int, offset: int) -> int:
    """Guest address stored at lo + offset (DemulShooter's & 0x01FFFFFF mask)."""
    return read_u32(mem, lo + offset) & MASK


# ---------------------------------------------------------------- readers

class TitleReader(abc.ABC):
    """One DemulShooter Flycast handler, ported to Linux.

    `locate` validates a candidate RAM block and returns an opaque state object,
    `compute` turns that state into the published output values.  Edge pulses
    (recoil, damage) are produced by the reader itself via `pulse`, because
    DemulShooter's AsyncGameOutput is an event, not a state.
    """

    name = ""
    roms: tuple[str, ...] = ()

    def __init__(self, rom: str):
        self.rom = rom
        self.last: dict[str, int] = {}
        self.pulse_until: dict[str, float] = {}
        self.last_raw: object = None

    @abc.abstractmethod
    def locate(self, mem, lo: int, size: int) -> object | None:
        """Return a state object once the pointer chain validates, else None."""

    @abc.abstractmethod
    def compute(self, mem, lo: int, state: object) -> dict[str, int]:
        """Turn the located state into the published output values."""

    @staticmethod
    def fits(offset: int, size: int, span: int = 0x800) -> bool:
        """True when a guest offset (plus the span we will read) is in the block."""
        return 0 < offset and offset + span < size

    # -- pulse helpers ----------------------------------------------------

    def pulse(self, name: str, ms: int) -> int:
        self.pulse_until[name] = max(self.pulse_until.get(name, 0.0),
                                     time.time() + ms / 1000.0)
        return 1

    def pulse_state(self, name: str) -> int:
        return 1 if time.time() < self.pulse_until.get(name, 0.0) else 0

    def on_edge(self, name: str, value: int, ms: int = RECOIL_ON) -> int:
        """1 when `value` fell since the last poll (DemulShooter's rule)."""
        previous = self.last.get(name, 0)
        self.last[name] = value
        if value < previous:
            return self.pulse(name, ms)
        return self.pulse_state(name)


class NaomiTitle(TitleReader):
    """Shared shape of the Naomi handlers: status-gated life/ammo/lamps/credits.

    Subclasses only read the raw values; the output mapping (clip, recoil on an
    ammo drop, damage on a life drop) is DemulShooter's common logic.
    """

    #: status values that mean "playing"
    in_game: tuple[int, ...] = (5,)

    def read_values(self, mem, lo: int, state: object) -> dict:
        """Return {'status': (p1, p2), 'life': (p1, p2), 'ammo': (p1, p2),
        'lamp': (p1, p2), 'credits': int, 'active': (p1, p2) | None,
        'damage': (p1, p2) | None}."""
        raise NotImplementedError

    def compute(self, mem, lo: int, state: object) -> dict[str, int]:
        raw = self.read_values(mem, lo, state)
        self.last_raw = raw
        out: dict[str, int] = dict.fromkeys(OUTPUT_NAMES, 0)
        out["Credits"] = raw["credits"]
        active = raw.get("active")
        for idx, tag in ((0, "P1"), (1, "P2")):
            if raw["status"][idx] not in self.in_game:
                continue
            if active is not None and not active[idx]:
                continue
            life = raw["life"][idx]
            ammo = raw["ammo"][idx]
            out[f"{tag}_Life"] = life
            out[f"{tag}_Ammo"] = ammo
            out[f"{tag}_Clip"] = 1 if ammo > 0 else 0
            out[f"{tag}_LmpStart"] = 1 if raw["lamp"][idx] else 0
            out[f"{tag}_CtmRecoil"] = self.on_edge(f"{tag}_CtmRecoil", ammo)
            out[f"{tag}_Damaged"] = self.on_edge(f"{tag}_Damaged", life,
                                                 DAMAGED_ON)
        return out


class Hotd2(NaomiTitle):
    """hotd2 / hotd2o / hotd2p - Compute_Hotd2_Outputs(DataPtr).

    P1 block = ram + (read32(ram + DataPtr) & 0x01FFFFFF) + 0x04, P2 = P1 + 0x100,
    status 5 = in game, life +0x0C, ammo +0x20, start lamp +0xFB bit 6,
    credits +0x75C off the P1 block.
    """

    name = "hotd2"
    roms = ("hotd2", "hotd2o", "hotd2p")
    DATA_PTR = {"hotd2": 0x00096FA0, "hotd2o": 0x00096F58, "hotd2p": 0x00082D00}
    in_game = (5,)

    def __init__(self, rom: str):
        super().__init__(rom)
        self.data_ptr = self.DATA_PTR[rom]

    def locate(self, mem, lo: int, size: int) -> tuple[int, int] | None:
        raw = ptr(mem, lo, self.data_ptr)
        if raw == 0:
            return None
        p1 = raw + 0x04
        p2 = p1 + 0x100
        if not self.fits(p1, size) or not self.fits(p2, size):
            return None
        if read_u8(mem, lo + p1) in (4, 5, 6, 9) and \
                read_u8(mem, lo + p2) in (4, 5, 6, 9):
            return p1, p2
        return None

    def read_values(self, mem, lo: int, state: object) -> dict:
        p1, p2 = state  # type: ignore[misc]
        return {
            "status": (read_u8(mem, lo + p1), read_u8(mem, lo + p2)),
            "life": (read_u8(mem, lo + p1 + 0x0C), read_u8(mem, lo + p2 + 0x0C)),
            "ammo": (read_u8(mem, lo + p1 + 0x20), read_u8(mem, lo + p2 + 0x20)),
            "lamp": ((read_u8(mem, lo + p1 + 0xFB) >> 6) & 1,
                     (read_u8(mem, lo + p2 + 0xFB) >> 6) & 1),
            "credits": read_u8(mem, lo + p1 + 0x75C),
        }


class Confmiss(NaomiTitle):
    """confmiss - Compute_Confmiss_Outputs.

    P1 status = ram + (read32(ram + 0x2FBAC) & MASK), P2 = P1 + 0x40, life +0x14;
    ammo comes off the 0x2AA50 pointer (-0x14 for P1, +0x100 for P2); credits off
    0x2F88C; start lamps are bits 7/4 of ram + 0x152AEA.  Status 0/1 = in game.
    """

    name = "confmiss"
    roms = ("confmiss",)
    in_game = (0, 1)

    def locate(self, mem, lo: int, size: int) -> tuple[int, int] | None:
        p1 = ptr(mem, lo, 0x2FBAC)
        ammo = ptr(mem, lo, 0x2AA50)
        if p1 == 0 or ammo == 0:
            return None
        p2 = p1 + 0x40
        if not self.fits(p1, size) or not self.fits(p2, size):
            return None
        if not self.fits(ammo - 0x14, size, 0x200):
            return None
        if read_u8(mem, lo + p1) in (0, 1, 2, 4) and \
                read_u8(mem, lo + p2) in (0, 1, 2, 4):
            return p1, p2
        return None

    def read_values(self, mem, lo: int, state: object) -> dict:
        p1, p2 = state  # type: ignore[misc]
        ammo = ptr(mem, lo, 0x2AA50)
        lamps = read_u8(mem, lo + 0x152AEA)
        return {
            "status": (read_u8(mem, lo + p1), read_u8(mem, lo + p2)),
            "life": (read_u8(mem, lo + p1 + 0x14), read_u8(mem, lo + p2 + 0x14)),
            "ammo": (read_u8(mem, lo + ammo - 0x14), read_u8(mem, lo + ammo + 0x100)),
            "lamp": ((lamps >> 7) & 1, (lamps >> 4) & 1),
            "credits": read_u8(mem, lo + ptr(mem, lo, 0x2F88C)),
        }


class Deathcox(NaomiTitle):
    """deathcox - Compute_Deathcox_Outputs.

    Fixed addresses: in-game byte 0x982B8 == 1, ammo 0x18E395 (+0x3C for P2,
    enable bytes at +0xC), credits 0x9917C, life as float x100 at credits
    +0x04/+0x08, start lamps as raw bytes 0x98258 / 0x9825C (DemulShooter's
    substitute - the genuine bits were never found for this title).
    """

    name = "deathcox"
    roms = ("deathcox",)
    in_game = (1,)

    def locate(self, mem, lo: int, size: int) -> int | None:
        if self.fits(0x982B8, size) and read_u8(mem, lo + 0x982B8) == 1:
            return 0x982B8
        return None

    def read_values(self, mem, lo: int, state: object) -> dict:
        credits = lo + 0x9917C
        enable1 = read_u8(mem, lo + 0x18E395 + 0xC) == 1
        enable2 = read_u8(mem, lo + 0x18E395 + 0x3C + 0xC) == 1
        return {
            "status": (1 if enable1 else 0, 1 if enable2 else 0),
            "life": (int(read_f32(mem, credits + 0x04) * 100),
                     int(read_f32(mem, credits + 0x08) * 100)),
            "ammo": (read_u8(mem, lo + 0x18E395),
                     read_u8(mem, lo + 0x18E395 + 0x3C)),
            "lamp": (read_u8(mem, lo + 0x98258), read_u8(mem, lo + 0x9825C)),
            "credits": read_u8(mem, credits),
        }


class Deathcoxo(NaomiTitle):
    """deathcoxo - Compute_Deathcoxo_Outputs.

    Same shape as deathcox with different fixed addresses: in-game 0x96680 == 1,
    ammo 0x18BFC9 (+0x3C, enable +0xC), credits 0x974A8, life float x100 at
    credits +0x04/+0x08, genuine lamp bits 7/4 of 0x1C8D16.
    """

    name = "deathcoxo"
    roms = ("deathcoxo",)
    in_game = (1,)

    def locate(self, mem, lo: int, size: int) -> int | None:
        if self.fits(0x96680, size) and read_u8(mem, lo + 0x96680) == 1:
            return 0x96680
        return None

    def read_values(self, mem, lo: int, state: object) -> dict:
        credits = lo + 0x974A8
        enable1 = read_u8(mem, lo + 0x18BFC9 + 0xC) == 1
        enable2 = read_u8(mem, lo + 0x18BFC9 + 0x3C + 0xC) == 1
        lamps = read_u8(mem, lo + 0x1C8D16)
        return {
            "status": (1 if enable1 else 0, 1 if enable2 else 0),
            "life": (int(read_f32(mem, credits + 0x04) * 100),
                     int(read_f32(mem, credits + 0x08) * 100)),
            "ammo": (read_u8(mem, lo + 0x18BFC9),
                     read_u8(mem, lo + 0x18BFC9 + 0x3C)),
            "lamp": ((lamps >> 7) & 1, (lamps >> 4) & 1),
            "credits": read_u8(mem, credits),
        }


class Lupinsho(NaomiTitle):
    """lupinsho - Compute_Lupinsho_Outputs.

    Everything is a float and nothing is dereferenced: game status 0xA4C780 == 1
    means playing, per-player active flags 0xA4C760/0xA4C764 == 1, life
    0xA4C8B0/0xA4C8B4, ammo 0xA4C830/0xA4C834, start lamps bits 7/4 of 0xB77C16,
    credits 0xB69FF8.
    """

    name = "lupinsho"
    roms = ("lupinsho",)
    in_game = (1,)

    def locate(self, mem, lo: int, size: int) -> float | None:
        if not self.fits(0xA4C780, size, 0x2000):
            return None
        status = read_f32(mem, lo + 0xA4C780)
        if status in (0.0, 1.0, 2.0):
            return status
        return None

    def read_values(self, mem, lo: int, state: object) -> dict:
        lamps = read_u8(mem, lo + 0xB77C16)
        return {
            "status": (1, 1),
            "active": (read_f32(mem, lo + 0xA4C760) == 1.0,
                       read_f32(mem, lo + 0xA4C764) == 1.0),
            "life": (int(read_f32(mem, lo + 0xA4C8B0)),
                     int(read_f32(mem, lo + 0xA4C8B4))),
            "ammo": (int(read_f32(mem, lo + 0xA4C830)),
                     int(read_f32(mem, lo + 0xA4C834))),
            "lamp": ((lamps >> 7) & 1, (lamps >> 4) & 1),
            "credits": read_u8(mem, lo + 0xB69FF8),
        }


class Mok(NaomiTitle):
    """mok - Compute_Mok_Outputs.

    P1 block = ram + (read32(ram + 0x23464) & MASK), P2 = P1 + 0x64, status at
    +0x48 (7/8 = playing), ammo +0x58, life +0x5C, credits +0x7C, start lamps
    bits 7/4 of 0xEC396.
    """

    name = "mok"
    roms = ("mok",)
    in_game = (7, 8)

    def locate(self, mem, lo: int, size: int) -> tuple[int, int] | None:
        p1 = ptr(mem, lo, 0x23464)
        if p1 == 0:
            return None
        p2 = p1 + 0x64
        if not self.fits(p1, size) or not self.fits(p2, size):
            return None
        if 1 <= read_u8(mem, lo + p1 + 0x48) <= 9 and \
                1 <= read_u8(mem, lo + p2 + 0x48) <= 9:
            return p1, p2
        return None

    def read_values(self, mem, lo: int, state: object) -> dict:
        p1, p2 = state  # type: ignore[misc]
        lamps = read_u8(mem, lo + 0xEC396)
        return {
            "status": (read_u8(mem, lo + p1 + 0x48),
                       read_u8(mem, lo + p2 + 0x48)),
            "life": (read_u8(mem, lo + p1 + 0x5C), read_u8(mem, lo + p2 + 0x5C)),
            "ammo": (read_u8(mem, lo + p1 + 0x58), read_u8(mem, lo + p2 + 0x58)),
            "lamp": ((lamps >> 7) & 1, (lamps >> 4) & 1),
            "credits": read_u8(mem, lo + p1 + 0x7C),
        }


class Ninjaslt(TitleReader):
    """ninjaslt / ninjaslta / ninjasltj / ninjasltu - Game_FlycastNinjaslt.

    Per-ROM fixed offsets (outputs byte, credits byte, player-data block); the
    in-game test is player-data + 0x1A == 1.  Life and ammo are signed Int16 and
    the players are adjacent in one block; damage comes from an invincibility
    byte (rising edge), not from a life drop.
    """

    name = "ninjaslt"
    roms = ("ninjaslt", "ninjaslta", "ninjasltj", "ninjasltu")
    OFFSETS = {
        "ninjaslt": (0x22C42D, 0x480D0C, 0x3D9CB0),
        "ninjaslta": (0x22C4AD, 0x480D8C, 0x3D9D30),
        "ninjasltj": (0x22C3F1, 0x480CD4, 0x3D9C78),
        "ninjasltu": (0x22C4AD, 0x480D8C, 0x3D9D30),
    }

    def __init__(self, rom: str):
        super().__init__(rom)
        self.outputs, self.credits, self.player = self.OFFSETS[rom]

    def locate(self, mem, lo: int, size: int) -> int | None:
        if not self.fits(self.player, size, 0x100):
            return None
        if read_u8(mem, lo + self.player + 0x1A) == 1:
            return self.player
        return None

    def compute(self, mem, lo: int, state: object) -> dict[str, int]:
        base = lo + self.player  # type: ignore[operator]
        self.last_raw = {"in_game": read_u8(mem, base + 0x1A),
                         "life": (read_i16(mem, base + 0x54),
                                  read_i16(mem, base + 0x56)),
                         "ammo": (read_i16(mem, base + 0x62),
                                  read_i16(mem, base + 0x64))}
        out: dict[str, int] = dict.fromkeys(OUTPUT_NAMES, 0)
        lamps = read_u8(mem, lo + self.outputs)
        out["P1_LmpStart"] = (lamps >> 6) & 1
        out["P2_LmpStart"] = (lamps >> 4) & 1
        out["P1_GunRecoil"] = (lamps >> 7) & 1
        out["P2_GunRecoil"] = (lamps >> 5) & 1
        out["Credits"] = read_u8(mem, lo + self.credits)
        for tag, life_at, ammo_at, dmg_at in (
                ("P1", 0x54, 0x62, 0xBC), ("P2", 0x56, 0x64, 0xBE)):
            life = read_i16(mem, base + life_at)
            out[f"{tag}_Life"] = life
            if life <= 0:
                continue
            ammo = read_i16(mem, base + ammo_at)
            out[f"{tag}_Ammo"] = ammo
            out[f"{tag}_Clip"] = 1 if ammo > 0 else 0
            out[f"{tag}_CtmRecoil"] = self.on_edge(f"{tag}_CtmRecoil", ammo)
            damage = read_u8(mem, base + dmg_at)
            previous = self.last.get(f"{tag}_DmgByte", 0)
            self.last[f"{tag}_DmgByte"] = damage
            if damage and not previous:
                out[f"{tag}_Damaged"] = self.pulse(f"{tag}_Damaged", DAMAGED_ON)
            else:
                out[f"{tag}_Damaged"] = self.pulse_state(f"{tag}_Damaged")
        return out


READERS: tuple[type[TitleReader], ...] = (
    Hotd2, Confmiss, Deathcox, Deathcoxo, Lupinsho, Mok, Ninjaslt,
)


def reader_for(rom: str) -> TitleReader | None:
    for cls in READERS:
        if rom in cls.roms:
            return cls(rom)
    return None


def known_roms() -> list[str]:
    return sorted({rom for cls in READERS for rom in cls.roms})


# ---------------------------------------------------------------- discovery

def find_target() -> tuple[str, str] | None:
    """Return (pid, rom_name) for a running Flycast, or None."""
    try:
        names = os.listdir("/proc")
    except OSError:
        return None
    for name in sorted(names):
        if not name.isdigit():
            continue
        try:
            with open(f"/proc/{name}/comm", encoding="utf-8") as fh:
                comm = fh.read().strip()
            with open(f"/proc/{name}/cmdline", "rb") as fh:
                argv = [a for a in
                        fh.read().decode("utf-8", "replace").split("\0") if a]
        except OSError:
            continue
        if "lycast" not in comm.lower() and \
                not any("flycast_libretro" in a for a in argv):
            continue
        rom = ""
        for arg in reversed(argv):
            if ROM_RE.search(arg):
                rom = os.path.basename(arg)
                break
        return name, ROM_RE.sub("", rom).lower()
    return None


def candidate_blocks(pid: str) -> list[dict]:
    try:
        with open(f"/proc/{pid}/maps") as fh:
            rows = [line.split() for line in fh]
    except OSError:
        return []
    out = []
    for parts in rows:
        low, high = (int(x, 16) for x in parts[0].split("-"))
        size = high - low
        if "rw" not in parts[1] or size < MIN_BLOCK:
            continue
        out.append({"lo": low, "size": size,
                    "path": parts[5] if len(parts) > 5 else ""})
    # Flycast keeps the emulated RAM in its own shared-memory mappings; a plain
    # anonymous block of the same size (the flat guest view) can pass a weak
    # status test, so prefer the shared ones and only then the bigger blocks.
    return sorted(out, key=lambda m: (m["path"].startswith("/dev/shm/"),
                                      m["size"]), reverse=True)


# ---------------------------------------------------------------- daemon

class Publisher:
    """Owns port 8000: handshake on connect, then change-only broadcasts."""

    def __init__(self, port: int, verbose: bool = False):
        self.port = port
        self.verbose = verbose
        self.values: dict[str, int] = dict.fromkeys(OUTPUT_NAMES, 0)
        self.clients: list[socket.socket] = []
        self.lock = threading.Lock()
        self.game: str | None = None
        self.server: socket.socket | None = None

    def start(self) -> bool:
        self.server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            self.server.bind(("127.0.0.1", self.port))
            self.server.listen(5)
        except OSError as exc:
            log(f"cannot listen on 127.0.0.1:{self.port}: {exc}")
            return False
        threading.Thread(target=self._accept_loop, daemon=True).start()
        log(f"listening on 127.0.0.1:{self.port}")
        return True

    def _accept_loop(self) -> None:
        assert self.server is not None
        while True:
            try:
                client, addr = self.server.accept()
            except OSError:
                return
            with contextlib.suppress(OSError):
                client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            with self.lock:
                self.clients.append(client)
            log(f"client connected from {addr[0]}:{addr[1]}")
            self._send_handshake(client)
            self._send_all(client)

    def _write(self, client: socket.socket, text: str) -> None:
        try:
            client.sendall(text.encode("ascii", "replace"))
        except OSError:
            with self.lock:
                if client in self.clients:
                    self.clients.remove(client)

    def _send_handshake(self, client: socket.socket) -> None:
        if self.game:
            self._write(client, "mame_stop = 1\r")
            self._write(client, f"mame_start = {self.game}\r")
        else:
            self._write(client, "mame_start = ___empty\r")

    def _send_all(self, client: socket.socket) -> None:
        """State snapshot; the event outputs (recoil/damage) go out as 0."""
        events = {"P1_CtmRecoil", "P2_CtmRecoil", "P1_Damaged", "P2_Damaged"}
        for name, value in self.values.items():
            self._write(client, f"{name} = {0 if name in events else value}\r")

    def set_game(self, game: str | None) -> None:
        if game == self.game:
            return
        self.game = game
        with self.lock:
            clients = list(self.clients)
        for client in clients:
            self._send_handshake(client)
            self._send_all(client)
        log(f"game hooked: {game}" if game else "game unhooked")

    def update(self, new_values: dict[str, int]) -> None:
        changed = []
        for name, value in new_values.items():
            if self.values.get(name) != value:
                self.values[name] = value
                changed.append((name, value))
        if not changed:
            return
        with self.lock:
            clients = list(self.clients)
        for client in clients:
            for name, value in changed:
                self._write(client, f"{name} = {value}\r")
        if self.verbose:
            log("changed: " + ", ".join(f"{n}={v}" for n, v in changed))

    def close(self) -> None:
        with self.lock:
            for client in self.clients:
                with contextlib.suppress(OSError):
                    client.close()
            self.clients.clear()
        if self.server is not None:
            with contextlib.suppress(OSError):
                self.server.close()


class Target:
    """A Flycast process, its ROM, its reader, and (once found) its RAM block."""

    def __init__(self, pid: str, rom: str, reader: TitleReader):
        self.pid = pid
        self.rom = rom
        self.reader = reader
        self.ram: int | None = None
        self.state: object | None = None
        self.checked = 0.0

    def reset_ram(self) -> None:
        self.ram = None
        self.state = None

    def location(self) -> tuple[int, object] | None:
        if self.ram is None or self.state is None:
            return None
        return self.ram, self.state


def locate_ram(mem, target: Target) -> tuple[int, object, dict] | None:
    """Pick the RAM block whose pointer chain validates, or None.

    Candidate order matters: Flycast's own shared-memory mappings come first, so
    a not-yet-validated block early in a title's boot must not let a weaker
    anonymous mapping win - the caller re-checks and switches when a better one
    starts validating.
    """
    for block in candidate_blocks(target.pid):
        found = target.reader.locate(mem, block["lo"], block["size"])
        if found is not None:
            return block["lo"], found, block
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=PORT)
    ap.add_argument("--poll", type=float, default=POLL)
    ap.add_argument("--rom", default=None, help="override the detected rom name")
    ap.add_argument("--print", action="store_true",
                    help="print the state instead of serving port 8000")
    ap.add_argument("--list-blocks", action="store_true")
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--debug", action="store_true",
                    help="log the raw per-title state each second")
    ap.add_argument("--log", default=None)
    args = ap.parse_args()

    publisher: Publisher | None = None
    if not args.print:
        publisher = Publisher(args.port, args.verbose)
        if not publisher.start():
            return 1

    target: Target | None = None
    last_print = 0.0
    last_debug = 0.0
    prev_print: dict[str, int] = {}

    log(f"started (poll {args.poll}s, rom override {args.rom})", args.log)
    while True:
        if target is not None and not os.path.exists(f"/proc/{target.pid}"):
            log("target exited", args.log)
            target = None
            if publisher:
                publisher.set_game(None)
        if target is None:
            found = find_target()
            if found is None:
                if publisher:
                    publisher.set_game(None)
                time.sleep(1)
                continue
            pid, rom = found
            rom = args.rom or rom
            reader = reader_for(rom)
            if reader is None:
                log(f"title '{rom}' has no reader "
                    f"(known: {', '.join(known_roms())})", args.log)
                time.sleep(3)
                continue
            target = Target(pid, rom, reader)
            if args.list_blocks:
                try:
                    with open(f"/proc/{pid}/mem", "rb", 0) as mem:
                        for block in candidate_blocks(pid):
                            hit = reader.locate(mem, block["lo"], block["size"])
                            log(f"  block 0x{block['lo']:x} "
                                f"{block['size'] // 1048576}MB "
                                f"{block['path'] or '(anon)'} -> {hit}")
                except OSError as exc:
                    log(f"read error: {exc}", args.log)
                return 0
            log(f"attached to pid {pid} ({rom}, reader {reader.name})", args.log)
            if publisher:
                publisher.set_game(rom)

        now = time.time()
        try:
            with open(f"/proc/{target.pid}/mem", "rb", 0) as mem:
                location = target.location()
                if location is None or now - target.checked >= RELOCATE_SECONDS:
                    target.checked = now
                    found = locate_ram(mem, target)
                    if found is None:
                        if location is None:
                            time.sleep(0.5)
                            continue
                    else:
                        lo, state, block = found
                        if location is None or lo != location[0]:
                            log(f"RAM block 0x{lo:x} "
                                f"({block['size'] // 1048576}MB "
                                f"{block['path'] or '(anon)'}), state {state}",
                                args.log)
                        target.ram, target.state = lo, state
                        location = target.ram, target.state
                values = target.reader.compute(mem, location[0], location[1])
        except OSError as exc:
            log(f"read error: {exc}", args.log)
            target.reset_ram()
            time.sleep(0.5)
            continue

        if args.print:
            if now - last_print >= 1.0 or values != prev_print:
                print(time.strftime("%H:%M:%S"), " ".join(
                    f"{n}={values[n]}" for n in OUTPUT_NAMES), flush=True)
                last_print = now
            prev_print = dict(values)
        elif publisher:
            publisher.update(values)
        if args.debug and now - last_debug >= 1.0:
            log(f"raw: {getattr(target.reader, 'last_raw', None)}", args.log)
            last_debug = now
        time.sleep(args.poll)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        sys.exit(0)
