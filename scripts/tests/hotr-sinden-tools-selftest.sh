#!/bin/bash
# Self-test for the Sinden operator tools.
#
# Proves, without a gun and without root:
#   1. hotr-sinden-check resolves a running broker, its state file and counters;
#   2. hotr-sinden-check --fire sends exactly one A8 frame to the device and
#      reports it as delivered;
#   3. --fire refuses a player the listening port does not serve;
#   4. a dropped fire quotes the broker's own last_drop reason;
#   5. hotr-sinden-disable stops the broker and removes the enable file;
#   6. the tools are wired into install.sh, check-install.sh, uninstall.sh and
#      the README;
#   7. install.sh refuses to start when root, x86_64, a required tool or the
#      free space on /userdata is missing;
#   8. hotr-sinden-autoconfig keeps a Sinden entry preferring recoil over ammo;
#   9. the report names the tracker's recoil keys and HOTR's chosen recoil mode.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/../../payload/system/hotr-sinden-broker.py" ]; then
  ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
else
  ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
for tool in hotr-sinden-check hotr-sinden-disable; do
  if [ ! -x "$ROOT/scripts/$tool" ] && [ ! -x "$ROOT/bin/$tool" ] && [ ! -x "/usr/bin/$tool" ]; then
    echo "[FAIL] $tool is missing from $ROOT/scripts, $ROOT/bin and /usr/bin" >&2
    exit 1
  fi
done

echo "HOTR Sinden operator-tool self-test"
echo "Repository: $ROOT"
echo

python3 - "$ROOT" <<'PY'
import json
import os
import pty
import re
import select
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(sys.argv[1])


def resolve(*candidates):
    """First existing candidate; the suites run from a repo and from $HOTR."""
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return candidates[0]


BROKER = resolve(ROOT / "payload/system/hotr-sinden-broker.py", ROOT / "bin/hotr-sinden-broker.py")
CHECK = resolve(ROOT / "scripts/hotr-sinden-check", ROOT / "bin/hotr-sinden-check",
                Path("/usr/bin/hotr-sinden-check"))
DISABLE = resolve(ROOT / "scripts/hotr-sinden-disable", ROOT / "bin/hotr-sinden-disable",
                  Path("/usr/bin/hotr-sinden-disable"))
PATCH_TOOL = resolve(ROOT / "scripts/patch-batocera-sinden-hotr.sh",
                     ROOT / "tools/patch-batocera-sinden-hotr.sh")
STATUS = resolve(ROOT / "scripts/hotr-status", ROOT / "tools/hotr-status",
                 Path("/usr/bin/hotr-status"))
TRIGGER_RECOIL = resolve(ROOT / "payload/system/hotr-sinden-trigger-recoil",
                         ROOT / "bin/hotr-sinden-trigger-recoil",
                         Path("/usr/bin/hotr-sinden-trigger-recoil"))
AUTOCONFIG = resolve(ROOT / "scripts/hotr-sinden-autoconfig", ROOT / "bin/hotr-sinden-autoconfig",
                     Path("/usr/bin/hotr-sinden-autoconfig"))
HELPER = resolve(ROOT / "buildroot/src/batocera.linux-43/package/batocera/controllers/guns/sinden-guns/virtual-sindenlightgun-add",
                 Path("/usr/bin/virtual-sindenlightgun-add"))
TMP = Path(tempfile.mkdtemp(prefix="hotr-sinden-tools-"))
HOTR_ROOT = TMP / "hotr"
RUN_DIR = TMP / "run"
DEV_ROOT = TMP / "dev"
TRACKER_ROOT = TMP / "sinden"
CONFIG = TMP / "lightguns.hor"
STATE = HOTR_ROOT / "sinden-broker-state.json"
PID_FILE = RUN_DIR / "broker.pid"
LOG = TMP / "broker.log"
PORT = 46103
A8_FRAME = bytes.fromhex("aa a8 00 00 00 00 bb")
failures = []
skips = []
PROCESSES = []


class SkipCheck(Exception):
    """Raised when a check needs repository files this install does not have."""


def report(name, function):
    try:
        detail = function()
    except SkipCheck as exc:
        skips.append(name)
        print(f"[SKIP] {name}: {exc}")
    except Exception as exc:  # noqa: BLE001 - the point is to report any failure
        failures.append(name)
        print(f"[FAIL] {name}: {exc}")
    else:
        print(f"[PASS] {name}" + (f": {detail}" if detail else ""))


def wait_for(predicate, timeout=6.0, interval=0.1):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return False


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def environment():
    return dict(
        os.environ,
        HOTR_ROOT=str(HOTR_ROOT),
        HOTR_SINDEN_PID_FILE=str(PID_FILE),
        HOTR_SINDEN_RUN_DIR=str(RUN_DIR),
        HOTR_SINDEN_LOG=str(LOG),
    )


def run_tool(arguments, **kwargs):
    return subprocess.run([sys.executable, str(CHECK), *arguments], env=environment(),
                          text=True, capture_output=True, check=False, **kwargs)


def tool_json(arguments):
    result = run_tool([*arguments, "--json"])
    if result.returncode not in (0, 1):
        raise RuntimeError(f"hotr-sinden-check exited {result.returncode}: {result.stderr}")
    return result.returncode, json.loads(result.stdout)


def run_trigger_recoil(arguments):
    return subprocess.run([sys.executable, str(TRIGGER_RECOIL), *arguments],
                          text=True, capture_output=True, check=False)


for folder in (HOTR_ROOT, RUN_DIR, DEV_ROOT, TRACKER_ROOT / "pabcd"):
    folder.mkdir(parents=True, exist_ok=True)
(CONFIG).write_text("Light Gun #1\nEND_GENERAL_SETTINGS\n%d\n0\n" % PORT, encoding="utf-8")
(HOTR_ROOT / "sinden-tcp.enabled").touch()

master, slave = pty.openpty()
gun_port = os.ttyname(slave)
os.symlink(gun_port, DEV_ROOT / "ttyACM0")
(TRACKER_ROOT / "pabcd" / "LightgunMono-abcd.exe.config").write_text(
    f'<add key="SerialPortWrite" value="{gun_port}" />\n', encoding="utf-8")

