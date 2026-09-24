#!/bin/bash
# Hook of the Reaper — Gun Setup & Rescan
#
# Accessible from ES → Ports → "HOTR Setup".
#
# What this does:
#   1. Stops any running HOTR instance.
#   2. Re-scans for RS3 Reaper guns and writes a fresh config for them.
#      (Other gun types are cleared — add them manually in the UI that follows.)
#   3. Starts HOTR with its full UI visible so the user can review auto-detected
#      guns and add any others (Gun4IR, Blamcon, OpenFire, Sinden, etc.).
#   4. Returns to ES when the user minimizes the HOTR window.
#      The engine keeps running in the background.
#
# Tips for serial guns (Gun4IR, Blamcon, OpenFire, X-Gunner, Fusion, Xenas):
#   Use the /dev/serial/by-path/ port entries shown in the HOTR port dropdown.
#   These are stable per physical USB socket — plug each gun into the same USB
#   port every time and HOTR's saved config will find it on every reboot.
#   Avoid /dev/ttyACM* entries — their numbers change on each boot.

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

# --- Ensure userdata directories are bind-mounted ---
# (Normally done by S35hookofthereaper on boot; redo here in case this script
#  is run before the init script or after an unmount.)
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

# Re-mount in case a previous stop unmounted them
mountpoint -q /usr/bin/data    || mount --bind "$HOTR_DATADIR" /usr/bin/data
mountpoint -q /usr/bin/defaultLG || mount --bind "$HOTR_LGDIR" /usr/bin/defaultLG

# --- Re-scan for RS3 guns and write fresh config ---
# --force: always rewrites config from current USB state.
# Non-RS3 guns will need to be re-added via the UI below.
python3 /usr/bin/hotr-autoconfig --force | tee -a "$LOGFILE"

# --- Start HOTR with full UI visible ---
nohup "$DAEMON" >> "$LOGFILE" 2>&1 &
HOTR_PID=$!
echo "$HOTR_PID" > "$PIDFILE"

# Wait for the window to appear (HOTR takes a moment to initialise Qt)
for i in $(seq 1 15); do
    WID=$(xdotool search --name "Hook" 2>/dev/null | head -1)
    [ -n "$WID" ] && break
    sleep 1
done

if [ -n "$WID" ]; then
    xdotool windowactivate --sync "$WID" 2>/dev/null
    xdotool windowraise "$WID" 2>/dev/null

    # Wait until the user minimizes or closes the window, then return to ES.
    while true; do
        if ! xdotool getwindowgeometry "$WID" > /dev/null 2>&1; then
            break
        fi
        ICONIC=$(xprop -id "$WID" WM_STATE 2>/dev/null | grep -c "Iconic")
        if [ "$ICONIC" -gt 0 ]; then
            break
        fi
        sleep 1
    done
else
    # Window never appeared — just wait briefly and return
    sleep 5
fi
