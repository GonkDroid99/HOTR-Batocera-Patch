#!/bin/bash
# Enable the HOTR Sinden broker integration in Batocera's native helper.
# This is deliberately separate from patch-batocera-sinden.sh, which contains
# the optional Batocera 43 detection workaround.
set -euo pipefail

ADD="${HOTR_SINDEN_ADD_PATH:-/usr/bin/virtual-sindenlightgun-add}"
BACKUP="${HOTR_SINDEN_BACKUP_DIR:-/userdata/system/hotr/backups}"
ORIGINAL="$BACKUP/virtual-sindenlightgun-add.hotr-original"
MARKER="# HOTR SINDEN BROKER INTEGRATION"

case "${1:-apply}" in
  remove)
    if [ -f "$ORIGINAL" ]; then
      cp -a "$ORIGINAL" "$ADD"
      rm -f "$ORIGINAL"
      chmod 0755 "$ADD"
      udevadm control --reload-rules 2>/dev/null || true
      command -v batocera-save-overlay >/dev/null 2>&1 && batocera-save-overlay || true
      echo "HOTR Sinden broker integration removed; stock helper restored."
    else
      echo "No HOTR Sinden broker helper backup found; nothing changed."
    fi
    exit 0
    ;;
  apply) ;;
  *) echo "Usage: $0 [apply|remove]" >&2; exit 2 ;;
esac

[ -f "$ADD" ] || { echo "Batocera Sinden helper not found: $ADD" >&2; exit 0; }
mkdir -p "$BACKUP"
[ -f "$ORIGINAL" ] || cp -a "$ADD" "$ORIGINAL"

python3 - "$ADD" "$MARKER" <<'PY'
from pathlib import Path
import sys

import re

path = Path(sys.argv[1])
marker = sys.argv[2]
text = path.read_text()
if marker in text:
    raise SystemExit(0)

anchor = re.compile(r'(?m)^[ \t]*ACMDEV=/dev/\$\(basename "\$\{ACM\}"\)\n')
match = anchor.search(text)
if not match:
    raise SystemExit("unsupported virtual-sindenlightgun-add: ACM device anchor not found")

block = r'''    # HOTR SINDEN BROKER INTEGRATION
    # Keep the real tty owned by the broker and give Mono the broker PTY.
    if test -x /userdata/system/hotr/bin/hotr-sinden-worker-launch
    then
        HOTR_MONO_TTY=$(/userdata/system/hotr/bin/hotr-sinden-worker-launch start "${PARENTHASH}" "${ACMDEV}" 2>>"${LOGFILE}" || true)
        test -z "${HOTR_MONO_TTY}" || ACMDEV="${HOTR_MONO_TTY}"
    fi
'''

path.write_text(text[:match.end()] + block + text[match.end():])
PY

chmod 0755 "$ADD"
udevadm control --reload-rules 2>/dev/null || true
command -v batocera-save-overlay >/dev/null 2>&1 && batocera-save-overlay || true
echo "HOTR Sinden broker integration applied. Original helper backed up at $ORIGINAL."