broker = subprocess.Popen([
    sys.executable, str(BROKER),
    "--port", f"1={PORT}",
    "--device", f"1={gun_port}",
    "--tracker-gate", "off",
    "--state-file", str(STATE),
    "--log", str(LOG),
])
PROCESSES.append(broker)
PID_FILE.write_text(str(broker.pid), encoding="ascii")

common = ["--dev-root", str(DEV_ROOT), "--tracker-root", str(TRACKER_ROOT),
          "--config", str(CONFIG), "--state-file", str(STATE)]


def test_report_resolves_broker():
    if not wait_for(lambda: STATE.is_file() and read_json(STATE).get("players")):
        raise RuntimeError(f"the broker never published {STATE}")
    code, data = tool_json(common)
    broker_section = data["broker"]
    if not broker_section["running"] or broker_section["pid"] != broker.pid:
        raise RuntimeError(f"the report does not see the running broker: {broker_section}")
    if data["state"].get("1", {}).get("backend") != "direct":
        raise RuntimeError(f"the report lost the backend: {data['state']}")
    if data["config"]["ports"] != {str(PORT): ["1"]}:
        raise RuntimeError(f"the report misread lightguns.hor: {data['config']}")
    if any(item["level"] == "FAIL" for item in data["checks"]):
        raise RuntimeError(f"a healthy broker produced failures: {data['checks']}")
    if code != 0:
        raise RuntimeError(f"a healthy broker made hotr-sinden-check exit {code}")
    return f"pid {broker.pid}, fresh state, no failures"


def test_device_override():
    (HOTR_ROOT / "sinden-devices.conf").write_text(f"1={gun_port}\n", encoding="utf-8")
    try:
        code, data = tool_json(common)
        if data["overrides"] != {"1": gun_port}:
            raise RuntimeError(f"the report lost the override: {data.get('overrides')}")
        if not any("sinden-devices.conf override" in item["message"] for item in data["checks"]):
            raise RuntimeError(f"the override was not reported: {data['checks']}")
        if any(item["level"] == "FAIL" for item in data["checks"]):
            raise RuntimeError(f"the override produced failures: {data['checks']}")
        if code != 0:
            raise RuntimeError(f"an existing override made hotr-sinden-check exit {code}")
        (HOTR_ROOT / "sinden-devices.conf").write_text("1=/dev/does-not-exist\n", encoding="utf-8")
        code, data = tool_json(common)
        if not any(item["level"] == "FAIL" and "does not exist" in item["message"] for item in data["checks"]):
            raise RuntimeError(f"a dangling override was accepted: {data['checks']}")
        if code == 0:
            raise RuntimeError("a dangling override should fail the report")
    finally:
        (HOTR_ROOT / "sinden-devices.conf").unlink(missing_ok=True)
    return "the override is reported, a dangling override fails"


def test_fire_delivers_one_frame():
    before = read_json(STATE)["players"]["1"]["sent"]
    code, data = tool_json([*common, "--fire"])
    entry = data.get("fire", {})
    if entry.get("outcome") != "delivered" or not entry.get("sent"):
        raise RuntimeError(f"--fire did not report delivery: {entry}")
    if entry["state_after"]["sent"] != before + 1:
        raise RuntimeError(f"the sent counter did not advance once: {before} -> {entry['state_after']}")
    if entry["state_after"]["last_frame"] != "aa a8 00 00 00 00 bb":
        raise RuntimeError(f"the wrong frame was counted: {entry['state_after']['last_frame']}")
    ready, _, _ = select.select([master], [], [], 2.0)
    received = os.read(master, 64) if ready else b""
    if A8_FRAME not in received:
        raise RuntimeError(f"the device never received {A8_FRAME.hex(' ')}: got {received.hex(' ')}")
    if code != 0:
        raise RuntimeError(f"--fire exited {code}")
    return "one A8 frame reached the device and was counted"


def test_fire_refuses_a_foreign_player():
    code, data = tool_json([*common, "--fire", "--player", "2"])
    entry = data.get("fire", {})
    if entry.get("sent") or entry.get("state_after"):
        raise RuntimeError(f"player 2 was fired on a port that serves player 1: {entry}")
    if "not served" not in (entry.get("outcome") or ""):
        raise RuntimeError(f"the refusal does not name the configured ports: {entry}")
    if code != 1:
        raise RuntimeError(f"a refused fire must exit 1, got {code}")
    return "player 2 refused before anything was sent"


def test_fire_reports_the_brokers_drop_reason():
    """A dropped fire must quote the broker's own last_drop, not a guess.

    The broker publishes the reason under ``last_drop``; reading any other key
    silently degrades the verdict to "the tracker gate or a missing gun", which
    is what made a gun the broker had never recognised look like a timing
    problem. Player 1 is deliberately given no device here, so the frame takes
    the no-gun path and the broker records exactly why.
    """
    gate_port = PORT + 7
    gate_config = TMP / "lightguns-gate.hor"
    gate_state = HOTR_ROOT / "gate-state.json"
    gate_config.write_text("Light Gun #1\nEND_GENERAL_SETTINGS\n%d\n0\n" % gate_port,
                           encoding="utf-8")
    gated = subprocess.Popen([
        sys.executable, str(BROKER),
        "--port", f"1={gate_port}",
        "--device", f"2={gun_port}",
        "--tracker-gate", "off",
        "--state-file", str(gate_state),
        "--log", str(TMP / "gate-broker.log"),
    ])
    PROCESSES.append(gated)
    try:
        if not wait_for(lambda: gate_state.is_file() and read_json(gate_state).get("players")):
            raise RuntimeError(f"the gunless broker never published {gate_state}")
        common_gate = ["--dev-root", str(DEV_ROOT), "--tracker-root", str(TRACKER_ROOT),
                       "--config", str(gate_config), "--state-file", str(gate_state)]
        code, data = tool_json([*common_gate, "--fire"])
        entry = data.get("fire", {})
        reason = (entry.get("state_after") or {}).get("last_drop")
        if entry.get("outcome") != "dropped":
            raise RuntimeError(f"a broker with no gun did not drop the frame: {entry}")
        if reason != "no Sinden gun is attached":
            raise RuntimeError(f"the report lost the broker's own drop reason: {reason!r}")
        if not any(item["level"] == "WARN" and reason in item["message"]
                   for item in data["checks"]):
            raise RuntimeError(f"the verdict did not quote the broker's reason: {data['checks']}")
        if code != 0:
            raise RuntimeError(f"a dropped fire is a WARN, not a failure, got {code}")
    finally:
        if gated.poll() is None:
            gated.terminate()
        gated.wait(timeout=5)
    return "the drop verdict quotes the broker's last_drop"


