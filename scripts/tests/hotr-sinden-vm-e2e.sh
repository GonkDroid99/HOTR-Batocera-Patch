#!/usr/bin/env bash
# HOTR Sinden recoil — normal-usage acceptance run (PLAN.md section C).
#
# This is the "smooth experience" test: the real Batocera stack with the gun's
# serial port pointed at the lab fake gun, exercised the way a user does it.
# It runs ON a Batocera install as root, and can also drive one over SSH:
#
#   scripts/tests/hotr-sinden-vm-e2e.sh --dry-run
#   scripts/tests/hotr-sinden-vm-e2e.sh                 # on the Batocera box
#   scripts/tests/hotr-sinden-vm-e2e.sh --ssh root@batocera.local
#
# What it does per step (each step prints PASS/FAIL/SKIP/INFO):
#   1. pre-flight   root, install present, tools present, recoil enabled
#   2. report       hotr-sinden-check (read-only) into the bundle
#   3. fake gun     no real gun? attach the firmware-faithful fake gun as the
#                   player's serial port through sinden-devices.conf
#   4. game launch  you launch HOTD2 from EmulationStation and fire; the runner
#                   asserts the chain HOTR -> broker -> gun and that the real
#                   LightgunMono survived the session
#   5. exit/relaunch  mute on exit, frames again on relaunch, no restarts
#   6. menu         opening the HOTR UI / moving around ES must change nothing
#   7. painful      kill the broker, upgrade over a patched helper, uninstall
#   8. bundle       hotr-sinden-check + hotr-debug-report.sh + frame log
#
# Everything it changes is restored on exit; the fake gun only exists while the
# run is active. Nothing here is destructive unless you pass --allow-uninstall.
set -u

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAKE_GUN="$REPO_ROOT/scripts/tests/fake-gun-firmware-faithful.py"
# ssh mode: the repository is not on the machine, only this script and the fake gun are.
[ -f "$FAKE_GUN" ] || FAKE_GUN="$(dirname "$SELF")/fake-gun-firmware-faithful.py"

HOTR="/userdata/system/hotr"
HOTR_DATA="/userdata/system/hook-of-the-reaper/data"
SINDEN_CMD_FILE="$HOTR_DATA/sinden.hor"
HOTR_LOG="/userdata/system/logs/hook-of-the-reaper.log"
# Game profiles live next to, not inside, the data directory on an installed system.
PROFILE_DIR="/userdata/system/hook-of-the-reaper/defaultLG"
SINDEN_DEVICES="$HOTR/sinden-devices.conf"
SINDEN_ENABLE="$HOTR/sinden-tcp.enabled"
SINDEN_PID="/var/run/hotr-sinden-broker.pid"
STATE_FILE="$HOTR/sinden-broker-state.json"
BROKER_LOG="/userdata/system/logs/hotr-sinden-broker.log"
SERVICE="/userdata/system/services/hotr"

# Commands the firmware itself treats as silent; anything else must never be
# emitted by HOTR (A0/A7/AB/AC answer on the wire and are refused by design).
WHITELIST="a1 a2 a3 a4 a8"
REPLY_PRODUCING="a0 a7 ab ac"

OUT=""
SSH_TARGET=""
ASSUME_YES=0
DRY_RUN=0
SELF_TEST=0
LOCAL=0
ALLOW_UNINSTALL=0
GAME="${HOTR_SINDEN_VM_GAME:-HOTD2 (MAME)}"
# The id HOTR logs as GameStart game= "...": it names the defaultLG profile that
# decides whether the game's GunRecoil_PN signal is registered at all.
GAME_ID="${HOTR_SINDEN_VM_GAME_ID:-SLUS-20219}"
LAB_PROFILE="$PROFILE_DIR/$GAME_ID.txt"
PROFILE_BACKUP=""
WAIT_SECONDS="${HOTR_SINDEN_VM_WAIT:-90}"
# Unattended runs: a command that launches the game, one that leaves it, and an
# optional command that starts a real LightgunMono against the lab gun.
LAUNCH_CMD="${HOTR_SINDEN_VM_LAUNCH:-}"
EXIT_CMD="${HOTR_SINDEN_VM_EXIT:-}"
MONO_CMD="${HOTR_SINDEN_VM_MONO:-}"
# Unattended recoil stimulus: normally the game tells the emulator bridge when the
# player fires (GunRecoil_PN), and the bridge forwards it on its control pipe.
FIRE_CMD="${HOTR_SINDEN_VM_FIRE:-}"
MAMEOUT_PIPE="${HOTR_SINDEN_VM_PIPE:-/tmp/CoreFxPipe_MameHookerProxyControl}"
LAB_MONO="${HOTR_SINDEN_LAB_MONO:-/userdata/system/hotr/tools/hotr-sinden-lab-mono.sh}"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
INFO_COUNT=0
FAKE_GUN_PID=""
LAB_MONO_STARTED=0
# 1 once a real LightgunMono has actually been seen running in this session
LAB_MONO_ALIVE=0
FAKE_GUN_DEVICE=""
DEVICES_BACKUP=""
BROKER_WAS_RUNNING=0
RESTORE_DEVICES=0
RESTORE_PROFILE=0
MONO_PID_BEFORE=""
# 1 when the lab fake gun is mandatory: the attach step fails instead of
# skipping, so a CI run cannot quietly pass without exercising the gun path.
FAKE_GUN_REQUIRED=0

log() { printf '%s\n' "$*" | tee -a "$RUN_LOG" 2>/dev/null || printf '%s\n' "$*"; }

record() { # record LEVEL name message...
  local level="$1" name="$2"; shift 2
  case "$level" in
    PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    SKIP) SKIP_COUNT=$((SKIP_COUNT + 1)) ;;
    *)    INFO_COUNT=$((INFO_COUNT + 1)) ;;
  esac
  log "[$level] $name: $*"
}

prompt() { # prompt step instruction
  if [ "$ASSUME_YES" = 1 ]; then
    log "[INFO] $1 (--yes: continuing)"
    return 0
  fi
  printf '\n=== %s\n' "$1" >&2
  printf '    press Enter when done, or type "skip" to skip this step: ' >&2
  local answer=""
  read -r answer || answer="skip"
  case "$answer" in skip|SKIP|s) return 1 ;; *) return 0 ;; esac
}

on_exit() {
  if [ "$LAB_MONO_STARTED" = 1 ]; then
    if [ -x "$LAB_MONO" ]; then
      "$LAB_MONO" stop >/dev/null 2>&1 || true
    else
      pkill -f 'LightgunMono-labp1\.exe' 2>/dev/null || true
    fi
  fi
  if [ -n "$FAKE_GUN_PID" ]; then
    kill -TERM "$FAKE_GUN_PID" 2>/dev/null || true
  fi
  if [ "$RESTORE_DEVICES" = 1 ]; then
    if [ -f "$DEVICES_BACKUP" ]; then
      cp -f "$DEVICES_BACKUP" "$SINDEN_DEVICES" 2>/dev/null || true
    else
      rm -f "$SINDEN_DEVICES" 2>/dev/null || true
    fi
    if [ "$BROKER_WAS_RUNNING" = 1 ]; then
      "$SERVICE" start >/dev/null 2>&1 || true
    fi
  fi
  if [ "$RESTORE_PROFILE" = 1 ]; then
    if [ -f "$PROFILE_BACKUP" ]; then
      cp -f "$PROFILE_BACKUP" "$LAB_PROFILE" 2>/dev/null || true
    else
      rm -f "$LAB_PROFILE" 2>/dev/null || true
    fi
  fi
  if [ "$FAIL_COUNT" = 0 ] && [ "$PASS_COUNT" -gt 0 ]; then
    log ""
    log "RESULT: PASS ($PASS_COUNT passed, $SKIP_COUNT skipped, $INFO_COUNT informational)"
  else
    log ""
    log "RESULT: $FAIL_COUNT step(s) FAILED ($PASS_COUNT passed, $SKIP_COUNT skipped, $INFO_COUNT informational)"
  fi
  log "Evidence bundle: $OUT"
}

