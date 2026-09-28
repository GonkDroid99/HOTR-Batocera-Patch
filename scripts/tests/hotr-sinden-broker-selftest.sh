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

cleanup() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null || true
  [ -n "$PID" ] && wait "$PID" 2>/dev/null || true
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
    (45987, b"1B\n"),
    (45987, b"1C\n"),
):
    sock = socket.create_connection(("127.0.0.1", port), 2)
    sock.sendall(command)
    sock.close()
PY

for _ in $(seq 1 30); do
  [ "$(wc -l < "$CAPTURE" 2>/dev/null || echo 0)" -ge 5 ] && break
  sleep 0.1
done

grep -q 'player=1 reason=A data=aa a8 00 00 00 00 bb' "$CAPTURE"
grep -q 'player=2 reason=A data=aa a8 00 00 00 00 bb' "$CAPTURE"
grep -q 'player=1 reason=N8 data=aa a7 50 00 00 00 bb' "$CAPTURE"
grep -q 'player=1 reason=B data=aa a9 00 00 00 00 bb' "$CAPTURE"
grep -q 'player=1 reason=C data=aa aa 00 00 00 00 bb' "$CAPTURE"

echo "[PASS] HOTR TCP commands translated to simulated Sinden serial frames."