def test_disable_stops_the_broker():
    result = subprocess.run(["bash", str(DISABLE)], env=environment(), text=True,
                            capture_output=True, check=False)
    if result.returncode != 0:
        raise RuntimeError(f"hotr-sinden-disable exited {result.returncode}: {result.stderr}")
    if not wait_for(lambda: broker.poll() is not None, timeout=8.0):
        raise RuntimeError("the broker survived hotr-sinden-disable")
    if (HOTR_ROOT / "sinden-tcp.enabled").exists():
        raise RuntimeError("the enable file survived hotr-sinden-disable")
    if PID_FILE.exists():
        raise RuntimeError("the pid file survived hotr-sinden-disable")
    if "Recoil is off" not in result.stdout:
        raise RuntimeError(f"the tool did not explain how to re-enable: {result.stdout}")
    return "broker stopped, enable file and pid file removed"


def test_patch_revert_restores_backup():
    """Section B6: upgrading over a patched helper restores it byte-for-byte."""
    helper = HELPER
    if not helper.is_file():
        raise SkipCheck(f"the stock Sinden helper is not installed: {helper}")
    work = TMP / "patch"
    (work / "backups").mkdir(parents=True, exist_ok=True)
    target = work / "virtual-sindenlightgun-add"
    shutil.copy2(helper, target)
    original = target.read_bytes()
    env = environment()
    env["HOTR_SINDEN_ADD_PATH"] = str(target)
    env["HOTR_SINDEN_BACKUP_DIR"] = str(work / "backups")
    patch_tool = PATCH_TOOL

    def patch(action):
        return subprocess.run(["bash", str(patch_tool), action], env=env, text=True,
                              capture_output=True, check=False)

    if patch("remove").returncode != 0:
        raise RuntimeError("remove failed on an unpatched helper")
    if target.read_bytes() != original:
        raise RuntimeError("remove changed an unpatched helper")
    if patch("apply").returncode != 0:
        raise RuntimeError("apply failed on the stock helper")
    if "HOTR SINDEN BROKER INTEGRATION" not in target.read_text(encoding="utf-8"):
        raise RuntimeError("apply did not patch the helper")
    if patch("apply").returncode != 0:
        raise RuntimeError("a second apply is not idempotent")
    if (work / "backups/virtual-sindenlightgun-add.hotr-original").read_bytes() != original:
        raise RuntimeError("the backup does not match the stock helper")
    result = patch("remove")
    if result.returncode != 0:
        raise RuntimeError(f"remove failed: {result.stderr}")
    if target.read_bytes() != original:
        raise RuntimeError("the upgrade path did not restore the stock helper byte-for-byte")
    if (work / "backups/virtual-sindenlightgun-add.hotr-original").exists():
        raise RuntimeError("the backup survived the revert")
    return "apply, idempotent re-apply and revert all behave as documented"


def test_status_renders_sinden_section():
    (HOTR_ROOT / "sinden-tcp.enabled").write_text("", encoding="utf-8")
    state = HOTR_ROOT / "sinden-broker-state.json"
    state.write_text(json.dumps({
        "updated": "2026-10-05T12:00:00",
        "pid": 4242,
        "control_socket": None,
        "players": {
            "1": {"backend": "direct", "device": gun_port, "usb_id": "16c0:0f39",
                  "tracker_ready": True, "worker": False, "sent": 7, "dropped": 1,
                  "refused": 2, "reply_bytes": 0, "last_frame": "aa a8 00 00 00 00 bb",
                  "last_frame_time": "2026-10-05T12:00:00", "last_frame_age": 3,
                  "last_drop": None},
            "2": {"backend": "none", "device": None, "usb_id": None,
                  "tracker_ready": False, "worker": False, "sent": 0, "dropped": 0,
                  "refused": 0, "reply_bytes": 0, "last_frame": None},
        },
    }), encoding="utf-8")
    env = environment()
    env["HOTR_ROOT"] = str(HOTR_ROOT)
    result = subprocess.run(["bash", str(STATUS)], env=env,
                            text=True, capture_output=True, check=False)
    if result.returncode != 0:
        raise RuntimeError(f"hotr-status exited {result.returncode}: {result.stderr}")
    wanted = {
        r"Sinden recoil": "the Sinden section",
        r"enabled\s+yes": "the enable state",
        "direct " + gun_port: "the per-player backend and device",
        r"sent 7 dropped 1 refused 2 gun-replies 0": "the frame counters",
        r"aa a8 00 00 00 00 bb \(3s ago\)": "the last frame and its age",
        r"no gun found for player 2": "a clear line for a player without a gun",
    }
    missing = [label for pattern, label in wanted.items() if not re.search(pattern, result.stdout)]
    if missing:
        raise RuntimeError(f"hotr-status is missing {', '.join(missing)}: {result.stdout}")
    return "counters, last frame age and the no-gun line are all shown"


