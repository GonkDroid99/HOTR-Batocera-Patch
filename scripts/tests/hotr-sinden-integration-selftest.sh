#!/bin/bash
# Full installed-path test using a pseudo-terminal as an emulated Sinden gun.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/../../payload/system/hotr-sinden-broker.py" ]; then
  ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
else
  ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
if [ -f "$ROOT/payload/system/hotr-sinden-broker.py" ]; then
  BROKER="$ROOT/payload/system/hotr-sinden-broker.py"
  WORKER_LAUNCH="$ROOT/payload/system/hotr-sinden-worker-launch"
else
  BROKER="$ROOT/bin/hotr-sinden-broker.py"
  WORKER_LAUNCH="$ROOT/bin/hotr-sinden-worker-launch"
fi

command -v python3 >/dev/null || { echo "[FAIL] python3 is unavailable" >&2; exit 1; }
[ -x "$WORKER_LAUNCH" ] || { echo "[FAIL] worker launcher is unavailable: $WORKER_LAUNCH" >&2; exit 1; }

python3 - "$BROKER" "$WORKER_LAUNCH" <<'PY'
import os
import pty
import select
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

broker_path, worker_path = sys.argv[1:]
run_dir = Path("/var/run/hotr-sinden")
control = run_dir / "broker.sock"
hash_name = f"selftest-{os.getpid()}"
pid_file = run_dir / f"p{hash_name}.worker.pid"
pty_file = run_dir / f"p{hash_name}.pty"
physical_master, physical_slave = pty.openpty()
physical = os.ttyname(physical_slave)
broker = None

def read_physical(expected: bytes) -> None:
    deadline = time.time() + 5
    data = b""
    while time.time() < deadline:
        ready, _, _ = select.select([physical_master], [], [], 0.25)
        if ready:
            data += os.read(physical_master, 4096)
            if expected in data:
                return
    raise RuntimeError(f"emulated Sinden did not receive {expected.hex(' ')}; got {data.hex(' ')}")

try:
    run_dir.mkdir(parents=True, exist_ok=True)
    broker = subprocess.Popen([
        sys.executable, broker_path, "--port", "1=45990",
        "--control-socket", str(control), "--log", "/tmp/hotr-sinden-integration.log",
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.time() + 5
    while time.time() < deadline and not control.exists():
        time.sleep(0.05)
    if not control.exists():
        raise RuntimeError("broker control socket did not appear")

    result = subprocess.run([
        worker_path, "start", hash_name, physical,
    ], check=True, capture_output=True, text=True)
    mono_path = result.stdout.strip().splitlines()[-1]
    if not os.path.exists(mono_path):
        raise RuntimeError(f"worker PTY did not appear: {mono_path}")

    client = socket.create_connection(("127.0.0.1", 45990), 2)
    client.sendall(b"1A\n")
    client.close()
    read_physical(bytes.fromhex("aa a8 00 00 00 00 bb"))

    mono_fd = os.open(mono_path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    os.write(mono_fd, b"sinden-mono-test")
    read_physical(b"sinden-mono-test")
    os.close(mono_fd)
finally:
    if pid_file.exists():
        try:
            os.kill(int(pid_file.read_text().strip()), 15)
        except (OSError, ValueError):
            pass
        try:
            pid_file.unlink()
        except FileNotFoundError:
            pass
    try:
        pty_file.unlink()
    except FileNotFoundError:
        pass
    if broker is not None:
        broker.terminate()
        broker.wait(timeout=5)
    try:
        control.unlink()
    except FileNotFoundError:
        pass
    try:
        os.close(physical_master)
        os.close(physical_slave)
    except OSError:
        pass
    map_file = Path("/userdata/system/hotr/sinden-player-map")
    if map_file.exists():
        lines = [line for line in map_file.read_text().splitlines() if not line.startswith(hash_name + "=")]
        map_file.write_text("\n".join(lines) + ("\n" if lines else ""))

print("[PASS] Installed Sinden helper -> worker -> emulated serial integration.")
PY
