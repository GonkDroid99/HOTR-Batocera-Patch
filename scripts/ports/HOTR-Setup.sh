#!/bin/bash
export DISPLAY=:0.0 HOME=/userdata/system XDG_CONFIG_HOME=/userdata/system/configs
ROOT=/userdata/system/hotr
APP="$ROOT/software/hook-of-the-reaper"
LOG=/userdata/system/logs/hook-of-the-reaper.log
/userdata/system/services/hotr stop 2>/dev/null || true
python3 "$ROOT/bin/hotr-autoconfig.py" --force 2>&1 | tee -a "$LOG"
cd "$APP" || exit 1
nohup "$APP/hook-of-the-reaper" >>"$LOG" 2>&1 &
echo $! >/var/run/hook-of-the-reaper.pid
for _ in $(seq 1 15); do WID=$(xdotool search --name "Hook" 2>/dev/null | head -1 || true); [ -n "$WID" ] && break; sleep 1; done
if [ -n "${WID:-}" ]; then
  xdotool windowactivate --sync "$WID" 2>/dev/null || true; xdotool windowraise "$WID" 2>/dev/null || true
  while xdotool getwindowgeometry "$WID" >/dev/null 2>&1; do xprop -id "$WID" WM_STATE 2>/dev/null | grep -q Iconic && break; sleep 1; done
fi