# --- helpers ---------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage: hotr-sinden-vm-e2e.sh [--ssh USER@HOST] [--out DIR] [--yes] [--dry-run]
                             [--allow-uninstall] [--fake-gun-required] [--self-test]

  --ssh USER@HOST     push to and drive a Batocera VM over SSH (passwordless)
  --out DIR           evidence bundle directory (default ./hotr-sinden-vm-DATE)
  --yes               do not wait for Enter between steps (unattended)
  --dry-run           print every step that would run, change nothing
  --allow-uninstall   include the destructive uninstall check (stock behaviour)
  --fake-gun-required fail instead of skipping when the lab fake gun cannot be
                      attached (CI/lab runs that must exercise the gun path)
  --local             run against the current machine instead of pushing over SSH
  --game NAME         HOTR game profile to launch (default "$GAME")
  --self-test         exercise the runner's own parsers against fixtures

Environment:
  HOTR_SINDEN_VM_GAME   game to launch (default HOTD2 (MAME))
  HOTR_SINDEN_VM_WAIT   seconds to wait for frames (default 90)
  HOTR_SINDEN_VM_LAUNCH shell command that launches the game; when set, the
                        launch steps run unattended instead of prompting
  HOTR_SINDEN_VM_EXIT   shell command that leaves the running game
  HOTR_SINDEN_VM_MONO   shell command that starts a real LightgunMono against
                        the lab gun; without it the runner uses
                        /userdata/system/hotr/tools/hotr-sinden-lab-mono.sh when
                        that helper is installed
  HOTR_SINDEN_VM_FIRE   shell command that asks the game side for recoil; without
                        it the runner writes 'GunRecoil_P1/P2: 1' into
                        HOTR_SINDEN_VM_PIPE (default /tmp/CoreFxPipe_MameHookerProxyControl),
                        which is how the emulator output bridge reports a shot

Options --launch/--exit/--mono/--fire take the same commands and are forwarded to
the remote run, so an unattended VM walk needs no interactive menu driving.
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --ssh) SSH_TARGET="${2:-}"; shift 2 || exit 2 ;;
      --out) OUT="${2:-}"; shift 2 || exit 2 ;;
      --yes) ASSUME_YES=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --allow-uninstall) ALLOW_UNINSTALL=1; shift ;;
      --fake-gun-required) FAKE_GUN_REQUIRED=1; shift ;;
      --self-test) SELF_TEST=1; shift ;;
      --local) LOCAL=1; shift ;;
      --game) GAME="${2:-}"; shift 2 || exit 2 ;;
      --launch) LAUNCH_CMD="${2:-}"; shift 2 || exit 2 ;;
      --exit) EXIT_CMD="${2:-}"; shift 2 || exit 2 ;;
      --mono) MONO_CMD="${2:-}"; shift 2 || exit 2 ;;
      --fire) FIRE_CMD="${2:-}"; shift 2 || exit 2 ;;
      -h|--help) usage; exit 0 ;;
      *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
  done
}

frame_commands() { # frame_commands <report.json> -> one command byte per line
  python3 - "$1" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        report = json.load(handle)
except (OSError, ValueError) as exc:
    print(f"cannot read {sys.argv[1]}: {exc}", file=sys.stderr)
    raise SystemExit(2)
frames = report.get("frame_log") or []
for frame in frames:
    parts = str(frame).split()
    if len(parts) >= 2:
        print(parts[1].lower())
PY
}

state_field() { # state_field <player> <field>
  python3 - "$STATE_FILE" "$1" "$2" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        state = json.load(handle)
except (OSError, ValueError):
    print("")
    raise SystemExit(0)
player = (state.get("players") or {}).get(sys.argv[2]) or {}
value = player.get(sys.argv[3])
print("" if value is None else value)
PY
}

broker_pid() {
  [ -r "$SINDEN_PID" ] || return 1
  local pid
  pid="$(cat "$SINDEN_PID" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && { printf '%s' "$pid"; return 0; }
  return 1
}

mono_pid() {
  pgrep -f 'LightgunMono.*\.exe' 2>/dev/null | head -1
}

wait_for_state_change() { # wait_for_state_change <player> <field> <old> <seconds>
  local player="$1" field="$2" old="$3" deadline=$(( $(date +%s) + $4 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local now
    now="$(state_field "$player" "$field")"
    [ -n "$now" ] && [ "$now" != "$old" ] && { printf '%s' "$now"; return 0; }
    sleep 0.5
  done
  return 1
}

# --- checks ----------------------------------------------------------------

check_whitelist() { # check_whitelist <name> <frame-command-file> <require-a8>
  local name="$1" commands="$2" require_a8="$3"
  if [ ! -s "$commands" ]; then
    record FAIL "$name" "no frames reached the gun: HOTR never asked for recoil"
    return 1
  fi
  local bad reply missing
  bad="$(grep -v -E "^($(printf '%s' "$WHITELIST" | tr ' ' '|'))$" "$commands" | sort -u | tr '\n' ' ' || true)"
  reply="$(grep -E "^($(printf '%s' "$REPLY_PRODUCING" | tr ' ' '|'))$" "$commands" | sort -u | tr '\n' ' ' || true)"
  missing=""
  if [ "$require_a8" = 1 ] && ! grep -qx a8 "$commands"; then
    missing="no A8 frame"
  fi
  if [ -n "$bad" ] || [ -n "$reply" ] || [ -n "$missing" ]; then
    record FAIL "$name" "commands seen: $(sort -u "$commands" | tr '\n' ' ')${reply:+ (reply-producing: $reply)}${bad:+ (not whitelisted: $bad)}${missing:+ ($missing)}"
    return 1
  fi
  local total
  total="$(wc -l <"$commands" | tr -d ' ')"
  record PASS "$name" "$total frame(s), all whitelisted, no reply-producing command"
  return 0
}

check_handshake() { # check_handshake <name> <fake gun report>
  local name="$1" report="$2"
  python3 - "$report" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        data = json.load(handle)
except (OSError, ValueError) as exc:
    print(f"FAIL cannot read {sys.argv[1]}: {exc}")
    raise SystemExit(1)
errors = data.get("errors") or []
handshake = data.get("handshake") or {}
if errors:
    print("FAIL " + "; ".join(str(item) for item in errors[:3]))
elif data.get("sent_unsolicited"):
    print("FAIL the fake gun had to answer bytes HOTR never asked for")
elif not handshake.get("true_sent"):
    print("INFO LightgunMono has not completed the handshake yet (no game run?)")
else:
    print("PASS handshake completed, no resync errors, no unsolicited gun traffic")
PY
}

report_check_handshake() { # report_check_handshake <name> <report>
  local name="$1" result
  result="$(check_handshake "$name" "$2" || true)"
  while IFS= read -r line; do
    case "$line" in
      PASS*) record PASS "$name" "${line#PASS }" ;;
      FAIL*) record FAIL "$name" "${line#FAIL }" ;;
      '')    ;;
      *)     record INFO "$name" "${line#INFO }" ;;
    esac
  done <<<"$result"
}

