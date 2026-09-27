#!/bin/bash
# Apply the Sinden fixes required by Batocera 43.1.
# The upstream scripts are installed in the root filesystem, so this must run
# before batocera-save-overlay during HOTR installation.
set -euo pipefail

ADD=/usr/bin/virtual-sindenlightgun-add
HELPER=/usr/bin/evsieve-helper
BACKUP=/userdata/system/sinden-patch-backup

case "${1:-apply}" in
  apply) ;;
  remove)
    if [ -f "$BACKUP/virtual-sindenlightgun-add" ] && [ -f "$BACKUP/evsieve-helper" ]; then
      cp -a "$BACKUP/virtual-sindenlightgun-add" "$ADD"
      cp -a "$BACKUP/evsieve-helper" "$HELPER"
      rm -rf "$BACKUP"
      udevadm control --reload-rules 2>/dev/null || true
      udevadm trigger 2>/dev/null || true
      command -v batocera-save-overlay >/dev/null && batocera-save-overlay || true
      echo "Sinden compatibility patch removed; stock helpers restored."
    else
      echo "No Sinden patch backup found; nothing changed."
    fi
    exit 0
    ;;
  *) echo "Usage: $0 [apply|remove]" >&2; exit 2 ;;
esac

[ -f "$ADD" ] && [ -f "$HELPER" ] || exit 0
mkdir -p "$BACKUP"
[ -f "$BACKUP/virtual-sindenlightgun-add" ] || cp -a "$ADD" "$BACKUP/virtual-sindenlightgun-add"
[ -f "$BACKUP/evsieve-helper" ] || cp -a "$HELPER" "$BACKUP/evsieve-helper"

python3 - "$ADD" "$HELPER" <<'PY'
from pathlib import Path
import sys

add = Path(sys.argv[1])
helper = Path(sys.argv[2])

def replace(path, replacements):
    text = path.read_text()
    original = text
    for old, new in replacements:
        text = text.replace(old, new)
    if text != original:
        path.write_text(text)

replace(add, [
    (' | tr -d "\\n" | tr -d "\\n" | md5sum | cut -c 1-32',
     ' | tr -d "\\n" | md5sum | cut -c 1-32'),
    ('sed -e s+"\\.2$"+".1"+ | md5sum | cut -c 1-32',
     'sed -e s+"\\.2$"+".1"+ | tr -d "\\n" | md5sum | cut -c 1-32'),
    ('sed -e s+"\\.1$"+".2"+ | md5sum | cut -c 1-32',
     'sed -e s+"\\.1$"+".2"+ | tr -d "\\n" | md5sum | cut -c 1-32'),
    ('evsieve-helper parent-raw "${DEVNAME}" video usb',
     'evsieve-helper parent-raw "${DEVNAME}" video4linux usb'),
    ('evsieve-helper parent "${DEVNAME}" video usb',
     'evsieve-helper parent "${DEVNAME}" video4linux usb'),
    ('evsieve-helper children "${PARENTVIDEOSHASH}" video usb',
     'evsieve-helper children "${PARENTVIDEOSHASH}" video4linux usb'),
    ('test "${NDEVSINPUTS}" = 2 -a "${NDEVSVIDEOS}" -ge 1',
     'test "${NDEVSINPUTS}" -ge 2 -a "${NDEVSVIDEOS}" -ge 1'),
])

replace(helper, [
    ('elif childtype == "video":', 'elif childtype == "video4linux":'),
    ('children.append({ "video": "/dev/"+cname})',
     'children.append({ "video4linux": "/dev/"+cname})'),
    ('elif childtype == "video" or childtype == "hidraw":',
     'elif childtype == "video4linux" or childtype == "hidraw":'),
])
PY

chmod 0755 "$ADD" "$HELPER"
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger 2>/dev/null || true
command -v batocera-save-overlay >/dev/null && batocera-save-overlay || true
echo "Sinden compatibility patch applied. Original helpers backed up in $BACKUP."
