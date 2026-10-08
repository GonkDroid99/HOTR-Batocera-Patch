#!/usr/bin/env python3
"""Bridge HOTR's Sinden TCP protocol to Sinden serial.

With a physical device the default backend writes to the gun's serial port
**write-only, per burst**: LightgunMono keeps owning the tty and its termios and
the broker never reads from it, so aiming cannot be disturbed. The retired
``--pty-bridge`` backend (also used by ``--worker``) owns the tty itself,
presents a PTY to LightgunMono and forwards bytes in both directions; it is kept
for hardware comparison only. ``--simulate`` never opens hardware and is used by
the self-test.
"""

from __future__ import annotations

import argparse
import errno
import json
import logging
import os
import pty
import re
import selectors
import socket
import termios
import time
import tty
from contextlib import suppress
from dataclasses import dataclass
from logging.handlers import RotatingFileHandler
from pathlib import Path
from typing import cast

START = 0xAA
END = 0xBB


def frame(command: int, *payload: int) -> bytes:
    values = list(payload[:4])
    values.extend([0] * (4 - len(values)))
    return bytes([START, command, *values, END])


def parse_hotr_command(text: str) -> tuple[str, str] | None:
    value = "".join(text.strip().split()).upper()
    if not value:
        return None
    # HOTR writes the same command text down every gun's socket and identifies
    # the player by the connection, so an unprefixed command must follow the
    # socket that carried it ("" target) rather than being pinned to player 1.
    # "1"/"2" address one player explicitly, "B" addresses all of them.
    target = value[0] if value[0] in "12B" else ""
    command = value[1:] if target else value
    return (target, command) if command else None


#: The only commands the broker may emit. The decoded firmware image
#: (reference/sinden-firmware-notes.md) shows these handlers write no bytes back to
#: the host: A1, A2, A3, A4 and A8. A0/A7/AB/AC answer the host, A9/AA only queue
#: internal events whose field semantics are unverified, and 0x64-0x9E are
#: diagnostics that transmit; none of them may leave this process.
SAFE_COMMANDS = (0xA1, 0xA2, 0xA3, 0xA4, 0xA8)

#: "Normal" per-gun settings from the Sinden presets, reused for HOTR's legacy
#: strength commands so an A2 frame always carries all four fields.
NORMAL_PULSE_DELAY = 13

#: Gap between the frames of one command (F7 pattern: configuration frame, short
#: pause, fire frame) when the broker owns the write path.
DIRECT_BURST_DELAY = 0.02

#: Devices that are real kernel ttys and therefore get the tracker gate by
#: default. A ``/dev/pts`` PTY or a regular file is a test fixture and is never
#: blocked.
DIRECT_DEVICE_PREFIXES = ("/dev/ttyACM", "/dev/ttyUSB", "/dev/serial/by-id/")

#: LightgunMono's portable config: Batocera's Sinden helper writes it under
#: ``/var/run/sinden/p<parent-hash>/`` and points ``SerialPortWrite`` at the tty
#: Mono has open. The directory name is the evdev parent hash, not a player
#: number, so the port value is the only reliable association.
TRACKER_CONFIG_GLOB = "p*/LightgunMono-*.exe.config"
TRACKER_ROOT = Path("/var/run/sinden")
DEFAULT_STATE_FILE = Path("/userdata/system/hotr/sinden-broker-state.json")

#: The broker log is capped at the same size as the service's HOTR log. Rotating
#: inside the broker keeps a machine that never restarts the service from filling
#: /userdata with serial frame lines; scripts/hotr-service rotates an oversized
#: legacy file on start as well.
DEFAULT_SINDEN_LOG_MAX_BYTES = 1048576
SERIAL_PORT_WRITE_RE = re.compile(r'key="SerialPortWrite"\s+value="([^"]+)"')
TRACKER_POLL_SECONDS = 1.0

#: F7: guns are resolved by USB id, never by tty number. The firmware notes
#: record the same pair for the real hardware.
SINDEN_USB_IDS = {"16c0:0f39": "1", "16c0:0f01": "2"}
SYSFS_TTY_ROOT = Path("/sys/class/tty")
DEV_ROOT = Path("/dev")


class UnsafeFrame(ValueError):
    """A frame that is not on the firmware-verified whitelist."""