check_mono_alive() { # check_mono_alive <name> <pid-before>
  local name="$1" before="$2" pid
  pid="$(mono_pid)"
  if [ -z "$pid" ]; then
    if [ -n "$before" ] || [ "$LAB_MONO_ALIVE" = 1 ]; then
      record FAIL "$name" "LightgunMono is not running any more"
      return 1
    fi
    # No Sinden USB device (a VM, for example): LightgunMono cannot run at all, so
    # this assertion is unverifiable here. The real-gun run still has to prove it.
    record SKIP "$name" "no LightgunMono can run in this environment (no Sinden device); the real-gun run covers this assertion"
    return 0
  fi
  local bad_log
  bad_log="$(grep -rl 'Cannot communicate with lightgun' /var/run/sinden 2>/dev/null | head -3 || true)"
  if [ -n "$bad_log" ]; then
    record FAIL "$name" "LightgunMono logged 'Cannot communicate with lightgun' in $bad_log"
    return 1
  fi
  if [ -n "$before" ] && [ "$before" != "$pid" ]; then
    record INFO "$name" "LightgunMono was restarted during the run (PID $before -> $pid)"
    return 0
  fi
  record PASS "$name" "LightgunMono is alive (PID $pid) with no handshake failure in /var/run/sinden"
  return 0
}

# --- steps -----------------------------------------------------------------

step_preflight() {
  local name="pre-flight"
  if [ "$(id -u)" != 0 ]; then
    record FAIL "$name" "run this as root on the Batocera box (or pass --dry-run)"
    return 1
  fi
  if [ ! -x "$SERVICE" ]; then
    record FAIL "$name" "$SERVICE does not exist: this is not a HOTR install"
    return 1
  fi
  if [ ! -x /usr/bin/hotr-sinden-check ] && [ ! -x "$HOTR/bin/hotr-sinden-check" ]; then
    record FAIL "$name" "hotr-sinden-check is not installed; run install.sh first"
    return 1
  fi
  local batocera_version="unknown"
  [ -r /etc/os-release ] && batocera_version="$(grep -m1 '^PRETTY_NAME=' /etc/os-release | cut -d= -f2- | tr -d '"')"
  record PASS "$name" "root on $batocera_version with a HOTR install at $HOTR"
  if [ -f "$SINDEN_ENABLE" ]; then
    record PASS "recoil enabled" "$SINDEN_ENABLE exists"
  else
    record SKIP "recoil enabled" "Sinden recoil is off; enable it (HOTR_SINDEN_TCP=1 install.sh) and rerun"
    return 1
  fi
  step_command_vocabulary || return 1
  return 0
}

step_command_vocabulary() {
  local name="Sinden command file" recoil=""
  if ! grep -qsiE '^Sinden[[:space:]]*$' "$HOTR_DATA/lightguns.hor" 2>/dev/null; then
    record SKIP "$name" "no Sinden gun is configured in $HOTR_DATA/lightguns.hor"
    return 0
  fi
  [ -r "$SINDEN_CMD_FILE" ] && recoil="$(sed -n 's/^Recoil=//p' "$SINDEN_CMD_FILE" | head -1)"
  if [ -n "$recoil" ]; then
    record PASS "$name" "$(basename "$SINDEN_CMD_FILE") asks for recoil with '$recoil'"
    return 0
  fi
  record FAIL "$name" "$(basename "$SINDEN_CMD_FILE") has no Recoil command, so HOTR can never ask a Sinden gun for recoil; reinstall with a payload that ships the Sinden command vocabulary"
  return 1
}

write_lab_recoil_profile() {
  # HOTR chooses the game's recoil mode by matching the profile's supported modes
  # against the *gun's* recoil priority list (lightguns.hor). A gun that prefers
  # Ammo_Value never registers the game's GunRecoil_PN signal, so no recoil frame
  # can arrive however loud the game shouts. Pin the recoil mode for this run so the
  # A8 path is exercised deterministically; the operator's profile goes back on exit.
  cat >"$LAB_PROFILE" <<'EOF'
Players
1
P1
Recoil & Reload
Ammo_Value 0
Recoil 1
Recoil_R2S 0
Recoil_Value 0
[States]
:mame_start
*All
>Open_COM_NoInit
>Open_COM
:mame_stop
*All
>Close_COM
[Signals]
:GunRecoil_P1
*P1
#Recoil
EOF
}

write_lab_ammo_profile() {
  # The ammo path: this profile lets HOTR pick the ammo mode (as it does on a gun
  # whose recoil priority list prefers Ammo_Value), so HOTR registers the game's
  # P1_Ammo signal instead of GunRecoil_P1. Recoil then comes from the gun's own
  # firmware trigger recoil, which needs Sinden_Trigger_Recoil; without that option
  # LightGun::AmmoValueSinden() sends nothing at all on a reload.
  cat >"$LAB_PROFILE" <<'EOF'
Players
1
P1
Recoil & Reload
Ammo_Value 1 Reload_Value
Recoil 1 Reload_Value
Recoil_R2S 0
Recoil_Value 0
[Options]
Sinden_Trigger_Recoil 2
End Options
[States]
:mame_start
*All
>Open_COM_NoInit
>Open_COM
:mame_stop
*All
>Close_COM
[Signals]
:GunRecoil_P1
*P1
#Recoil
:P1_Ammo
*P1
#Ammo_Value
EOF
}

step_lab_profile() {
  local name="lab game profile"
  if [ ! -d "$PROFILE_DIR" ]; then
    record SKIP "$name" "no $PROFILE_DIR on this machine"
    return 1
  fi
  if [ -f "$LAB_PROFILE" ]; then
    cp -f "$LAB_PROFILE" "$OUT/$GAME_ID.txt.backup"
    PROFILE_BACKUP="$OUT/$GAME_ID.txt.backup"
  fi
  write_lab_recoil_profile
  RESTORE_PROFILE=1
  record PASS "$name" "wrote a recoil-mode profile for $GAME_ID (the machine's own file is put back on exit)"
}

wait_for_a8() { # wait_for_a8 <frames file> <seconds>: give the recoil frame time to arrive
  # NB: keep these two statements apart. `local a="$1" b=$(( … + a ))` is an unbound-variable
  # error under `set -u` because local declares every name (unset) before it runs any assignment.
  local file="$1"
  local seconds="$2"
  local deadline=$(( $(date +%s) + seconds ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    grep -qx a8 "$file" 2>/dev/null && return 0
    sleep 0.5
    frame_commands "$OUT/fake-gun.json" >"$file" 2>/dev/null || true
  done
  return 1
}

last_signal_filter() { # last_signal_filter [from_line]: newest "Output signal filter" line at or after from_line, or nothing
  [ -f "$HOTR_LOG" ] || return 1
  local from="${1:-0}"
  tail -n "+$((from + 1))" "$HOTR_LOG" 2>/dev/null | grep 'Output signal filter' 2>/dev/null | tail -1
}

check_signal_filter() { # check_signal_filter <name>: did HOTR register the game's recoil signal?
  local name="$1" line
  if [ ! -f "$HOTR_LOG" ]; then
    record INFO "$name (signals)" "no $HOTR_LOG to read"
    return 0
  fi
  line="$(last_signal_filter || true)"
  case "$line" in
    *GunRecoil_P1*)
      record PASS "$name (signals)" "HOTR registered the game's recoil signal: ${line#*Output signal filter: }"
      ;;
    "")
      record INFO "$name (signals)" "HOTR has not logged a signal filter yet"
      ;;
    *)
      record FAIL "$name (signals)" "HOTR registered ${line#*Output signal filter: } instead of GunRecoil_P1, so no recoil frame can reach the gun: this gun's recoil priority or the game profile selects another recoil mode"
      return 1
      ;;
  esac
  return 0
}

