#!/bin/bash
# patch-libretro-flycast-network-output.sh — make Batocera's libretro core options
# expose Flycast's "Broadcast Digital Outputs" (reicast_network_output).
#
# Why: the Flycast libretro core can broadcast its digital outputs (lamps, gun
# recoil) on TCP 8000 in the MAME network-output format, but Batocera's configgen
# rewrites the per-core .opt files on every launch and never sets this option, so
# a hand edit to naomi.opt is wiped before the core ever sees it.
#
# This adds one line to the Flycast section of libretroOptions.py and sets
# <system>.reicast_network_output=enabled in batocera.conf for the systems we
# care about (naomi, naomi2, atomiswave).  Reversible with --revert.
#
# Usage:
#   patch-libretro-flycast-network-output.sh            # apply (default)
#   patch-libretro-flycast-network-output.sh --check    # 0 = patched, 1 = not
#   patch-libretro-flycast-network-output.sh --revert   # restore the backup
#   patch-libretro-flycast-network-output.sh --no-save  # skip batocera-save-overlay
#
# Environment:
#   ROOT=<dir>   test hook: prefixes every system path (fake-root testing)
set -euo pipefail

ROOT="${ROOT:-}"
OPTS="$ROOT/usr/lib/python3.12/site-packages/configgen/generators/libretro/libretroOptions.py"
CONF="$ROOT/userdata/system/batocera.conf"
BACKUP_DIR="$ROOT/userdata/system/hotr/backups"
BACKUP="$BACKUP_DIR/libretroOptions.py.orig"
MARKER="reicast_network_output"
INSERT="_set_from_system(coreSettings, 'reicast_network_output', system, 'reicast_network_output', default='disabled')"
ANCHOR="reicast_enable_purupuru"
SYSTEMS=(naomi naomi2 atomiswave)
SAVE=1

# The standalone /usr/bin/flycast keeps its own config (emu.cfg, [network] NetworkOutput)
# and the RGS flycast generator rewrites that file on every launch, but it maps
# <system>.flycast.<section>.<option>=<value> from batocera.conf straight into it.
STANDALONE_KEYS=(network.NetworkOutput)

for arg in "$@"; do
    case "$arg" in
        --check|--revert|--no-save) ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

save_overlay() {
    [ "$SAVE" -eq 1 ] || { echo "note: --no-save, overlay not saved"; return 0; }
    if [ -n "$ROOT" ]; then echo "note: test root, overlay not saved"; return 0; fi
    if command -v batocera-save-overlay >/dev/null 2>&1; then
        batocera-save-overlay >/dev/null 2>&1 && echo "overlay saved" || echo "warning: batocera-save-overlay failed"
    fi
}

do_check() {
    local ok=0
    if grep -q "$MARKER" "$OPTS" 2>/dev/null; then
        echo "PASS  libretroOptions.py carries $MARKER"
    else
        echo "FAIL  libretroOptions.py does not carry $MARKER"; ok=1
    fi
    for s in "${SYSTEMS[@]}"; do
        if grep -qE "^${s}\.${MARKER}=" "$CONF" 2>/dev/null; then
            echo "PASS  ${s}.${MARKER} set in batocera.conf"
        else
            echo "FAIL  ${s}.${MARKER} missing from batocera.conf"; ok=1
        fi
    done
    for s in "${SYSTEMS[@]}"; do
        for k in "${STANDALONE_KEYS[@]}"; do
            if grep -qE "^${s}\.flycast\.${k}=" "$CONF" 2>/dev/null; then
                echo "PASS  ${s}.flycast.${k} set (standalone flycast)"
            else
                echo "FAIL  ${s}.flycast.${k} missing (standalone flycast)"; ok=1
            fi
        done
    done
    return $ok
}

do_revert() {
    if [ -f "$BACKUP" ]; then
        cp -a "$BACKUP" "$OPTS"
        echo "restored $OPTS from $BACKUP"
    else
        echo "no backup at $BACKUP - nothing to restore" >&2
    fi
    for s in "${SYSTEMS[@]}"; do
        sed -i "/^${s}\.${MARKER}=/d" "$CONF" 2>/dev/null || true
        for k in "${STANDALONE_KEYS[@]}"; do
            sed -i "/^${s}\.flycast\.${k}=/d" "$CONF" 2>/dev/null || true
        done
    done
    save_overlay
}

do_apply() {
    [ -f "$OPTS" ] || { echo "error: $OPTS not found" >&2; exit 1; }
    mkdir -p "$BACKUP_DIR"
    if grep -q "$MARKER" "$OPTS"; then
        echo "already patched: $OPTS"
    else
        [ -f "$BACKUP" ] || cp -a "$OPTS" "$BACKUP"
        local line
        line=$(grep -n "$ANCHOR" "$OPTS" | head -1 | cut -d: -f1)
        [ -n "$line" ] || { echo "error: anchor '$ANCHOR' not found in $OPTS" >&2; exit 1; }
        sed -i "${line}a\\
    ${INSERT}" "$OPTS"
        echo "patched $OPTS at line $line (backup: $BACKUP)"
    fi
    for s in "${SYSTEMS[@]}"; do
        if grep -qE "^${s}\.${MARKER}=" "$CONF" 2>/dev/null; then
            sed -i "s/^${s}\.${MARKER}=.*/${s}.${MARKER}=enabled/" "$CONF"
        else
            printf '%s.%s=enabled\n' "$s" "$MARKER" >> "$CONF"
        fi
    done
    echo "set ${SYSTEMS[*]} .${MARKER}=enabled in batocera.conf"
    for s in "${SYSTEMS[@]}"; do
        for k in "${STANDALONE_KEYS[@]}"; do
            if grep -qE "^${s}\.flycast\.${k}=" "$CONF" 2>/dev/null; then
                sed -i "s/^${s}\.flycast\.${k}=.*/${s}.flycast.${k}=yes/" "$CONF"
            else
                printf '%s.flycast.%s=yes\n' "$s" "$k" >> "$CONF"
            fi
        done
    done
    echo "set the standalone keys (${STANDALONE_KEYS[*]}) for ${SYSTEMS[*]} in batocera.conf"
    save_overlay
}

for arg in "$@"; do
    case "$arg" in
        --check) do_check; exit $? ;;
        --revert) do_revert; exit 0 ;;
        --no-save) SAVE=0 ;;
    esac
done
do_apply
