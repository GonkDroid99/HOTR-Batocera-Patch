#!/bin/bash
# Comprehensive hardware-free Sinden/Batocera integration test.
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
  PATCH_TOOL="$ROOT/scripts/patch-batocera-sinden-hotr.sh"
  STOCK_HELPER="$ROOT/buildroot/src/batocera.linux-43/package/batocera/controllers/guns/sinden-guns/virtual-sindenlightgun-add"
else
  BROKER="$ROOT/bin/hotr-sinden-broker.py"
  WORKER_LAUNCH="$ROOT/bin/hotr-sinden-worker-launch"
  PATCH_TOOL="$ROOT/tools/patch-batocera-sinden-hotr.sh"
  STOCK_HELPER=/usr/bin/virtual-sindenlightgun-add
fi

LOG="${HOTR_SINDEN_TEST_LOG:-/userdata/system/logs/hotr-sinden-full-selftest.log}"
V43_HELPER="${HOTR_SINDEN_V43_HELPER:-$STOCK_HELPER}"
mkdir -p "$(dirname "$LOG")"
exec > >(tee "$LOG") 2>&1

echo "HOTR Sinden comprehensive self-test"
echo "Started: $(date)"
echo "Broker: $BROKER"
echo "Worker launcher: $WORKER_LAUNCH"
echo "Patch tool: $PATCH_TOOL"

[ -x "$WORKER_LAUNCH" ] || { echo "[FAIL] worker launcher unavailable"; exit 1; }
[ -x "$PATCH_TOOL" ] || { echo "[FAIL] patch tool unavailable"; exit 1; }

python3 - "$BROKER" "$WORKER_LAUNCH" "$PATCH_TOOL" "$V43_HELPER" "$STOCK_HELPER" <<'PY'
import os
import pty
import select
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

broker_path, worker_path, patch_path, v43_helper, v44_helper = sys.argv[1:]
run_dir = Path("/var/run/hotr-sinden")
control = run_dir / "broker.sock"
broker_log = Path("/tmp/hotr-sinden-full-selftest-broker.log")
map_file = Path("/userdata/system/hotr/sinden-player-map")
results = []
workers = []
guns = {}
broker = None

def cleanup_old_test_runtime():
    for path in run_dir.glob("pfulltest-*.worker.pid"):
        try:
            os.kill(int(path.read_text().strip()), 15)
        except (OSError, ValueError):
            pass
        path.unlink(missing_ok=True)
        Path(str(path).replace(".worker.pid", ".pty")).unlink(missing_ok=True)
    for path in run_dir.glob("pfulltest-*.pty"):
        path.unlink(missing_ok=True)

def report(name, fn):
    try:
        fn()
        results.append((name, True, ""))
        print(f"[PASS] {name}")
    except Exception as exc:
        results.append((name, False, str(exc)))
        print(f"[FAIL] {name}: {exc}")

def read_fd(fd, expected, timeout=5):
    deadline = time.time() + timeout
    data = b""
    while time.time() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.2)
        if ready:
            data += os.read(fd, 4096)
            if expected in data:
                return data
    raise RuntimeError(f"expected {expected.hex(' ')}; received {data.hex(' ')}")

def launch_gun(name):
    master, slave = pty.openpty()
    physical = os.ttyname(slave)
    result = subprocess.run([worker_path, "start", name, physical], check=True,
                            capture_output=True, text=True)
    mono = result.stdout.strip().splitlines()[-1]
    if not os.path.exists(mono):
        raise RuntimeError(f"worker PTY missing: {mono}")
    pid_file = run_dir / f"p{name}.worker.pid"
    workers.append((name, master, slave, pid_file))
    guns[name] = {"master": master, "slave": slave, "mono": os.open(mono, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK), "path": mono}

def send(port, command):
    client = socket.create_connection(("127.0.0.1", port), 2)
    client.sendall(command.encode("ascii") + b"\n")
    client.close()

def physical(name, expected):
    return read_fd(guns[name]["master"], expected)

def mono(name, data):
    os.write(guns[name]["mono"], data)
    return physical(name, data)

def test_patch_variants():
    if not Path(v43_helper).is_file():
        raise RuntimeError(f"Batocera 43 helper unavailable: {v43_helper}")
    if not Path(v44_helper).is_file():
        raise RuntimeError(f"Batocera 44 helper unavailable: {v44_helper}")
    with tempfile.TemporaryDirectory(prefix="hotr-sinden-patch-test-") as raw:
        root = Path(raw)
        for variant, source in (("batocera43", v43_helper), ("batocera44", v44_helper)):
            helper = root / f"virtual-sindenlightgun-add-{variant}"
            backup = root / f"backup-{variant}"
            fixture = Path(source).read_bytes()
            helper.write_bytes(fixture)
            helper.chmod(0o755)
            env = dict(os.environ, HOTR_SINDEN_ADD_PATH=str(helper), HOTR_SINDEN_BACKUP_DIR=str(backup))
            subprocess.run([patch_path, "apply"], check=True, env=env, capture_output=True, text=True)
            patched = helper.read_text()
            if patched.count("HOTR SINDEN BROKER INTEGRATION") != 1:
                raise RuntimeError(f"{variant}: marker missing or duplicated")
            if 'HOTR_MONO_TTY=$(/userdata/system/hotr/bin/hotr-sinden-worker-launch' not in patched:
                raise RuntimeError(f"{variant}: worker hook missing")
            subprocess.run([patch_path, "remove"], check=True, env=env, capture_output=True, text=True)
            if helper.read_bytes() != fixture:
                raise RuntimeError(f"{variant}: remove did not restore stock helper")