def assert_safe_frame(frame_bytes: bytes) -> None:
    """Reject everything that is not a whitelisted, firmware-verified frame.

    The gun answers A0/A7/AB/AC (and the 0x64-0x9E diagnostics) with bytes of its
    own. Those bytes travel back up the same link LightgunMono reads from and can
    desynchronise its protocol, which is what stops the gun tracking. This gate is
    the single place that decides whether a frame may be written, so the whitelist
    is enforced mechanically instead of by review.
    """
    if len(frame_bytes) != 7:
        raise UnsafeFrame(f"frame length {len(frame_bytes)} is not 7")
    if frame_bytes[0] != START or frame_bytes[6] != END:
        raise UnsafeFrame(f"frame is not AA..BB delimited: {frame_bytes.hex(' ')}")
    command = frame_bytes[1]
    if command not in SAFE_COMMANDS:
        allowed = " ".join(f"0x{value:02X}" for value in SAFE_COMMANDS)
        raise UnsafeFrame(f"command 0x{command:02X} is not whitelisted (allowed: {allowed})")
    if command == 0xA1 and frame_bytes[2] != 1:
        # F9: A1 0 makes the firmware swallow the next trigger pull and can fire
        # slow repeats by itself. Muting is A2 with strength 0.
        raise UnsafeFrame("A1 is only allowed with value 1; mute with A2 strength 0")


def command_frames(command: str) -> list[bytes] | None:
    """Translate HOTR's Sinden TCP commands to native serial frames.

    Every frame returned here is drawn from the firmware-verified set that writes
    nothing back to the host (A1/A2/A3/A4/A8). Commands with no verified framing
    are refused and logged instead of guessed at.
    """
    op = command[0]
    if op in {"A", "S"}:
        # Recovered from Lightgun.exe::FireSingleRecoil().
        return [frame(0xA8)]
    if op == "B":
        logging.warning("refusing command %s: A9 only queues an internal event and its "
                        "fields are unverified, so HOTR does not emit it", command)
        return None
    if op == "C":
        logging.warning("refusing command %s: AA only queues an internal event and its "
                        "fields are unverified, so HOTR does not emit it", command)
        return None
    if op == "D":
        return [frame(0xA3, 0)]
    if op == "E":
        return [frame(0xA3, 1)]
    if op == "N" and command[1:].isdigit():
        # A7 was dropped: the firmware answers it, so the strength now travels in
        # the A2 frame that the F/G/H/I presets already used for the same value.
        value = max(0, min(255, int(command[1:]) * 10))
        return [frame(0xA2, value, 0, value, NORMAL_PULSE_DELAY)]
    if op in {"F", "G", "H", "I"}:
        # Sinden's TCP server applies these presets by sending A2, A7 and A3
        # configuration frames. Values match the executable's built-in presets:
        # mixed, automatic-normal, automatic-fast, automatic-strong. The A7 frame
        # is dropped because the firmware replies to it; A2 already carries the
        # strength.
        presets = {
            "F": (80, 5, 13),
            "G": (40, 0, 3),
            "H": (50, 0, 9),
            "I": (60, 0, 13),
        }
        strength, start_delay, pulse_delay = presets[op]
        return [
            frame(0xA2, strength, start_delay, strength, pulse_delay),
            frame(0xA3, 1),
        ]
    if op == "J" and len(command) == 2 and command[1] in "01":
        if command[1] == "0":
            # F9: muting with A1 0 makes the firmware swallow the next trigger
            # pull. An A2 frame with strength 0 mutes without that side effect.
            return [frame(0xA2, 0, 0, 0, 0)]
        return [frame(0xA1, 1)]
    if op == "K" and len(command) == 2 and command[1] in "01":
        return [frame(0xA4, int(command[1]), 0, 0, 0)]
    if op in {"P", "Q", "R"} and command[1:].isdigit():
        value = max(0, min(255, int(command[1:])))
        # A2 contains strength, start delay, strength and pulse delay. Keep
        # the other values at the executable's normal defaults.
        if op == "P":
            return [frame(0xA2, value, 0, value, NORMAL_PULSE_DELAY)]
        if op == "Q":
            return [frame(0xA2, 50, 0, 50, value)]
        return [frame(0xA2, 50, value, 50, NORMAL_PULSE_DELAY)]
    if op == "U" and command[1:].isdigit():
        # A7 was dropped; the strength travels in A2 and A8 still fires the burst.
        value = max(0, min(255, int(command[1:]) * 10))
        return [frame(0xA2, value, 0, value, NORMAL_PULSE_DELAY), frame(0xA8)]
    logging.warning("refusing unknown command %r: no firmware-verified framing", command)
    return None


def command_frame(command: str) -> bytes | None:
    """Compatibility helper for callers that need the first frame only."""
    packets = command_frames(command)
    return packets[0] if packets else None


