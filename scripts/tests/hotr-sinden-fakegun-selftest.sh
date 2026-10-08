#!/bin/bash
# Self-test for the firmware-faithful Sinden fake gun.
#
# Proves four things without owning a gun:
#   1. the command table embedded in the fake gun matches the real firmware
#      image (skipped when the Windows firmware hex is not on the machine);
#   2. the fake gun reproduces the handshake LightgunMono insists on;
#   3. HOTR's serial traffic through the real broker/worker code path reaches
#      the gun as firmware-shaped frames, and the firmware-verified whitelist
#      keeps the traffic silent;
#   4. the broker's write chokepoint refuses every frame that would make the
#      gun answer, and (until the PTY bridge is retired) gun-originated bytes
#      written directly at the device are still copied into LightgunMono's PTY.
#
# Point 4's bridge check documents the known pre-retirement leak. Set
# HOTR_SINDEN_EXPECT_LEAK=0 once the PTY bridge is retired from the default
# install to turn that observation into a hard requirement.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/../../payload/system/hotr-sinden-broker.py" ]; then
  ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
  BROKER="$ROOT/payload/system/hotr-sinden-broker.py"
else
  ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  BROKER="$ROOT/bin/hotr-sinden-broker.py"
fi
FAKE_GUN="$SCRIPT_DIR/fake-gun-firmware-faithful.py"
[ -f "$FAKE_GUN" ] || FAKE_GUN="$ROOT/scripts/tests/fake-gun-firmware-faithful.py"
[ -f "$FAKE_GUN" ] || FAKE_GUN="$ROOT/scripts/fake-gun-firmware-faithful.py"
DEBUG_REPORT="$ROOT/scripts/hotr-debug-report.sh"
[ -f "$DEBUG_REPORT" ] || DEBUG_REPORT="$ROOT/tools/hotr-debug-report.sh"
[ -f "$BROKER" ] || { echo "[FAIL] broker not found: $BROKER" >&2; exit 1; }
[ -f "$FAKE_GUN" ] || { echo "[FAIL] fake gun not found: $FAKE_GUN" >&2; exit 1; }
command -v python3 >/dev/null || { echo "[FAIL] python3 is unavailable" >&2; exit 1; }

echo "HOTR Sinden fake-gun self-test"
echo "Broker:   $BROKER"
echo "Fake gun: $FAKE_GUN"
echo

python3 - "$FAKE_GUN" "$BROKER" "$DEBUG_REPORT" <<'PY'
import hashlib
import importlib.util
import json
import logging
import os
import pty
import re
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import termios
import time
import tty
from contextlib import suppress
from pathlib import Path

FAKE_GUN, BROKER, DEBUG_REPORT = sys.argv[1:4]
SALT = b"SindenLightgun364294735243894HaveANiceDay"
CHALLENGE = b"12345678901234567890123456789012"
CONSTANT = b"60341663085532170074617363215964"
EXPECT_LEAK = os.environ.get("HOTR_SINDEN_EXPECT_LEAK", "1") != "0"
TMP = Path(tempfile.mkdtemp(prefix="hotr-sinden-fakegun-"))
PROCS = []
failures = []
skips = []


class SkipCheck(Exception):
    """Raised when a check cannot run here (for example strace is absent)."""


def frame(command, *payload):
    values = list(payload[:4]) + [0] * (4 - len(payload[:4]))
    return bytes([0xAA, command, *values, 0xBB])


def start_gun(**kwargs):
    report = TMP / f"{kwargs.pop('name')}.json"
    command = [sys.executable, FAKE_GUN, "--pty", "--report", str(report), *sum(
        ([f"--{key.replace('_', '-')}", str(value)] if value is not True else
         [f"--{key.replace('_', '-')}"] for key, value in kwargs.items()), [])]
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True)
    PROCS.append(process)
    line = process.stdout.readline().strip()
    if not line.startswith("/dev/"):
        raise RuntimeError(f"fake gun did not announce a PTY: {line!r}")
    return process, line, report


def read_json(path, timeout=5.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if path.exists():
            try:
                return json.loads(path.read_text())
            except json.JSONDecodeError:
                pass
        time.sleep(0.05)
    raise RuntimeError(f"report never appeared: {path}")


def read_exact(fd, count, timeout=5.0):
    deadline = time.time() + timeout
    data = b""
    while len(data) < count and time.time() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.2)
        if ready:
            chunk = os.read(fd, 4096)
            if not chunk:
                break
            data += chunk
    return data


