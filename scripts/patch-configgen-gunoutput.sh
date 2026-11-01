#!/bin/bash
# patch-configgen-gunoutput.sh - install / remove the gun-output hook in configgen's Generator.py.
#
# The launcher patch (patch-batocera-wine-gunoutput.sh) covers wine launches. Native emulators
# never run through batocera-wine, so the native producer - today the Flycast state reader - is
# started from here instead: configgen calls Generator.running() around every emulator launch, and
# the hook starts the producer before the emulator and stops it afterwards. It is a no-op unless
# /usr/bin/batocera-wine-gunoutput finds a kind=flycast row for the system+rom, so it is safe for
# every emulator.
#
#   patch-configgen-gunoutput.sh                 # patch the installed Generator.py
#   patch-configgen-gunoutput.sh --check         # is it patched?
#   patch-configgen-gunoutput.sh --revert        # restore the backup
#   patch-configgen-gunoutput.sh --file PATH     # work on a copy (testing)
#   patch-configgen-gunoutput.sh --no-save       # do not run batocera-save-overlay
#   GUNOUTPUT_ROOT=/tmp/x patch-configgen-gunoutput.sh   # staging root (testing)
#
# Idempotent: running it twice changes nothing. Reversible: the original file is kept as a backup
# and the inserted code is delimited by versioned markers. The patched file is syntax-checked with
# py_compile before it is accepted; a file that does not compile is left untouched.

set -u

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

ROOT="${GUNOUTPUT_ROOT:-}"
MARK_START="# >>> HOTR-GUNOUTPUT-HOOK v1 >>>"
MARK_END="# <<< HOTR-GUNOUTPUT-HOOK v1 <<<"
TARGET="${ROOT}/usr/lib/python3.12/site-packages/configgen/generators/Generator.py"
BACKUP_DIR="${ROOT}/userdata/system/hotr/backups"
ANCHOR="        return nullcontext()"
SAVE_OVERLAY=1
MODE="apply"

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    return 0
}

log() {
    printf '%s\n' "$*" >&2
    return 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --check) MODE="check" ;;
        --revert) MODE="revert" ;;
        --file)
            shift
            [ $# -gt 0 ] || { log "--file needs a path"; exit 2; }
            TARGET="$1"
            ;;
        --no-save) SAVE_OVERLAY=0 ;;
        -h|--help) usage; exit 0 ;;
        *) log "unknown argument: $1"; usage; exit 2 ;;
    esac
    shift
done

[ -f "$TARGET" ] || { log "not found: $TARGET"; exit 2; }

patched() {
    grep -qF "$MARK_START" "$TARGET"
}

save_overlay() {
    [ "$SAVE_OVERLAY" = "1" ] || return 0
    [ -z "$ROOT" ] || return 0
    command -v batocera-save-overlay >/dev/null 2>&1 || return 0
    log "saving the overlay so the patch survives a reboot..."
    batocera-save-overlay >/dev/null 2>&1 || log "warning: batocera-save-overlay failed"
    return 0
}

do_check() {
    if patched; then
        log "PASS configgen hook present in $TARGET"
        return 0
    fi
    log "FAIL configgen hook missing from $TARGET"
    return 1
}

do_revert() {
    if ! patched; then
        log "configgen hook not present - nothing to revert"
        return 0
    fi
    local backup
    backup="$BACKUP_DIR/$(basename "$TARGET").orig"
    if [ -f "$backup" ]; then
        cp -f "$backup" "$TARGET" || { log "could not restore $backup"; return 1; }
        log "restored $TARGET from $backup"
    else
        python3 - "$TARGET" "$MARK_START" "$MARK_END" <<'PY' || return 1
import sys
from pathlib import Path

target, mark_start, mark_end = sys.argv[1], sys.argv[2], sys.argv[3]
path = Path(target)
text = path.read_text(encoding="utf-8")
start = text.find(mark_start)
end = text.find(mark_end)
if start != -1 and end != -1:
    text = text[:start].rstrip("\n") + "\n" + text[end + len(mark_end):].lstrip("\n")
text = text.replace("        return _hotr_gunoutput_running(config, rom)  # HOTR-GUNOUTPUT-HOOK v1\n",
                    "        return nullcontext()\n")
path.write_text(text, encoding="utf-8")
PY
        log "removed the inserted block from $TARGET"
    fi
    save_overlay
    return 0
}

do_apply() {
    if patched; then
        log "already patched: $TARGET"
        return 0
    fi
    mkdir -p "$BACKUP_DIR"
    local backup
    backup="$BACKUP_DIR/$(basename "$TARGET").orig"
    [ -f "$backup" ] || cp -f "$TARGET" "$backup" || { log "could not back up $TARGET"; return 1; }

    python3 - "$TARGET" "$ANCHOR" "$MARK_START" "$MARK_END" <<'PY' || return 1
import sys
from pathlib import Path

target, anchor, mark_start, mark_end = sys.argv[1:5]
path = Path(target)
text = path.read_text(encoding="utf-8")
if mark_start in text:
    sys.exit(0)
if anchor not in text:
    sys.exit(f"anchor not found in {target}: {anchor!r}")
if text.count(anchor) != 1:
    sys.exit(f"anchor is not unique in {target} ({text.count(anchor)} matches)")

hook = f'''
{mark_start}
# Added by the HOTR gun-output component (scripts/patch-configgen-gunoutput.sh). Starts the
# native output producer for the whole life of the emulator and stops it again; a no-op unless
# /usr/bin/batocera-wine-gunoutput has a kind=flycast row for this system and rom.
def _hotr_gunoutput_running(config, rom):
    import os
    import subprocess
    from contextlib import contextmanager

    helper = "/usr/bin/batocera-wine-gunoutput"
    game = os.path.basename(str(rom))
    # configgen passes a plain Config mapping (no .name), and every rom lives in
    # /userdata/roms/<system>/, so the parent directory names the system.
    system = getattr(config, "name", "") or os.path.basename(os.path.dirname(str(rom))) or ""

    def call(action):
        try:
            return subprocess.run(
                [helper, action, system, game],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30,
            ).returncode == 0
        except Exception:
            return False

    @contextmanager
    def _ctx():
        started = bool(system) and os.path.exists(helper) and call("native-start")
        try:
            yield
        finally:
            if started and os.path.exists(helper):
                call("native-stop")

    return _ctx()
{mark_end}
'''

text = text.replace(anchor, "        return _hotr_gunoutput_running(config, rom)  # HOTR-GUNOUTPUT-HOOK v1")
if not text.endswith("\n"):
    text += "\n"
path.write_text(text + hook, encoding="utf-8")
PY
    [ $? -eq 0 ] || return 1

    if ! python3 -m py_compile "$TARGET" 2>/dev/null; then
        log "patched file does not compile - restoring the backup"
        cp -f "$backup" "$TARGET"
        return 1
    fi
    rm -rf "$(dirname "$TARGET")/__pycache__" 2>/dev/null
    log "patched $TARGET"
    save_overlay
    return 0
}

case "$MODE" in
    check) do_check ;;
    revert) do_revert ;;
    *) do_apply ;;
esac