def configured_ports(config: Path) -> dict[int, set[str]]:
    """Read Sinden TCP ports and player numbers from HOTR's V3 data file."""
    try:
        lines = [line.strip() for line in config.read_text(encoding="utf-8").splitlines()]
    except OSError as exc:
        logging.warning("cannot read %s: %s", config, exc)
        return {}

    result: dict[int, set[str]] = {}
    for index, line in enumerate(lines):
        if not line.startswith("Light Gun #"):
            continue
        try:
            end = lines.index("END_GENERAL_SETTINGS", index + 1)
            port = int(lines[end + 1])
            player = lines[end + 2]
        except (IndexError, ValueError):
            continue
        if 1024 <= port <= 65535 and player in ("0", "1"):
            result.setdefault(port, set()).add(str(int(player) + 1))
    return result


def make_raw(fd: int) -> None:
    tty.setraw(fd)
    attrs = termios.tcgetattr(fd)
    attrs[2] |= termios.CLOCAL | termios.CREAD
    termios.tcsetattr(fd, termios.TCSANOW, attrs)


def configure_serial(fd: int) -> None:
    """Configure the physical Sinden UART as 115200 8N1.

    Only the retired ``--pty-bridge`` path calls this: the direct backend never
    touches termios, because LightgunMono's own configuration must stay in force.
    """
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0
    attrs[1] = 0
    attrs[2] = (attrs[2] & ~(termios.PARENB | termios.CSTOPB | termios.CSIZE)) | termios.CS8 | termios.CLOCAL | termios.CREAD
    attrs[3] = 0
    attrs[4] = termios.B115200
    attrs[5] = termios.B115200
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)


@dataclass
class GunChannel:
    player: str
    device_path: str | None = None
    physical: int | None = None
    bridge: bool = False
    simulate: bool = False
    capture: Path | None = None
    pty_master: int | None = None
    pty_slave: int | None = None
    pty_path: str | None = None
    require_tracker: bool = False
    tracker_ready: bool = False
    tracker_drop_logged: bool = False
    missing_logged: bool = False
    usb_id: str | None = None
    sent: int = 0
    dropped: int = 0
    refused: int = 0
    reply_bytes: int = 0
    last_frame: str | None = None
    last_frame_time: str | None = None
    last_frame_monotonic: float | None = None
    last_reason: str | None = None
    last_drop: str | None = None
    last_reply: str | None = None
    last_refusal: str | None = None

    @property
    def direct(self) -> bool:
        """True when this channel itself owns and writes the real gun tty."""
        return self.device_path is not None and not self.bridge

    @property
    def backend(self) -> str:
        """Name the active backend for status, diagnostics and the state file."""
        if self.direct:
            return "direct"
        if self.bridge:
            return "bridge"
        if self.simulate:
            return "simulate"
        return "none"

    def frame_age(self) -> int | None:
        """Seconds since the last delivered frame (None if none yet)."""
        if self.last_frame_monotonic is None:
            return None
        return int(time.monotonic() - self.last_frame_monotonic)

    def start(self) -> None:
        if self.direct:
            logging.info(
                "player %s: direct write-only backend on %s (LightgunMono keeps the tty)%s",
                self.player,
                self.device_path,
                f", USB {self.usb_id}" if self.usb_id else "",
            )
            return
        if self.physical is None:
            if self.simulate:
                logging.info("player %s: simulation backend enabled", self.player)
            else:
                logging.warning(
                    "player %s: no Sinden gun is attached; recoil frames will be dropped",
                    self.player,
                )
            return
        configure_serial(self.physical)
        make_raw(self.physical)
        self.pty_master, self.pty_slave = pty.openpty()
        make_raw(self.pty_master)
        self.pty_path = os.ttyname(self.pty_slave)
        logging.info("player %s: physical fd bridged through %s", self.player, self.pty_path)

    def send(self, data: bytes, reason: str) -> None:
        try:
            assert_safe_frame(data)
        except UnsafeFrame as exc:
            self.refused += 1
            self.last_refusal = str(exc)
            logging.error("player %s: refused frame (%s): %s", self.player, reason, exc)
            return
        if self.require_tracker and not self.tracker_ready:
            # Option A item 7: a frame sent before LightgunMono finishes its
            # handshake can land in its protocol window, so early commands are
            # dropped (once, with a reason) instead of queued.
            self.dropped += 1
            self.last_drop = f"waiting for LightgunMono on {self.device_path}"
            if not self.tracker_drop_logged:
                self.tracker_drop_logged = True
                logging.warning(
                    "player %s: dropping %s until a LightgunMono tracker owns %s",
                    self.player,
                    reason,
                    self.device_path,
                )
            return
        if self.capture:
            with self.capture.open("a", encoding="utf-8") as stream:
                stream.write(f"player={self.player} reason={reason} data={data.hex(' ')}\n")
        if self.physical is not None:
            try:
                os.write(self.physical, data)
            except OSError as exc:
                logging.error("player %s: serial write failed: %s", self.player, exc)
                return
        elif self.device_path is not None:
            if not self.write_direct(data):
                return
        elif not self.simulate:
            # Option A: a player with no gun must be visibly inert, not silently
            # counted as sent, or status/diagnostics would claim recoil worked.
            self.dropped += 1
            self.last_drop = "no Sinden gun is attached"
            if not self.missing_logged:
                self.missing_logged = True
                logging.warning(
                    "player %s: dropping %s: no Sinden gun is attached",
                    self.player,
                    reason,
                )
            return
        self.sent += 1
        self.last_frame = data.hex(" ")
        self.last_reason = reason
        self.last_frame_monotonic = time.monotonic()
        self.last_frame_time = time.strftime("%Y-%m-%dT%H:%M:%S")
        logging.info("player %s: serial %s (%s)", self.player, data.hex(" "), reason)

    def write_direct(self, data: bytes) -> bool:
        """Write one complete frame and close the device again.

        Opened write-only and non-blocking, with no termios call and no read, so
        LightgunMono's 115200 8N1 configuration stays in force for the session.
        """
        device = self.device_path
        if device is None:
            return False
        try:
            fd = os.open(device, os.O_WRONLY | os.O_NOCTTY | os.O_NONBLOCK)
        except OSError as exc:
            logging.error("player %s: cannot open %s: %s", self.player, device, exc)
            return False
        try:
            os.write(fd, data)
        except OSError as exc:
            logging.error("player %s: serial write to %s failed: %s", self.player, device, exc)
            return False
        finally:
            with suppress(OSError):
                os.close(fd)
        return True

    def send_burst(self, packets: list[bytes], reason: str) -> None:
        """Send one command's frames, leaving the F7 gap in direct mode."""
        for index, packet in enumerate(packets):
            if index and self.physical is None and self.device_path is not None:
                time.sleep(DIRECT_BURST_DELAY)
            self.send(packet, reason)

    def forward_pty_to_physical(self) -> None:
        if self.pty_master is None or self.physical is None:
            return
        try:
            data = os.read(self.pty_master, 4096)
            if data:
                os.write(self.physical, data)
        except OSError as exc:
            if exc.errno not in (errno.EIO, errno.EAGAIN, errno.EWOULDBLOCK):
                logging.warning("player %s: PTY forwarding failed: %s", self.player, exc)

    def forward_physical_to_pty(self) -> None:
        if self.physical is None or self.pty_master is None:
            return
        try:
            data = os.read(self.physical, 4096)
            if data:
                # Only the retired bridge reads the gun. Count what it saw so the
                # diagnostics can prove whether replies leaked into Mono's PTY.
                self.reply_bytes += len(data)
                self.last_reply = data[:48].hex(" ")
                os.write(self.pty_master, data)
        except OSError as exc:
            if exc.errno not in (errno.EAGAIN, errno.EWOULDBLOCK):
                logging.warning("player %s: serial forwarding failed: %s", self.player, exc)

    def close(self) -> None:
        for fd in (self.physical, self.pty_master, self.pty_slave):
            if fd is not None:
                with suppress(OSError):
                    os.close(fd)