def test_trigger_recoil_patcher():
    """The game-file option that makes a Sinden gun recoil in ammo mode.

    HOTR prefers the ammo recoil mode for a Sinden gun and only arms the gun's
    firmware trigger recoil when the game file sets Sinden_Trigger_Recoil, so
    the installer has to add that option without disturbing anything else.
    """
    games = TMP / "trigger-recoil-games"
    if games.exists():
        shutil.rmtree(games)
    (games / "MAME_LUA").mkdir(parents=True)
    # LF file that already has an options block.
    (games / "with-options.txt").write_bytes(
        b"Players\n1\nP1\nRecoil & Reload\nAmmo_Value 1 Reload_Value\nRecoil 1 Reload_Value\n"
        b"Recoil_R2S 0\nRecoil_Value 0\n[Options]\nRS3_Ammo_LED_Map 0:0 1:1\nEnd Options\n"
        b"[States]\n:mame_start\n*All\n>Open_COM\n[Signals]\n:P1_Ammo\n*P1\n#Ammo_Value\n")
    # CRLF header, LF signal tail, no options block.
    (games / "no-options.txt").write_bytes(
        b"Players\r\n2\r\nP1\r\nP2\r\nRecoil & Reload\r\nAmmo_Value 1\r\nRecoil 1\r\n"
        b"[States]\r\n:mame_start\r\n*All\r\n>Open_COM\r\n[Signals]\n:P1_Ammo\n*P1\n#Ammo_Value\n")
    # Already configured: the tool must leave it alone.
    (games / "configured.txt").write_bytes(
        b"Players\n1\nP1\nRecoil & Reload\nAmmo_Value 1\nRecoil 1\n[Options]\n"
        b"Sinden_Trigger_Recoil 2\nEnd Options\n[States]\n:mame_start\n*All\n>Open_COM\n[Signals]\n")
    # Recoil-only game file: no ammo mode, so the option does not belong there.
    (games / "recoil-only.txt").write_bytes(
        b"Players\n1\nP1\nRecoil & Reload\nAmmo_Value 0\nRecoil 1\n[States]\n:mame_start\n*All\n"
        b">Open_COM\n[Signals]\n:GunRecoil_P1\n*P1\n#Recoil\n")
    # MAME Lua game file, patched like any other, and a plain notes file.
    (games / "MAME_LUA" / "area51.txt").write_bytes(
        b"Players\r\n1\r\nP1\r\nRecoil & Reload\r\nAmmo_Value 1\r\nRecoil 1\r\n[States]\r\n"
        b":mame_start\r\n*All\r\n>Open_COM\r\n[Signals]\r\n:P1_Ammo\r\n*P1\r\n#Ammo_Value\r\n")
    (games / "notes.txt").write_bytes(b"This is not a game file.\n")
    untouched = {name: (games / name).read_bytes() for name in ("recoil-only.txt", "notes.txt")}

    before = run_trigger_recoil(["--dir", str(games), "--check"])
    if before.returncode != 1 or "missing=3" not in before.stdout:
        raise RuntimeError(f"--check should report 3 missing options: rc={before.returncode} {before.stdout!r}")

    dry = run_trigger_recoil(["--dir", str(games), "--dry-run"])
    if dry.returncode != 0 or "would_update=3" not in dry.stdout:
        raise RuntimeError(f"--dry-run should predict 3 updates: rc={dry.returncode} {dry.stdout!r}")
    if b"Sinden_Trigger_Recoil" in (games / "with-options.txt").read_bytes():
        raise RuntimeError("--dry-run wrote to a game file")

    first = run_trigger_recoil(["--dir", str(games)])
    if first.returncode != 0 or "updated=3" not in first.stdout or "unconfigured=0" not in first.stdout:
        raise RuntimeError(f"first run should update 3 files: rc={first.returncode} {first.stdout!r}")
    second = run_trigger_recoil(["--dir", str(games)])
    if "updated=0" not in second.stdout or "already=4" not in second.stdout:
        raise RuntimeError(f"the tool is not idempotent: {second.stdout!r}")
    after = run_trigger_recoil(["--dir", str(games), "--check"])
    if after.returncode != 0 or "missing=0" not in after.stdout:
        raise RuntimeError(f"--check should pass after the update: rc={after.returncode} {after.stdout!r}")

    with_options = (games / "with-options.txt").read_bytes()
    expected = b"[Options]\nSinden_Trigger_Recoil 2\nRS3_Ammo_LED_Map 0:0 1:1\nEnd Options\n"
    if expected not in with_options or b"\r" in with_options:
        raise RuntimeError("the option was not inserted first in the existing [Options] block")
    no_options = (games / "no-options.txt").read_bytes()
    if b"[States]\r\n" not in no_options or b"Recoil 1\r\n[Options]\r\nSinden_Trigger_Recoil 2\r\nEnd Options\r\n[States]\r\n" not in no_options:
        raise RuntimeError(f"a missing [Options] block was not created before [States]: {no_options!r}")
    lua = (games / "MAME_LUA" / "area51.txt").read_bytes()
    if b"[Options]\r\nSinden_Trigger_Recoil 2\r\nEnd Options\r\n[States]\r\n" not in lua:
        raise RuntimeError("MAME_LUA game files are not patched")
    for name, original in untouched.items():
        if (games / name).read_bytes() != original:
            raise RuntimeError(f"{name} should not have been modified")

    value = run_trigger_recoil(["--dir", str(games), "--value", "4"])
    if value.returncode != 2:
        raise RuntimeError("an out-of-range --value must be refused")

    # A later writer must be recoverable: install-mame-msop.sh copies its own
    # MAME game files over the machine's, so the installer runs the tool again
    # after that step. This is the VM failure of the first ammo-mode install:
    # the install summary said updated=96 and 18 files had lost the option.
    clobbered = games / "no-options.txt"
    clobbered.write_bytes(
        b"Players\r\n2\r\nP1\r\nP2\r\nRecoil & Reload\r\nAmmo_Value 1\r\nRecoil 1\r\n"
        b"[States]\r\n:mame_start\r\n*All\r\n>Open_COM\r\n[Signals]\n:P1_Ammo\n*P1\n#Ammo_Value\n")
    again = run_trigger_recoil(["--dir", str(games)])
    if again.returncode != 0 or "updated=1" not in again.stdout:
        raise RuntimeError(f"a game file overwritten by a later writer was not re-patched: {again.stdout!r}")
    restored = run_trigger_recoil(["--dir", str(games), "--check"])
    if restored.returncode != 0 or "missing=0" not in restored.stdout:
        raise RuntimeError(f"--check should pass after re-patching a clobbered file: {restored.stdout!r}")
    return ("ammo-mode files get Sinden_Trigger_Recoil, others and line endings are untouched, "
            "repeat runs change nothing, a clobbered file is re-patched")


def _autoconfig(arguments):
    return subprocess.run([sys.executable, str(AUTOCONFIG), *arguments],
                          text=True, capture_output=True, check=False)


def _write_stub_broker(path, players):
    path.parent.mkdir(parents=True, exist_ok=True)
    body = ", ".join(f'"{player}": "{device}"' for player, device in players.items())
    path.write_text(f"def discover_devices(*args, **kwargs):\n    return {{{body}}}\n",
                    encoding="utf-8")
    return path


