#!/bin/bash
# HOTR diagnostic capture for serial/TTY failures during game launch.
set -u

ROOT=/userdata/system/hotr
LOGROOT=/userdata/system/logs/hotr-debug
STATE="$LOGROOT/current"
SERVICE=/userdata/system/services/hotr
REPORT="$STATE/report.txt"
WATCHPID="$STATE/watcher.pid"
STRACEWATCHPID="$STATE/strace-watcher.pid"
STRACEPIDS="$STATE/strace.pids"

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

hotr_pids(){
  local p pid line
  for p in /proc/[0-9]*; do
    pid="${p##*/}"
    line="$(proc_cmdline "$pid")"
    case "$line" in
      *HookOfTheReaper*|*/hook-of-the-reaper*) printf '%s %s\n' "$pid" "$line" ;;
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
    cmd tail -n 500 /userdata/system/logs/hook-of-the-reaper.log
    section 'Game launch log'
    cmd tail -n 300 /userdata/system/logs/hotr-game-launch.log

    section 'HOTR configuration'
    cmd sed -n '1,240p' /userdata/system/hook-of-the-reaper/data/lightguns.hor
    cmd sed -n '1,160p' /userdata/system/hook-of-the-reaper/data/playersAss.hor
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
    section 'Serial syscall trace'
    cmd cat "$STATE/strace-attach.log"
    for trace in "$STATE"/strace.*; do
      [ -f "$trace" ] || continue
      cmd cat "$trace"
    done
  } >>"$REPORT" 2>&1
}

start_capture(){
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

  # Attach to HOTR when possible so the report contains the exact open(2)
  # path and kernel errno. This is useful when the UI test works but a game
  # profile tries to open a different or stale TTY.
  if command -v strace >/dev/null 2>&1; then
    : >"$STRACEPIDS"
    (
      while :; do
        for pid in $(hotr_pids | awk '{print $1}'); do
          grep -qx "$pid" "$STATE/strace-attached" 2>/dev/null && continue
          printf '%s\n' "$pid" >>"$STATE/strace-attached"
          strace -ff -tt -s 128 \
            -e trace=open,openat,close,ioctl \
            -p "$pid" -o "$STATE/strace.$pid" \
            2>>"$STATE/strace-attach.log" &
          echo $! >>"$STRACEPIDS"
        done
        sleep 1
      done
    ) </dev/null >/dev/null 2>&1 &
    echo $! >"$STRACEWATCHPID"
  else
    echo 'strace unavailable; process/device sampling only.' >"$STATE/strace-attach.log"
  fi
  echo "HOTR debug capture started. Launch the failing game now."
  echo "When finished, run: $0 finish"
  echo "Capture directory: $STATE"
}

stop_watcher(){
  if [ -r "$WATCHPID" ]; then
    kill "$(cat "$WATCHPID")" 2>/dev/null || true
    rm -f "$WATCHPID"
  fi
  if [ -r "$STRACEWATCHPID" ]; then
    kill "$(cat "$STRACEWATCHPID")" 2>/dev/null || true
    rm -f "$STRACEWATCHPID"
  fi
  if [ -r "$STRACEPIDS" ]; then
    while read -r pid; do kill "$pid" 2>/dev/null || true; done <"$STRACEPIDS"
  fi
}

finish_capture(){
  [ -d "$STATE" ] || { echo "No active HOTR debug capture." >&2; exit 2; }
  stop_watcher
  collect_report
  cp -f "$REPORT" "$LOGROOT/hotr-debug-$(date +%Y%m%d-%H%M%S).txt"
  echo "HOTR debug report created: $REPORT"
  upload_report
}

upload_report(){
  [ -s "$REPORT" ] || { echo "No HOTR report found at $REPORT" >&2; exit 2; }
  if ! command -v curl >/dev/null 2>&1; then
    echo "curl is unavailable; report remains at $REPORT" >&2
    return 1
  fi
  local endpoint url
  endpoint="${HOTR_PASTE_URL:-https://paste.rs}"
  url="$(curl -fsS --max-time 30 --data-binary "@$REPORT" "$endpoint" 2>/dev/null || true)"
  if [ -n "$url" ]; then
    printf '%s\n' "$url" | tee "$STATE/paste-url"
  else
    echo "Upload failed; report remains at $REPORT" >&2
    return 1
  fi
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