def canonical_tty(path: str) -> str:
    """Resolve a tty path so ``/dev/serial/by-id/*`` matches ``/dev/ttyACM*``."""
    return os.path.realpath(path)


def tracker_write_ports(root: Path = TRACKER_ROOT) -> dict[str, str]:
    """Map every live tracker tty to the config file that claims it."""
    ports: dict[str, str] = {}
    for path in sorted(root.glob(TRACKER_CONFIG_GLOB)):
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        match = SERIAL_PORT_WRITE_RE.search(text)
        if match:
            ports[canonical_tty(match.group(1))] = str(path)
    return ports


def wants_tracker_gate(device: str, mode: str) -> bool:
    """Decide whether a device waits for LightgunMono before it is written."""
    if mode == "on":
        return True
    if mode == "off":
        return False
    return any(device.startswith(prefix) for prefix in DIRECT_DEVICE_PREFIXES)


def usb_id_of(device: str, tty_root: Path = SYSFS_TTY_ROOT) -> str | None:
    """Return ``vendor:product`` for a serial tty, or None when it has none.

    F7 resolves each gun by USB id from ``/sys/class/tty/<tty>/device`` upwards,
    because tty numbers are not stable across boots or replugs.
    """
    name = Path(os.path.realpath(device)).name
    node = tty_root / name / "device"
    if not name or not node.exists():
        return None
    current = Path(os.path.realpath(node))
    for _ in range(4):
        try:
            vendor = (current / "idVendor").read_text(encoding="ascii").strip()
            product = (current / "idProduct").read_text(encoding="ascii").strip()
        except OSError:
            pass
        else:
            return f"{vendor}:{product}"
        if current.parent == current:
            break
        current = current.parent
    return None