def test_autoconfig_creates_the_gun_list():
    data = TMP / "autoconfig" / "fresh"
    result = _autoconfig(["--data-dir", str(data), "--json"])
    if result.returncode != 0:
        raise RuntimeError(f"a fresh data dir should be configured: {result.returncode}: {result.stderr}")
    guns = (data / "lightguns.hor").read_text(encoding="utf-8").splitlines()
    if guns[0].strip() != "Light Gun Data File V4":
        raise RuntimeError(f"a fresh gun list must be V4: {guns[:2]!r}")
    block = guns[guns.index("Light Gun #0"):]
    expected = ["Light Gun #0", "0", "Sinden", "1", "12", "1", "0", "2", "3", "1", "1", "1",
                "1", "0", "END_GENERAL_SETTINGS", "13000", "0", "8"]
    if block[:len(expected)] != expected:
        raise RuntimeError(f"the created gun block is wrong: {block[:len(expected)]!r}")
    if guns[1].strip() != "1" or guns[-1].strip() != "END_OF_FILE":
        raise RuntimeError(f"the gun count or terminator is wrong: {guns[:2]!r} {guns[-1]!r}")
    assignments = (data / "playersAss.hor").read_text(encoding="utf-8").splitlines()
    # A slot holds the gun index, not the player number (hotr-gun-assignment
    # writes values[player - 1] = gun), so player 1 in gun 0 is a plain "0".
    if assignments[:2] != ["Player Assignments", "0"]:
        raise RuntimeError(f"player 1 was not assigned to the new gun: {assignments!r}")
    if assignments[2:-1] != ["69"] * 7 or assignments[-1] != "END_OF_FILE":
        raise RuntimeError(f"every other player must stay unassigned: {assignments!r}")

    before = ((data / "lightguns.hor").read_bytes(), (data / "playersAss.hor").read_bytes())
    again = _autoconfig(["--data-dir", str(data), "--json"])
    after = ((data / "lightguns.hor").read_bytes(), (data / "playersAss.hor").read_bytes())
    if again.returncode != 0 or before != after or '"changed": false' not in again.stdout:
        raise RuntimeError(f"a second run must change nothing and say so: {again.stdout!r}")
    return ("a fresh install gets a V4 Sinden entry on 13000 assigned to player 1, and a second run "
            "is a no-op")


def test_autoconfig_two_guns():
    root = TMP / "autoconfig"
    stub = _write_stub_broker(root / "stub-two.py", {"1": "/dev/ttyACM0", "2": "/dev/ttyACM1"})
    data = root / "two"
    result = _autoconfig(["--auto", "--broker", str(stub), "--data-dir", str(data), "--json"])
    if result.returncode != 0:
        raise RuntimeError(f"a two-gun box should be configured: {result.stderr!r}")
    guns = (data / "lightguns.hor").read_text(encoding="utf-8").splitlines()
    if guns[1].strip() != "2":
        raise RuntimeError(f"the gun count must be 2: {guns[:3]!r}")
    first = guns[guns.index("Light Gun #0"):guns.index("Light Gun #1")]
    second = guns[guns.index("Light Gun #1"):]
    if [first[2], first[15], first[16]] != ["Sinden", "13000", "0"]:
        raise RuntimeError(f"gun 0 must be player 1 on 13000: {first!r}")
    if [second[2], second[15], second[16]] != ["Sinden2", "13001", "1"]:
        raise RuntimeError(f"gun 1 must be player 2 on 13001: {second!r}")
    assignments = (data / "playersAss.hor").read_text(encoding="utf-8").splitlines()
    if assignments[:3] != ["Player Assignments", "0", "1"] or assignments[3] != "69":
        raise RuntimeError(f"both players must be assigned (slots hold gun indexes): {assignments!r}")

    # A broker that cannot answer is a fallback, never a failure.
    broken = _write_stub_broker(root / "stub-broken.py", {})
    broken.write_text("def discover_devices(*args, **kwargs):\n    raise RuntimeError('boom')\n",
                      encoding="utf-8")
    data3 = root / "broken"
    result = _autoconfig(["--auto", "--broker", str(broken), "--data-dir", str(data3)])
    if result.returncode != 0 or "boom" not in result.stderr:
        raise RuntimeError(f"an unusable broker must still leave one usable entry: {result!r}")
    if not (data3 / "lightguns.hor").is_file():
        raise RuntimeError("the fallback must still create the player 1 entry")
    return ("two attached guns get consecutive ports 13000/13001 with players 1 and 2, both "
            "assigned, and a broker that cannot answer falls back to one gun")


def test_autoconfig_upgrades_only_the_shipped_default():
    root = TMP / "autoconfig" / "legacy"
    root.mkdir(parents=True, exist_ok=True)
    serial = ["0", "12", "0", "1", "2", "3", "1", "1", "1", "1", "0", "END_GENERAL_SETTINGS"]
    pristine = root / "pristine.hor"
    pristine.write_text(
        "\n".join(["Light Gun #0", *serial, "/dev/ttyUSB1", "0", "8",
                   "Light Gun #1", *serial, "/dev/ttyUSB3", "1", "8", "END_OF_FILE", ""]),
        encoding="utf-8")
    guns = root / "data" / "lightguns.hor"
    guns.parent.mkdir(parents=True, exist_ok=True)
    guns.write_text(pristine.read_text(encoding="utf-8"), encoding="utf-8")
    result = _autoconfig(["--data-dir", str(guns.parent), "--pristine-default", str(pristine)])
    upgraded = guns.read_text(encoding="utf-8")
    if result.returncode != 0 or "Light Gun Data File V4" not in upgraded or "13000" not in upgraded:
        raise RuntimeError(f"the shipped default must be replaced by a V4 Sinden entry: {upgraded!r}")
    if "ttyUSB" in upgraded:
        raise RuntimeError("the generic placeholder guns must not survive the rewrite")

    edited = pristine.read_text(encoding="utf-8").replace("/dev/ttyUSB1", "/dev/ttyACM9")
    guns.write_text(edited, encoding="utf-8")
    result = _autoconfig(["--data-dir", str(guns.parent), "--pristine-default", str(pristine)])
    if guns.read_text(encoding="utf-8") != edited:
        raise RuntimeError("a user-edited legacy gun list must never be rewritten")
    if result.returncode != 0 or "lightguns.hor" not in result.stderr:
        raise RuntimeError(f"a legacy list should be explained, not changed: {result.stderr!r}")
    return ("the unmodified shipped default is upgraded in place; a user-edited legacy list is "
            "reported and left untouched")


