#!/usr/bin/env python3
"""Run the patched Batocera Sinden udev helper against a fake gun."""

from __future__ import annotations

import os
import pty
import re
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
ROOT = SCRIPT_DIR.parents[1] if (SCRIPT_DIR.parents[1] / "payload/system/hotr-sinden-broker.py").exists() else SCRIPT_DIR.parent
if (ROOT / "payload/system/hotr-sinden-broker.py").exists():
    BROKER = ROOT / "payload/system/hotr-sinden-broker.py"
    PATCH = ROOT / "scripts/patch-batocera-sinden-hotr.sh"
    V43_HELPER = ROOT / "buildroot/src/batocera.linux-43/package/batocera/controllers/guns/sinden-guns/virtual-sindenlightgun-add"
else:
    BROKER = Path("/userdata/system/hotr/bin/hotr-sinden-broker.py")
    PATCH = Path("/userdata/system/hotr/tools/patch-batocera-sinden-hotr.sh")
    V43_HELPER = Path(os.environ.get("HOTR_SINDEN_V43_HELPER", "/usr/bin/virtual-sindenlightgun-add"))
V44_HELPER = Path(os.environ.get("HOTR_SINDEN_V44_HELPER", "/usr/bin/virtual-sindenlightgun-add"))
WORKER = Path("/userdata/system/hotr/bin/hotr-sinden-worker-launch")


def wait_for(fd: int, expected: bytes, timeout: float = 5) -> bytes:
    end = time.time() + timeout
    data = b""
    while time.time() < end:
        ready, _, _ = select.select([fd], [], [], 0.2)
        if ready:
            data += os.read(fd, 4096)
            if expected in data:
                return data
    raise RuntimeError(f"serial did not receive {expected.hex(' ')}; got {data.hex(' ')}")


def make_command(directory: Path, name: str, body: str) -> None:
    path = directory / name
    path.write_text("#!/bin/bash\nset -e\n" + body, encoding="utf-8")
    path.chmod(0o755)


def run_variant(source: Path, label: str, broker: subprocess.Popen, master: int, temp: Path) -> None:
    if not source.is_file():
        raise RuntimeError(f"{label} helper unavailable: {source}")
    fixture = temp / f"helper-{label}"
    shutil.copy2(source, fixture)
    fixture.chmod(0o755)
    backup = temp / f"backup-{label}"
    env = dict(os.environ, HOTR_SINDEN_ADD_PATH=str(fixture), HOTR_SINDEN_BACKUP_DIR=str(backup))
    subprocess.run([str(PATCH), "apply"], check=True, env=env, capture_output=True, text=True)

    hash_name = f"native-{label}-{os.getpid()}"
    device = Path("/dev/ttyACM0")
    if device.exists() or device.is_symlink():
        raise RuntimeError("/dev/ttyACM0 already exists; refusing to overwrite it")
    os.symlink(os.ttyname(physical_slave), device)
    old_started = Path("/var/run/virtual-events.started").exists()
    Path("/var/run/virtual-events.started").touch()
    try:
        result = subprocess.run(
            [str(fixture)],
            env=dict(env, ACTION="add", DEVNAME="/dev/input/event999", DEVPATH="/devices/fake/input999"),
            capture_output=True,
            text=True,
            timeout=15,
        )
        if result.returncode:
            raise RuntimeError(f"{label} helper exited {result.returncode}: {result.stderr.strip()}")

        config = Path(f"/var/run/sinden/p{hash_name}/LightgunMono-{hash_name}.exe.config")
        # The fake evsieve-helper supplies this hash through the parent query.
        candidates = list(Path("/var/run/sinden").glob("p*/LightgunMono-*.exe.config"))
        if not candidates:
            raise RuntimeError(f"{label} did not create a Mono config")
        config = candidates[-1]
        xml = config.read_text(encoding="utf-8")
        match = re.search(r'key="SerialPortWrite"\s+value="([^"]+)"', xml)
        if not match or not match.group(1).startswith("/dev/pts/"):
            raise RuntimeError(f"{label} config did not receive a worker PTY: {xml}")
        pty_path = match.group(1)
        if not Path(pty_path).exists():
            raise RuntimeError(f"{label} worker PTY does not exist: {pty_path}")

        client = socket.create_connection(("127.0.0.1", 45992), 2)
        client.sendall(b"1A\n")
        client.close()
        wait_for(master, bytes.fromhex("aa a8 00 00 00 00 bb"))
        print(f"[PASS] {label} native helper generated Mono PTY {pty_path} and routed HOTR recoil")
    finally:
        for pid_file in Path("/var/run/hotr-sinden").glob("pnative-*.worker.pid"):
            try:
                os.kill(int(pid_file.read_text().strip()), 15)
            except (OSError, ValueError):
                pass
            pid_file.unlink(missing_ok=True)
            Path(str(pid_file).replace(".worker.pid", ".pty")).unlink(missing_ok=True)
        for path in Path("/var/run/sinden").glob("p*/LightgunMono-*.exe.config"):
            parent = path.parent
            shutil.rmtree(parent, ignore_errors=True)
        device.unlink(missing_ok=True)
        if not old_started:
            Path("/var/run/virtual-events.started").unlink(missing_ok=True)
        subprocess.run([str(PATCH), "remove"], check=True, env=env, capture_output=True, text=True)


with tempfile.TemporaryDirectory(prefix="hotr-native-helper-") as raw:
    temp = Path(raw)
    fake_log = temp / "fake-commands.log"
    fake_log_q = str(fake_log)
    make_command(temp, "evsieve-helper", f'''\ncase "$1" in\n  parent|parent-raw) echo "native-test-parent" ;;\n  children)\n    if [ "$3" = input ]; then printf "/dev/input/event101\\n/dev/input/event102\\n"; else printf "/dev/video88\\n"; fi ;;\nesac\n''')
    make_command(temp, "evsieve", f'''printf "evsieve %s\\n" "$*" >> "{fake_log_q}"\n''')
    make_command(temp, "mono-service", f'''printf "mono-service %s\\n" "$*" >> "{fake_log_q}"\n''')
    make_command(temp, "batocera-settings-get", 'case "$2" in *recoil*) echo gun ;; *) echo "" ;; esac\n')
    make_command(temp, "find", 'printf "/sys/devices/fake/ttyACM0\\n"\n')
    make_command(temp, "cp", '''dest="${@: -1}"; mkdir -p "$dest"; printf '<configuration><appSettings><add key="SerialPortWrite" value="/dev/ttyACM0" /></appSettings></configuration>\n' > "$dest/LightgunMono.exe.config"; : > "$dest/LightgunMono.exe"\n''')

    physical_master, physical_slave = pty.openpty()
    control = Path("/var/run/hotr-sinden/broker.sock")
    broker = subprocess.Popen([
        sys.executable, str(BROKER), "--port", "1=45992",
        "--control-socket", str(control), "--log", str(temp / "broker.log"),
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.time() + 5
        while time.time() < deadline and not control.exists():
            time.sleep(0.05)
        if not control.exists():
            raise RuntimeError("broker control socket did not appear")
        path_env = f"{temp}:{os.environ.get('PATH', '')}"
        os.environ["PATH"] = path_env
        run_variant(V43_HELPER, "batocera43", broker, physical_master, temp)
        run_variant(V44_HELPER, "batocera44", broker, physical_master, temp)
    finally:
        broker.terminate()
        broker.wait(timeout=5)
        control.unlink(missing_ok=True)
        os.close(physical_master)
        os.close(physical_slave)

print("SUMMARY: native Batocera helper emulation passed for v43 and v44")