step_report() {
  local name="read-only report" tool=hotr-sinden-check
  command -v "$tool" >/dev/null 2>&1 || tool="$HOTR/bin/hotr-sinden-check"
  "$tool" --json >"$OUT/check-before.json" 2>"$OUT/check-before.err"
  python3 - "$OUT/check-before.json" >"$OUT/check-before.txt" <<'PY' || true
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        report = json.load(handle)
except (OSError, ValueError):
    raise SystemExit(0)
for item in report.get("checks", []):
    print(f"{item['level']:4} {item['message']}")
print(f"verdict: {'FAIL' if any(i['level'] == 'FAIL' for i in report.get('checks', [])) else 'OK'}")
PY
  if grep -q '^FAIL' "$OUT/check-before.txt"; then
    record FAIL "$name" "hotr-sinden-check found failures before the game run; see $OUT/check-before.txt"
    return 1
  fi
  record PASS "$name" "hotr-sinden-check ran clean; output in check-before.txt"
  return 0
}

step_attach_fake_gun() {
  local name="fake gun"
  if [ -f "$SINDEN_DEVICES" ]; then
    DEVICES_BACKUP="$OUT/sinden-devices.conf.backup"
    cp -f "$SINDEN_DEVICES" "$DEVICES_BACKUP"
    log "[INFO] $name: existing $SINDEN_DEVICES saved to $DEVICES_BACKUP"
  fi
  local real_guns=""
  for candidate in /dev/ttyACM*; do
    [ -e "$candidate" ] && { real_guns="$candidate"; break; }
  done
  if [ -n "$real_guns" ]; then
    if [ "$FAKE_GUN_REQUIRED" -eq 1 ]; then
      record FAIL "$name" "a real serial gun is present on $real_guns, but --fake-gun-required demands the lab fake gun"
      return 1
    fi
    record INFO "$name" "a real serial gun is present on $real_guns; using it instead of the fake gun"
    return 0
  fi
  if [ ! -f "$FAKE_GUN" ]; then
    if [ "$FAKE_GUN_REQUIRED" -eq 1 ]; then
      record FAIL "$name" "$FAKE_GUN is missing and --fake-gun-required was given"
    else
      record SKIP "$name" "$FAKE_GUN is missing; copy the repo tests over or attach a real gun"
    fi
    return 1
  fi
  BROKER_WAS_RUNNING=0
  broker_pid >/dev/null && BROKER_WAS_RUNNING=1
  local stdout_file="$OUT/fake-gun.stdout"
  python3 "$FAKE_GUN" --pty --report "$OUT/fake-gun.json" \
    --handshake-mode firmware >"$stdout_file" 2>"$OUT/fake-gun.err" &
  FAKE_GUN_PID=$!
  local deadline=$(( $(date +%s) + 10 ))
  while [ -z "$FAKE_GUN_DEVICE" ] && [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 0.2
    FAKE_GUN_DEVICE="$(head -1 "$stdout_file" 2>/dev/null | tr -d '\r')"
  done
  if [ -z "$FAKE_GUN_DEVICE" ]; then
    record FAIL "$name" "the fake gun did not print a PTY path; see $OUT/fake-gun.err"
    return 1
  fi
  printf '1=%s\n' "$FAKE_GUN_DEVICE" >"$SINDEN_DEVICES"
  RESTORE_DEVICES=1
  "$SERVICE" stop >/dev/null 2>&1 || true
  "$SERVICE" start >/dev/null 2>&1 || true
  deadline=$(( $(date +%s) + 15 ))
  local pid=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    pid="$(broker_pid || true)"
    [ -n "$pid" ] && break
    sleep 0.5
  done
  if [ -z "$pid" ]; then
    record FAIL "$name" "the broker did not start with $SINDEN_DEVICES; see $BROKER_LOG"
    return 1
  fi
  record PASS "$name" "fake gun on $FAKE_GUN_DEVICE, broker PID $pid, player 1 overridden via sinden-devices.conf"
  start_lab_mono "$name"
  return 0
}

start_lab_mono() { # start real LightgunMono against the lab gun when available
  local name="$1"
  [ -n "$MONO_CMD" ] || [ -x "$LAB_MONO" ] || return 0
  if mono_pid >/dev/null; then
    record INFO "$name (LightgunMono)" "LightgunMono is already running (PID $(mono_pid))"
    return 0
  fi
  local command="${MONO_CMD:-$LAB_MONO $FAKE_GUN_DEVICE}"
  log "[INFO] $name: starting LightgunMono against $FAKE_GUN_DEVICE"
  LAB_MONO_STARTED=1
  sh -c "$command" >>"$OUT/lab-mono.log" 2>&1 &
  local deadline=$(( $(date +%s) + 25 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    mono_pid >/dev/null && break
    sleep 0.5
  done
  if mono_pid >/dev/null; then
    record PASS "$name (LightgunMono)" "real LightgunMono is running against the lab gun (PID $(mono_pid))"
    LAB_MONO_ALIVE=1
  else
    record INFO "$name (LightgunMono)" "LightgunMono did not start against the lab gun; see $OUT/lab-mono.log"
  fi
  return 0
}

launch_game() { # launch_game <step name>: start the game without a human
  log "[INFO] $1: launching the game with: $LAUNCH_CMD"
  # The runner owns the emulator when LAUNCH_CMD is set, so a game left over from an earlier
  # run must go first: two emulators fight over the output bridge port and the HOTR session.
  if pkill -f 'pcsx2[-]lightgun-qt' 2>/dev/null || pkill -f 'batocera[-]launch .*pcsx2' 2>/dev/null; then
    log "[INFO] $1: stopped an emulator left over from an earlier run"
    sleep 2
  fi
  # An emulator killed with --emukill can leave its forked output bridge behind (reparented
  # to PID 1). That orphan still holds TCP 8000 and its control socket, so the next launch's
  # bridge dies with EADDRINUSE and no game-side recoil signal can ever arrive.
  if pkill -f 'MameOutput[S]ender' 2>/dev/null; then
    log "[INFO] $1: cleared a leftover emulator output bridge (it would block the next one)"
    sleep 1
  fi
  rm -f /tmp/CoreFxPipe_MameHookerProxy* 2>/dev/null || true
  sh -c "$LAUNCH_CMD" >>"$OUT/launch.log" 2>&1 &
  sleep "${HOTR_SINDEN_VM_LAUNCH_SETTLE:-8}"
  log "[INFO] $1: waiting up to ${WAIT_SECONDS}s for frames"
  fire_recoil "$1" || true
}

fire_bridge() { # fire_bridge <path> [line ...]: ask the emulator's MameHooker control socket
  # Extra lines let a caller ask for another signal (the ammo step asks for P1_Ammo).
  python3 - "$@" <<'PY'
import socket, sys, time

path = sys.argv[1]
lines = sys.argv[2:] or ["GunRecoil_P1: 1", "GunRecoil_P2: 1"]
payload = "".join(line if line.endswith("\n") else line + "\n" for line in lines).encode()
for attempt in range(1, 4):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.settimeout(3)
        sock.connect(path)
        # The bridge turns each line into 'GunRecoil_PN = 1' on HOTR's socket,
        # exactly what the patched emulator sends when a player pulls the trigger.
        sock.sendall(payload)
        print(f"asked for {', '.join(lines)} on {path} (attempt {attempt})", flush=True)
    except OSError as exc:
        print(f"could not use {path}: {exc}", file=sys.stderr, flush=True)
        sys.exit(1)
    finally:
        sock.close()
    time.sleep(2)
PY
}

fire_recoil() { # fire_recoil <step name>: make the game side ask for recoil
  local name="$1"
  if [ -n "$FIRE_CMD" ]; then
    log "[INFO] $name: asking for recoil with: $FIRE_CMD"
    sh -c "$FIRE_CMD" >>"$OUT/fire.log" 2>&1 || true
    return 0
  fi
  if [ -S "$MAMEOUT_PIPE" ]; then
    log "[INFO] $name: asking for recoil on $MAMEOUT_PIPE (unix socket)"
    fire_bridge "$MAMEOUT_PIPE" >>"$OUT/fire.log" 2>&1 || {
      record FAIL "$name (stimulus)" "the emulator control socket $MAMEOUT_PIPE could not be used, so nothing asked the game for recoil; see $OUT/fire.log"
      return 1
    }
    return 0
  fi
  if [ -p "$MAMEOUT_PIPE" ]; then
    local attempt
    for attempt in 1 2 3; do
      if { printf 'GunRecoil_P1: 1\n'; printf 'GunRecoil_P2: 1\n'; } >"$MAMEOUT_PIPE" 2>>"$OUT/fire.log"; then
        log "[INFO] $name: asked for recoil on $MAMEOUT_PIPE (attempt $attempt)"
      fi
      sleep 2
    done
    return 0
  fi
  log "[INFO] $name: no emulator output bridge on $MAMEOUT_PIPE (the emulator is not running, or this is not a MameHooker build)"
  record FAIL "$name (stimulus)" "nothing could ask the game for recoil: $MAMEOUT_PIPE does not exist; pass --fire with your own stimulus command"
  return 1
}

step_game_launch() {
  local name="game launch"
  if [ -n "$LAUNCH_CMD" ]; then
    launch_game "$name"
  else
    prompt "Launch $GAME from the EmulationStation menu, play a few seconds and fire a few shots." || { record SKIP "$name" "skipped by the operator"; return 1; }
  fi
  local before_pid after_pid player=1
  before_pid="$(broker_pid || true)"
  local sent_before sent_after
  sent_before="$(state_field "$player" sent)"
  local frames_file="$OUT/frames-after-launch.txt"
  frame_commands "$OUT/fake-gun.json" >"$frames_file" 2>/dev/null || true
  check_signal_filter "$name" || true
  wait_for_a8 "$frames_file" "${HOTR_SINDEN_VM_A8_WAIT:-20}" || true
  if [ -f "$OUT/fake-gun.json" ] && [ -n "$FAKE_GUN_PID" ]; then
    check_whitelist "$name" "$frames_file" 1 || return 1
    report_check_handshake "game launch handshake" "$OUT/fake-gun.json"
  else
    sent_after="$(wait_for_state_change "$player" sent "$sent_before" "$WAIT_SECONDS" || true)"
    if [ -n "$sent_after" ] && [ "$sent_after" != "$sent_before" ]; then
      record PASS "$name" "the broker sent frames to the real gun (sent $sent_before -> $sent_after, last $(state_field "$player" last_frame))"
    else
      record FAIL "$name" "no frames were sent to the gun; did the game really run?"
      return 1
    fi
  fi
  check_mono_alive "$name (LightgunMono)" "$MONO_PID_BEFORE"
  after_pid="$(broker_pid || true)"
  if [ -n "$before_pid" ] && [ "$after_pid" != "$before_pid" ]; then
    record FAIL "$name (broker)" "the broker restarted during the game (PID $before_pid -> $after_pid)"
    return 1
  fi
  record PASS "$name (broker)" "the broker survived the launch (PID ${after_pid:-unknown})"
  "$SERVICE" status >"$OUT/service-status.txt" 2>&1 || true
  command -v hotr-status >/dev/null 2>&1 && hotr-status >"$OUT/hotr-status.txt" 2>&1 || true
  return 0
}

step_exit_relaunch() {
  local name="exit and relaunch" player=1 pid frames_before frames_after
  pid="$(broker_pid || true)"
  if [ -n "$EXIT_CMD" ]; then
    log "[INFO] $name: leaving the game with: $EXIT_CMD"
    sh -c "$EXIT_CMD" >>"$OUT/launch.log" 2>&1 &
    sleep 3
  else
    prompt "Exit the game back to EmulationStation." || { record SKIP "$name" "skipped by the operator"; return 1; }
  fi
  frames_before="$(wc -l <"$OUT/frames-after-launch.txt" 2>/dev/null | tr -d ' ' || echo 0)"
  sleep 5
  frames_after="$(frame_commands "$OUT/fake-gun.json" 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$frames_after" -gt "$frames_before" ]; then
    local last
    last="$(frame_commands "$OUT/fake-gun.json" | tail -1)"
    if [ "$last" = "a2" ]; then
      record PASS "$name (mute)" "the last frame after exit was the A2 mute"
    else
      record INFO "$name (mute)" "frames were still arriving 5 s after exit (last command $last); HOTR may hold the game open"
    fi
  else
    record PASS "$name (mute)" "no frames after exit"
  fi
  frame_commands "$OUT/fake-gun.json" >"$OUT/frames-before-relaunch.txt" 2>/dev/null || true
  if [ -n "$LAUNCH_CMD" ]; then
    launch_game "$name (relaunch)"
  else
    prompt "Launch $GAME again from EmulationStation and fire a few shots." || { record SKIP "$name (relaunch)" "skipped by the operator"; return 1; }
  fi
  frames_after="$(wc -l <"$OUT/frames-before-relaunch.txt" | tr -d ' ')"
  local deadline=$(( $(date +%s) + WAIT_SECONDS ))
  local delivered=0 fired=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local now
    now="$(frame_commands "$OUT/fake-gun.json" 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$now" -gt "$frames_after" ]; then delivered=1; break; fi
    if [ "$fired" = 0 ]; then fire_recoil "$name (relaunch)" || true; fired=1; fi
    sleep 1
  done
  broker_pid >/dev/null && [ "$(broker_pid)" = "$pid" ] || { record FAIL "$name (relaunch)" "the broker restarted instead of reusing its session"; return 1; }
  if [ "$delivered" = 1 ]; then
    record PASS "$name (relaunch)" "frames flowed again on the second launch with the same broker (PID $pid)"
  else
    record FAIL "$name (relaunch)" "no frames after relaunching the game"
    return 1
  fi
  return 0
}

step_ammo_path() {
  # The ammo path is a different recoil mode, so it needs its own launch: HOTR reads
  # the game profile once per game start. Everything here is restored before the
  # next step (the recoil-mode lab profile goes back and the game is closed again).
  local name="ammo-mode recoil"
  if [ -z "$FAKE_GUN_PID" ]; then
    record SKIP "$name" "needs the lab fake gun (a real gun cannot be driven unattended)"
    return 1
  fi
  if [ -z "$LAUNCH_CMD" ]; then
    record SKIP "$name" "pass --launch '<command>' to run this step unattended"
    return 1
  fi
  write_lab_ammo_profile
  log "[INFO] $name: wrote an ammo-mode lab profile for $GAME_ID"
  if [ -n "$EXIT_CMD" ]; then
    log "[INFO] $name: closing the previous game with: $EXIT_CMD"
    sh -c "$EXIT_CMD" >>"$OUT/ammo-launch.log" 2>&1 || true
    sleep 2
  fi
  pkill -f 'pcsx2[-]lightgun-qt' 2>/dev/null || true
  pkill -f 'batocera[-]launch .*pcsx2' 2>/dev/null || true
  local settle=0
  while [ "$settle" -lt 20 ] && pgrep -f 'pcsx2[-]lightgun-qt|batocera[-]launch .*pcsx2' >/dev/null 2>&1; do
    sleep 0.5
    settle=$((settle + 1))
  done
  pkill -f 'MameOutput[S]ender' 2>/dev/null || true
  sleep 2
  rm -f /tmp/CoreFxPipe_MameHookerProxy* 2>/dev/null || true
  # HOTR logs one "Output signal filter" line per game start. Only a line written
  # after this mark belongs to the launch below, so a game that never reaches HOTR
  # can never be mistaken for a stale result from the step before this one.
  local log_mark=0
  if [ -f "$HOTR_LOG" ]; then log_mark="$(wc -l <"$HOTR_LOG" | tr -d ' ')"; fi
  sh -c "$LAUNCH_CMD" >>"$OUT/ammo-launch.log" 2>&1 &
  sleep "${HOTR_SINDEN_VM_LAUNCH_SETTLE:-8}"
  local line="" deadline=$(( $(date +%s) + WAIT_SECONDS ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    line="$(last_signal_filter "$log_mark" || true)"
    case "$line" in *P1_Ammo*) break ;; esac
    sleep 1
  done
  case "$line" in
    *P1_Ammo*)
      record PASS "$name (signals)" "HOTR chose the ammo mode: ${line#*Output signal filter: }"
      ;;
    "")
      record FAIL "$name (signals)" "HOTR logged no new signal filter line for this launch (the previous game's teardown may have raced it); see $HOTR_LOG"
      write_lab_recoil_profile
      return 1
      ;;
    *GunRecoil_P1*)
      record SKIP "$name (signals)" "this machine's gun recoil priority chose the recoil mode for this fresh game start, so the ammo path cannot be exercised here: ${line#*Output signal filter: }"
      write_lab_recoil_profile
      return 1
      ;;
    *)
      record FAIL "$name (signals)" "HOTR registered ${line#*Output signal filter: } with an ammo-mode profile, so no ammo frame can reach the gun"
      write_lab_recoil_profile
      return 1
      ;;
  esac
  local frames_file="$OUT/frames-ammo.txt" a4_before a4_after
  frame_commands "$OUT/fake-gun.json" >"$frames_file" 2>/dev/null || true
  a4_before="$(grep -c '^a4$' "$frames_file" || true)"
  # A reload (the ammo count grows) is what arms the gun: LightGun::AmmoValueSinden()
  # prepends 1K1, which the broker writes as the quiet A4 01 frame.
  if [ -n "$FIRE_CMD" ]; then
    log "[INFO] $name: asking for a reload with: $FIRE_CMD"
    sh -c "$FIRE_CMD" >>"$OUT/ammo-signal.log" 2>&1 || true
  elif [ -S "$MAMEOUT_PIPE" ]; then
    fire_bridge "$MAMEOUT_PIPE" "P1_Ammo: 7" >>"$OUT/ammo-signal.log" 2>&1 || {
      record FAIL "$name (stimulus)" "the emulator control socket $MAMEOUT_PIPE could not be used, so nothing changed the ammo count; see $OUT/ammo-signal.log"
      write_lab_recoil_profile
      return 1
    }
  elif [ -p "$MAMEOUT_PIPE" ]; then
    printf 'P1_Ammo: 7\n' >"$MAMEOUT_PIPE" 2>>"$OUT/ammo-signal.log" || true
  else
    record FAIL "$name (stimulus)" "no emulator output bridge on $MAMEOUT_PIPE; is the emulator really running?"
    write_lab_recoil_profile
    return 1
  fi
  local wait_deadline=$(( $(date +%s) + ${HOTR_SINDEN_VM_A4_WAIT:-20} ))
  while [ "$(date +%s)" -lt "$wait_deadline" ]; do
    frame_commands "$OUT/fake-gun.json" >"$frames_file" 2>/dev/null || true
    a4_after="$(grep -c '^a4$' "$frames_file" || true)"
    [ "${a4_after:-0}" -gt "${a4_before:-0}" ] && break
    sleep 0.5
  done
  frame_commands "$OUT/fake-gun.json" >"$frames_file" 2>/dev/null || true
  a4_after="$(grep -c '^a4$' "$frames_file" || true)"
  if [ "${a4_after:-0}" -gt "${a4_before:-0}" ]; then
    record PASS "$name (frames)" "the reload armed the gun's firmware trigger recoil (A4 frames $a4_before -> $a4_after)"
    check_whitelist "$name (frames)" "$frames_file" 0 || true
  else
    record FAIL "$name (frames)" "no A4 frame after an ammo reload, so Sinden_Trigger_Recoil does not reach the gun (frames: $frames_file, broker log: $BROKER_LOG)"
  fi
  if [ -n "$EXIT_CMD" ]; then
    log "[INFO] $name: leaving the game with: $EXIT_CMD"
    sh -c "$EXIT_CMD" >>"$OUT/ammo-launch.log" 2>&1 &
    sleep 3
  else
    record INFO "$name" "the game is still running; exit it before the menu step"
  fi
  write_lab_recoil_profile
  return 0
}

