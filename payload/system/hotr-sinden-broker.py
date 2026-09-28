#!/usr/bin/env python3
"""Bridge HOTR's Sinden TCP protocol to Sinden serial.

With a physical device this process is the sole opener of the gun's serial
port. It presents a PTY for Batocera's LightgunMono process, forwards normal
traffic in both directions, and serialises HOTR recoil frames onto the real
device. ``--simulate`` never opens hardware and is used by the self-test.
"""

from __future__ import annotations

import argparse
import errno
import logging
import os
import pty
import selectors
import socket
import termios
import tty
from dataclasses import dataclass
from pathlib import Path

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
    target = value[0] if value[0] in "12B" else "1"
    command = value[1:] if value[0] in "12B" else value
    return (target, command) if command else None


def command_frames(command: str) -> list[bytes] | None:
    """Translate HOTR's Sinden TCP commands to native serial frames.

    A/B/C and the A7/A8/A9/AA frames were recovered directly from the Sinden
    executable. The small mode-setting frames cover the commands HOTR emits
    during profile setup; Mono continues to own camera/input processing.
    """
    op = command[0]
    if op == "A":
        # Recovered from Lightgun.exe::FireSingleRecoil().
        return [frame(0xA8)]
    if op == "B":
        return [frame(0xA9)]
    if op == "C":
        return [frame(0xAA)]
    if op == "D":
        return [frame(0xA3, 0)]
    if op == "E":
        return [frame(0xA3, 1)]
    if op == "N" and command[1:].isdigit():
        return [frame(0xA7, max(0, min(10, int(command[1:]))) * 10)]
    if op in {"F", "G", "H", "I"}:
        # Sinden's TCP server applies these presets by sending A2, A7 and A3
        # configuration frames. Values match the executable's built-in
        # presets: mixed, automatic-normal, automatic-fast, automatic-strong.
        presets = {
            "F": (80, 5, 13),
            "G": (40, 0, 3),
            "H": (50, 0, 9),
            "I": (60, 0, 13),
        }
        strength, start_delay, pulse_delay = presets[op]
        return [
            frame(0xA2, strength, start_delay, strength, pulse_delay),
            frame(0xA7, strength),
            frame(0xA3, 1),
        ]
    if op == "J" and len(command) == 2 and command[1] in "01":
        return [frame(0xA1, int(command[1]))]
    if op == "K" and len(command) == 2 and command[1] in "01":
        return [frame(0xA4, int(command[1]), 0, 0, 0)]
    if op in {"P", "Q", "R"} and command[1:].isdigit():
        value = max(0, min(255, int(command[1:])))
        # A2 contains strength, start delay, strength and pulse delay. Keep
        # the other values at the executable's normal defaults.
        if op == "P":
            return [frame(0xA2, value, 0, value, 13)]
        if op == "Q":
            return [frame(0xA2, 50, 0, 50, value)]
        return [frame(0xA2, 50, value, 50, 13)]
    if op == "S":
        return [frame(0xA8)]
    if op == "U" and command[1:].isdigit():
        value = max(0, min(10, int(command[1:]))) * 10
        return [frame(0xA7, value), frame(0xA8)]
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
    """Configure the physical Sinden UART as 115200 8N1."""
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
    physical: int | None = None
    capture: Path | None = None
    pty_master: int | None = None
    pty_slave: int | None = None
    pty_path: str | None = None

    def start(self) -> None:
        if self.physical is None:
            logging.info("player %s: simulation backend enabled", self.player)
            return
        configure_serial(self.physical)
        make_raw(self.physical)
        self.pty_master, self.pty_slave = pty.openpty()
        make_raw(self.pty_master)
        self.pty_path = os.ttyname(self.pty_slave)
        logging.info("player %s: physical fd bridged through %s", self.player, self.pty_path)

    def send(self, data: bytes, reason: str) -> None:
        if self.capture:
            with self.capture.open("a", encoding="utf-8") as stream:
                stream.write(f"player={self.player} reason={reason} data={data.hex(' ')}\n")
        if self.physical is not None:
            try:
                os.write(self.physical, data)
            except OSError as exc:
                logging.error("player %s: serial write failed: %s", self.player, exc)
                return
        logging.info("player %s: serial %s (%s)", self.player, data.hex(" "), reason)

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
                os.write(self.pty_master, data)
        except OSError as exc:
            if exc.errno not in (errno.EAGAIN, errno.EWOULDBLOCK):
                logging.warning("player %s: serial forwarding failed: %s", self.player, exc)

    def close(self) -> None:
        for fd in (self.physical, self.pty_master, self.pty_slave):
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    pass


