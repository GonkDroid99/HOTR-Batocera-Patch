#!/bin/bash
# Run the real LightgunMono against a lab serial device (a fake-gun PTY).
#
# The acceptance runner uses this on a machine without a Sinden gun so that the
# real Batocera LightgunMono executable - not a replay - talks to the lab gun
# while HOTR writes recoil frames to the same port. It lays out exactly what the
# stock udev helper creates: /var/run/sinden/p<name>/LightgunMono-<name>.exe and
# its .config, started with mono-service the same way.
#
# Usage:
#   hotr-sinden-lab-mono.sh start /dev/pts/N
#   hotr-sinden-lab-mono.sh stop
set -u

ACTION="${1:-start}"
DEVICE="${2:-${HOTR_SINDEN_LAB_DEVICE:-}}"
SOURCE="${HOTR_SINDEN_MONO_SOURCE:-/usr/share/sinden}"
TRACKER_ROOT="${HOTR_SINDEN_TRACKER_ROOT:-/var/run/sinden}"
NAME="${HOTR_SINDEN_LAB_NAME:-labp1}"

log() { printf '[lab-mono] %s\n' "$*"; }

stop_lab_mono() {
  local found=0
  while read -r pid; do
    [ -n "$pid" ] || continue
    found=1
    kill "$pid" 2>/dev/null || true
  done <<EOF
$(pgrep -f "LightgunMono-${NAME}\.exe" 2>/dev/null || true)
EOF
  if [ "$found" = 1 ]; then
    log "stopped the lab LightgunMono (${NAME})"
  else
    log "no lab LightgunMono was running"
  fi
  return 0
}

if [ "$ACTION" = stop ]; then
  stop_lab_mono
  exit 0
fi

if [ -z "$DEVICE" ]; then
  log "usage: $0 start /dev/pts/N   (or set HOTR_SINDEN_LAB_DEVICE)"
  exit 2
fi
if [ ! -e "$DEVICE" ]; then
  log "the lab device $DEVICE does not exist"
  exit 1
fi
BIN="$(command -v mono-service || true)"
if [ -z "$BIN" ]; then
  log "mono-service is not installed; the Sinden support is missing"
  exit 1
fi
if [ ! -d "$SOURCE" ]; then
  log "$SOURCE is missing; install the Batocera Sinden support first"
  exit 1
fi

TARGET="$TRACKER_ROOT/p${NAME}"
EXE="LightgunMono-${NAME}.exe"
CONFIG="LightgunMono-${NAME}.exe.config"
LOG="${HOTR_SINDEN_LAB_MONO_LOG:-/tmp/hotr-sinden-lab-mono.log}"

stop_lab_mono
rm -rf "$TARGET"
mkdir -p "$TARGET" || exit 1
cp -pr "$SOURCE"/. "$TARGET"/ || exit 1
mv "$TARGET/LightgunMono.exe" "$TARGET/$EXE" || exit 1
mv "$TARGET/LightgunMono.exe.config" "$TARGET/$CONFIG" || exit 1

# Point LightgunMono at the lab device. The broker and hotr-sinden-check both
# read this key back to know which tty the tracker owns.
if ! python3 - "$TARGET/$CONFIG" "$DEVICE" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
device = sys.argv[2]
text = path.read_text(encoding="utf-8-sig")
patched, count = re.subn(
    r'(<add key="SerialPortWrite" value=")[^"]*(")',
    lambda match: f"{match.group(1)}{device}{match.group(2)}",
    text,
    count=1,
)
if count != 1:
    raise SystemExit(f"SerialPortWrite not found in {path}")
path.write_text(patched, encoding="utf-8")
PY
then
  log "could not point $CONFIG at $DEVICE"
  exit 1
fi

log "starting $TARGET/$EXE against $DEVICE (log: $LOG)"
# The stock helper waits a moment so the tty is ready before the exe opens it.
sleep 1
cd "$TARGET" || exit 1
PATH=/bin:/sbin:/usr/bin:/usr/sbin nohup "$BIN" \
  -l:"$TARGET/lockfile" -d:"$TARGET" --no-daemon "./$EXE" \
  </dev/null >"$LOG" 2>&1 &
sleep 2
if pgrep -f "LightgunMono-${NAME}\.exe" >/dev/null; then
  log "LightgunMono is running against $DEVICE"
  exit 0
fi
log "LightgunMono exited immediately; see $LOG"
exit 1