step_menu_navigation() {
  local name="menu navigation" pid
  pid="$(broker_pid || true)"
  prompt "Open and close the HOTR UI, then move around EmulationStation for a few seconds." || { record SKIP "$name" "skipped by the operator"; return 1; }
  local now
  now="$(broker_pid || true)"
  if [ -z "$now" ] || { [ -n "$pid" ] && [ "$now" != "$pid" ]; }; then
    record FAIL "$name" "the broker died or restarted (PID ${pid:-none} -> ${now:-none}); see $BROKER_LOG"
    return 1
  fi
  record PASS "$name" "broker PID unchanged ($now)"
  if command -v hotr-status >/dev/null 2>&1; then
    if hotr-status >"$OUT/hotr-status-after-menu.txt" 2>&1; then
      record PASS "$name (hotr-status)" "hotr-status still works; output captured"
    else
      record FAIL "$name (hotr-status)" "hotr-status failed; see hotr-status-after-menu.txt"
      return 1
    fi
  else
    record INFO "$name (hotr-status)" "hotr-status is not installed; skipping that assertion"
  fi
  return 0
}

step_painful_paths() {
  local name="painful paths"
  local pid
  pid="$(broker_pid || true)"
  if [ -n "$pid" ]; then
    kill -KILL "$pid" 2>/dev/null || true
    "$SERVICE" start >/dev/null 2>&1 || true
    local deadline=$(( $(date +%s) + 15 )) restarted=""
    while [ "$(date +%s)" -lt "$deadline" ]; do
      restarted="$(broker_pid || true)"
      [ -n "$restarted" ] && break
      sleep 0.5
    done
    if [ -n "$restarted" ] && [ "$restarted" != "$pid" ]; then
      record PASS "$name (SIGKILL)" "the service brought the broker back (PID $pid -> $restarted)"
    else
      record FAIL "$name (SIGKILL)" "the broker did not come back after a SIGKILL; see $BROKER_LOG"
    fi
  else
    record INFO "$name (SIGKILL)" "no broker was running; skipping the kill test"
  fi
  local add_helper=/usr/bin/virtual-sindenlightgun-add
  if [ -f "$add_helper" ] && grep -q 'HOTR SINDEN BROKER INTEGRATION' "$add_helper" 2>/dev/null; then
    record INFO "$name (upgrade)" "the retired PTY bridge hook is still in $add_helper; install.sh reverts it"
    if [ -x "$HOTR/tools/patch-batocera-sinden-hotr.sh" ]; then
      "$HOTR/tools/patch-batocera-sinden-hotr.sh" remove >"$OUT/patch-remove.txt" 2>&1 || true
      if grep -q 'HOTR SINDEN BROKER INTEGRATION' "$add_helper" 2>/dev/null; then
        record FAIL "$name (upgrade)" "the helper still carries the hook after remove; see patch-remove.txt"
      else
        record PASS "$name (upgrade)" "the helper was reverted to stock"
      fi
    fi
  else
    record PASS "$name (upgrade)" "no retired PTY bridge hook on $add_helper"
  fi
  if [ "$ALLOW_UNINSTALL" = 1 ]; then
    if prompt "Uninstall HOTR now (this removes the install; you must reinstall afterwards)?"; then
      if [ -x "$REPO_ROOT/uninstall.sh" ]; then
        "$REPO_ROOT/uninstall.sh" >"$OUT/uninstall.txt" 2>&1 || true
        if [ -e "$HOTR" ] || [ -e /usr/bin/hotr-sinden-check ]; then
          record FAIL "$name (uninstall)" "leftovers after uninstall.sh; see uninstall.txt"
        else
          record PASS "$name (uninstall)" "uninstall removed the install and the tools"
        fi
      else
        record INFO "$name (uninstall)" "uninstall.sh not found in $REPO_ROOT; skipping"
      fi
    else
      record SKIP "$name (uninstall)" "skipped by the operator"
    fi
  else
    record SKIP "$name (uninstall)" "not requested (pass --allow-uninstall)"
  fi
  return 0
}

