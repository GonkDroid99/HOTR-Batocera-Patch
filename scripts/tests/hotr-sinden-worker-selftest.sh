#!/bin/bash
# End-to-end simulated test: HOTR TCP -> broker -> worker -> fake serial.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/../../payload/system/hotr-sinden-broker.py" ]; then
  ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
else
  ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
if [ -f "$ROOT/payload/system/hotr-sinden-broker.py" ]; then
  BROKER="$ROOT/payload/system/hotr-sinden-broker.py"
else
  BROKER="$ROOT/bin/hotr-sinden-broker.py"
fi
python3 - "$BROKER" <<'PY'
import os
import pty
import select
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

broker = sys.argv[1]
with tempfile.TemporaryDirectory(prefix="hotr-sinden-worker-test-") as raw:
    work = Path(raw)
    control = work / "broker.sock"
    pty_file = work / "p1.pty"
    log = work / "broker.log"
    physical_master, physical_slave = pty.openpty()
    physical = os.ttyname(physical_slave)
    broker_proc = subprocess.Popen([
        sys.executable, broker, "--port", "1=45989", "--control-socket", str(control),
        "--log", str(log),
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    worker = None
    mono_fd = None
    try:
        deadline = time.time() + 5
        while time.time() < deadline and not control.exists():
            time.sleep(0.05)
        if not control.exists():
            raise RuntimeError("broker control socket did not appear")
        worker = subprocess.Popen([
            sys.executable, broker, "--worker", "--player", "1",
            "--device", f"1={physical}", "--control-socket", str(control),
            "--pty-file", str(pty_file), "--log", str(log),
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.time() + 5
        while time.time() < deadline and not pty_file.exists():
            time.sleep(0.05)
        if not pty_file.exists():
            raise RuntimeError(f"worker PTY file did not appear; log={log.read_text() if log.exists() else ''}")
        mono_path = pty_file.read_text().strip()
        mono_fd = os.open(mono_path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)

        client = socket.create_connection(("127.0.0.1", 45989), 2)
        client.sendall(b"1A\n")
        client.close()
        ready, _, _ = select.select([physical_master], [], [], 2)
        if not ready or os.read(physical_master, 64) != bytes.fromhex("aa a8 00 00 00 00 bb"):
            raise RuntimeError("HOTR recoil frame did not reach the physical serial side")

        os.write(mono_fd, b"mono-test")
        ready, _, _ = select.select([physical_master], [], [], 2)
        if not ready or os.read(physical_master, 64) != b"mono-test":
            raise RuntimeError("Mono PTY traffic did not reach the physical serial side")
    finally:
        if mono_fd is not None:
            os.close(mono_fd)
        if worker is not None:
            worker.terminate()
            worker.wait(timeout=3)
        broker_proc.terminate()
        broker_proc.wait(timeout=3)
        os.close(physical_master)
        os.close(physical_slave)
print("[PASS] HOTR TCP -> Sinden worker -> fake serial and Mono PTY forwarding.")
PY