try:
    run_dir.mkdir(parents=True, exist_ok=True)
    cleanup_old_test_runtime()
    if control.exists():
        control.unlink()
    try:
        broker_log.unlink()
    except FileNotFoundError:
        pass
    broker = subprocess.Popen([
        sys.executable, broker_path,
        "--port", "1=45990", "--port", "2=45991",
        "--control-socket", str(control), "--log", str(broker_log),
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.time() + 5
    while time.time() < deadline and not control.exists():
        time.sleep(0.05)
    if not control.exists():
        raise RuntimeError("broker control socket did not appear")

    report("Batocera helper patch apply/remove for v43/v44 contracts", test_patch_variants)
    report("first emulated Sinden worker creates a Mono PTY", lambda: launch_gun(f"fulltest-{os.getpid()}-a"))
    report("second emulated Sinden worker creates a second gun", lambda: launch_gun(f"fulltest-{os.getpid()}-b"))
    names = list(guns)
    if len(names) == 2:
        first, second = names
        report("player 1 HOTR recoil routing", lambda: (send(45990, "1A"), physical(first, bytes.fromhex("aa a8 00 00 00 00 bb"))))
        report("player 2 HOTR recoil routing", lambda: (send(45991, "2A"), physical(second, bytes.fromhex("aa a8 00 00 00 00 bb"))))
        command_tests = [
            ("B repeat recoil", "1B", first, "aa a9 00 00 00 00 bb"),
            ("C stop recoil", "1C", first, "aa aa 00 00 00 00 bb"),
            ("D recoil disabled", "1D", first, "aa a3 00 00 00 00 bb"),
            ("E recoil enabled", "1E", first, "aa a3 01 00 00 00 bb"),
            ("N strength", "1N8", first, "aa a7 50 00 00 00 bb"),
            ("J enable flag", "1J1", first, "aa a1 01 00 00 00 bb"),
            ("K trigger flag", "1K1", first, "aa a4 01 00 00 00 bb"),
            ("P pulse settings", "1P80", first, "aa a2 50 00 50 0d bb"),
            ("Q pulse delay", "1Q9", first, "aa a2 32 00 32 09 bb"),
            ("R start delay", "1R5", first, "aa a2 32 05 32 0d bb"),
            ("S single recoil alias", "1S", first, "aa a8 00 00 00 00 bb"),
            ("U strength and recoil", "1U7", first, "aa a7 46 00 00 00 bb"),
        ]
        for label, command, gun, expected in command_tests:
            report(label, lambda command=command, gun=gun, expected=bytes.fromhex(expected): (send(45990, command), physical(gun, expected)))
        report("F preset produces configuration frames", lambda: (send(45990, "1F"), physical(first, bytes.fromhex("aa a2 50 05 50 0d bb"))))
        report("Mono-to-Sinden transparent serial path", lambda: mono(first, b"mono-config-test"))
        report("Sinden-to-Mono transparent serial path", lambda: (os.write(guns[first]["master"], b"sinden-status"), read_fd(guns[first]["mono"], b"sinden-status")))
        original_map = map_file.read_text() if map_file.exists() else ""
        report("stable player mapping is written", lambda: None if any(line.startswith(first + "=") for line in original_map.splitlines()) else (_ for _ in ()).throw(RuntimeError("mapping missing")))
        # Verify that a stopped/restarted worker retains its assigned player.
        def restart_same():
            entry = next(item for item in workers if item[0] == first)
            pid = int(entry[3].read_text().strip())
            os.kill(pid, 15)
            time.sleep(0.3)
            subprocess.run([worker_path, "start", first, os.ttyname(entry[2])], check=True, capture_output=True, text=True)
            mapping = map_file.read_text() if map_file.exists() else ""
            if not any(line.startswith(first + "=") for line in mapping.splitlines()):
                raise RuntimeError("player mapping was not retained")
        report("worker restart retains stable player assignment", restart_same)
finally:
    for name, master, slave, pid_file in workers:
        if pid_file.exists():
            try:
                os.kill(int(pid_file.read_text().strip()), 15)
            except (OSError, ValueError):
                pass
            pid_file.unlink(missing_ok=True)
        Path(str(pid_file).replace(".worker.pid", ".pty")).unlink(missing_ok=True)
        try:
            os.close(guns.get(name, {}).get("mono", -1))
        except OSError:
            pass
        for fd in (master, slave):
            try:
                os.close(fd)
            except OSError:
                pass
    if broker is not None:
        broker.terminate()
        broker.wait(timeout=5)
    try:
        control.unlink()
    except FileNotFoundError:
        pass
    if map_file.exists():
        prefixes = {name + "=" for name, *_ in workers}
        lines = [line for line in map_file.read_text().splitlines() if not any(line.startswith(prefix) for prefix in prefixes)]
        map_file.write_text("\n".join(lines) + ("\n" if lines else ""))

passed = sum(1 for _, ok, _ in results if ok)
failed = [(name, detail) for name, ok, detail in results if not ok]
print(f"SUMMARY: {passed} passed, {len(failed)} failed")
if failed:
    for name, detail in failed:
        print(f"FAILED: {name}: {detail}")
    raise SystemExit(1)
PY

echo "--- broker log tail ---"
tail -n 120 /tmp/hotr-sinden-full-selftest-broker.log 2>/dev/null || true
echo "--- runtime cleanup state ---"
find /var/run/hotr-sinden -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort || true
echo "Completed: $(date)"
echo "Log: $LOG"