step_bundle() {
  local name="evidence bundle"
  if command -v hotr-sinden-check >/dev/null 2>&1; then
    hotr-sinden-check --json >"$OUT/check-after.json" 2>"$OUT/check-after.err" || true
    python3 - "$OUT/check-after.json" >"$OUT/check-after.txt" <<'PY' || true
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        report = json.load(handle)
except (OSError, ValueError):
    raise SystemExit(0)
for item in report.get("checks", []):
    print(f"{item['level']:4} {item['message']}")
PY
  fi
  if [ -x "$REPO_ROOT/scripts/hotr-debug-report.sh" ]; then
    "$REPO_ROOT/scripts/hotr-debug-report.sh" >"$OUT/debug-report.txt" 2>&1 || true
    if [ -n "$(ls /var/lib/hotr-debug 2>/dev/null)" ]; then
      cp -a /var/lib/hotr-debug "$OUT/debug-report-files" 2>/dev/null || true
    fi
  fi
  for extra in "$BROKER_LOG" "$STATE_FILE" "$SINDEN_DEVICES" /var/run/sinden/p*/LightgunMono-*.exe.config; do
    [ -e "$extra" ] && cp -a "$extra" "$OUT/" 2>/dev/null || true
  done
  tar czf "$OUT.tar.gz" -C "$(dirname "$OUT")" "$(basename "$OUT")" 2>/dev/null || true
  if [ -f "$OUT.tar.gz" ]; then
    record PASS "$name" "$OUT.tar.gz is ready to send"
  else
    record FAIL "$name" "could not create the archive"
    return 1
  fi
  return 0
}