def discover_devices(dev_root: Path = DEV_ROOT, tty_root: Path = SYSFS_TTY_ROOT) -> dict[str, str]:
    """Resolve each player's gun by USB id instead of by tty number (F7)."""
    found: dict[str, str] = {}
    for device in sorted(dev_root.glob("ttyACM*")):
        usb = usb_id_of(str(device), tty_root)
        player = SINDEN_USB_IDS.get(usb) if usb else None
        if player is None:
            continue
        if player in found:
            logging.warning(
                "two Sinden guns report USB id %s; keeping %s for player %s and ignoring %s",
                usb,
                found[player],
                player,
                device,
            )
            continue
        found[player] = str(device)
    return found


def verify_device(device: str, player: str, tty_root: Path = SYSFS_TTY_ROOT) -> str | None:
    """Warn when the gun on this port belongs to a different player (F7)."""
    usb = usb_id_of(device, tty_root)
    if usb is None:
        return None
    actual = SINDEN_USB_IDS.get(usb)
    if actual is None:
        logging.warning("player %s: %s reports unknown Sinden USB id %s", player, device, usb)
    elif actual != player:
        logging.warning(
            "gun on port %s is not player %s: its USB id %s is player %s",
            device,
            player,
            usb,
            actual,
        )
    return usb


