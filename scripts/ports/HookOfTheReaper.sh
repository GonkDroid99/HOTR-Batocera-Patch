#!/bin/bash
# Open HOTR's GUI for manual configuration without creating a second instance.
ROOT=/userdata/system/hotr
APPDIR="$ROOT/software/hook-of-the-reaper"
APP="$APPDIR/hook-of-the-reaper"
SERVICE=/userdata/system/services/hotr
LOG=/userdata/system/logs/hook-of-the-reaper.log

"$SERVICE" stop 2>/dev/null || true
rm -f /tmp/qipc_sharedmemory_HookOfTheReaper* \
      /tmp/qipc_systemsem_HookOfTheReaper* 2>/dev/null || true

export DISPLAY=:0
export HOME=/userdata/system
export XDG_CONFIG_HOME=/userdata/system/configs
export QT_QPA_PLATFORM=xcb
export HOTR_DATA_DIR=/userdata/system/hook-of-the-reaper/data
unset XDG_RUNTIME_DIR

cd "$APPDIR" || exit 1
"$APP" >>"$LOG" 2>&1
rc=$?

# Return to appliance/service mode when the GUI closes.
"$SERVICE" start 2>/dev/null || true
exit "$rc"