# --- modes -----------------------------------------------------------------

fire_bridge_self_test() { # a throwaway local socket proves the stimulus helper can build its payload
  local sock="$SELFTEST_TMP/fire.sock" received="$SELFTEST_TMP/fire.received" pid
  rm -f "$sock" "$received"
  python3 - "$sock" "$received" <<'PY' &
import socket, sys, time

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sys.argv[1])
server.listen(1)
server.settimeout(20)
try:
    client, _ = server.accept()
except OSError:
    raise SystemExit(1)
with open(sys.argv[2], "wb") as handle:
    handle.write(client.recv(512))
client.close()
time.sleep(0.1)
PY
  pid=$!
  sleep 1
  # The helper retries three times; after this listener closes it reports failure,
  # which is fine here: only the payload it delivered matters.
  fire_bridge "$sock" "P1_Ammo: 7" >/dev/null 2>&1 || true
  wait "$pid" 2>/dev/null || true
  grep -q 'P1_Ammo: 7' "$received" 2>/dev/null
}

signal_filter_mark_self_test() { # a filter line from an earlier game start must not answer a later one
  local log="$SELFTEST_TMP/hotr.log" old_mark new_mark expected
  printf '%s\n' 'game start one' \
    '[HOTR] Output signal filter: QList("mame_start", "mame_stop", "GunRecoil_P1")' \
    'game over' >"$log"
  HOTR_LOG="$log"
  old_mark="$(wc -l <"$log" | tr -d ' ')"
  expected='[HOTR] Output signal filter: QList("mame_start", "mame_stop", "P1_Ammo")'
  printf '%s\n' "$expected" >>"$log"
  [ "$(last_signal_filter)" = "$expected" ] || return 1
  [ "$(last_signal_filter "$old_mark")" = "$expected" ] || return 1
  new_mark="$(wc -l <"$log" | tr -d ' ')"
  [ -z "$(last_signal_filter "$new_mark")" ] || return 1
  return 0
}
run_self_test() {
  SELFTEST_TMP="$(mktemp -d)"
  trap 'rm -rf "${SELFTEST_TMP:-}"' EXIT
  local tmp="$SELFTEST_TMP"
  OUT="$tmp"
  RUN_LOG="$tmp/selftest.log"
  : >"$RUN_LOG"
  local failures=0
  printf '%s' '{"frame_log": ["aa a8 00 00 00 00 bb", "aa a2 50 00 50 0d bb"]}' >"$tmp/good.json"
  printf '%s' '{"frame_log": ["aa a7 50 00 00 00 bb", "aa a8 00 00 00 00 bb"]}' >"$tmp/reply.json"
  printf '%s' '{"frame_log": []}' >"$tmp/empty.json"
  frame_commands "$tmp/good.json" >"$tmp/good.txt"
  check_whitelist "self-test good frames" "$tmp/good.txt" 1 >/dev/null || { echo "FAIL good frames"; failures=$((failures + 1)); }
  frame_commands "$tmp/reply.json" >"$tmp/reply.txt"
  if check_whitelist "self-test reply frame" "$tmp/reply.txt" 1 >/dev/null; then
    echo "FAIL reply-producing frame was accepted"; failures=$((failures + 1))
  fi
  frame_commands "$tmp/empty.json" >"$tmp/empty.txt"
  if check_whitelist "self-test empty" "$tmp/empty.txt" 1 >/dev/null; then
    echo "FAIL empty frame log was accepted"; failures=$((failures + 1))
  fi
  printf '%s' '{"errors": [], "sent_unsolicited": false, "handshake": {"true_sent": true}}' >"$tmp/hs-good.json"
  if ! check_handshake "self-test handshake" "$tmp/hs-good.json" | grep -q '^PASS'; then
    echo "FAIL good handshake report rejected"; failures=$((failures + 1))
  fi
  printf '%s' '{"errors": ["resync: dropped byte 0x00"], "sent_unsolicited": true}' >"$tmp/hs-bad.json"
  if check_handshake "self-test bad handshake" "$tmp/hs-bad.json" | grep -q '^PASS'; then
    echo "FAIL bad handshake report accepted"; failures=$((failures + 1))
  fi
  printf '%s' '{"players": {"1": {"sent": 7, "last_frame": "aa a8 00 00 00 00 bb"}}}' >"$tmp/state.json"
  STATE_FILE="$tmp/state.json"
  if [ "$(state_field 1 sent)" != "7" ] || [ "$(state_field 1 missing)" != "" ]; then
    echo "FAIL state_field did not read the broker state"; failures=$((failures + 1))
  fi
  if ! fire_bridge_self_test; then
    echo "FAIL the emulator bridge stimulus helper does not deliver its payload"
    failures=$((failures + 1))
  fi
  if ! signal_filter_mark_self_test; then
    echo "FAIL the signal filter marker accepts a stale line from an earlier game start"
    failures=$((failures + 1))
  fi
  if [ "$failures" = 0 ]; then
    echo "PASS self-test: frame whitelist and handshake parsers behave as documented"
    return 0
  fi
  echo "FAIL self-test: $failures check(s) failed"
  return 1
}