class Broker:
    def __init__(
        self,
        ports: dict[int, set[str]],
        channels: dict[str, GunChannel],
        control_socket: Path | None = None,
        tracker_root: Path = TRACKER_ROOT,
        state_file: Path | None = None,
    ):
        self.ports = ports
        self.channels = channels
        self.selector = selectors.DefaultSelector()
        self.listeners: list[socket.socket] = []
        self.clients: list[socket.socket] = []
        self.workers: dict[str, socket.socket] = {}
        self.control_socket = control_socket
        self.tracker_root = tracker_root
        self.state_file = state_file
        self.state_logged = False
        self.next_tracker_check = 0.0

    def start(self) -> None:
        for port, players in self.ports.items():
            server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            server.bind(("127.0.0.1", port))
            server.listen(8)
            server.setblocking(False)
            self.selector.register(server, selectors.EVENT_READ, ("listen", players))
            self.listeners.append(server)
            logging.info("listening on 127.0.0.1:%d for players %s", port, ",".join(sorted(players)))
        for channel in self.channels.values():
            channel.start()
            if channel.pty_master is not None:
                os.set_blocking(channel.pty_master, False)
                os.set_blocking(channel.physical, False)  # type: ignore[arg-type]
                self.selector.register(channel.pty_master, selectors.EVENT_READ, ("pty", channel))
                self.selector.register(channel.physical, selectors.EVENT_READ, ("physical", channel))  # type: ignore[arg-type]
        if self.control_socket:
            self.control_socket.parent.mkdir(parents=True, exist_ok=True)
            with suppress(FileNotFoundError):
                self.control_socket.unlink()
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(str(self.control_socket))
            server.listen(8)
            server.setblocking(False)
            self.selector.register(server, selectors.EVENT_READ, ("worker-listen", None))
            self.listeners.append(server)
            logging.info("worker control socket: %s", self.control_socket)

    def refresh_tracker(self) -> None:
        """Enable a channel only once LightgunMono's tracker owns its tty."""
        if not any(channel.require_tracker for channel in self.channels.values()):
            return
        ports = tracker_write_ports(self.tracker_root)
        for channel in self.channels.values():
            if not channel.require_tracker or channel.device_path is None:
                continue
            ready = canonical_tty(channel.device_path) in ports
            if ready == channel.tracker_ready:
                continue
            channel.tracker_ready = ready
            if ready:
                channel.tracker_drop_logged = False
                logging.info(
                    "player %s: LightgunMono tracker is up on %s; recoil enabled",
                    channel.player,
                    channel.device_path,
                )
            else:
                logging.info(
                    "player %s: no LightgunMono tracker for %s yet; dropping recoil commands",
                    channel.player,
                    channel.device_path,
                )

    def write_state(self) -> None:
        """Publish per-player counters for hotr-status and the debug report.

        The file is replaced atomically so a reader never sees a partial JSON
        document. Direct mode never reads the gun, so ``reply_bytes`` stays 0
        there; a non-zero value proves the retired bridge saw gun replies.
        """
        if self.state_file is None:
            return
        snapshot = {
            "updated": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "pid": os.getpid(),
            "control_socket": str(self.control_socket) if self.control_socket else None,
            "players": {
                player: {
                    "backend": channel.backend,
                    "device": channel.device_path,
                    "usb_id": channel.usb_id,
                    "tracker_ready": channel.tracker_ready,
                    "tracker_gate": channel.require_tracker,
                    "worker": player in self.workers,
                    "sent": channel.sent,
                    "dropped": channel.dropped,
                    "refused": channel.refused,
                    "reply_bytes": channel.reply_bytes,
                    "last_frame": channel.last_frame,
                    "last_frame_time": channel.last_frame_time,
                    "last_frame_age": channel.frame_age(),
                    "last_reason": channel.last_reason,
                    "last_drop": channel.last_drop,
                    "last_reply": channel.last_reply,
                    "last_refusal": channel.last_refusal,
                }
                for player, channel in sorted(self.channels.items())
            },
        }
        try:
            self.state_file.parent.mkdir(parents=True, exist_ok=True)
            temporary = self.state_file.with_suffix(self.state_file.suffix + ".tmp")
            temporary.write_text(json.dumps(snapshot, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            os.replace(temporary, self.state_file)
        except OSError as exc:
            if not self.state_logged:
                self.state_logged = True
                logging.info("cannot publish the state file %s: %s", self.state_file, exc)

    def accept_worker(self, server: socket.socket) -> None:
        client, _ = server.accept()
        client.setblocking(False)
        self.selector.register(client, selectors.EVENT_READ, ("worker", None, bytearray()))
        self.clients.append(client)

    def worker_message(self, client: socket.socket, buffer: bytearray) -> None:
        try:
            data = client.recv(4096)
        except OSError:
            data = b""
        if not data:
            for player, worker in list(self.workers.items()):
                if worker is client:
                    del self.workers[player]
                    logging.info("worker for player %s disconnected", player)
            with suppress(OSError):
                self.selector.unregister(client)
            client.close()
            return
        buffer.extend(data)
        while b"\n" in buffer:
            raw, _, remainder = buffer.partition(b"\n")
            buffer[:] = remainder
            message = raw.decode("ascii", errors="ignore")
            if message.startswith("REGISTER "):
                player = message[9:].strip()
                if player in ("1", "2"):
                    old = self.workers.get(player)
                    if old and old is not client:
                        old.close()
                    self.workers[player] = client
                    logging.info("worker registered for player %s", player)

    def accept(self, server: socket.socket, players: set[str]) -> None:
        client, address = server.accept()
        client.setblocking(False)
        self.selector.register(client, selectors.EVENT_READ, ("client", players, bytearray()))
        self.clients.append(client)
        logging.info("HOTR connected from %s on port %s", address, ",".join(sorted(players)))
        # A game has just started (HOTR connects on game start): say plainly when
        # there is no gun to write to, instead of silently dropping every pull.
        for player in self.gunless_players(players):
            logging.warning(
                "player %s: no Sinden gun is attached; recoil will be dropped for this session",
                player,
            )

    def gunless_players(self, players: set[str]) -> list[str]:
        """Players in ``players`` that currently have nowhere to write to."""
        missing = []
        for player in sorted(players):
            if player in self.workers:
                continue
            channel = self.channels.get(player)
            if channel is None or channel.backend == "none":
                missing.append(player)
        return missing

    def dispatch(self, target: str, command: str, default_players: set[str]) -> None:
        if target == "B":
            players = set(self.channels) | set(self.workers) | {"1", "2"}
        elif target in ("1", "2"):
            players = {target}
        else:
            # No explicit player in the command: the delivering socket decides.
            players = set(default_players) or {"1"}
        packets = command_frames(command)
        if packets is None:
            logging.warning("unsupported Sinden command %s", command)
            return
        for player in players:
            channel = self.channels.get(player)
            worker = self.workers.get(player)
            if worker is not None and (channel is None or not channel.direct):
                # Legacy bridge: the worker owns the real gun, so HOTR commands
                # are relayed to it; the broker-side channel only tracks the
                # Mono PTY and must not swallow the frames.
                try:
                    for packet in packets:
                        worker.sendall(b"FRAME " + packet.hex().encode("ascii") + b"\n")
                        logging.info("player %s: dispatched serial %s (%s)", player, packet.hex(" "), command)
                except OSError:
                    logging.warning("worker for player %s is unavailable", player)
            elif channel:
                channel.send_burst(packets, command)
            else:
                logging.warning("no active Sinden channel for player %s", player)

    def run(self) -> None:
        while True:
            if time.monotonic() >= self.next_tracker_check:
                self.next_tracker_check = time.monotonic() + TRACKER_POLL_SECONDS
                self.refresh_tracker()
                self.write_state()
            for key, _ in self.selector.select(timeout=0.25):
                kind = key.data[0]
                if kind == "listen":
                    self.accept(cast(socket.socket, key.fileobj), key.data[1])
                elif kind == "worker-listen":
                    self.accept_worker(cast(socket.socket, key.fileobj))
                elif kind == "worker":
                    self.worker_message(cast(socket.socket, key.fileobj), key.data[2])
                elif kind == "pty":
                    key.data[1].forward_pty_to_physical()
                elif kind == "physical":
                    key.data[1].forward_physical_to_pty()
                else:
                    client = cast(socket.socket, key.fileobj)
                    players, buffer = key.data[1], key.data[2]
                    try:
                        data = client.recv(4096)
                    except OSError:
                        data = b""
                    if not data:
                        self.selector.unregister(client)
                        client.close()
                        continue
                    buffer.extend(data)
                    while b"\n" in buffer:
                        raw, _, remainder = buffer.partition(b"\n")
                        buffer[:] = remainder
                        parsed = parse_hotr_command(raw.decode("ascii", errors="ignore"))
                        if parsed:
                            self.dispatch(parsed[0], parsed[1], players)

    def close(self) -> None:
        for client in self.clients:
            with suppress(OSError):
                self.selector.unregister(client)
                client.close()
        for server in self.listeners:
            with suppress(OSError):
                self.selector.unregister(server)
                server.close()
        for channel in self.channels.values():
            channel.close()
        if self.control_socket:
            with suppress(FileNotFoundError):
                self.control_socket.unlink()


def run_worker(player: str, device: str, control_socket: Path, pty_file: Path, capture: Path | None) -> int:
    physical = os.open(device, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    channel = GunChannel(player, physical=physical, bridge=True, capture=capture)
    control: socket.socket | None = None
    selector: selectors.BaseSelector | None = None
    try:
        channel.start()
        if channel.pty_path is None or channel.pty_master is None or channel.pty_slave is None:
            raise RuntimeError("worker could not create PTY")
        pty_file.parent.mkdir(parents=True, exist_ok=True)
        pty_file.write_text(channel.pty_path + "\n", encoding="ascii")
        control_socket.parent.mkdir(parents=True, exist_ok=True)
        control = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        for _ in range(480):
            try:
                control.connect(str(control_socket))
                break
            except OSError:
                import time
                time.sleep(0.25)
        else:
            raise RuntimeError(f"broker control socket unavailable: {control_socket}")
        control.sendall(f"REGISTER {player}\n".encode("ascii"))
        control.setblocking(False)
        if channel.pty_master is None or channel.physical is None:
            raise RuntimeError("worker channel is missing its PTY or physical device")
        os.set_blocking(channel.pty_master, False)
        os.set_blocking(channel.physical, False)
        selector = selectors.DefaultSelector()
        selector.register(channel.pty_master, selectors.EVENT_READ, "pty")
        selector.register(channel.physical, selectors.EVENT_READ, "physical")
        selector.register(control, selectors.EVENT_READ, "control")
        buffer = bytearray()
        logging.info("worker player %s ready; Mono PTY is %s", player, channel.pty_path)
        while True:
            for key, _ in selector.select(timeout=0.5):
                if key.data == "pty":
                    channel.forward_pty_to_physical()
                elif key.data == "physical":
                    channel.forward_physical_to_pty()
                else:
                    try:
                        data = control.recv(4096)
                    except OSError:
                        data = b""
                    if not data:
                        return 0
                    buffer.extend(data)
                    while b"\n" in buffer:
                        raw, _, remainder = buffer.partition(b"\n")
                        buffer[:] = remainder
                        message = raw.decode("ascii", errors="ignore")
                        if message.startswith("FRAME "):
                            channel.send(bytes.fromhex(message[6:].strip()), "HOTR")
    finally:
        if selector is not None:
            selector.close()
        if control is not None:
            control.close()
        channel.close()
        with suppress(FileNotFoundError):
            pty_file.unlink()


def parse_devices(values: list[str]) -> dict[str, str]:
    result: dict[str, str] = {}
    for value in values:
        player, separator, device = value.partition("=")
        if separator and player in ("1", "2") and device:
            result[player] = device
    return result


class SindenLogHandler(RotatingFileHandler):
    """Rotating handler whose one previous generation ends in ``.old``.

    ``scripts/hotr-service`` rotates the HOTR log to ``<name>.old`` on start.
    Using the same suffix here means an operator always finds one previous
    generation under one name, whichever side rotated it.
    """

    def rotation_filename(self, default_name: str) -> str:
        if default_name.endswith(".1"):
            return default_name[: -len(".1")] + ".old"
        return default_name


def sinden_log_max_bytes() -> int:
    """Broker log cap, overridable with HOTR_SINDEN_LOG_MAX_BYTES."""
    raw = os.environ.get("HOTR_SINDEN_LOG_MAX_BYTES", "")
    try:
        value = int(raw)
    except ValueError:
        return DEFAULT_SINDEN_LOG_MAX_BYTES
    return value if value > 0 else DEFAULT_SINDEN_LOG_MAX_BYTES


def configure_logging(log_path: Path | None) -> None:
    """Log to the rotating file when given one, otherwise to the console."""
    if log_path is None:
        logging.basicConfig(level=logging.INFO, format="%(asctime)s hotr-sinden-broker: %(message)s")
        return
    log_path.parent.mkdir(parents=True, exist_ok=True)
    handler = SindenLogHandler(log_path, maxBytes=sinden_log_max_bytes(), backupCount=1, encoding="utf-8")
    handler.setFormatter(logging.Formatter("%(asctime)s hotr-sinden-broker: %(message)s"))
    logging.basicConfig(level=logging.INFO, handlers=[handler])


def main() -> int:
    parser = argparse.ArgumentParser(description="HOTR Sinden serial broker")
    parser.add_argument("--worker", action="store_true")
    parser.add_argument("--player", choices=("1", "2"))
    parser.add_argument("--control-socket", type=Path)
    parser.add_argument("--pty-file", type=Path)
    parser.add_argument("--config", type=Path)
    parser.add_argument("--port", action="append", default=[], help="PORT or PLAYER=PORT")
    parser.add_argument("--device", action="append", default=[], help="PLAYER=/dev/ttyACM0")
    parser.add_argument(
        "--pty-bridge",
        action="store_true",
        help="legacy byte-transparent PTY bridge instead of the direct write-only backend",
    )
    parser.add_argument(
        "--tracker-gate",
        choices=("auto", "on", "off"),
        default="auto",
        help="wait for LightgunMono's config before writing real ttys (auto: only for kernel ttys)",
    )
    parser.add_argument("--simulate", action="store_true")
    parser.add_argument(
        "--tracker-root",
        type=Path,
        default=TRACKER_ROOT,
        help="directory holding LightgunMono's runtime configs (default /var/run/sinden)",
    )
    parser.add_argument("--capture", type=Path)
    parser.add_argument(
        "--state-file",
        type=Path,
        default=DEFAULT_STATE_FILE,
        help="per-player counters read by hotr-status and hotr-debug-report.sh",
    )
    parser.add_argument("--log", type=Path)
    args = parser.parse_args()

    configure_logging(args.log)

    if args.worker:
        if not all((args.player, args.device, len(args.device) == 1, args.control_socket, args.pty_file)):
            parser.error("--worker requires --player, one --device, --control-socket and --pty-file")
        device = parse_devices(args.device).get(args.player)
        if not device:
            parser.error("worker device must be PLAYER=/dev/ttyACM0")
        return run_worker(args.player, device, args.control_socket, args.pty_file, args.capture)

    ports = configured_ports(args.config) if args.config else {}
    for value in args.port:
        player, separator, number = value.partition("=")
        if not separator:
            player, number = "1", value
        try:
            port = int(number)
        except ValueError:
            parser.error(f"invalid port: {value}")
        ports.setdefault(port, set()).add(player if player in ("1", "2") else "1")
    if not ports:
        parser.error("provide --config or --port")

    devices = parse_devices(args.device)
    players = sorted(set().union(*ports.values()))
    if not devices and not args.simulate:
        devices = discover_devices()
        if not devices:
            logging.warning("no Sinden gun found: checked %s for USB ids %s", DEV_ROOT / "ttyACM*", ", ".join(SINDEN_USB_IDS))
    channels: dict[str, GunChannel] = {}
    for player in players:
        device = None if args.simulate else devices.get(player)
        if not args.simulate and device is None:
            logging.warning("no Sinden gun found for player %s", player)
        physical = None
        if device is not None and args.pty_bridge:
            physical = os.open(device, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        usb = verify_device(device, player) if device is not None else None
        channels[player] = GunChannel(
            player,
            device_path=device,
            physical=physical,
            bridge=args.pty_bridge,
            simulate=args.simulate,
            capture=args.capture,
            require_tracker=device is not None and wants_tracker_gate(device, args.tracker_gate),
            usb_id=usb,
        )

    broker = Broker(ports, channels, args.control_socket, args.tracker_root, args.state_file)
    broker.start()
    try:
        broker.run()
    except KeyboardInterrupt:
        pass
    finally:
        broker.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