def test_autoconfig_repairs_the_recoil_mode_order():
    data = TMP / "autoconfig" / "priority" / "data"
    data.mkdir(parents=True, exist_ok=True)
    # A gun list in the order HOTR writes by itself: ammo before recoil.
    guns = data / "lightguns.hor"
    guns.write_text("\n".join([
        "Light Gun Data File V4", "1",
        "Light Gun #0", "0", "P1Sinden", "1", "12", "0", "1", "2", "3", "1", "1", "1", "1", "0",
        "END_GENERAL_SETTINGS", "13000", "0", "8", "END_OF_FILE", "",
    ]), encoding="utf-8")
    result = _autoconfig(["--data-dir", str(data), "--json"])
    if result.returncode != 0:
        raise RuntimeError(f"an existing Sinden entry must be accepted: {result.stderr!r}")
    lines = guns.read_text(encoding="utf-8").splitlines()
    start = lines.index("Light Gun #0")
    block = lines[start:start + 14]
    # The four numbers after the name are the mode order (ammoValue, recoil, ...).
    if [block[5], block[6], block[7], block[8]] != ["1", "0", "2", "3"]:
        raise RuntimeError(f"the Sinden must prefer recoil over ammo: {block!r}")
    if '"changed": true' not in result.stdout:
        raise RuntimeError(f"the mode repair must be reported as a change: {result.stdout!r}")
    again = _autoconfig(["--data-dir", str(data), "--json"])
    if '"changed": false' not in again.stdout:
        raise RuntimeError(f"a second repair must change nothing: {again.stdout!r}")
    kept = guns.read_text(encoding="utf-8").replace("1\n0\n2\n3\n", "0\n1\n2\n3\n")
    guns.write_text(kept, encoding="utf-8")
    keep = _autoconfig(["--data-dir", str(data), "--recoil-priority", "keep", "--json"])
    if keep.returncode != 0 or guns.read_text(encoding="utf-8") != kept:
        raise RuntimeError("--recoil-priority keep must leave the gun list alone")
    ammo = _autoconfig(["--data-dir", str(data), "--recoil-priority", "ammo", "--json"])
    if ammo.returncode != 0 or "0\n1\n2\n3\n" not in guns.read_text(encoding="utf-8"):
        raise RuntimeError("--recoil-priority ammo must write HOTR's own order back")
    return ("an existing Sinden entry is switched to recoil-first, a repeat run is a no-op, keep "
            "leaves the file alone and ammo restores HOTR's own order")


def test_fire_refuses_an_unknown_command():
    completed = subprocess.run(
        [sys.executable, str(CHECK), "--fire", "--command", "Z", "--json"],
        text=True, capture_output=True, check=False)
    report = json.loads(completed.stdout)
    fire = report.get("fire") or {}
    if completed.returncode == 0 or fire.get("sent"):
        raise RuntimeError(f"--fire must fail on a command the broker does not know: {completed.stdout!r}")
    if "does not accept" not in str(fire.get("outcome")):
        raise RuntimeError(f"the refusal must name the command: {fire.get('outcome')!r}")
    return "an unknown --command is refused before any frame is sent"


def test_check_reports_the_recoil_programming():
    root = TMP / "recoil-report"
    tracker = root / "sinden" / "pabc"
    tracker.mkdir(parents=True, exist_ok=True)
    (tracker / "LightgunMono-abc.exe.config").write_text(
        '<add key="SerialPortWrite" value="/dev/ttyACM0"/>\n'
        '<add key="EnableRecoil" value="0"/>\n'
        '<add key="TriggerRecoilNormalOrRepeat" value="1"/>\n'
        '<add key="AutoRecoilDelayBetweenPulses" value="10"/>\n',
        encoding="utf-8")
    log = root / "hook-of-the-reaper.log"
    log.write_text('Output signal filter: QList("mame_start", "P1_Ammo")\n', encoding="utf-8")
    completed = subprocess.run(
        [sys.executable, str(CHECK), "--tracker-root", str(root / "sinden")],
        text=True, capture_output=True, check=False, env=dict(os.environ, HOTR_LOG=str(log)))
    if "EnableRecoil=0" not in completed.stdout:
        raise RuntimeError(f"the report must show the tracker's recoil keys: {completed.stdout!r}")
    if "TriggerRecoilNormalOrRepeat=1" not in completed.stdout:
        raise RuntimeError(f"the report must show the repeat mode: {completed.stdout!r}")
    if "P1_Ammo" not in completed.stdout or "ammo recoil mode" not in completed.stdout:
        raise RuntimeError(f"the report must name HOTR's own mode choice: {completed.stdout!r}")
    return "the check names the tracker's recoil keys and HOTR's chosen recoil mode"


