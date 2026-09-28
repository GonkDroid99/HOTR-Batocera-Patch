#!/bin/bash
LOG=/userdata/system/logs/hotr-debug-start.log
mkdir -p "${LOG%/*}"
# Batocera v44 waits on inherited descriptors, including descriptors beyond
# stdin/stdout/stderr. start-stop-daemon closes them before backgrounding.
start-stop-daemon --start --background \
  --exec /userdata/system/hotr/tools/hotr-debug-report.sh \
  --startas /userdata/system/hotr/tools/hotr-debug-report.sh \
  --output "$LOG" -- start
exit 0
