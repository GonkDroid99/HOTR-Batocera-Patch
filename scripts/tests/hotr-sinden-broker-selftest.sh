#!/bin/bash
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
WORK="$(mktemp -d /tmp/hotr-sinden-broker-test.XXXXXX)"
LOG="$WORK/broker.log"
CAPTURE="$WORK/serial.log"
PID=""
PID2=""

cleanup() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null || true
  [ -n "$PID" ] && wait "$PID" 2>/dev/null || true
  [ -n "$PID2" ] && kill "$PID2" 2>/dev/null || true
  [ -n "$PID2" ] && wait "$PID2" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

command -v python3 >/dev/null || { echo "[FAIL] python3 is unavailable" >&2; exit 1; }

python3 "$BROKER" --simulate --port 1=45987 --port 2=45988 \
  --capture "$CAPTURE" --log "$LOG" >/dev/null 2>&1 &
PID=$!

for _ in $(seq 1 30); do
  grep -q 'listening on 127.0.0.1:45987' "$LOG" 2>/dev/null && break
  sleep 0.1
done
grep -q 'listening on 127.0.0.1:45987' "$LOG" || { cat "$LOG"; exit 1; }

python3 - <<'PY'
import socket

for port, command in (
    (45987, b"1A\n"),
    (45988, b"2A\n"),
    (45987, b"1N8\n"),
    (45987, b"1J0\n"),
    (45987, b"1U1\n"),
    # The ammo path (F12): a game profile with Sinden_Trigger_Recoil makes HOTR
    # prepend 1K1/1K0 when the ammo count changes.
    (45987, b"1K1\n"),
    (45988, b"2K0\n"),
    (45987, b"1B\n"),
    (45987, b"1C\n"),
    # Unprefixed: HOTR writes the same profile command text down every gun's socket,
    # so the socket has to decide the player. "S" is also an A8 recoil command.
    (45988, b"S\n"),
    (45987, b"BN8\n"),
):
    sock = socket.create_connection(("127.0.0.1", port), 2)
    sock.sendall(command)
    sock.close()
PY

for _ in $(seq 1 30); do
  [ "$(wc -l < "$CAPTURE" 2>/dev/null || echo 0)" -ge 7 ] && break
  sleep 0.1
done

grep -q 'player=1 reason=A data=aa a8 00 00 00 00 bb' "$CAPTURE"
grep -q 'player=2 reason=A data=aa a8 00 00 00 00 bb' "$CAPTURE"
# N/U no longer emit A7: the strength rides in the A2 frame the presets already use.
grep -q 'player=1 reason=N8 data=aa a2 50 00 50 0d bb' "$CAPTURE"
grep -q 'player=1 reason=U1 data=aa a2 0a 00 0a 0d bb' "$CAPTURE"
grep -q 'player=1 reason=U1 data=aa a8 00 00 00 00 bb' "$CAPTURE"
# F9: muting is A2 strength 0, never A1 0.
grep -q 'player=1 reason=J0 data=aa a2 00 00 00 00 bb' "$CAPTURE"
# The ammo path's trigger-recoil arm/disarm frames are the quiet A4 frames.
grep -q 'player=1 reason=K1 data=aa a4 01 00 00 00 bb' "$CAPTURE"
grep -q 'player=2 reason=K0 data=aa a4 00 00 00 00 bb' "$CAPTURE"

# An unprefixed command follows the socket that carried it (player 2 here).
if ! grep -q 'player=2 reason=S data=aa a8 00 00 00 00 bb' "$CAPTURE"; then
  echo "[FAIL] an unprefixed command from player 2's socket did not reach player 2" >&2
  exit 1
fi
if grep -q 'player=1 reason=S data=' "$CAPTURE"; then
  echo "[FAIL] an unprefixed command from player 2's socket reached player 1" >&2
  exit 1
fi
# 'B' still addresses every gun, prefix or not.
grep -q 'player=1 reason=N8 data=aa a2 50 00 50 0d bb' "$CAPTURE"
grep -q 'player=2 reason=N8 data=aa a2 50 00 50 0d bb' "$CAPTURE"

# The retired commands must be refused with a logged reason and no frame at all.
grep -q 'refusing command B' "$LOG"
grep -q 'refusing command C' "$LOG"
if grep -q 'reason=B \|reason=C ' "$CAPTURE"; then
  echo "[FAIL] a retired command still produced a serial frame" >&2
  exit 1
fi
if grep -q 'aa a7 \|aa a0 \|aa a9 \|aa aa \|aa ab \|aa ac ' "$CAPTURE"; then
  echo "[FAIL] the broker emitted a command the firmware answers" >&2
  exit 1
fi

# The broker log must not grow without bound: past the cap the live file is
# replaced by <name>.old and starts again from empty (scripts/hotr-service
# rotates an oversized legacy file on start for the same reason).
ROTATE_LOG="$WORK/rotate.log"
HOTR_SINDEN_LOG_MAX_BYTES=1024 python3 "$BROKER" --simulate --port 1=45990 \
  --log "$ROTATE_LOG" >/dev/null 2>&1 &
PID2=$!

for _ in $(seq 1 30); do
  grep -q 'listening on 127.0.0.1:45990' "$ROTATE_LOG" 2>/dev/null && break
  sleep 0.1
done
grep -q 'listening on 127.0.0.1:45990' "$ROTATE_LOG" || { cat "$ROTATE_LOG"; exit 1; }

python3 - <<'PY'
import socket

for _ in range(80):
    sock = socket.create_connection(("127.0.0.1", 45990), 2)
    sock.sendall(b"1A\n")
    sock.close()
PY

for _ in $(seq 1 30); do
  [ -f "$ROTATE_LOG.old" ] && break
  sleep 0.1
done
[ -f "$ROTATE_LOG.old" ] || { echo "[FAIL] the broker log never rotated past the cap" >&2; exit 1; }
ROTATE_SIZE="$(wc -c <"$ROTATE_LOG" | tr -d ' ')"
if [ "$ROTATE_SIZE" -ge 1024 ]; then
  echo "[FAIL] the live broker log is still over the cap ($ROTATE_SIZE bytes)" >&2
  exit 1
fi
grep -q 'player 1: serial aa a8 00 00 00 00 bb' "$ROTATE_LOG.old"

# HOTR_SINDEN_LOG_MAX_BYTES only accepts a positive integer; anything else falls
# back to the documented 1 MiB default instead of disabling rotation.
if ! python3 -c '
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("broker", sys.argv[1])
module = importlib.util.module_from_spec(spec)
# Register before execution: dataclasses on Python 3.14 resolves the class
# module through sys.modules while the decorator runs.
sys.modules["broker"] = module
spec.loader.exec_module(module)
os.environ["HOTR_SINDEN_LOG_MAX_BYTES"] = ""
assert module.sinden_log_max_bytes() == 1048576
os.environ["HOTR_SINDEN_LOG_MAX_BYTES"] = "0"
assert module.sinden_log_max_bytes() == 1048576
os.environ["HOTR_SINDEN_LOG_MAX_BYTES"] = "not-a-number"
assert module.sinden_log_max_bytes() == 1048576
os.environ["HOTR_SINDEN_LOG_MAX_BYTES"] = "2048"
assert module.sinden_log_max_bytes() == 2048
' "$BROKER"; then
  echo "[FAIL] HOTR_SINDEN_LOG_MAX_BYTES parsing is not the documented cap-or-default" >&2
  exit 1
fi

echo "[PASS] HOTR TCP commands translated to simulated Sinden serial frames."
echo "[PASS] the broker log rotates to a single .old generation at the configured cap."