print_plan() {
  cat <<EOF
HOTR Sinden virtual-machine acceptance run (no changes made: --dry-run)

  repository:      $REPO_ROOT
  install:         $HOTR
  fake gun:        $FAKE_GUN
  game:            $GAME
  evidence bundle: ${OUT:-./hotr-sinden-vm-<date>}

  1. pre-flight           root, $SERVICE present, hotr-sinden-check installed, recoil enabled,
                          $SINDEN_CMD_FILE asks for recoil
  2. fake gun             python3 $FAKE_GUN --pty --report <bundle>/fake-gun.json
                          write 1=<pty> to $SINDEN_DEVICES, restart the hotr service
                          (skipped automatically when a real /dev/ttyACM* gun is attached)
  3. read-only report      hotr-sinden-check --json -> check-before.txt (must have no FAIL)
                          run after step 2 so it sees the gun this run uses
  4. game launch          launch $GAME (or --launch '<command>') and fire;
                          --fire '<command>' or the MameHooker control pipe supplies the
                          recoil signal when nobody can play by hand
                          assert: >=1 A8 frame at the gun, only $WHITELIST frames,
                          never $REPLY_PRODUCING, no resync errors, LightgunMono alive,
                          no 'Cannot communicate with lightgun', broker PID unchanged
  5. exit and relaunch    exit -> last frame is the A2 mute (or frames stop),
                          relaunch -> frames flow again with the same broker PID
  6. ammo-mode recoil     relaunch with an ammo-mode profile (Ammo_Value 1 + Sinden_Trigger_Recoil):
                          HOTR must register the game's P1_Ammo signal, and an ammo reload
                          must put a quiet A4 frame on the wire (the gun's firmware trigger
                          recoil)
  7. menu navigation      open/close the HOTR UI and move around ES:
                          broker PID unchanged and hotr-status still works
  8. painful paths        SIGKILL the broker -> service start brings it back;
                          revert a leftover PTY bridge hook in /usr/bin/virtual-sindenlightgun-add
  9. evidence bundle      hotr-sinden-check, hotr-debug-report.sh, broker log, state file,
                          frame log -> ${OUT:-<bundle>}.tar.gz

  ssh mode:  --ssh USER@HOST pushes this script plus the fake gun to /tmp/hotr-sinden-vm,
             runs the same run there as root and copies the bundle back here.
             The VM must already have this repository installed (install.sh).
EOF
}

run_remote() {
  local remote_dir=/tmp/hotr-sinden-vm
  local remote_args="--local --out $remote_dir/out"
  [ "$ASSUME_YES" = 1 ] && remote_args="$remote_args --yes"
  [ "$ALLOW_UNINSTALL" = 1 ] && remote_args="$remote_args --allow-uninstall"
  local extra
  for extra in "$LAUNCH_CMD" "$EXIT_CMD" "$MONO_CMD" "$FIRE_CMD"; do
    case "$extra" in *"'"*) printf '[FAIL] commands must not contain a single quote: %s\n' "$extra" >&2; return 1 ;; esac
  done
  [ -n "$LAUNCH_CMD" ] && remote_args="$remote_args --launch '$LAUNCH_CMD'"
  [ -n "$EXIT_CMD" ] && remote_args="$remote_args --exit '$EXIT_CMD'"
  [ -n "$MONO_CMD" ] && remote_args="$remote_args --mono '$MONO_CMD'"
  [ -n "$FIRE_CMD" ] && remote_args="$remote_args --fire '$FIRE_CMD'"
  printf '[INFO] pushing the runner to %s:%s\n' "$SSH_TARGET" "$remote_dir"
  # Batocera images do not always ship sudo, and a root login needs none.
  local remote_gate=""
  if [ "$(ssh "$SSH_TARGET" 'id -u' 2>/dev/null | tr -d '\r')" != "0" ]; then
    if ssh "$SSH_TARGET" 'command -v sudo >/dev/null 2>&1' 2>/dev/null; then
      remote_gate="sudo"
    else
      printf '[FAIL] %s is not root and has no sudo; this acceptance run needs root on the machine\n' "$SSH_TARGET" >&2
      return 1
    fi
  fi
  ssh "$SSH_TARGET" 'rm -rf /tmp/hotr-sinden-vm/out && mkdir -p /tmp/hotr-sinden-vm' || return 1
  scp -q "$SELF" "$SSH_TARGET:$remote_dir/" || return 1
  [ -f "$FAKE_GUN" ] && scp -q "$FAKE_GUN" "$SSH_TARGET:$remote_dir/" || true
  printf '[INFO] running the acceptance run on the VM\n'
  local remote_status=0
  if [ -t 0 ]; then
    ssh -t "$SSH_TARGET" "$remote_gate $remote_dir/$(basename "$SELF") $remote_args" || remote_status=$?
  else
    ssh "$SSH_TARGET" "$remote_gate $remote_dir/$(basename "$SELF") $remote_args" || remote_status=$?
  fi
  mkdir -p "$OUT"
  scp -q -r "$SSH_TARGET:$remote_dir/out/." "$OUT/" || return 1
  printf '[INFO] bundle copied to %s\n' "$OUT"
  # The remote status must reach the caller: a swallowed FAIL is a silent green run.
  [ "$remote_status" = 0 ] || printf '[FAULT] the remote run reported failures (exit %s); see %s/run.log\n' "$remote_status" "$OUT" >&2
  return "$remote_status"
}

main() {
  parse_args "$@"
  if [ "$SELF_TEST" = 1 ]; then
    run_self_test
    return $?
  fi
  OUT="${OUT:-$(pwd)/hotr-sinden-vm-$(date +%Y%m%d-%H%M%S)}"
  RUN_LOG="/dev/null"
  print_plan >/dev/null 2>&1 || true
  if [ "$DRY_RUN" = 1 ]; then
    print_plan
    return 0
  fi
  if [ -n "$SSH_TARGET" ] && [ "$LOCAL" != 1 ]; then
    run_remote
    return $?
  fi
  mkdir -p "$OUT" || { printf 'cannot create %s\n' "$OUT" >&2; return 2; }
  RUN_LOG="$OUT/run.log"
  : >"$RUN_LOG"
  trap on_exit EXIT
  log "HOTR Sinden VM acceptance run — $(date '+%Y-%m-%d %H:%M:%S')"
  log "repository: $REPO_ROOT"
  log "game: $GAME"
  print_plan | tee -a "$RUN_LOG" >/dev/null
  MONO_PID_BEFORE="$(mono_pid)"

  step_preflight || { log "stopping: pre-flight failed"; return 1; }
  # Attach the gun before the report so the report describes the setup this run uses
  # (on a machine without a Sinden device the fake gun is the only gun there is).
  step_attach_fake_gun || true
  step_lab_profile || true
  step_report || true
  step_game_launch || true
  step_exit_relaunch || true
  # The ammo path needs its own launch with a profile that selects the ammo mode and
  # arms the gun's firmware trigger recoil; it puts the recoil-mode profile back.
  step_ammo_path || true
  step_menu_navigation || true
  step_painful_paths || true
  # The acceptance started the game itself, so it closes it too: a leftover emulator would
  # hold the output bridge port and confuse the next run (and the operator's machine).
  if [ -n "$EXIT_CMD" ] && [ -n "$LAUNCH_CMD" ]; then
    log "[INFO] leaving the game: the acceptance started it, so it closes it too"
    sh -c "$EXIT_CMD" >>"$OUT/launch.log" 2>&1 || true
    sleep 3
    pkill -f 'MameOutput[S]ender' 2>/dev/null || true
  fi
  step_bundle || true
  return $(( FAIL_COUNT > 0 ))
}

main "$@"