class Broker:
    def __init__(self, ports: dict[int, set[str]], channels: dict[str, GunChannel], control_socket: Path | None = None):
        self.ports = ports
        self.channels = channels
        self.selector = selectors.DefaultSelector()
        self.listeners: list[socket.socket] = []
        self.clients: list[socket.socket] = []
        self.workers: dict[str, socket.socket] = {}
        self.control_socket = control_socket

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
            try:
                self.control_socket.unlink()
            except FileNotFoundError:
                pass
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(str(self.control_socket))
            server.listen(8)
            server.setblocking(False)
            self.selector.register(server, selectors.EVENT_READ, ("worker-listen", None))
            self.listeners.append(server)
            logging.info("worker control socket: %s", self.control_socket)

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
            try:
                self.selector.unregister(client)
            except OSError:
                pass
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

    def dispatch(self, target: str, command: str, default_players: set[str]) -> None:
        players = (set(self.channels) | set(self.workers) | {"1", "2"}) if target == "B" else {target}
        if target not in "12B":
            players = default_players
        packets = command_frames(command)
        if packets is None:
            logging.warning("unsupported Sinden command %s", command)
            return
        for player in players:
            channel = self.channels.get(player)
            if channel:
                for packet in packets:
                    channel.send(packet, command)
            elif player in self.workers:
                try:
                    for packet in packets:
                        self.workers[player].sendall(b"FRAME " + packet.hex().encode("ascii") + b"\n")
                        logging.info("player %s: dispatched serial %s (%s)", player, packet.hex(" "), command)
                except OSError:
                    logging.warning("worker for player %s is unavailable", player)
            else:
                logging.warning("no active Sinden channel for player %s", player)

    def run(self) -> None:
        while True:
            for key, _ in self.selector.select(timeout=0.25):
                kind = key.data[0]
                if kind == "listen":
                    self.accept(key.fileobj, key.data[1])
                elif kind == "worker-listen":
                    self.accept_worker(key.fileobj)
                elif kind == "worker":
                    self.worker_message(key.fileobj, key.data[2])
                elif kind == "pty":
                    key.data[1].forward_pty_to_physical()
                elif kind == "physical":
                    key.data[1].forward_physical_to_pty()
                else:
                    client, players, buffer = key.fileobj, key.data[1], key.data[2]
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
            try:
                self.selector.unregister(client)
                client.close()
            except OSError:
                pass
        for server in self.listeners:
            try:
                self.selector.unregister(server)
                server.close()
            except OSError:
                pass
        for channel in self.channels.values():
            channel.close()
        if self.control_socket:
            try:
                self.control_socket.unlink()
            except FileNotFoundError:
                pass


def run_worker(player: str, device: str, control_socket: Path, pty_file: Path, capture: Path | None) -> int:
    physical = os.open(device, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    channel = GunChannel(player, physical=physical, capture=capture)
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
        try:
            pty_file.unlink()
        except FileNotFoundError:
            pass


def parse_devices(values: list[str]) -> dict[str, str]:
    result: dict[str, str] = {}
    for value in values:
        player, separator, device = value.partition("=")
        if separator and player in ("1", "2") and device:
            result[player] = device
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="HOTR Sinden serial broker")
    parser.add_argument("--worker", action="store_true")
    parser.add_argument("--player", choices=("1", "2"))
    parser.add_argument("--control-socket", type=Path)
    parser.add_argument("--pty-file", type=Path)
    parser.add_argument("--config", type=Path)
    parser.add_argument("--port", action="append", default=[], help="PORT or PLAYER=PORT")
    parser.add_argument("--device", action="append", default=[], help="PLAYER=/dev/ttyACM0")
    parser.add_argument("--simulate", action="store_true")
    parser.add_argument("--capture", type=Path)
    parser.add_argument("--log", type=Path)
    args = parser.parse_args()

    if args.log:
        args.log.parent.mkdir(parents=True, exist_ok=True)
        logging.basicConfig(filename=args.log, level=logging.INFO, format="%(asctime)s hotr-sinden-broker: %(message)s")
    else:
        logging.basicConfig(level=logging.INFO, format="%(asctime)s hotr-sinden-broker: %(message)s")

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
    channels: dict[str, GunChannel] = {}
    if args.simulate or devices:
        for player in players:
            physical = None
            if not args.simulate and player in devices:
                physical = os.open(devices[player], os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
            channels[player] = GunChannel(player, physical=physical, capture=args.capture)

    broker = Broker(ports, channels, args.control_socket)
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
