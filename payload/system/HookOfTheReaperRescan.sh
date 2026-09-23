#!/bin/bash
# Hook of the Reaper — Silent Gun Rescan
#
# Accessible from ES → Ports → "HOTR Rescan Guns".
#
# Use this when:
#   - You plugged a gun into a different USB port and want HOTR to find it again.
#   - You added or removed a gun and want the engine to pick up the change.
#   - You want to reset to auto-detected config after manual edits.
#
# What this does:
#   1. Stops HOTR.
#   2. Re-scans all USB ports for supported guns and writes a fresh config.
#   3. Restarts the HOTR engine silently (no UI window).
#   4. Returns to ES immediately — no interaction needed.
#
# Note: saves paths as /dev/serial/by-path/ entries, which are stable per
# physical USB port across reboots.  Keep each gun in the same USB port.
#
# Guns not auto-detected (Alien USB, AimTrak, Custom USB, RKADE, MX24, Sinden,
# Xenas BTLE): use "HOTR Setup" from Ports to add them manually via the UI.

export DISPLAY=:0.0
export HOME=/userdata/system
export XDG_CONFIG_HOME=/userdata/system/configs

DAEMON=/usr/bin/hook-of-the-reaper
PIDFILE=/var/run/hook-of-the-reaper.pid
LOGFILE=/var/log/hook-of-the-reaper.log

# --- Stop any running HOTR instance ---
if [ -f "$PIDFILE" ]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null
    rm -f "$PIDFILE"
fi
pkill -x hook-of-the-reaper 2>/dev/null
sleep 1

# --- Ensure userdata bind-mounts are in place ---
HOTR_DATADIR=/userdata/system/hook-of-the-reaper/data
HOTR_LGDIR=/userdata/system/hook-of-the-reaper/defaultLG

if [ ! -d "$HOTR_DATADIR" ]; then
    mkdir -p "$HOTR_DATADIR"
    cp -r /usr/bin/data/. "$HOTR_DATADIR/"
fi
if [ ! -d "$HOTR_LGDIR" ]; then
    mkdir -p "$HOTR_LGDIR"
    cp -r /usr/bin/defaultLG/. "$HOTR_LGDIR/"
fi

mountpoint -q /usr/bin/data     || mount --bind "$HOTR_DATADIR" /usr/bin/data
mountpoint -q /usr/bin/defaultLG || mount --bind "$HOTR_LGDIR"  /usr/bin/defaultLG

# --- Rescan all supported guns ---
echo "HOTR Rescan: scanning for connected guns..."
python3 /usr/bin/hotr-autoconfig --force 2>&1 | tee -a "$LOGFILE"

# --- Restart engine silently ---
nohup "$DAEMON" --no-ui >> "$LOGFILE" 2>&1 &
echo $! > "$PIDFILE"
echo "HOTR Rescan: engine restarted (PID $(cat $PIDFILE))"

# Return to ES immediately — engine runs in the background