def collect(fd, timeout=1.5):
    data = b""
    deadline = time.time() + timeout
    while time.time() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.2)
        if ready:
            chunk = os.read(fd, 4096)
            if not chunk:
                break
            data += chunk
    return data


def wait_for(predicate, timeout=5.0, interval=0.05):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return False


def report(name, function):
    try:
        function()
    except SkipCheck as exc:
        skips.append((name, str(exc)))
        print(f"[SKIP] {name}: {exc}")
    except Exception as exc:                                  # noqa: BLE001
        failures.append((name, str(exc)))
        print(f"[FAIL] {name}: {exc}")
    else:
        print(f"[PASS] {name}")


def load_broker_module():
    spec = importlib.util.spec_from_file_location("hotr_sinden_broker", BROKER)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot import the broker module from {BROKER}")
    module = importlib.util.module_from_spec(spec)
    # dataclasses resolve postponed annotations through sys.modules, so the module
    # must be registered before it is executed.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def decode_firmware_hex(path):
    data = bytearray()
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if not line.startswith(":") or line[7:9] not in ("00", "01"):
            continue
        count, address = int(line[1:3], 16), int(line[3:7], 16)
        if line[7:9] == "01":
            break
        payload = bytes.fromhex(line[9:9 + 2 * count])
        if len(data) < address + count:
            data.extend(b"\xff" * (address + count - len(data)))
        data[address:address + count] = payload
    return bytes(data)


def find_firmware_hex():
    candidates = [os.environ.get("HOTR_SINDEN_FIRMWARE_HEX", "")]
    candidates.append("/home/matt/Downloads/sinden/SindenLightgunSoftwareReleaseV2.08b/"
                      "SindenLightgunWindowsV2.08/SindenLightgun/firmware/"
                      "LightgunFirmwareRed.hex")
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return candidate
    return None


