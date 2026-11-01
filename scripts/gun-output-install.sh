#!/bin/bash
# gun-output-install.sh - install, check or remove the gun-output component.
#
# The component makes gun recoil work for the TeknoParrot-family titles whose image does not
# already start DemulShooter itself. It is opt-in (HOTR_GUN_OUTPUT=1 during install) and fully
# reversible:
#
#   gun-output-install.sh install     # helper + table + DemulShooter + batocera-wine hook
#   gun-output-install.sh --check     # report the state of every piece (exit 1 if incomplete)
#   gun-output-install.sh --revert    # remove the hook and the installed files
#   gun-output-install.sh fetch       # only (re)fetch the DemulShooter binaries
#   gun-output-install.sh --no-fetch install
#
# What it installs:
#   /usr/bin/batocera-wine-gunoutput              the launcher/helper (payload/system)
#   /usr/share/batocera/hotr/gun-output.tsv       the per-title table (payload/hotr)
#   /userdata/system/hotr/demulshooter/           DemulShooter binaries + config.ini
#   /usr/bin/batocera-wine                        the hook (scripts/patch-batocera-wine-gunoutput.sh)
#   /userdata/system/hotr/gun-output.enabled      opt-in marker (like sinden-tcp.enabled)
#
# A user table at /userdata/system/hotr/gun-output.local.tsv overrides the shipped rows and is
# never touched by install or revert.

set -uo pipefail

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

BASE="$(cd "$(dirname "$0")/.." && pwd)"
# GUNOUTPUT_ROOT lets the whole component be exercised inside a fake tree (tests); empty on a
# real machine.
ROOT="${GUNOUTPUT_ROOT:-}"
HOTR="$ROOT/userdata/system/hotr"
HELPER="$ROOT/usr/bin/batocera-wine-gunoutput"
TABLE_SHIPPED="$ROOT/usr/share/batocera/hotr/gun-output.tsv"
TABLE_LOCAL="$HOTR/gun-output.local.tsv"
DS_CACHE="$HOTR/demulshooter"
MARKER="$HOTR/gun-output.enabled"
PATCHER="$BASE/scripts/patch-batocera-wine-gunoutput.sh"
# Native emulators (Flycast today) never run through batocera-wine, so their producer is started
# from configgen's Generator.running() instead - that is what this second patcher installs.
PATCHER_GEN="$BASE/scripts/patch-configgen-gunoutput.sh"
GENERATOR="$ROOT/usr/lib/python3.12/site-packages/configgen/generators/Generator.py"
LAUNCHER="$ROOT/usr/bin/batocera-wine"
READER="$HOTR/tools/flycast-outputs.py"
# The community "RGS" layer ships its own copy of the launcher plus a boot service that copies it
# over /usr/bin/batocera-wine whenever the two differ - so that copy has to be patched as well,
# otherwise the hook disappears at the next reboot.
RGS_LAUNCHER="$ROOT/userdata/system/rgs/fix/batocera-wine"
HOTR_PROFILE_DIR="$ROOT/userdata/system/hook-of-the-reaper/defaultLG"
DS_REPO="argonlefou/DemulShooter"
DS_ASSET_RE='^DemulShooter_v.*\.zip$'
# (the component's own log is written by the helper, not by this installer)

msg() { printf '[gun-output] %s\n' "$*"; }
warn() { printf '[gun-output] WARNING: %s\n' "$*" >&2; }
die() { printf '[gun-output] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"
    return 0
}

# ------------------------------------------------------------------- DemulShooter fetch

