#!/bin/bash
ROOT=/userdata/system/hotr
SERVICE=/userdata/system/services/hotr
LOG=/userdata/system/logs/hook-of-the-reaper.log

"$SERVICE" stop 2>/dev/null || true
python3 "$ROOT/bin/hotr-autoconfig.py" --force 2>&1 | tee -a "$LOG"
rc=${PIPESTATUS[0]}
"$SERVICE" start
exit "$rc"