def test_static_wiring():
    if not (ROOT / "install.sh").is_file():
        raise SkipCheck("the repository sources are not part of an installed system")
    install = (ROOT / "install.sh").read_text(encoding="utf-8")
    for expected in ('"$BASE/scripts/hotr-sinden-check" "$HOTR/bin/hotr-sinden-check"',
                     '"$BASE/scripts/hotr-sinden-disable" "$HOTR/bin/hotr-sinden-disable"',
                     '"$BASE/scripts/hotr-sinden-autoconfig" "$HOTR/bin/hotr-sinden-autoconfig"',
                     '"$BASE/scripts/hotr-sinden-check" /usr/bin/hotr-sinden-check',
                     '"$BASE/scripts/hotr-sinden-disable" /usr/bin/hotr-sinden-disable',
                     '"$BASE/scripts/hotr-sinden-autoconfig" /usr/bin/hotr-sinden-autoconfig',
                     '"$BASE/payload/system/hotr-sinden-trigger-recoil" "$HOTR/bin/hotr-sinden-trigger-recoil"',
                     '"$BASE/payload/system/hotr-sinden-trigger-recoil" /usr/bin/hotr-sinden-trigger-recoil'):
        if expected not in install:
            raise RuntimeError(f"install.sh does not ship {expected}")
    if 'copy_missing_tree "$BASE/payload/hotr/defaultLG" "$HOTR_DATA/defaultLG"' not in install:
        raise RuntimeError("install.sh does not install the game files add-only")
    if 'hotr-sinden-trigger-recoil" --dir "$HOTR_DATA/defaultLG"' not in install:
        raise RuntimeError("install.sh does not configure Sinden trigger recoil in the game files")
    # install-mame-msop.sh writes its own copies of the MAME game files, so the
    # patch step must run after the MSOP step, and the MSOP script itself must
    # re-add the option too (it is also useful on its own).
    if "configure_sinden_trigger_recoil(){" not in install:
        raise RuntimeError("install.sh does not define configure_sinden_trigger_recoil")
    msop_call = install.find('"$BASE/scripts/install-mame-msop.sh"')
    patch_call = install.rfind("configure_sinden_trigger_recoil")
    if msop_call < 0 or patch_call < msop_call:
        raise RuntimeError("install.sh must add the Sinden trigger recoil option after the MSOP step, "
                           "because the MSOP archive overwrites the MAME game files")
    msop = (ROOT / "scripts/install-mame-msop.sh").read_text(encoding="utf-8")
    if "hotr-sinden-trigger-recoil" not in msop:
        raise RuntimeError("install-mame-msop.sh overwrites game files without re-adding the "
                           "Sinden trigger recoil option")
    # The gun list is HOTR's own file, so the entry has to exist before anything
    # reads it: install.sh adds it for the whole install, the service adds it on
    # every start (which is also what re-checks it after a gun is replugged).
    if "configure_sinden_gun(){" not in install or "\nconfigure_sinden_gun\n" not in install:
        raise RuntimeError("install.sh does not define and call configure_sinden_gun")
    if '"$tool" --auto' not in install:
        raise RuntimeError("install.sh must configure one gun entry per attached gun")
    service = (ROOT / "scripts/hotr-service").read_text(encoding="utf-8")
    if 'SINDEN_AUTOCONFIG="$ROOT/bin/hotr-sinden-autoconfig"' not in service:
        raise RuntimeError("scripts/hotr-service does not ship hotr-sinden-autoconfig")
    if '"$SINDEN_AUTOCONFIG" --auto --data-dir "$DATADIR"' not in service:
        raise RuntimeError("scripts/hotr-service must keep the gun list correct on every start")
    checker = (ROOT / "check-install.sh").read_text(encoding="utf-8")
    for expected in ("check_exec /userdata/system/hotr/bin/hotr-sinden-check",
                     "check_exec /userdata/system/hotr/bin/hotr-sinden-disable",
                     "check_exec /userdata/system/hotr/bin/hotr-sinden-autoconfig",
                     "check_exec /usr/bin/hotr-sinden-autoconfig",
                     "check_exec /usr/bin/hotr-sinden-trigger-recoil",
                     "hotr-sinden-trigger-recoil --check --quiet"):
        if expected not in checker:
            raise RuntimeError(f"check-install.sh does not {expected}")
    uninstall = (ROOT / "uninstall.sh").read_text(encoding="utf-8")
    for expected in ("/usr/bin/hotr-sinden-check", "/usr/bin/hotr-sinden-disable",
                     "/usr/bin/hotr-sinden-autoconfig", "/usr/bin/hotr-sinden-trigger-recoil"):
        if expected not in uninstall:
            raise RuntimeError(f"uninstall.sh does not remove {expected}")
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    for expected in ("hotr-sinden-check", "hotr-sinden-disable", "hotr-sinden-autoconfig",
                     "hotr-sinden-trigger-recoil"):
        if expected not in readme:
            raise RuntimeError(f"README.md does not document {expected}")
    return "install, check-install, uninstall, the service and the README all reference all four tools"


def test_runner_flags_are_implemented():
    runner = ROOT / "scripts/tests/hotr-sinden-vm-e2e.sh"
    if not runner.is_file():
        raise SkipCheck("the acceptance runner is not part of this checkout")
    text = runner.read_text(encoding="utf-8")
    usage = re.search(r"cat <<'EOF'\n(.*?)\nEOF\n", text, re.S)
    if usage is None:
        raise RuntimeError("hotr-sinden-vm-e2e.sh has no usage block to compare against")
    cases = re.search(r"parse_args\(\) \{\n(.*?)\n\}", text, re.S)
    if cases is None:
        raise RuntimeError("hotr-sinden-vm-e2e.sh has no parse_args block")
    documented = re.findall(r"^\s+(--[a-z][a-z-]*)", usage.group(1), re.M)
    if not documented:
        raise RuntimeError("the usage block documents no options")
    for flag in documented:
        if f"{flag})" not in cases.group(1):
            raise RuntimeError(f"usage documents {flag} but parse_args does not accept it")
    if "FAKE_GUN_REQUIRED" not in text or "step_attach_fake_gun" not in text:
        raise RuntimeError("--fake-gun-required is not wired into step_attach_fake_gun")
    attach = text.split("step_attach_fake_gun()", 1)[1].split("\n}\n", 1)[0]
    if attach.count("FAKE_GUN_REQUIRED") < 2:
        raise RuntimeError("step_attach_fake_gun does not honour --fake-gun-required for both "
                           "the missing-fake-gun and the real-gun cases")
    syntax = subprocess.run(["bash", "-n", str(runner)], capture_output=True, text=True)
    if syntax.returncode != 0:
        raise RuntimeError(f"hotr-sinden-vm-e2e.sh fails bash -n: {syntax.stderr.strip()}")
    return f"every documented option ({', '.join(documented)}) is parsed and the flag is honoured"


PREFLIGHT_HARNESS = '''#!/bin/bash
set -u
MODE="${MODE:---auto}"
msg(){ printf '[HOTR] %s\\n' "$*"; }
warn(){ printf '[HOTR WARNING] %s\\n' "$*" >&2; }
die(){ printf '[HOTR ERROR] %s\\n' "$*" >&2; exit 1; }
id(){ printf '%s\\n' "${FAKE_UID:-0}"; }
uname(){ printf '%s\\n' "${FAKE_UNAME:-x86_64}"; }
if [ -n "${FAKE_FREE:-}" ]; then
  df(){ printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\n/dev/root 1000000 500000 %s 50%% %s\\n' "$FAKE_FREE" "$1"; }
fi
@FUNCTION@
preflight
'''


