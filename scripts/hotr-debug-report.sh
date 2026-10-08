#!/bin/bash
# HOTR diagnostic capture for serial/TTY failures during game launch.
set -u

ROOT=/userdata/system/hotr
SINDEN_STATE="$ROOT/sinden-broker-state.json"
LOGROOT=/userdata/system/logs/hotr-debug
STATE="$LOGROOT/current"
SERVICE=/userdata/system/services/hotr
REPORT="$STATE/report.txt"
WATCHPID="$STATE/watcher.pid"

mkdir -p "$LOGROOT"

now(){ date '+%Y-%m-%dT%H:%M:%S%z'; }
section(){ printf '\n===== %s =====\n' "$1"; }
cmd(){
  printf '\n$ %s\n' "$*"
  "$@" 2>&1 || printf '[exit %s]\n' "$?"
}
proc_cmdline(){
  [ -r "/proc/$1/cmdline" ] || return 0
  tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null || true
}

autoconfig_summary(){
  local config=/userdata/system/hook-of-the-reaper/data/lightguns.hor
  local service_log=/userdata/system/logs/hook-of-the-reaper.log
  local raw_path path count=0

  echo 'Recent hardware-manager messages:'
  grep -E '\[HOTR\] (New device detected|Device state|Hardware manager matched|Hardware manager registry)' "$service_log" 2>/dev/null | tail -n 20 || echo '  none found'
  echo
  if [ -f "$config" ]; then
    printf 'Configuration timestamp: '
    stat -c '%y' "$config" 2>/dev/null || stat "$config" 2>/dev/null || true
    echo 'Saved serial paths:'
    while IFS= read -r raw_path; do
      path="$raw_path"
      case "$path" in
        /dev/ttyUSB*|/dev/ttyACM*) ;;
        ttyUSB*|ttyACM*) path="/dev/$path" ;;
        *) continue ;;
      esac
      count=$((count + 1))
      if [ -e "$path" ]; then
        echo "  PRESENT  $path"
      else
        echo "  MISSING  $path"
      fi
    done < <(grep -E '^(/dev/)?tty(USB|ACM)' "$config" 2>/dev/null || true)
    echo "Paths written: $count"
  else
    echo "Configuration file missing: $config"
  fi
}

sinden_summary(){
  local tracker found=0
  echo "Broker state file: $SINDEN_STATE"
  if [ -f "$SINDEN_STATE" ]; then
    python3 - "$SINDEN_STATE" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        state = json.load(stream)
except (OSError, ValueError) as exc:
    print(f"  unreadable: {exc}")
    raise SystemExit(0)

players = state.get("players") or {}
print(f"  updated={state.get('updated')} pid={state.get('pid')} control-socket={state.get('control_socket')}")
if not players:
    print("  no player channel is configured")
for player, data in sorted(players.items()):
    print(
        "  player {}: backend={} device={} usb={} tracker_ready={} worker={}".format(
            player,
            data.get("backend"),
            data.get("device") or "none",
            data.get("usb_id") or "unknown",
            data.get("tracker_ready"),
            data.get("worker"),
        )
    )
    print(
        "    sent={} dropped={} refused={} reply-bytes={}".format(
            data.get("sent"), data.get("dropped"), data.get("refused"), data.get("reply_bytes")
        )
    )
    if data.get("last_frame"):
        print(f"    last frame: {data['last_frame']} ({data.get('last_reason')})")
    if data.get("last_reply"):
        print(f"    last gun reply read by the legacy bridge: {data['last_reply']}")
    if data.get("last_refusal"):
        print(f"    last refused frame: {data['last_refusal']}")
PY
  else
    echo '  state file missing (the broker is stopped or could not write it)'
  fi
  echo 'LightgunMono tracker configs (SerialPortWrite names the tty each player uses):'
  for tracker in /var/run/sinden/p*/LightgunMono-*.exe.config; do
    [ -f "$tracker" ] || continue
    found=1
    printf '  %s -> ' "$tracker"
    grep -o 'key="SerialPortWrite"[^/]*' "$tracker" 2>/dev/null | head -n 1 || true
  done
  [ "$found" -eq 1 ] || echo '  none found (LightgunMono is not running)'
}

hotr_pids(){
  local p pid line
  for p in /proc/[0-9]*; do
    pid="${p##*/}"
    line="$(proc_cmdline "$pid")"
    case "$line" in
      /tmp/.mount_hook-*/usr/bin/HookOfTheReaper\ --headless*|\
      /tmp/.mount_hook-*/usr/bin/HookOfTheReaper\ --no-ui*|\
      "$ROOT/software/hook-of-the-reaper"\ --headless*|\
      "$ROOT/software/hook-of-the-reaper"\ --no-ui*)
        printf '%s %s\n' "$pid" "$line" ;;
    esac
  done
}

