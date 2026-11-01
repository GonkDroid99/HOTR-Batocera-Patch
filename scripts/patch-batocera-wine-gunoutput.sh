#!/bin/bash
# patch-batocera-wine-gunoutput.sh - install / remove the gun-output hook in batocera-wine.
#
# The hook is what makes the gun-output shim automatic: for every wine launch it asks
# batocera-wine-gunoutput whether the system+rom has a table row, applies the row's game
# environment and starts the per-game output producer; cleanAndExit() stops it again.
#
#   patch-batocera-wine-gunoutput.sh                 # patch /usr/bin/batocera-wine
#   patch-batocera-wine-gunoutput.sh --check         # is it patched?
#   patch-batocera-wine-gunoutput.sh --revert        # restore the backup
#   patch-batocera-wine-gunoutput.sh --file PATH     # work on a copy (testing)
#   patch-batocera-wine-gunoutput.sh --no-save       # do not run batocera-save-overlay
#
# Idempotent: running it twice changes nothing. Every change is reversible: the original file is
# kept as a backup and the inserted blocks are delimited by versioned markers.
#
# Insertion points (anchored on content, not line numbers, so Batocera updates do not silently
# move them):
#   * before every `if [[ -n "${WINE_LANG}" ]]; then` inside the play_* launchers - that is
#     exactly the line that precedes the wine exec, after the overlay is mounted and the prefix
#     is prepared, and it appears once per launcher (play_wine, play_pc, play_winetgz,
#     play_system, play_squashfs)
#   * after `stop_guns` in cleanAndExit(), so the producer dies with the session

set -u

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

MARK_START="# >>> HOTR-GUNOUTPUT-HOOK v1 >>>"
MARK_END="# <<< HOTR-GUNOUTPUT-HOOK v1 <<<"
TARGET="/usr/bin/batocera-wine"
BACKUP_DIR="/userdata/system/hotr/backups"
HELPER="/usr/bin/batocera-wine-gunoutput"
ANCHOR='    if [[ -n "${WINE_LANG}" ]]; then'
SAVE_OVERLAY=1
MODE="apply"
DRY=0

usage() {
    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
    return 0
}

log() {
    printf '[patch-gunoutput] %s\n' "$*"
    return 0
}

die() {
    printf '[patch-gunoutput] ERROR: %s\n' "$*" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --check) MODE="check" ;;
        --revert) MODE="revert" ;;
        --file) shift; [ $# -gt 0 ] || die "--file needs a path"; TARGET="$1" ;;
        --no-save) SAVE_OVERLAY=0 ;;
        --dry-run) DRY=1 ;;
        -h|--help|help) usage; exit 0 ;;
        *) die "unknown argument '$1' (try --help)" ;;
    esac
    shift
done

[ -f "$TARGET" ] || die "no such file: $TARGET"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

# ------------------------------------------------------------------ the patch logic (python)

patch_apply() {
    python3 - "$TARGET" "$MARK_START" "$MARK_END" "$ANCHOR" "$HELPER" <<'PY'
import sys

path, mark_start, mark_end, anchor, helper = sys.argv[1:6]
with open(path, "r", encoding="utf-8", errors="surrogateescape") as fh:
    lines = fh.readlines()

if any(line.strip() == mark_start for line in lines):
    print("already-patched")
    sys.exit(0)

env_block = [
    "    " + mark_start + "\n",
    "    # Starts the per-game gun-output producer (DemulShooter in MAME network-output mode).\n",
    "    # No-op unless /usr/share/batocera/hotr/gun-output.tsv has a row for this system+rom.\n",
    "    if [ -x " + helper + " ]; then\n",
    "        eval \"$(" + helper + " env \"${SYSTEM}\" \"${ROMGAMENAME}\" 2>/dev/null)\" 2>/dev/null || true\n",
    "        " + helper + " start \"${SYSTEM}\" \"${ROMGAMENAME}\" \"${WINEPOINT}\" \"${WINE}\" >/dev/null 2>&1 || true\n",
    "    fi\n",
    "    " + mark_end + "\n",
]
stop_block = [
    "    " + mark_start + "\n",
    "    if [ -x " + helper + " ]; then\n",
    "        " + helper + " stop \"${SYSTEM}\" \"${ROMGAMENAME}\" >/dev/null 2>&1 || true\n",
    "    fi\n",
    "    " + mark_end + "\n",
]

out = []
starts = 0
stop_added = False
in_clean = False
for line in lines:
    stripped = line.rstrip("\n")

    if stripped == anchor:
        out.extend(env_block)
        starts += 1

    if stripped.startswith("cleanAndExit()"):
        in_clean = True
    elif in_clean and not stop_added and stripped.strip() == "stop_guns":
        out.append(line)
        out.extend(stop_block)
        stop_added = True
        in_clean = False
        continue
    elif in_clean and stripped.strip() and not stripped.strip().startswith("#") and stripped.strip() != "stop_guns":
        # left the first statement of cleanAndExit() without finding stop_guns
        in_clean = False

    out.append(line)

if starts == 0:
    print("error:no-anchor")
    sys.exit(3)
if not stop_added:
    print("error:no-cleanandexit")
    sys.exit(4)

with open(path, "w", encoding="utf-8", errors="surrogateescape") as fh:
    fh.writelines(out)
print("patched:%d" % (starts + 1))
PY
}