fetch_demulshooter() {
    local tmpdir zip
    if [ -f "$DS_CACHE/DemulShooter.exe" ] && [ -f "$DS_CACHE/DemulShooterX64.exe" ]; then
        msg "DemulShooter already present in ${DS_CACHE}"
        write_ds_config
        return 0
    fi
    command -v python3 >/dev/null 2>&1 || { warn "python3 missing - cannot fetch DemulShooter"; return 1; }

    tmpdir="$(mktemp -d)" || { warn "cannot create temp dir"; return 1; }
    zip="${tmpdir}/demulshooter.zip"
    msg "Fetching the latest DemulShooter release from GitHub..."
    if ! python3 - "$DS_REPO" "$DS_ASSET_RE" "$zip" <<'PY'
import json, re, sys, urllib.request

repo, rx, out = sys.argv[1:]
req = urllib.request.Request(
    f"https://api.github.com/repos/{repo}/releases/latest",
    headers={"User-Agent": "HOTR-Batocera43"},
)
with urllib.request.urlopen(req, timeout=30) as r:
    data = json.load(r)
for asset in data.get("assets", []):
    if re.search(rx, asset.get("name", ""), re.I):
        req = urllib.request.Request(
            asset["browser_download_url"], headers={"User-Agent": "HOTR-Batocera43"}
        )
        with urllib.request.urlopen(req, timeout=300) as src, open(out, "wb") as dst:
            while chunk := src.read(1024 * 1024):
                dst.write(chunk)
        print(asset["name"])
        raise SystemExit(0)
raise SystemExit("no release asset matched " + rx)
PY
    then
        warn "DemulShooter download failed (offline?). Titles whose image ships DemulShooter still work."
        rm -rf "$tmpdir"
        return 1
    fi

    command -v unzip >/dev/null 2>&1 || { warn "unzip missing"; rm -rf "$tmpdir"; return 1; }
    if ! unzip -q -o "$zip" -d "$tmpdir/extract"; then
        warn "DemulShooter archive did not extract"
        rm -rf "$tmpdir"
        return 1
    fi
    if [ ! -f "$tmpdir/extract/DemulShooterX64.exe" ] && [ ! -f "$tmpdir/extract/DemulShooter.exe" ]; then
        warn "DemulShooter archive layout not recognised"
        rm -rf "$tmpdir"
        return 1
    fi
    mkdir -p "$DS_CACHE"
    cp -a "$tmpdir/extract/." "$DS_CACHE/"
    rm -rf "$tmpdir"
    msg "DemulShooter installed into ${DS_CACHE}"
    write_ds_config
    return 0
}

# DemulShooter's config parser is flat (DsCore/Config/Configurator.cs: "key = value" lines, no
# sections). Network output is what HOTR consumes; the window-messages route must be off or it
# shadows the network one.
write_ds_config() {
    local cfg="$DS_CACHE/config.ini"
    [ -d "$DS_CACHE" ] || return 0
    {
        printf '; DemulShooter configuration written by the HOTR gun-output component\n'
        printf 'TcpInputPort = 33610\n'
        printf 'OutputEnabled = True\n'
        printf 'WM_OutputsEnabled = False\n'
        printf 'Net_OutputsEnabled = True\n'
    } >"$cfg" || { warn "cannot write ${cfg}"; return 1; }
    msg "DemulShooter network output enabled in ${cfg}"
    return 0
}

# ------------------------------------------------------------------------- install / revert

