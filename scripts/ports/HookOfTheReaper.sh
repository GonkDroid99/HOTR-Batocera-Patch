#!/bin/bash
export DISPLAY=:0.0 HOME=/userdata/system XDG_CONFIG_HOME=/userdata/system/configs
ROOT=/userdata/system/hotr/software/hook-of-the-reaper
DAEMON="$ROOT/hook-of-the-reaper"
LOG=/userdata/system/logs/hook-of-the-reaper.log
if pgrep -f "$DAEMON" >/dev/null 2>&1; then
  WID=$(xdotool search --name "Hook" 2>/dev/null | head -1 || true)
  if [ -n "$WID" ]; then
    xdotool windowactivate --sync "$WID" 2>/dev/null || true
    xdotool windowraise "$WID" 2>/dev/null || true
    while xdotool getwindowgeometry "$WID" >/dev/null 2>&1; do
      xprop -id "$WID" WM_STATE 2>/dev/null | grep -q Iconic && break
      sleep 1
    done
  fi
else
  cd "$ROOT" || exit 1
  "$DAEMON" >>"$LOG" 2>&1
fi
