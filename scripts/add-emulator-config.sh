#!/bin/bash
set -euo pipefail
TYPE="${1:-}"; FILE="${2:-}"
[ -f "$FILE" ] || { echo "Usage: $0 {duckstation|pcsx2} /path/to/config.ini"; exit 2; }
case "$TYPE" in
  duckstation) DEST=/userdata/system/configs/duckstation/settings.ini ;;
  pcsx2) DEST=/userdata/system/configs/PCSX2-lightgun/inis/PCSX2.ini ;;
  *) echo "TYPE must be duckstation or pcsx2"; exit 2 ;;
esac
mkdir -p "$(dirname "$DEST")"; cp -a "$FILE" "$DEST"; echo "Installed: $DEST"