def test_table_matches_firmware():
    hex_path = find_firmware_hex()
    if not hex_path:
        print("[SKIP] firmware dispatch table check (set HOTR_SINDEN_FIRMWARE_HEX to "
              "LightgunFirmwareRed.hex to enable)")
        return
    image = TMP / "LightgunFirmwareRed.bin"
    image.write_bytes(decode_firmware_hex(hex_path))
    result = subprocess.run([sys.executable, FAKE_GUN, "--verify-firmware", str(image)],
                            capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(result.stdout.strip() or result.stderr.strip())
    print(f"       {result.stdout.strip()}")


def test_handshake():
    digest = bytes(range(32))
    process, slave, report = start_gun(name="handshake")
    fd = os.open(slave, os.O_RDWR | os.O_NOCTTY)
    try:
        os.write(fd, frame(0x6E))
        os.write(fd, digest)
        first = read_exact(fd, 32)
        expected = hashlib.sha256(digest + SALT).digest()
        if first != expected:
            raise RuntimeError(f"phase-1 reply {first.hex(' ')} != LightgunMono expectation")
        os.write(fd, frame(0x6D))
        challenge = read_exact(fd, 32)
        if challenge != CHALLENGE:
            raise RuntimeError(f"phase-2 challenge {challenge.hex(' ')} != firmware constant")
        os.write(fd, hashlib.sha256(challenge + CONSTANT).digest())
        tail = read_exact(fd, len(b"true\r\n"))
        if tail != b"true\r\n":
            raise RuntimeError(f"handshake did not end with 'true\\r\\n': {tail!r}")
        os.write(fd, frame(0x79))
        os.write(fd, frame(0x79))
        time.sleep(0.2)
        state = read_json(report)
        if not state["handshake"].get("true_sent"):
            raise RuntimeError("report does not record a completed handshake")
        if state["errors"]:
            raise RuntimeError(f"handshake produced parser errors: {state['errors']}")
    finally:
        os.close(fd)
        process.terminate()


def start_broker_and_worker(slave, name, port):
    """Run the real broker/worker pair with unprivileged runtime paths."""
    run_dir = TMP / f"run-{name}"
    run_dir.mkdir(parents=True, exist_ok=True)
    control = run_dir / "broker.sock"
    pty_file = run_dir / "p1.pty"
    log = run_dir / "broker.log"
    broker = subprocess.Popen([sys.executable, BROKER, "--port", f"1={port}",
                               "--control-socket", str(control), "--log", str(log)],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    PROCS.append(broker)
    if not wait_for(lambda: control.exists(), 5):
        raise RuntimeError("broker control socket did not appear")
    worker = subprocess.Popen([sys.executable, BROKER, "--worker", "--player", "1",
                               "--device", f"1={slave}", "--control-socket", str(control),
                               "--pty-file", str(pty_file), "--log", str(log)],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    PROCS.append(worker)
    if not wait_for(lambda: pty_file.exists(), 5):
        raise RuntimeError("worker did not publish a Mono PTY")
    mono = pty_file.read_text().strip()
    if not mono.startswith("/dev/"):
        raise RuntimeError(f"worker PTY path looks wrong: {mono!r}")

    def stop() -> None:
        for process in (worker, broker):
            if process.poll() is None:
                process.terminate()
        for process in (worker, broker):
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()

    return port, mono, log, stop


def read_log(path):
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def start_direct_broker(slave, name, port, extra=()):
    """Run the broker in its default device mode (direct write-only)."""
    run_dir = TMP / f"run-{name}"
    run_dir.mkdir(parents=True, exist_ok=True)
    log = run_dir / "broker.log"
    broker = subprocess.Popen([sys.executable, BROKER, "--port", f"1={port}",
                               "--device", f"1={slave}", "--log", str(log),
                               "--state-file", str(run_dir / "state.json"), *extra],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    PROCS.append(broker)
    if not wait_for(lambda: "listening on" in read_log(log), 5):
        raise RuntimeError(f"direct broker did not start listening: {read_log(log)}")

    def stop() -> None:
        if broker.poll() is None:
            broker.terminate()
        try:
            broker.wait(timeout=5)
        except subprocess.TimeoutExpired:
            broker.kill()

    return port, log, stop


def test_whitelist_frames_are_silent():
    process, slave, report = start_gun(name="whitelist")
    port, mono, _log, stop = start_broker_and_worker(slave, "whitelist", 45977)
    mono_fd = os.open(mono, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        client = socket.create_connection(("127.0.0.1", port), 2)
        # A8 (fire), A3 (enable), A4 (trigger-recoil arm/disarm: the ammo path),
        # plus the two commands that used to emit A7: N1 (strength preset) and
        # U1 (strength preset + fire).
        for command in (b"1A\n", b"1D\n", b"1N1\n", b"1U1\n", b"1J0\n", b"1K1\n"):
            client.sendall(command)
        client.close()
        expected = {"a8": 2, "a3": 1, "a2": 3, "a4": 1}
        if not wait_for(lambda: all(read_json(report).get("frames", {}).get(name, 0) >= count
                                   for name, count in expected.items()), 5):
            raise RuntimeError(f"whitelist frames never arrived: {read_json(report)}")
        state = read_json(report)
        if state["bytes_sent"] != 0:
            raise RuntimeError(f"gun had to answer a whitelist command: {state['replies']}")
        for banned in ("a0", "a7", "a9", "aa", "ab", "ac"):
            if banned in state["frames"]:
                raise RuntimeError(f"broker emitted the banned command {banned}: {state['frames']}")
        leaked = collect(mono_fd, 1.0)
        if leaked:
            raise RuntimeError(f"gun bytes reached LightgunMono's PTY: {leaked.hex(' ')}")
        # The bridge must actually work in the Mono -> gun direction, otherwise the
        # silence above would be meaningless. A8 is a silent command in firmware.
        os.write(mono_fd, frame(0xA8))
        if not wait_for(lambda: read_json(report).get("frames", {}).get("a8", 0) >= 3, 5):
            raise RuntimeError("frames written by LightgunMono never reached the gun")
        # And a frame that the gun answers must never come from HOTR's table.
        broker_module = load_broker_module()
        if broker_module.command_frames("N1") != [frame(0xA2, 10, 0, 10, 13)]:
            raise RuntimeError(f"N1 no longer maps onto the A2 strength frame: "
                               f"{broker_module.command_frames('N1')}")
        if broker_module.command_frames("B") is not None:
            raise RuntimeError("the retired B command still produces a frame")
        if broker_module.command_frames("C") is not None:
            raise RuntimeError("the retired C command still produces a frame")
    finally:
        os.close(mono_fd)
        stop()
        process.terminate()


def test_send_chokepoint_refuses_replying_commands():
    broker_module = load_broker_module()
    master, slave = pty.openpty()
    tty.setraw(master)
    tty.setraw(slave)
    records = []
    handler = logging.Handler()
    handler.emit = lambda record: records.append(record.getMessage())
    logger = logging.getLogger()
    logger.addHandler(handler)
    channel = broker_module.GunChannel(player="1", physical=master)
    try:
        channel.send(broker_module.frame(0xA8), "selftest-allowed")
        if read_exact(slave, 7, 1.0) != frame(0xA8):
            raise RuntimeError("the whitelisted A8 frame was not written to the device")
        banned = [
            (broker_module.frame(0xA0), "A0 answers the host"),
            (broker_module.frame(0xA7, 0x11), "A7 answers the host"),
            (broker_module.frame(0xA9), "A9 is unverified"),
            (broker_module.frame(0xAA), "AA is unverified"),
            (broker_module.frame(0xAB), "AB answers the host"),
            (broker_module.frame(0xAC), "AC answers the host"),
            (broker_module.frame(0xA1, 0), "A1 0 swallows the next trigger pull"),
            (broker_module.frame(0x6E), "the handshake frame does not belong to HOTR"),
            (bytes([0xAA, 0xA8, 0, 0, 0, 0]), "truncated frame"),
            (bytes([0xAA, 0xA8, 0, 0, 0, 0, 0xCC]), "wrong trailer"),
        ]
        for data, reason in banned:
            channel.send(data, "selftest-banned")
        if read_exact(slave, 1, 0.5):
            raise RuntimeError(
                f"the chokepoint wrote a banned frame to the device: {reason}")
        refused = [message for message in records if "refused frame" in message]
        if len(refused) != len(banned):
            raise RuntimeError(f"expected {len(banned)} refusals, logged {len(refused)}: "
                               f"{records}")
    finally:
        logger.removeHandler(handler)
        os.close(master)
        os.close(slave)


def test_direct_write_backend():
    process, slave, report = start_gun(name="direct")
    port, log, stop = start_direct_broker(slave, "direct", 45979)
    try:
        client = socket.create_connection(("127.0.0.1", port), 2)
        client.sendall(b"1N8\n")
        client.sendall(b"1A\n")
        client.close()
        if not wait_for(lambda: read_json(report).get("frames", {}).get("a2", 0) >= 1, 5):
            raise RuntimeError(f"the direct backend wrote nothing: {read_json(report)}")
        state = read_json(report)
        sent = state.get("frame_log", [])
        if "aa a2 50 00 50 0d bb" not in sent:
            raise RuntimeError(f"N8 lost its A2 payload in direct mode: {sent}")
        if "aa a8 00 00 00 00 bb" not in sent:
            raise RuntimeError(f"the direct backend never fired: {sent}")
        for banned in ("a0", "a7", "a9", "aa", "ab", "ac"):
            if banned in state["frames"]:
                raise RuntimeError(f"the direct backend emitted {banned}: {state['frames']}")
        # A /dev/pts device is a test fixture, so the auto gate must stay out of the way.
        if "no LightgunMono tracker" in read_log(log):
            raise RuntimeError("the tracker gate blocked a non-kernel test device")
        if "is not player" in read_log(log):
            raise RuntimeError(f"a PTY device was mistaken for a Sinden gun: {read_log(log)}")
        if "direct write-only backend" not in read_log(log):
            raise RuntimeError(f"the broker did not announce direct mode: {read_log(log)}")
        # F12: the diagnostics state file must carry identity and counters.
        published = read_json(TMP / "run-direct" / "state.json").get("players", {}).get("1", {})
        if not wait_for(lambda: read_json(TMP / "run-direct" / "state.json")["players"]["1"]["sent"] >= 2, 6):
            raise RuntimeError("the state file never counted the delivered frames")
        published = read_json(TMP / "run-direct" / "state.json")["players"]["1"]
        if published["backend"] != "direct" or published["device"] != slave:
            raise RuntimeError(f"the state file reports the wrong backend or device: {published}")
        if published["dropped"] or published["refused"]:
            raise RuntimeError(f"clean commands were counted as drops or refusals: {published}")
        if published["reply_bytes"]:
            raise RuntimeError(f"direct mode must never read the gun: {published}")
        if published["last_frame"] != "aa a8 00 00 00 00 bb":
            raise RuntimeError(f"the state file lost the last delivered frame: {published}")
        # F13: hotr-status shows when the last frame went out.
        if not isinstance(published.get("last_frame_time"), str) or "T" not in published["last_frame_time"]:
            raise RuntimeError(f"the state file lost the last frame time: {published}")
        if not isinstance(published.get("last_frame_age"), int) or published["last_frame_age"] < 0:
            raise RuntimeError(f"the state file lost the last frame age: {published}")
    finally:
        stop()
        process.terminate()


def test_gunless_session_warns_on_connect():
    """A game that connects with no gun attached must say so out loud."""
    run_dir = TMP / "run-gunless"
    run_dir.mkdir(parents=True, exist_ok=True)
    log = run_dir / "broker.log"
    broker = subprocess.Popen([sys.executable, BROKER, "--port", "1=45981", "--log", str(log),
                               "--state-file", str(run_dir / "state.json")],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    PROCS.append(broker)
    try:
        if not wait_for(lambda: "listening on" in read_log(log), 5):
            raise RuntimeError(f"the gunless broker did not start: {read_log(log)}")
        client = socket.create_connection(("127.0.0.1", 45981), 2)
        client.sendall(b"1A\n")
        client.close()
        if not wait_for(lambda: "no Sinden gun is attached; recoil will be dropped" in read_log(log), 5):
            raise RuntimeError(f"a game with no gun was not warned: {read_log(log)}")
        state = read_json(run_dir / "state.json")
        entry = (state.get("players") or {}).get("1", {})
        if entry.get("backend") != "none" or entry.get("sent"):
            raise RuntimeError(f"a gunless player was counted as having sent frames: {entry}")
    finally:
        if broker.poll() is None:
            broker.terminate()
        try:
            broker.wait(timeout=5)
        except subprocess.TimeoutExpired:
            broker.kill()


def open_pty_pair():
    """Open a PTY pair that Mono itself has configured, as Mono would."""
    master_fd, slave_fd = pty.openpty()
    tty.setraw(slave_fd)
    return os.ttyname(slave_fd), master_fd, slave_fd


def test_port_is_left_alone():
    """Section A: no reads, no termios changes, and gun bytes stay queued."""
    text = Path(BROKER).read_text(encoding="utf-8")
    if "O_WRONLY | os.O_NOCTTY | os.O_NONBLOCK" not in text:
        raise RuntimeError("the direct writer no longer opens the device write-only")
    path, master_fd, slave_fd = open_pty_pair()
    port, log, stop = start_direct_broker(path, "leavealone", 45982)
    try:
        before = termios.tcgetattr(slave_fd)
        client = socket.create_connection(("127.0.0.1", port), 2)
        # Every HOTR command letter, plus bytes the broker must ignore.
        sweep = b"".join(f"1{letter}\n".encode() for letter in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        sweep += b"2A\n2D\n2N5\n2U1\nBA\n\n\x00\n"
        client.sendall(sweep)
        client.close()
        if not wait_for(lambda: "serial aa a8 00 00 00 00 bb" in read_log(log), 8):
            raise RuntimeError(f"no frame was written during the sweep: {read_log(log)}")
        after = termios.tcgetattr(slave_fd)
        if before != after:
            raise RuntimeError(f"the broker changed the port settings: {before} -> {after}")
        # Bytes the gun sends must still be waiting: nothing may drain the port.
        os.write(master_fd, b"\x11\x22\x33")
        time.sleep(0.4)
        queued = collect(slave_fd, 0.5)
        if queued != b"\x11\x22\x33":
            raise RuntimeError(f"the broker consumed gun bytes: {queued.hex(' ')}")
    finally:
        stop()
        for fd in (master_fd, slave_fd):
            with suppress(OSError):
                os.close(fd)


def split_strace_line(line):
    """Return (pid, syscall text); the pid is empty when strace omits it."""
    for pattern in (r"\[pid\s+(\d+)\]\s+", r"(\d+)\s+"):
        match = re.match(pattern, line)
        if match:
            return match.group(1), line[match.end():]
    return "", line


def analyze_strace(text, device):
    """Return (device opens, reads on it, termios ioctls on it) from a trace."""
    lines = [split_strace_line(line) for line in text.splitlines()]
    opens = []
    for index, (pid, rest) in enumerate(lines):
        match = re.match(r"(?:openat|open)\((.*)\)\s*=\s*(\d+)$", rest)
        if not match:
            continue
        args, fd = match.groups()
        if f'"{device}"' in args:
            opens.append((pid, fd, index, args))
    reads = 0
    termios_calls = 0
    for pid, fd, index, _args in opens:
        end = len(lines)
        for later in range(index + 1, len(lines)):
            if lines[later][0] == pid and lines[later][1].startswith(f"close({fd})"):
                end = later
                break
        for line_pid, rest in lines[index:end]:
            if line_pid != pid:
                continue
            if rest.startswith(f"read({fd},") or rest.startswith(f"read({fd})"):
                reads += 1
            if re.match(rf"ioctl\({fd},\s*TC(?:GETS|SETS)", rest):
                termios_calls += 1
    return opens, reads, termios_calls


def strace_is_clean(text, device):
    """True when the trace only ever writes to the device, without termios."""
    opens, reads, termios_calls = analyze_strace(text, device)
    if not opens or reads or termios_calls:
        return False
    return all("O_WRONLY" in args and "O_RDWR" not in args for _pid, _fd, _i, args in opens)


def test_strace_shows_no_reads_or_termios():
    """Section A: the syscall log must show write-only opens and no reads."""
    device = "/dev/pts/99"
    clean = (f'1  openat(AT_FDCWD, "{device}", O_WRONLY|O_NOCTTY|O_NONBLOCK) = 3\n'
             '1  write(3, "\\252\\250", 7) = 7\n'
             '1  close(3) = 0\n')
    bracketed = clean.replace("1  ", "[pid 7] ")
    pidless = "\n".join(line.partition("  ")[2] for line in clean.splitlines())
    for text, label in ((clean, "a pid-prefixed log"), (bracketed, "a [pid] log"), (pidless, "a pid-less log")):
        if not strace_is_clean(text, device):
            raise RuntimeError(f"the strace parser misread {label}: {text!r}")
    fixtures = [(clean.replace("write(3", "read(3"), "a read on the device"),
                (clean.replace("O_WRONLY", "O_RDWR"), "a read-write open"),
                (clean.replace("write(3", "ioctl(3, TCSETS) = 0\n1  write(3", 1), "a termios call"),
                (clean.replace(device, "/dev/pts/98"), "a trace without the device")]
    for text, label in fixtures:
        if strace_is_clean(text, device):
            raise RuntimeError(f"the strace parser accepted {label}: {text!r}")
    strace = shutil.which("strace")
    if strace is None:
        raise SkipCheck("strace is not installed; the Batocera run covers the syscall log")
    run_dir = TMP / "run-strace"
    run_dir.mkdir(parents=True, exist_ok=True)
    strace_log = run_dir / "strace.log"
    log = run_dir / "broker.log"
    path, _master_fd, _slave_fd = open_pty_pair()
    process = subprocess.Popen([strace, "-f", "-o", str(strace_log),
                                "-e", "trace=openat,open,read,write,ioctl,close",
                                sys.executable, BROKER, "--port", "1=45983",
                                "--device", f"1={path}", "--log", str(log)],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    PROCS.append(process)
    try:
        if not wait_for(lambda: "listening on" in read_log(log), 10):
            raise RuntimeError(f"the traced broker did not start: {read_log(log)}")
        client = socket.create_connection(("127.0.0.1", 45983), 2)
        for command in (b"1N8\n", b"1D\n", b"1J0\n", b"1A\n"):
            client.sendall(command)
        client.close()
        if not wait_for(lambda: read_log(log).count("serial ") >= 4, 8):
            raise RuntimeError(f"the traced broker wrote no frames: {read_log(log)}")
        time.sleep(0.3)
    finally:
        if process.poll() is None:
            process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
    text = strace_log.read_text(encoding="utf-8", errors="replace")
    opens, reads, termios_calls = analyze_strace(text, path)
    if not opens:
        raise RuntimeError(f"the trace never opens {path}: {text[-400:]}")
    for _pid, _fd, _index, args in opens:
        if "O_WRONLY" not in args or "O_RDWR" in args:
            raise RuntimeError(f"the direct writer opened the device as {args}")
    if reads or termios_calls:
        raise RuntimeError(f"the traced run shows {reads} read(s) and {termios_calls} termios ioctl(s)")


def test_tracker_gate_waits_for_lightgunmono():
    process, slave, report = start_gun(name="gate")
    root = TMP / "run-gate" / "sinden"
    root.mkdir(parents=True, exist_ok=True)
    port, log, stop = start_direct_broker(slave, "gate", 45980,
                                          ("--tracker-gate", "on", "--tracker-root", str(root)))
    try:
        client = socket.create_connection(("127.0.0.1", port), 2)
        client.sendall(b"1A\n")
        client.close()
        if not wait_for(lambda: "dropping A until a LightgunMono tracker owns" in read_log(log), 5):
            raise RuntimeError(f"the gate did not drop early recoil: {read_log(log)}")
        if read_json(report)["frames"]:
            raise RuntimeError("a frame reached the gun before LightgunMono's tracker was up")
        gate_state = TMP / "run-gate" / "state.json"
        if not wait_for(lambda: read_json(gate_state)["players"]["1"]["dropped"] >= 1, 8):
            raise RuntimeError(f"the state file does not show the gate drop: {read_json(gate_state)}")
        gated = read_json(gate_state)["players"]["1"]
        if gated["sent"]:
            raise RuntimeError(f"the state file counted a gated frame as sent: {gated}")
        config_dir = root / "pdeadbeef"
        config_dir.mkdir(parents=True, exist_ok=True)
        (config_dir / "LightgunMono-deadbeef.exe.config").write_text(
            '<configuration><appSettings><add key="SerialPortWrite" value="'
            f'{slave}" /></appSettings></configuration>\n', encoding="utf-8")
        if not wait_for(lambda: "tracker is up on" in read_log(log), 6):
            raise RuntimeError(f"the gate never noticed the tracker config: {read_log(log)}")
        client = socket.create_connection(("127.0.0.1", port), 2)
        client.sendall(b"1A\n")
        client.close()
        if not wait_for(lambda: read_json(report)["frames"].get("a8", 0) >= 1, 5):
            raise RuntimeError("recoil stayed blocked after the tracker came up")
        if "aa a8 00 00 00 00 bb" not in read_json(report).get("frame_log", []):
            raise RuntimeError("the unblocked frame was not the whitelisted A8")
    finally:
        stop()
        process.terminate()


def test_usb_identity_verification():
    """F7: guns are resolved by USB id, and a mismatch is a warning."""
    broker_module = load_broker_module()
    root = TMP / "run-usb"
    dev_root = root / "dev"
    tty_root = root / "sys" / "tty"
    dev_root.mkdir(parents=True, exist_ok=True)
    for name, product in (("ttyACM0", "0f01"), ("ttyACM1", "0f39")):
        (dev_root / name).write_text("", encoding="utf-8")
        node = tty_root / name / "device"
        node.mkdir(parents=True, exist_ok=True)
        (node / "idVendor").write_text("16c0\n", encoding="ascii")
        (node / "idProduct").write_text(f"{product}\n", encoding="ascii")
        if broker_module.usb_id_of(str(dev_root / name), tty_root) != f"16c0:{product}":
            raise RuntimeError(f"usb_id_of did not read the sysfs identity of {name}")
    found = broker_module.discover_devices(dev_root, tty_root)
    expected = {"1": str(dev_root / "ttyACM1"), "2": str(dev_root / "ttyACM0")}
    if found != expected:
        raise RuntimeError(f"USB ids resolved to the wrong players: {found} != {expected}")
    records = []
    handler = logging.Handler()
    handler.emit = lambda record: records.append(record.getMessage())
    logger = logging.getLogger()
    logger.addHandler(handler)
    try:
        # ttyACM0 is player 2's gun, so asking for player 1 must warn.
        broker_module.verify_device(str(dev_root / "ttyACM0"), "1", tty_root)
        broker_module.verify_device(str(dev_root / "ttyACM1"), "1", tty_root)
    finally:
        logger.removeHandler(handler)
    if not any("gun on port" in message and "is not player 1" in message for message in records):
        raise RuntimeError(f"the USB id mismatch warning was not logged: {records}")
    if not any("16c0:0f01" in message for message in records):
        raise RuntimeError(f"the warning did not name the offending USB id: {records}")
    if len(records) != 1:
        raise RuntimeError(f"the matching gun also warned: {records}")


def test_debug_report_reads_state_file():
    """F12: the debug report renders identity, frames sent and reply bytes."""
    script = Path(DEBUG_REPORT)
    if not script.is_file():
        raise SkipCheck("hotr-debug-report.sh is not installed here")
    readers = re.findall(r"python3 - \"\$SINDEN_STATE\" <<'PY'\n(.*?)\nPY",
                         script.read_text(encoding="utf-8"), re.S)
    if len(readers) != 2:
        raise RuntimeError(f"{script} must embed the summary and issue readers, found {len(readers)}")
    state = TMP / "run-report" / "state.json"
    state.parent.mkdir(parents=True, exist_ok=True)
    state.write_text(json.dumps({
        "updated": "2026-01-01T00:00:00",
        "pid": 4242,
        "control_socket": None,
        "players": {
            "1": {
                "backend": "direct", "device": "/dev/ttyACM0", "usb_id": "16c0:0f39",
                "tracker_ready": True, "worker": False, "sent": 7, "dropped": 1,
                "refused": 2, "reply_bytes": 0, "last_frame": "aa a8 00 00 00 00 bb",
                "last_reason": "A", "last_reply": None,
                "last_refusal": "command A0 is not allowed",
            },
            "2": {
                "backend": "bridge", "device": None, "usb_id": None, "tracker_ready": False,
                "worker": True, "sent": 0, "dropped": 0, "refused": 0, "reply_bytes": 5,
                "last_frame": None, "last_reason": None, "last_reply": "11 22 33 44 55",
                "last_refusal": None,
            },
        },
    }), encoding="utf-8")
    rendered = []
    for reader in readers:
        result = subprocess.run([sys.executable, "-", str(state)], input=reader,
                                text=True, capture_output=True, check=False)
        if result.returncode != 0:
            raise RuntimeError(f"the debug report reader failed: {result.stderr}")
        rendered.append(result.stdout)
    summary, issues = rendered
    for expected in ("sent=7", "usb=16c0:0f39", "aa a8 00 00 00 00 bb", "reply-bytes=5"):
        if expected not in summary:
            raise RuntimeError(f"the state summary is missing {expected!r}: {summary}")
    if "player 2 has no device" not in issues:
        raise RuntimeError(f"a gunless player was not reported as an issue: {issues}")
    if "5 gun reply byte(s)" not in issues:
        raise RuntimeError(f"bridge reply bytes were not reported as an issue: {issues}")
    if "2 frame(s) refused" not in issues:
        raise RuntimeError(f"refused frames were not reported as an issue: {issues}")


def test_gun_bytes_still_reach_mono_pty():
    process, slave, report = start_gun(name="bridge",
                                       state="0x36C=0x11,0x36D=0x22,0x36E=0x33,0x36F=0x44")
    port, mono, log, stop = start_broker_and_worker(slave, "bridge", 45978)
    mono_fd = os.open(mono, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    device_fd = os.open(slave, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        # The chokepoint stops HOTR from emitting A7, so inject the frame at the
        # device exactly as a stray Mono write or an older install would.
        os.write(device_fd, frame(0xA7, 0x00))
        if not wait_for(lambda: "a7" in read_json(report).get("frames", {}), 5):
            raise RuntimeError(f"A7 frame never arrived: {read_json(report)}")
        reply = read_json(report)["replies"].get("a7", {}).get("hex")
        if reply != "11 22 33 44":
            raise RuntimeError(f"firmware-faithful A7 reply expected, got {reply!r}")
        leaked = collect(mono_fd, 1.5)
        if leaked:
            message = (f"gun reply {leaked.hex(' ')} was injected into LightgunMono's PTY "
                       f"(worker {log})")
            if EXPECT_LEAK:
                print(f"[WARN] {message} — expected until the PTY bridge is retired "
                      "(HOTR_SINDEN_EXPECT_LEAK=0 makes this fatal)")
                return
            raise RuntimeError(message)
        if not EXPECT_LEAK:
            return
        raise RuntimeError("bridge check did not observe the known reply leak; "
                           "refusing to pass a containment test that proves nothing")
    finally:
        os.close(device_fd)
        os.close(mono_fd)
        stop()
        process.terminate()


try:
    report("firmware dispatch table matches the decoded image", test_table_matches_firmware)
    report("handshake reply matches LightgunMono's verification", test_handshake)
    report("whitelist commands arrive as silent 7-byte frames", test_whitelist_frames_are_silent)
    report("the default backend writes the device directly", test_direct_write_backend)
    report("a game session without a gun says so at connect time",
           test_gunless_session_warns_on_connect)
    report("the direct backend leaves the port and the gun's bytes alone",
           test_port_is_left_alone)
    report("the syscall log shows write-only access and no termios",
           test_strace_shows_no_reads_or_termios)
    report("the tracker gate blocks recoil until LightgunMono is up",
           test_tracker_gate_waits_for_lightgunmono)
    report("guns are resolved by USB id and a mismatch warns", test_usb_identity_verification)
    report("unsafe frames are refused at the write chokepoint",
           test_send_chokepoint_refuses_replying_commands)
    report("the debug report renders the broker state file", test_debug_report_reads_state_file)
    report("gun bytes still reach LightgunMono's PTY until the bridge is retired",
           test_gun_bytes_still_reach_mono_pty)
finally:
    for process in PROCS:
        if process.poll() is None:
            process.terminate()
    for process in PROCS:
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()

print()
if skips:
    print(f"[INFO] {len(skips)} check(s) skipped here: " + ", ".join(name for name, _ in skips))
if failures:
    print(f"[FAIL] {len(failures)} check(s) failed")
    sys.exit(1)
print("[PASS] firmware-faithful fake gun behaves as the documented hardware does")
PY