def _preflight_tools(name, tools=("python3", "tee", "unzip", "tar", "df", "awk")):
    """A PATH directory holding just the tools the preflight should find."""
    bindir = TMP / "preflight" / name
    shutil.rmtree(bindir, ignore_errors=True)
    bindir.mkdir(parents=True)
    for tool in tools:
        path = shutil.which(tool)
        if path:
            (bindir / tool).symlink_to(path)
    return bindir


def _run_preflight(harness, bindir, mode="--auto", **values):
    env = dict(os.environ)
    env.update(values)
    env["MODE"] = mode
    if bindir is not None:
        env["PATH"] = str(bindir)
    return subprocess.run([shutil.which("bash") or "bash", str(harness)],
                          capture_output=True, text=True, env=env, timeout=30)


def test_install_preflight():
    install = ROOT / "install.sh"
    if not install.is_file():
        raise SkipCheck("the repository sources are not part of an installed system")
    match = re.search(r"\npreflight\(\)\{\n.*?\n\}\n", install.read_text(encoding="utf-8"), re.S)
    if match is None:
        raise RuntimeError("install.sh has no preflight() function")
    base = TMP / "preflight"
    shutil.rmtree(base, ignore_errors=True)
    (base / "data").mkdir(parents=True)
    (base / "ro").mkdir()
    os.chmod(base / "ro", 0o500)
    function = match.group(0).replace("/userdata", str(base / "data"))
    harness = base / "harness.sh"
    harness.write_text(PREFLIGHT_HARNESS.replace("@FUNCTION@", function), encoding="utf-8")
    ro_harness = base / "harness-ro.sh"
    ro_harness.write_text(
        PREFLIGHT_HARNESS.replace("@FUNCTION@", function.replace(str(base / "data"), str(base / "ro"))),
        encoding="utf-8")
    full = _preflight_tools("tools")

    result = _run_preflight(harness, full)
    if result.returncode != 0 or "Preflight OK" not in result.stdout:
        raise RuntimeError(f"a healthy machine should pass the preflight: {result.stdout!r} {result.stderr!r}")

    result = _run_preflight(harness, _preflight_tools("no-unzip", ("python3", "tee", "tar", "df", "awk")))
    if result.returncode == 0 or "Missing required tool(s)" not in result.stderr or "unzip" not in result.stderr:
        raise RuntimeError(f"a missing unzip must stop the preflight: {result.stderr!r}")

    no_tar = _preflight_tools("no-tar", ("python3", "tee", "unzip", "df", "awk"))
    result = _run_preflight(harness, no_tar)
    if result.returncode == 0 or "tar" not in result.stderr:
        raise RuntimeError(f"a missing tar must stop a normal install: {result.stderr!r}")
    result = _run_preflight(harness, no_tar, mode="--infrastructure-only")
    if result.returncode != 0 or "Preflight OK" not in result.stdout:
        raise RuntimeError(f"--infrastructure-only must not require tar: {result.stderr!r}")

    result = _run_preflight(harness, full, FAKE_UID="1000")
    if "as root" not in result.stderr:
        raise RuntimeError("a non-root preflight must stop with 'Run this installer as root.'")
    result = _run_preflight(harness, full, FAKE_UNAME="armv7l")
    if "x86_64 only" not in result.stderr:
        raise RuntimeError("a non-x86_64 preflight must stop")
    result = _run_preflight(ro_harness, full)
    if "not writable" not in result.stderr:
        raise RuntimeError(f"an unwritable install root must stop the preflight: {result.stderr!r}")

    result = _run_preflight(harness, full, FAKE_FREE="100")
    if "needs at least 1024 MiB" not in result.stderr:
        raise RuntimeError(f"too little free space must stop a normal install: {result.stderr!r}")
    result = _run_preflight(harness, full, FAKE_FREE="400000", mode="--infrastructure-only")
    if result.returncode != 0 or "MiB free" not in result.stderr:
        raise RuntimeError(f"--infrastructure-only should only warn at 400 MB free: {result.stderr!r}")
    return ("root, x86_64, required tools, a writable root and 1 GiB of free space are checked; "
            "tar is optional for --infrastructure-only and only a warning")


try:
    report("the report resolves a running broker", test_report_resolves_broker)
    report("the device override is reported and validated", test_device_override)
    report("--fire delivers exactly one A8 frame", test_fire_delivers_one_frame)
    report("--fire refuses a player the port does not serve", test_fire_refuses_a_foreign_player)
    report("a dropped fire quotes the broker's drop reason",
           test_fire_reports_the_brokers_drop_reason)
    report("hotr-sinden-disable stops the broker", test_disable_stops_the_broker)
    report("hotr-status shows the recoil counters and the no-gun line",
           test_status_renders_sinden_section)
    report("upgrading over a patched Sinden helper restores it",
           test_patch_revert_restores_backup)
    report("the tools are wired into install, check and docs", test_static_wiring)
    report("the acceptance runner implements every option it documents",
           test_runner_flags_are_implemented)
    report("install.sh fails fast when the machine cannot run the installer",
           test_install_preflight)
    report("ammo-mode game files get the Sinden trigger recoil option",
           test_trigger_recoil_patcher)
    report("hotr-sinden-autoconfig creates the Sinden entry and the player assignment",
           test_autoconfig_creates_the_gun_list)
    report("hotr-sinden-autoconfig gives every attached gun its own entry",
           test_autoconfig_two_guns)
    report("hotr-sinden-autoconfig upgrades only the shipped default gun list",
           test_autoconfig_upgrades_only_the_shipped_default)
    report("hotr-sinden-autoconfig keeps a Sinden preferring recoil over ammo",
           test_autoconfig_repairs_the_recoil_mode_order)
    report("the check names the tracker recoil keys and HOTR's mode",
           test_check_reports_the_recoil_programming)
    report("--fire refuses a command the broker does not know",
           test_fire_refuses_an_unknown_command)
finally:
    for process in PROCESSES:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
    import shutil
    shutil.rmtree(TMP, ignore_errors=True)

if failures:
    print(f"\n[FAIL] {len(failures)} check(s) failed: {', '.join(failures)}")
    if skips:
        print(f"[INFO] {len(skips)} check(s) skipped here: {', '.join(skips)}")
    sys.exit(1)
if skips:
    print(f"\n[INFO] {len(skips)} check(s) skipped here: {', '.join(skips)}")
print("\n[PASS] Sinden operator tools behave as documented.")
PY