patch_revert() {
    python3 - "$TARGET" "$MARK_START" "$MARK_END" <<'PY'
import sys

path, mark_start, mark_end = sys.argv[1:4]
with open(path, "r", encoding="utf-8", errors="surrogateescape") as fh:
    lines = fh.readlines()

out = []
inside = False
removed = 0
for line in lines:
    stripped = line.strip()
    if stripped == mark_start:
        inside = True
        removed += 1
        continue
    if stripped == mark_end:
        inside = False
        continue
    if not inside:
        out.append(line)

if removed == 0:
    print("not-patched")
    sys.exit(0)

with open(path, "w", encoding="utf-8", errors="surrogateescape") as fh:
    fh.writelines(out)
print("reverted:%d" % removed)
PY
}

patch_check() {
    local n
    n="$(grep -cF "$MARK_START" "$TARGET" 2>/dev/null || true)"
    printf 'file=%s\nmarker_blocks=%s\nhelper=%s\n' "$TARGET" "${n:-0}" \
        "$([ -x "$HELPER" ] && echo present || echo missing)"
    if [ "${n:-0}" -gt 0 ]; then
        printf 'status=patched\n'
    else
        printf 'status=unpatched\n'
    fi
    return 0
}

# ------------------------------------------------------------------------------- main

log "target: ${TARGET}"
case "$MODE" in
    check)
        patch_check
        exit 0
        ;;
esac

if [ "$MODE" = "apply" ] && grep -qF "$MARK_START" "$TARGET" 2>/dev/null; then
    log "already patched - nothing to do (use --revert to remove)"
    exit 0
fi
if [ "$MODE" = "revert" ] && ! grep -qF "$MARK_START" "$TARGET" 2>/dev/null; then
    log "not patched - nothing to revert"
    exit 0
fi

# backup (once per target; the first backup is the pristine file)
if [ "$MODE" = "apply" ]; then
    if [ "$TARGET" = "/usr/bin/batocera-wine" ]; then
        mkdir -p "$BACKUP_DIR"
        backup="${BACKUP_DIR}/batocera-wine.orig"
    else
        backup="${TARGET}.hotr-gunoutput.orig"
    fi
    if [ ! -f "$backup" ]; then
        cp -a "$TARGET" "$backup" || die "cannot write backup ${backup}"
        log "backup: ${backup}"
    else
        log "backup already exists: ${backup}"
    fi
fi

if [ "$DRY" = "1" ]; then
    log "dry run - not writing"
    exit 0
fi

if [ "$MODE" = "apply" ]; then
    result="$(patch_apply)" || die "patching failed (${result:-no output})"
    case "$result" in
        already-patched) log "already patched"; exit 0 ;;
        patched:*) log "inserted ${result#patched:} hook block(s)" ;;
        *) die "unexpected result: $result" ;;
    esac
else
    result="$(patch_revert)" || die "revert failed (${result:-no output})"
    case "$result" in
        not-patched) log "not patched"; exit 0 ;;
        reverted:*) log "removed ${result#reverted:} hook block(s)" ;;
        *) die "unexpected result: $result" ;;
    esac
fi

# never leave a broken launcher behind
if ! bash -n "$TARGET" 2>/dev/null; then
    if [ "$MODE" = "apply" ] && [ -f "$backup" ]; then
        cp -a "$backup" "$TARGET"
        die "syntax check failed - restored ${backup}"
    fi
    die "syntax check failed on ${TARGET}"
fi
log "syntax check: OK"
chmod +x "$TARGET" 2>/dev/null

if [ "$SAVE_OVERLAY" = "1" ] && [ "$TARGET" = "/usr/bin/batocera-wine" ]; then
    if [ -x /usr/bin/batocera-save-overlay ]; then
        log "persisting with batocera-save-overlay"
        /usr/bin/batocera-save-overlay >/dev/null 2>&1 && log "overlay saved" || log "WARNING: batocera-save-overlay failed"
    else
        log "WARNING: batocera-save-overlay not found - change will not survive a reboot"
    fi
fi

patch_check
exit 0
