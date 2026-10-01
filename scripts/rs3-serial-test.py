#!/usr/bin/env python3
"""Interactive RS3 diagnostic; stop HOTR and close the game before use.

Uses only the Python standard library. With --auto-startup it sends ZS, waits
for the requested interval, then sends Z6 before entering interactive mode.
Z1-Z5 also operate recoil; Z0 holds the slide. Observe the physical gun.
"""
import argparse
import array
import fcntl
import os
from pathlib import Path
import select
import termios
import time
import tty


def send_command(fd, command):
    data = command.encode('ascii')
    count = os.write(fd, data)
    print(f"{time.strftime('%H:%M:%S')} TX {command} hex={data.hex()} accepted={count}/2")
    if count != len(data):
        raise RuntimeError('Short serial write')
    deadline = time.monotonic() + 2
    queued = array.array('i', [0])
    while True:
        fcntl.ioctl(fd, termios.TIOCOUTQ, queued, True)
        if not queued[0] or time.monotonic() >= deadline:
            break
        time.sleep(0.01)
    print(f"Kernel output queue={queued[0]} (not a firmware acknowledgement)")
    if select.select([fd], [], [], 0.2)[0]:
        reply = os.read(fd, 4096)
        print(f"RX {reply!r} hex={reply.hex()}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("device", help="Explicit Reaper tty or stable symlink")
    parser.add_argument(
        "--auto-startup", action="store_true",
        help="automatically send ZS, wait, then send Z6",
    )
    parser.add_argument(
        "--startup-delay-ms", type=int, default=100,
        help="delay between automatic ZS and Z6 (default: 100 ms)",
    )
    args = parser.parse_args()
    if args.startup_delay_ms < 0:
        parser.error("--startup-delay-ms must be zero or greater")
    device = os.path.realpath(args.device)
    # Refuse to compete with an existing process holding this tty.
    owners = []
    for entry in Path('/proc').glob('[0-9]*/fd/*'):
        try:
            if os.path.realpath(entry) == device:
                owners.append(entry.parts[2])
        except OSError:
            pass
    if owners:
        raise SystemExit(f"Device already open by PID(s): {', '.join(sorted(set(owners)))}")

    fd = os.open(device, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    original = termios.tcgetattr(fd)
    try:
        fcntl.ioctl(fd, termios.TIOCEXCL)
        tty.setraw(fd, termios.TCSANOW)
        attrs = termios.tcgetattr(fd)
        attrs[2] &= ~(termios.PARENB | termios.CSTOPB | termios.CSIZE | termios.CRTSCTS)
        attrs[2] |= termios.CS8 | termios.CLOCAL | termios.CREAD
        attrs[4] = attrs[5] = termios.B115200
        termios.tcsetattr(fd, termios.TCSANOW, attrs)
        print(f"Opened {device}: 115200 8N1, no flow control.")
        if args.auto_startup:
            print(f"Automatic startup: ZS, wait {args.startup_delay_ms} ms, Z6")
            send_command(fd, 'ZS')
            time.sleep(args.startup_delay_ms / 1000.0)
            send_command(fd, 'Z6')
        print("Enter one command: ZS ZX ZR Z6 Z5 Z4 Z3 Z2 Z1 Z0 ZZ; q exits.")
        print("Z1-Z5 recoil; Z0 holds slide; Z6 returns it. No command is sent on exit.")
        while True:
            command = input('RS3> ').strip().upper()
            if command == 'Q':
                break
            if command not in {'ZS', 'ZX', 'ZR', 'Z6', 'Z5', 'Z4', 'Z3', 'Z2', 'Z1', 'Z0', 'ZZ'}:
                print('Unknown command; nothing sent.')
                continue
            send_command(fd, command)
    finally:
        termios.tcsetattr(fd, termios.TCSANOW, original)
        os.close(fd)


if __name__ == '__main__':
    try:
        main()
    except (KeyboardInterrupt, EOFError):
        pass