collect_report(){
  : >"$REPORT"
  {
    printf 'HOTR debug report\nGenerated: %s\n' "$(now)"
    section 'System'
    cmd uname -a
    [ -r /usr/share/batocera/batocera.version ] && cmd cat /usr/share/batocera/batocera.version
    cmd id
    cmd uptime

    section 'HOTR processes and service'
    hotr_pids
    cmd "$SERVICE" status
    cmd ps -ef
    section 'HOTR service log'
    cmd tail -n 120 /userdata/system/logs/hook-of-the-reaper.log
    section 'Sinden broker log'
    cmd tail -n 120 /userdata/system/logs/hotr-sinden-broker.log
    section 'Sinden recoil state'
    sinden_summary
    section 'Sinden broker workers (legacy bridge only)'
    cmd ls -la /var/run/hotr-sinden
    cmd cat /userdata/system/hotr/sinden-player-map
    cmd sed -n '1,80p' /usr/bin/virtual-sindenlightgun-add
    section 'Autoconfiguration summary'
    autoconfig_summary
    section 'Historical HOTR errors'
    cmd sh -c "grep -Ein 'serial port error|failed to open|permission denied|resource busy|already in use|no such file|cannot open|autoconfiguration failed' /userdata/system/logs/hook-of-the-reaper.log 2>/dev/null | tail -n 80 || true"
    section 'Game launch log'
    cmd tail -n 300 /userdata/system/logs/hotr-game-launch.log

    section 'HOTR configuration'
    cmd sed -n '1,240p' /userdata/system/hook-of-the-reaper/data/lightguns.hor
    cmd sed -n '1,160p' /userdata/system/hook-of-the-reaper/data/playersAss.hor
    cmd sed -n '1,260p' /userdata/system/hook-of-the-reaper/data/devices.json
    cmd grep -E '^(psx-hotr|ps2-hotr)\.' /userdata/system/batocera.conf

    section 'Serial and HID device nodes'
    cmd find -L /dev/hotr /dev/serial/by-id /dev/serial/by-path -maxdepth 2 -type l -printf '%p -> %l\n'
    cmd ls -l /dev/ttyUSB* /dev/ttyACM* /dev/hidraw* 
    cmd stat /dev/hotr/* /dev/serial/by-id/* /dev/serial/by-path/* /dev/ttyUSB* /dev/ttyACM*
    cmd fuser -v /dev/ttyUSB* /dev/ttyACM*
    command -v lsof >/dev/null 2>&1 && cmd lsof /dev/ttyUSB* /dev/ttyACM*

    section 'udev metadata'
    for node in /dev/ttyUSB* /dev/ttyACM*; do
      [ -e "$node" ] || continue
      cmd udevadm info --query=property --name="$node"
    done

    section 'USB and TTY kernel messages'
    cmd dmesg | grep -Ei 'usb|tty|serial|option|cdc_acm|hidraw|0483|5750|5751|3AGAME|Retro_Shooter'

    section 'Live samples'
    cmd cat "$STATE/process-samples.log"
    section 'Open serial handles'
    for pid in $(hotr_pids | awk '{print $1}'); do
      printf '\nHOTR PID %s (%s)\n' "$pid" "$(proc_cmdline "$pid")"
      cmd ls -l "/proc/$pid/fd"
      cmd sh -c "ls -l /proc/$pid/fd 2>/dev/null | grep -E 'ttyUSB|ttyACM|serial' || true"
    done
  } >>"$REPORT" 2>&1

  {
    section 'Quick summary'
    if ! ls /dev/ttyUSB* /dev/ttyACM* >/dev/null 2>&1; then
      echo 'POSSIBLE ISSUE: No ttyUSB or ttyACM serial device exists.'
    elif ! find -L /dev/hotr /dev/serial/by-id /dev/serial/by-path -maxdepth 2 -type l 2>/dev/null | grep -q .; then
      echo 'WARNING: A serial node exists but no stable serial link was found.'
    fi
    if ! grep -q '3AGAME\|Retro Shooter' /proc/bus/input/devices 2>/dev/null; then
      echo 'POSSIBLE ISSUE: No RS3/Reaper HID input device was detected.'
    fi
    if ! hotr_pids | grep -q .; then
      echo 'POSSIBLE ISSUE: HOTR process is not currently running.'
    fi
    if grep -Eiq 'permission denied|access denied|eacces' \
        /userdata/system/logs/hook-of-the-reaper.log \
        /userdata/system/logs/hotr-game-launch.log \
        /userdata/system/logs/hotr-sinden-broker.log 2>/dev/null; then
      echo 'POSSIBLE ISSUE: A permission/access-denied error was found.'
    fi
    if grep -Eiq 'no such file|enoent|cannot open|failed to open|serial port error|error opening' \
        /userdata/system/logs/hook-of-the-reaper.log \
        /userdata/system/logs/hotr-game-launch.log \
        /userdata/system/logs/hotr-sinden-broker.log 2>/dev/null; then
      echo 'POSSIBLE ISSUE: A missing or unavailable device/configuration path was found.'
    fi
    if grep -Eiq 'resource busy|already in use|ebusy' \
        /userdata/system/logs/hook-of-the-reaper.log \
        /userdata/system/logs/hotr-game-launch.log \
        /userdata/system/logs/hotr-sinden-broker.log 2>/dev/null; then
      echo 'POSSIBLE ISSUE: A serial device may already be in use by another process.'
    fi
    if [ -f "$SINDEN_STATE" ]; then
      python3 - "$SINDEN_STATE" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        players = json.load(stream).get("players") or {}
except (OSError, ValueError):
    players = {}
for player, data in sorted(players.items()):
    if not data.get("device"):
        print(f"POSSIBLE ISSUE: Sinden player {player} has no device; recoil frames are dropped.")
    if data.get("reply_bytes"):
        print(
            f"POSSIBLE ISSUE: Sinden player {player} forwarded {data['reply_bytes']} gun reply byte(s) "
            "into LightgunMono's PTY; retire the legacy bridge."
        )
    if data.get("refused"):
        print(f"POSSIBLE ISSUE: Sinden player {player} had {data['refused']} frame(s) refused by the HOTR safety chokepoint.")
PY
    fi
    if ! grep -q 'POSSIBLE ISSUE' "$REPORT"; then
      echo 'No obvious HOTR serial, HID, process, or access errors were detected.'
    fi
  } >>"$REPORT" 2>&1
}

start_capture(){
  # Keep only the current capture and its eventual upload result. Older
  # reports are intentionally removed so users do not submit stale logs.
  rm -f "$LOGROOT"/hotr-debug-*.txt
  rm -rf "$STATE"
  mkdir -p "$STATE"
  printf '%s\n' "$(now)" >"$STATE/started-at"
  : >"$STATE/process-samples.log"

  (
    while :; do
      {
        printf '\n--- %s ---\n' "$(now)"
        hotr_pids
        ps -eo pid,ppid,stat,comm,args 2>/dev/null | grep -E 'HookOfTheReaper|pcsx2|duckstation|configgen' | grep -v grep || true
        ls -l /dev/hotr /dev/serial/by-id /dev/serial/by-path /dev/ttyUSB* /dev/ttyACM* 2>&1 || true
        fuser -v /dev/ttyUSB* /dev/ttyACM* 2>&1 || true
      } >>"$STATE/process-samples.log" 2>&1
      sleep 1
    done
  ) </dev/null >/dev/null 2>&1 &
  echo $! >"$WATCHPID"

  echo "HOTR debug capture started. Launch the failing game now."
  echo "When finished, run: $0 finish"
  echo "Capture directory: $STATE"
}

stop_watcher(){
  if [ -r "$WATCHPID" ]; then
    kill "$(cat "$WATCHPID")" 2>/dev/null || true
    rm -f "$WATCHPID"
  fi
}

finish_capture(){
  [ -d "$STATE" ] || { echo "No active HOTR debug capture." >&2; exit 2; }
  stop_watcher
  collect_report
  SAVED_REPORT="$LOGROOT/hotr-debug-$(date +%Y%m%d-%H%M%S).txt"
  cp -f "$REPORT" "$SAVED_REPORT"
  echo "HOTR debug report created: $REPORT"
  echo
  sed -n '/===== Quick summary =====/,$p' "$REPORT"
  echo
  upload_report
}

upload_report(){
  [ -s "$REPORT" ] || { echo "No HOTR report found at $REPORT" >&2; exit 2; }
  if ! command -v curl >/dev/null 2>&1; then
    echo "curl is unavailable; report remains at $REPORT" >&2
    return 1
  fi
  local endpoint url
  mkdir -p "$STATE"
  endpoint="${HOTR_PASTE_URL:-https://paste.rs/}"
  case "$endpoint" in
    */) ;;
    *) endpoint="$endpoint/" ;;
  esac
  if url="$(curl --fail --silent --show-error --max-time 30 \
      --data-binary "@$REPORT" "$endpoint")" && [ -n "$url" ]; then
    printf 'Paste URL: %s\n' "$url" | tee "$STATE/paste-url"
    return 0
  fi
  echo "Paste upload failed; report remains at $REPORT" >&2
  return 1
}

case "${1:-}" in
  start) start_capture ;;
  finish|stop) finish_capture ;;
  upload) upload_report ;;
  *)
    echo "Usage: $0 {start|finish|upload}" >&2
    exit 2
    ;;
esac
