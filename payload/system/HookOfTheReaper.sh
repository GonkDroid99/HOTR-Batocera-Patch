#!/bin/bash
# Hook of the Reaper — EmulationStation port launcher
#
# This script is placed in /userdata/roms/ports/ so the user can open
# the HOTR configuration UI from ES → Ports → Hook of the Reaper.
#
# Behaviour:
#   - If HOTR is already running (started at boot): raise the window to
#     front and wait until the user minimizes or closes it, then return
#     to ES.  The engine keeps running in the background after return.
#   - If HOTR is not running: start it fresh and wait for it to exit.

export DISPLAY=:0.0
export HOME=/userdata/system
export XDG_CONFIG_HOME=/userdata/system/configs

DAEMON=/usr/bin/hook-of-the-reaper
PIDFILE=/var/run/hook-of-the-reaper.pid
DATA_SRC=/usr/share/hook-of-the-reaper/data
DATA_DST=/userdata/system/hook-of-the-reaper/data

# Ensure user data directory exists
if [ ! -d "$DATA_DST" ]; then
    mkdir -p /userdata/system/hook-of-the-reaper
    cp -r "$DATA_SRC" /userdata/system/hook-of-the-reaper/
fi

if pgrep -x "hook-of-the-reaper" > /dev/null 2>&1; then
    # ----------------------------------------------------------------
    # Already running — raise the existing window and wait for it to
    # be minimized (user "done configuring") before returning to ES.
    # ----------------------------------------------------------------
    WID=$(xdotool search --name "Hook" 2>/dev/null | head -1)
    if [ -n "$WID" ]; then
        xdotool windowactivate --sync "$WID"
        xdotool windowraise "$WID"
        # Wait until the window is iconified (minimized) or destroyed.
        # xdotool wait-for-window-close blocks until the window is gone,
        # but we want to return to ES on minimize too — poll instead.
        while true; do
            # Window gone (closed)?
            if ! xdotool getwindowgeometry "$WID" > /dev/null 2>&1; then
                break
            fi
            # Window iconified (minimized)?
            ICONIC=$(xprop -id "$WID" WM_STATE 2>/dev/null | grep -c "Iconic")
            if [ "$ICONIC" -gt 0 ]; then
                break
            fi
            sleep 1
        done
    else
        # Process running but no window found yet — brief wait and return
        sleep 2
    fi
else
    # ----------------------------------------------------------------
    # Not running — start it and wait for exit (engine stops on exit).
    # ----------------------------------------------------------------
    export HOTR_DATA_DIR="$DATA_DST"
    "$DAEMON"
fi
