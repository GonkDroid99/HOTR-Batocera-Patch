#!/usr/bin/env python3
"""Firmware-faithful Sinden lightgun test double.

This is *not* a generic fake serial device: every command it accepts and every
reply it emits was derived from the real AVR firmware image (see
``reference/sinden-firmware-notes.md``), so the tests can measure what HOTR
puts on the wire without owning a gun.

Fidelity rules encoded here (firmware byte addresses in brackets):

* frame format ``AA cmd p1 p2 p3 p4 BB`` (7 bytes, no checksum); the parser
  resynchronises on a bad header/trailer exactly like the firmware state
  machine at 0x5340.
* commands that transmit to the host: ``A0`` [0x5FB0] 4 bytes, ``A7`` [0x61BA]
  4 bytes, ``AB`` [0x6230] 4 bytes, ``AC`` [0x62C4] 3 bytes, plus the
  diagnostic/config range ``0x64``-``0x9E`` [0x5706..0x5F70].
* commands that are silent: ``A1`` [0x6064], ``A2`` [0x6082], ``A3`` [0x60EC],
  ``A4`` [0x6106], ``A5`` [0x6160], ``A8`` [0x621E], ``A9`` [0x6224],
  ``AA`` [0x622A], ``AD`` [0x62FA], ``B4``-``B9`` [0x631A..0x64D0] and every
  command whose table entry points at the no-op handler 0x60E4.
* nothing is ever sent unsolicited: the gun only answers.
* the handshake replies with ``SHA256(host_digest || salt)`` because that is
  exactly what LightgunMono compares the reply against, then ``true\\r\\n``.

Modes for testing:
  --reply-mode firmware   behave exactly as above (default)
  --reply-mode silent     never answer (models a link with the gun muted)
  --reply-mode all        answer every command (worst case "noisy" device, used
                          to prove that HOTR never forwards gun bytes into
                          LightgunMono's serial stream)

Usage:
  scripts/tests/fake-gun-firmware-faithful.py --pty --report /tmp/gun.json
  scripts/tests/fake-gun-firmware-faithful.py --verify-firmware LightgunFirmwareRed.bin
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
import pty
import select
import signal
import sys
import termios
import time
import tty

FRAME_START = 0xAA
FRAME_END = 0xBB
FRAME_SIZE = 7

# --- constants copied from the firmware image (flash -> RAM 0x0100 mapping) ---
STRING_96 = b"123456789012345678901234567890127892568384634798502342579843579823453487956729736275846274839290"
STRING_70 = b"1234567890123456789012345678901260341663085532170074617363215964123456"
STRING_73 = b"ThisSpaceIsBlankThisSpaceIsBlankSindenLightgun364294735243894HaveANiceDay"
SALT = STRING_73[32:]                       # SindenLightgun364294735243894HaveANiceDay
PHASE2_CHALLENGE = STRING_70[:32]           # 12345678901234567890123456789012
PHASE2_CONSTANT = STRING_70[32:]            # 60341663085532170074617363215964123456
TRUE_LINE = b"true\r\n"
DIAG_TEXT = b"YesImSindenLightgun\r\n"

# command -> handler byte address, rebuilt from the firmware dispatch table
# (word at flash 0x8C + 2*cmd, doubled to a byte address).
HANDLER_COMMANDS: dict[int, tuple[int, ...]] = {
    0x5528: (0x30,),
    0x552E: (0x31,),
    0x5536: (0x32,),
    0x553E: (0x33,),
    0x5544: (0x36,),
    0x554C: (0x37,),
    0x5552: (0x3C,),
    0x5576: (0xBA,),
    0x5706: (0x64,),
    0x5718: (0x65,),
    0x5724: (0x66,),
    0x5744: (0x67,),
    0x5754: (0x68,),
    0x576C: (0x69,),
    0x5784: (0x6A,),
    0x579A: (0x6B,),
    0x57B6: (0x6F,),
    0x585E: (0x70,),
    0x5876: (0x71,),
    0x58C4: (0x72,),
    0x58E0: (0x73,),
    0x5944: (0x74,),
    0x595C: (0x75,),
    0x599C: (0x76,),
    0x59B4: (0x78,),
    0x59BA: (0x6C,),
    0x59C6: (0x6D,),
    0x5B9E: (0x6E,),
    0x5C88: (0x79,),
    0x5D18: (0x96,),
    0x5D8A: (0x97,),
    0x5DE4: (0x98,),
    0x5E12: (0x99,),
    0x5E82: (0x9A,),
    0x5EAE: (0x77,),
    0x5EB6: (0x9B,),
    0x5F10: (0x9C,),
    0x5F3E: (0x9D,),
    0x5F70: (0x9E,),
    0x5FB0: (0xA0,),
    0x6064: (0xA1,),
    0x6082: (0xA2,),
    0x60EC: (0xA3,),
    0x6106: (0xA4,),
    0x6160: (0xA5,),
    0x61BA: (0xA7,),
    0x621E: (0xA8,),
    0x6224: (0xA9,),
    0x622A: (0xAA,),
    0x6230: (0xAB,),
    0x62C4: (0xAC,),
    0x62FA: (0xAD,),
    0x631A: (0xB4,),
    0x6334: (0xB5,),
    0x634E: (0xB6,),
    0x645E: (0xB7,),
    0x6478: (0xB8,),
    0x64D0: (0xB9,),
    0x64D8: (0x28,),
    0x64E6: (0x29,),
}
NOOP_HANDLER = 0x60E4
NOOP_COMMANDS = (
    0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F, 0x34, 0x35, 0x38, 0x39, 0x3A, 0x3B,
    0x3D, 0x3E, 0x3F, 0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
    0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F, 0x50, 0x51, 0x52, 0x53, 0x54,
    0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x5B, 0x5C, 0x5D, 0x5E, 0x5F, 0x60,
    0x61, 0x62, 0x63, 0x7A, 0x7B, 0x7C, 0x7D, 0x7E, 0x7F, 0x80, 0x81, 0x82,
    0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8A, 0x8B, 0x8C, 0x8D, 0x8E,
    0x8F, 0x90, 0x91, 0x92, 0x93, 0x94, 0x95, 0x9F, 0xA6, 0xAE, 0xAF, 0xB0,
    0xB1, 0xB2, 0xB3,
)
TABLE_BASE = 0x8C  # flash offset of the command dispatch table

# Commands HOTR must never put on the wire (they make the firmware talk back).
REPLYING_COMMANDS = frozenset([0xA0, 0xA7, 0xAB, 0xAC])
DIAG_COMMANDS = frozenset([0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6D, 0x6E, 0x6F,
                           0x71, 0x73, 0x77, 0x96, 0x97, 0x98, 0x99, 0x9A,
                           0x9B, 0x9C, 0x9D, 0x9E])
DIAG_REPLY_LENGTH = {0x64: 0, 0x65: 2, 0x66: 1, 0x67: 2, 0x68: 2, 0x69: 1,
                     0x6D: 1, 0x6E: 1, 0x6F: 9, 0x71: 4, 0x73: 5, 0x77: 4,
                     0x96: 8, 0x97: 4, 0x98: 4, 0x99: 4, 0x9A: 4, 0x9B: 4,
                     0x9C: 3, 0x9D: 12, 0x9E: 8}
WHITELIST_COMMANDS = frozenset([0xA1, 0xA2, 0xA3, 0xA4, 0xA8])


def handler_for(command: int) -> int | None:
    """Firmware handler byte address for a command byte (None = out of range)."""
    if not 0x28 <= command < 0xBA:
        return None
    for handler, commands in HANDLER_COMMANDS.items():
        if command in commands:
            return handler
    return NOOP_HANDLER


def verify_firmware(path: str) -> int:
    """Re-derive the dispatch table from a decoded image and compare it."""
    with open(path, "rb") as handle:
        image = handle.read()
    if len(image) < 0x8C + 2 * 0xBA:
        print(f"[FAIL] {path} is too small to contain the dispatch table")
        return 1
    problems = []
    for command in range(0x28, 0xBA):
        offset = TABLE_BASE + 2 * command
        word = image[offset] | (image[offset + 1] << 8)
        expected = handler_for(command)
        if 2 * word != expected:
            problems.append((command, 2 * word, expected))
    if problems:
        for command, found, expected in problems:
            print(f"[FAIL] cmd {command:02x}: image says 0x{found:04x} "
                  f"expected 0x{expected:04x}")
        return 1
    print(f"[PASS] dispatch table matches {path} "
          f"({len(HANDLER_COMMANDS) + len(NOOP_COMMANDS)} commands checked)")
    return 0


class FakeGun:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.ram = dict(args.state)
        self.fd = -1
        self.slave_path: str | None = None
        self.buffer = bytearray()
        self.state = "idle"          # idle | wait_digest | wait_hash
        self.frames: dict[str, int] = {}
        self.frame_log: list[str] = []
        self.replies: dict[str, dict[str, object]] = {}
        self.handshake: dict[str, object] = {"6e": 0, "6d": 0, "true_sent": False}
        self.handshake_6e = 0
        self.handshake_6d = 0
        self.errors: list[str] = []
        self.bytes_sent = 0
        self.sent_unsolicited = False
        self.started = time.time()
        self.running = True
        self.slave_fd: int | None = None

    # -- plumbing ---------------------------------------------------------
    def open_channel(self) -> None:
        if self.args.pty:
            master, slave = pty.openpty()
            tty.setraw(slave)          # the gun owns the line discipline
            self.fd = master
            # Keep a slave descriptor open: with no slave attached, reads on the
            # master return EIO/EOF and the fake gun would stop immediately. Any
            # number of processes may open the same slave node afterwards.
            self.slave_fd = slave
            self.slave_path = os.ttyname(slave)
        else:
            self.fd = os.open(self.args.device, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
            self.slave_path = self.args.device
            with contextlib.suppress(termios.error):
                tty.setraw(self.fd)

    def close_channel(self) -> None:
        for fd in (self.fd, getattr(self, "slave_fd", None)):
            if fd is None:
                continue
            with contextlib.suppress(OSError):
                os.close(fd)


    def send(self, data: bytes) -> None:
        if not data:
            return
        self.bytes_sent += len(data)
        os.write(self.fd, data)
        if self.args.verbose:
            print(f"[gun] -> host {data.hex(' ')}", flush=True)

    def save_report(self) -> None:
        if not self.args.report:
            return
        report = {
            "role": "fake-gun-firmware-faithful",
            "reply_mode": self.args.reply_mode,
            "handshake_mode": self.args.handshake_mode,
            "slave_path": self.slave_path,
            "uptime_seconds": round(time.time() - self.started, 3),
            "frames": self.frames,
            "frame_log": self.frame_log[-100:],
            "replies": self.replies,
            "bytes_sent": self.bytes_sent,
            "sent_unsolicited": self.sent_unsolicited,
            "handshake": self.handshake,
            "errors": self.errors,
            "replying_commands_seen": sorted(
                f"0x{int(cmd, 16):02x}" for cmd in self.frames
                if int(cmd, 16) in REPLYING_COMMANDS),
        }
        tmp = f"{self.args.report}.tmp"
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(report, handle, indent=2, sort_keys=True)
        os.replace(tmp, self.args.report)

    def stop(self, *_args: object) -> None:
        self.running = False

    # -- protocol ---------------------------------------------------------
    def handle_frame(self, command: int, payload: bytes) -> None:
        key = f"{command:02x}"
        self.frames[key] = self.frames.get(key, 0) + 1
        self.frame_log.append((bytes([0xAA, command]) + (payload + b"\x00" * 4)[:4] + bytes([0xBB])).hex(" "))
        if self.args.verbose:
            print(f"[gun] <- host cmd {key} payload {payload.hex(' ')}", flush=True)

        if command == 0x6E:
            self.handshake_6e += 1
            self.handshake["6e"] = self.handshake_6e
            if self.args.handshake_mode == "off":
                self.save_report()
                return
            self.state = "wait_digest"
            self.save_report()
            return
        if command == 0x6D:
            self.handshake_6d += 1
            self.handshake["6d"] = self.handshake_6d
            if self.args.handshake_mode == "off":
                self.save_report()
                return
            self.send(PHASE2_CHALLENGE)
            self.state = "wait_hash"
            self.save_report()
            return
        if command == 0x79:
            self.apply_handler(command, payload)   # table handler is silent
            self.save_report()
            return

        reply = self.reply_bytes(command, payload)
        self.apply_handler(command, payload)
        if self.args.reply_mode == "silent":
            reply = b""
        elif self.args.reply_mode == "all" and not reply:
            reply = bytes([command])
        if reply:
            self.replies[key] = {"hex": reply.hex(" "), "count": len(reply)}
            self.send(reply)
        self.save_report()

    def reply_bytes(self, command: int, payload: bytes) -> bytes:
        """Firmware-derived reply for a command (empty = silent)."""
        if command == 0xA0:
            return bytes([self.ram[0x424], self.ram[0x36D], self.ram[0x36E],
                          self.ram[0x36F]])
        if command == 0xA7:
            return bytes(self.ram[address] for address in (0x36C, 0x36D, 0x36E, 0x36F))
        if command == 0xAB:
            result = (payload[0] + payload[1] + payload[2] + payload[3]) & 0xFF
            return bytes([self.ram[0x2ED], self.ram[0x2EE], self.ram[0x2EF], result])
        if command == 0xAC:
            return bytes(self.ram[address] for address in (0x36D, 0x36E, 0x36F))
        if command in DIAG_COMMANDS:
            if command in (0x64, 0x6D):
                return DIAG_TEXT
            return bytes(DIAG_REPLY_LENGTH.get(command, 0))
        return b""

    def apply_handler(self, command: int, payload: bytes) -> None:
        """Minimal state model of the silent handlers (no bytes to the host)."""
        p1, p2, p3, p4 = payload
        if command == 0xA1:
            self.ram[0x346] = 1 if p1 == 1 else 0
        elif command == 0xA2:
            self.ram[0x30A], self.ram[0x309] = p1, p1
            self.ram[0x30C], self.ram[0x30B] = p3, p3
            self.ram[0x307], self.ram[0x308] = p4, 0
        elif command == 0xA3:
            self.ram[0x345] = 1 if p1 == 1 else 0
        elif command == 0xA4:
            for address, value in zip((0x344, 0x343, 0x342, 0x341),
                                      (p1, p2, p3, p4), strict=True):
                self.ram[address] = 1 if value == 1 else 0
        elif command == 0xA5:
            for address, value in zip((0x340, 0x33F, 0x33E, 0x33D),
                                      (p1, p2, p3, p4), strict=True):
                self.ram[address] = 1 if value == 1 else 0
        elif command == 0xA7:
            self.ram[0x4EA], self.ram[0x4EB] = p1, (~p1) & 0xFF
        elif command == 0xAC:
            self.ram[0x305], self.ram[0x306] = p1, 0
        elif command == 0xAD:
            self.ram[0x33C] = 1 if p1 == 1 else 0
        elif command == 0xB4:
            self.ram[0x33B] = 1 if p1 == 1 else 0
        elif command == 0xB5:
            self.ram[0x108] = 1 if p1 == 1 else 0
        elif command == 0xB7:
            self.ram[0x339] = 1 if p1 == 1 else 0
        elif command == 0xB9:
            self.ram[0x338] = 1

    def handle_digest(self) -> None:
        digest = bytes(self.buffer[:32])
        del self.buffer[:32]
        expected = hashlib.sha256(digest + SALT).digest()
        self.send(expected)
        self.handshake["phase1_reply"] = expected.hex()
        self.state = "idle"
        self.save_report()

    def handle_hash(self) -> None:
        supplied = bytes(self.buffer[:32])
        del self.buffer[:32]
        expected = hashlib.sha256((PHASE2_CHALLENGE + PHASE2_CONSTANT)[:64]).digest()
        ok = supplied == expected
        self.handshake["phase2_ok"] = ok
        if self.args.handshake_mode == "firmware" and not ok:
            self.errors.append("phase-2 hash mismatch")
            self.state = "idle"
            self.save_report()
            return
        self.send(TRUE_LINE)
        self.handshake["true_sent"] = True
        self.state = "idle"
        self.save_report()

    def consume(self, data: bytes) -> None:
        self.buffer.extend(data)
        progress = True
        while progress:
            progress = False
            if self.state == "wait_digest":
                if len(self.buffer) >= 32:
                    self.handle_digest()
                    progress = True
                continue
            if self.state == "wait_hash":
                if len(self.buffer) >= 32:
                    self.handle_hash()
                    progress = True
                continue
            if len(self.buffer) < FRAME_SIZE:
                continue
            if self.buffer[0] != FRAME_START or self.buffer[FRAME_SIZE - 1] != FRAME_END:
                self.errors.append(
                    f"resync: dropped byte 0x{self.buffer[0]:02x} at "
                    f"t+{time.time() - self.started:.3f}s")
                del self.buffer[0]
                progress = True
                continue
            command = self.buffer[1]
            payload = bytes(self.buffer[2:6])
            del self.buffer[:FRAME_SIZE]
            self.handle_frame(command, payload)
            progress = True

    def run(self) -> int:
        self.open_channel()
        if self.args.pty:
            print(self.slave_path, flush=True)
        signals = (signal.SIGTERM, signal.SIGINT)
        for sig in signals:
            signal.signal(sig, self.stop)
        self.save_report()
        deadline = time.time() + self.args.timeout if self.args.timeout else None
        # Only watch stdin in an interactive session: a script launching the gun
        # with an exhausted stdin must not be mistaken for a stop request.
        interactive = sys.stdin.isatty()
        while self.running:
            if deadline and time.time() > deadline:
                break
            if self.args.expect_frames and sum(self.frames.values()) >= self.args.expect_frames:
                break
            watches = [self.fd, sys.stdin] if interactive else [self.fd]
            ready, _, _ = select.select(watches, [], [], 0.2)
            if self.fd in ready:
                try:
                    data = os.read(self.fd, 4096)
                except OSError:
                    break
                if not data:
                    break
                self.consume(data)
            if interactive and sys.stdin in ready and not sys.stdin.readline():
                break
        self.save_report()
        self.close_channel()
        if self.args.fail_on_reply and self.bytes_sent:
            print(f"[FAIL] fake gun answered {self.bytes_sent} byte(s); "
                  "the host link is not quiet", file=sys.stderr)
            return 2
        return 1 if (self.args.handshake_mode == "firmware"
                     and self.handshake.get("phase2_ok") is False) else 0


def parse_state(values: list[str]) -> list[tuple[int, int]]:
    state = []
    for item in values:
        for pair in item.split(","):
            pair = pair.strip()
            if not pair:
                continue
            address, _, value = pair.partition("=")
            state.append((int(address, 0), int(value, 0)))
    return state


def dump_table() -> None:
    for command in range(0x28, 0xBA):
        handler = handler_for(command)
        kind = ("reply" if command in REPLYING_COMMANDS or command in DIAG_COMMANDS
                else "silent")
        print(f"  cmd 0x{command:02x} -> handler 0x{handler:04x}  {kind}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--pty", action="store_true",
                        help="create a PTY pair and print the slave path")
    parser.add_argument("--device", help="existing tty to attach to (e.g. a PTY slave)")
    parser.add_argument("--report", help="write a JSON activity report here")
    parser.add_argument("--state", action="append", default=[],
                        help="seed firmware RAM, e.g. --state 0x36C=0x11,0x36D=0x22")
    parser.add_argument("--reply-mode", choices=("firmware", "silent", "all"),
                        default="firmware")
    parser.add_argument("--handshake-mode", choices=("firmware", "lenient", "off"),
                        default="firmware")
    parser.add_argument("--timeout", type=float, default=0,
                        help="stop after N seconds (0 = run until killed)")
    parser.add_argument("--expect-frames", type=int, default=0,
                        help="stop after N host frames")
    parser.add_argument("--fail-on-reply", action="store_true",
                        help="exit non-zero if the gun had to answer anything")
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--verify-firmware", metavar="IMAGE",
                        help="check the embedded dispatch table against a decoded image")
    parser.add_argument("--dump-table", action="store_true")
    args = parser.parse_args()

    if args.verify_firmware:
        return verify_firmware(args.verify_firmware)
    if args.dump_table:
        dump_table()
        return 0
    if not args.pty and not args.device:
        parser.error("one of --pty or --device is required")
    args.state = parse_state(args.state)
    return FakeGun(args).run()


if __name__ == "__main__":
    sys.exit(main())