do_install() {
    local fetch=1
    [ "${1:-}" = "--no-fetch" ] && fetch=0

    [ -w "$ROOT/userdata" ] || die "$ROOT/userdata is not writable."
    [ -f "$BASE/payload/system/batocera-wine-gunoutput" ] || die "payload helper missing from the release"
    [ -f "$BASE/payload/hotr/gun-output.tsv" ] || die "payload table missing from the release"
    [ -x "$PATCHER" ] || die "patcher missing: ${PATCHER}"
    [ -x "$PATCHER_GEN" ] || die "configgen patcher missing: ${PATCHER_GEN}"

    mkdir -p "$HOTR" "$ROOT/usr/share/batocera/hotr" "$ROOT/usr/bin"
    install -m 0755 "$BASE/payload/system/batocera-wine-gunoutput" "$HELPER" || die "cannot install ${HELPER}"
    msg "helper installed: ${HELPER}"

    # Keep a copy of this installer on the machine so support can re-run --check/--revert
    # after the release directory is gone.
    mkdir -p "$HOTR/tools"
    if [ "$0" != "$HOTR/tools/gun-output-install.sh" ]; then
        install -m 0755 "$0" "$HOTR/tools/gun-output-install.sh" \
            && msg "installer copied to ${HOTR}/tools/gun-output-install.sh" \
            || warn "cannot copy the installer to ${HOTR}/tools"
    fi

    if [ -f "$TABLE_SHIPPED" ] && ! cmp -s "$TABLE_SHIPPED" "$BASE/payload/hotr/gun-output.tsv"; then
        cp -a "$TABLE_SHIPPED" "${TABLE_SHIPPED}.bak" 2>/dev/null && msg "kept previous table as ${TABLE_SHIPPED}.bak"
    fi
    install -m 0644 "$BASE/payload/hotr/gun-output.tsv" "$TABLE_SHIPPED" || die "cannot install ${TABLE_SHIPPED}"
    rows="$(grep -cvE '^#|^$' "$TABLE_SHIPPED" 2>/dev/null)"
    msg "table installed: ${TABLE_SHIPPED} (${rows:-0} rows)"
    [ -f "$TABLE_LOCAL" ] && msg "user override present: ${TABLE_LOCAL}"

    # Profiles: install the files HOTR does not have yet.  A profile the user tuned (or
    # one HOTR already ships) is never overwritten - the corpus belongs to HOTR, and this
    # component only fills the gaps it knows about (the generic fallback, the wiki
    # profiles whose announced id has no file, and the recoil-bearing variants).
    if [ -d "$BASE/payload/hotr/defaultLG" ]; then
        mkdir -p "$HOTR_PROFILE_DIR"
        added=0
        for f in "$BASE/payload/hotr/defaultLG"/*.txt; do
            [ -e "$f" ] || continue
            name="$(basename "$f")"
            if [ ! -e "$HOTR_PROFILE_DIR/$name" ]; then
                install -m 0644 "$f" "$HOTR_PROFILE_DIR/$name" && added=$((added + 1))
            fi
        done
        msg "profiles installed: ${added} new (existing files kept)"
    fi

    if [ "$fetch" = "1" ]; then
        fetch_demulshooter || true
    else
        write_ds_config
    fi

    msg "patching the launcher hook..."
    if [ -n "$ROOT" ]; then
        "$PATCHER" --no-save --file "$LAUNCHER" || die "launcher patch failed"
    else
        "$PATCHER" --no-save || die "batocera-wine patch failed"
    fi
    if [ -f "$RGS_LAUNCHER" ] && [ ! "$RGS_LAUNCHER" = "$LAUNCHER" ]; then
        if cmp -s "$LAUNCHER" "$RGS_LAUNCHER"; then
            msg "RGS launcher copy already matches the patched launcher"
        else
            msg "RGS layer detected: patching its launcher copy too (it overwrites /usr/bin/batocera-wine at boot)"
            "$PATCHER" --no-save --file "$RGS_LAUNCHER" || warn "could not patch the RGS launcher copy"
        fi
    fi
    # The native producer (the Flycast reader) is started by the configgen hook below.
    if [ -f "$BASE/payload/hotr/tools/flycast-outputs.py" ]; then
        mkdir -p "$HOTR/tools"
        install -m 0755 "$BASE/payload/hotr/tools/flycast-outputs.py" "$READER" \
            && msg "flycast reader installed: ${READER}" \
            || warn "cannot install the flycast reader"
    fi
    if [ -x "$READER" ] && [ -x "$BASE/scripts/patch-libretro-flycast-network-output.sh" ]; then
        # The reader publishes the same values with semantics (ammo/life/damage/credits/recoil),
        # so Flycast's own raw-lamp broadcast is switched off to free port 8000 for the reader.
        if [ -n "$ROOT" ]; then
            ROOT="$ROOT" "$BASE/scripts/patch-libretro-flycast-network-output.sh" --revert --no-save >/dev/null 2>&1 \
                && msg "Flycast's own network output disabled (the reader publishes instead)" \
                || warn "could not disable Flycast's own network output"
        else
            "$BASE/scripts/patch-libretro-flycast-network-output.sh" --revert --no-save >/dev/null 2>&1 \
                && msg "Flycast's own network output disabled (the reader publishes instead)" \
                || warn "could not disable Flycast's own network output"
        fi
    fi
    if [ -f "$GENERATOR" ]; then
        msg "patching the configgen hook..."
        if [ -n "$ROOT" ]; then
            "$PATCHER_GEN" --no-save --file "$GENERATOR" || die "configgen patch failed"
        else
            "$PATCHER_GEN" --no-save || die "configgen patch failed"
        fi
    else
        warn "configgen Generator.py not found (${GENERATOR}) - native emulators will not get a producer"
    fi

    touch "$MARKER"
    msg "opt-in marker: ${MARKER}"

    if [ -z "$ROOT" ] && command -v batocera-save-overlay >/dev/null 2>&1; then
        msg "Saving Batocera overlay..."
        batocera-save-overlay >/dev/null 2>&1 && msg "overlay saved" || warn "batocera-save-overlay failed"
    elif [ -z "$ROOT" ]; then
        warn "batocera-save-overlay not found - changes will not survive a reboot"
    fi
    return 0
}

do_revert() {
    if [ -x "$PATCHER" ]; then
        if [ -n "$ROOT" ]; then
            "$PATCHER" --revert --no-save --file "$LAUNCHER" || warn "patching revert reported a problem"
        else
            "$PATCHER" --revert --no-save || warn "patching revert reported a problem"
        fi
        if [ -f "$RGS_LAUNCHER" ]; then
            "$PATCHER" --revert --no-save --file "$RGS_LAUNCHER" >/dev/null 2>&1 \
                || warn "could not revert the RGS launcher copy"
        fi
    fi
    if [ -x "$PATCHER_GEN" ]; then
        if [ -n "$ROOT" ]; then
            "$PATCHER_GEN" --revert --no-save --file "$GENERATOR" >/dev/null 2>&1 \
                || warn "could not revert the configgen hook"
        else
            "$PATCHER_GEN" --revert --no-save >/dev/null 2>&1 || warn "could not revert the configgen hook"
        fi
    fi
    rm -f "$READER" && msg "removed ${READER}"
    rm -f "$HELPER" && msg "removed ${HELPER}"
    rm -f "$TABLE_SHIPPED" && msg "removed ${TABLE_SHIPPED}"
    [ -f "${TABLE_SHIPPED}.bak" ] && { mv "${TABLE_SHIPPED}.bak" "$TABLE_SHIPPED" && msg "restored the previous table"; }
    rm -f "$MARKER"
    msg "DemulShooter binaries left in ${DS_CACHE} (delete manually if you want them gone)"
    if [ -z "$ROOT" ] && command -v batocera-save-overlay >/dev/null 2>&1; then
        batocera-save-overlay >/dev/null 2>&1 && msg "overlay saved" || warn "batocera-save-overlay failed"
    fi
    return 0
}

# ------------------------------------------------------------------------------- check

FAILED=0
ok()   { printf 'PASS  %s\n' "$*"; return 0; }
bad()  { printf 'FAIL  %s\n' "$*"; FAILED=$((FAILED + 1)); return 0; }
skip() { printf 'SKIP  %s\n' "$*"; return 0; }

do_check() {
    local rows blocks

    if [ -x "$HELPER" ]; then ok "helper installed: ${HELPER}"; else bad "helper missing: ${HELPER}"; fi

    if [ -f "$TABLE_SHIPPED" ]; then
        rows="$(grep -cvE '^#|^$' "$TABLE_SHIPPED" 2>/dev/null)"
        if [ "${rows:-0}" -gt 0 ]; then ok "table installed: ${TABLE_SHIPPED} (${rows} rows)"; else bad "table has no rows: ${TABLE_SHIPPED}"; fi
    else
        bad "table missing: ${TABLE_SHIPPED}"
    fi
    [ -f "$TABLE_LOCAL" ] && ok "user override present: ${TABLE_LOCAL}" || skip "no user override (${TABLE_LOCAL})"

    if [ -f "$DS_CACHE/DemulShooterX64.exe" ] || [ -f "$DS_CACHE/DemulShooter.exe" ]; then
        ok "DemulShooter binaries in ${DS_CACHE}"
        if [ -f "$DS_CACHE/config.ini" ] && grep -qE '^[[:space:]]*OutputEnabled[[:space:]]*=[[:space:]]*True' "$DS_CACHE/config.ini" \
           && grep -qE '^[[:space:]]*Net_OutputsEnabled[[:space:]]*=[[:space:]]*True' "$DS_CACHE/config.ini"; then
            ok "DemulShooter config.ini: network output enabled"
        else
            bad "DemulShooter config.ini missing or not network-enabled (${DS_CACHE}/config.ini)"
        fi
    else
        bad "DemulShooter binaries missing (${DS_CACHE}) - run: $0 fetch"
    fi

    blocks="$(grep -cF '# >>> HOTR-GUNOUTPUT-HOOK v1 >>>' "$LAUNCHER" 2>/dev/null)"
    if [ "${blocks:-0}" -ge 6 ]; then
        ok "launcher patched (${blocks} hook blocks)"
    else
        bad "launcher not patched (${blocks:-0}/6 hook blocks)"
    fi
    if [ -f "$RGS_LAUNCHER" ]; then
        rgs_blocks="$(grep -cF '# >>> HOTR-GUNOUTPUT-HOOK v1 >>>' "$RGS_LAUNCHER" 2>/dev/null)"
        if [ "${rgs_blocks:-0}" -ge 6 ]; then
            ok "RGS launcher copy patched (the hook survives a reboot)"
        else
            bad "RGS launcher copy not patched - the hook would be lost at the next reboot"
        fi
    fi
    if [ -f "$GENERATOR" ]; then
        if grep -qF '# >>> HOTR-GUNOUTPUT-HOOK v1 >>>' "$GENERATOR" 2>/dev/null; then
            ok "configgen hook present (native emulators can start a producer)"
        else
            bad "configgen hook missing from ${GENERATOR} (native emulators get no producer)"
        fi
    else
        skip "configgen Generator.py not found (${GENERATOR})"
    fi
    [ -x "$READER" ] && ok "flycast reader installed: ${READER}" || skip "no flycast reader (only needed for Flycast)"
    [ -f "$HOTR/backups/batocera-wine.orig" ] && ok "batocera-wine backup present" || skip "no batocera-wine backup yet"
    [ -f "$MARKER" ] && ok "opt-in marker present: ${MARKER}" || bad "opt-in marker missing: ${MARKER}"

    if [ -f "$HOTR_PROFILE_DIR/default.txt" ]; then
        ok "HOTR generic profile installed (${HOTR_PROFILE_DIR}/default.txt)"
    else
        bad "HOTR generic profile missing (${HOTR_PROFILE_DIR}/default.txt)"
    fi
    if [ -d "$BASE/payload/hotr/defaultLG" ]; then
        missing_profiles=0
        for f in "$BASE/payload/hotr/defaultLG"/*.txt; do
            [ -e "$f" ] || continue
            [ -e "$HOTR_PROFILE_DIR/$(basename "$f")" ] || missing_profiles=$((missing_profiles + 1))
        done
        if [ "$missing_profiles" -eq 0 ]; then
            ok "shipped profiles present in ${HOTR_PROFILE_DIR}"
        else
            bad "${missing_profiles} shipped profile(s) missing from ${HOTR_PROFILE_DIR} (re-run install)"
        fi
    fi
    if [ -d "$HOTR_PROFILE_DIR" ]; then
        ok "HOTR profile dir: $(ls -1 "$HOTR_PROFILE_DIR" 2>/dev/null | wc -l) files"
    else
        bad "HOTR profile dir missing: ${HOTR_PROFILE_DIR}"
    fi

    if [ -x "$HELPER" ]; then
        printf 'INFO  live producers:\n'
        "$HELPER" status 2>/dev/null | sed 's/^/      /'
    fi

    if [ "$FAILED" -eq 0 ]; then
        printf 'RESULT: gun-output component complete\n'
        return 0
    fi
    printf 'RESULT: %d problem(s) - see FAIL lines above\n' "$FAILED"
    return 1
}

# -------------------------------------------------------------------------------- main

case "${1:-}" in
    install)
        shift
        do_install "${1:-}"
        ;;
    fetch)
        fetch_demulshooter
        ;;
    --check|check)
        do_check
        ;;
    --revert|revert)
        do_revert
        ;;
    ""|-h|--help|help)
        usage
        ;;
    *)
        die "unknown argument '$1' (try --help)"
        ;;
esac
exit $?
