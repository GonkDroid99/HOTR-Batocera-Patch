#!/usr/bin/env python3
"""
hotr-autoconfig: Detect connected light guns and write HOTR config files.

Usage:
  hotr-autoconfig          # first-boot only — skips if config already has guns
  hotr-autoconfig --force  # always rescans and rewrites (triggered from Ports menu)

Detection works by scanning /dev/serial/by-id/ against known product name patterns.
Detected guns are saved using /dev/serial/by-path/ paths so the config survives
reboots unchanged — the by-path path is stable as long as the gun stays in the
same physical USB port.

Supported auto-detection:
  Serial guns: RS3 Reaper, JB Gun4IR, Fusion, Blamcon, OpenFire, X-Gunner, Xenas
  Not auto-detected (add via HOTR UI): Alien USB, AimTrak, Custom USB, RKADE,
    MX24 (DIP-switch player numbering), Sinden (TCP), Xenas BTLE (Bluetooth)

To add a new auto-detectable gun: add an entry to GUN_DEFINITIONS with a by_id_re
that matches its /dev/serial/by-id/ name.  Baud rates from Global.h BAUDDATA_ARRAY:
  index 0=115200  1=57600  2=38400  3=19200  4=9600  5=4800  6=2400  7=1200
"""
import glob
import os
import re
import sys

HOTR_DATA_DIR  = "/userdata/system/hook-of-the-reaper/data"
LIGHTGUNS_FILE = os.path.join(HOTR_DATA_DIR, "lightguns.hor")
PLAYERS_FILE   = os.path.join(HOTR_DATA_DIR, "playersAss.hor")
UNASSIGN       = 69
MAX_PLAYERS    = 8

# /dev/serial/by-id names follow the pattern:
#   usb-{Manufacturer}_{Product}_{Serial}-if{interface}-port{port}
# Spaces in USB strings become underscores.  We match the interface that carries
# the serial command channel (if02 for RS3 which is composite; if00 for single-
# function Arduino CDC ACM devices).
#
# serial tuple: (baud, data_bits, parity, stop_bits, flow_control)
# extra:        gun-type-specific lines after serial params (RS3 Reaper only)

GUN_DEFINITIONS = {
    # --- Retro Shooter RS3 Reaper (VID 0483 / PID 5750 or 5751) ---
    # Composite device; serial command interface is always if02.
    # Also has udev symlinks under /dev/hotr/ for primary detection.
    "rs3reaper": {
        "type_num": 1,
        "name":     "Retro Shooter: RS3 Reaper",
        "serial":   (115200, 8, 0, 1, 0),
        "extra":    [0, 15, 0, 1, 145, 5000],
        "by_id_re": re.compile(
            r"^usb-3AGAME_3A-3H_Retro_Shooter_(\d+)_.*-if02-port0$"
        ),
    },

    # --- JB Gun4IR (Arduino Pro Micro / Micro, CDC ACM, if00) ---
    # Product string contains "GUN4IR" followed by a player tag e.g. "P1".
    # Baud JBGUN4IRBAUD=4 → 9600.
    "gun4ir": {
        "type_num": 3,
        "name":     "JB Gun4IR",
        "serial":   (9600, 8, 0, 1, 0),
        "extra":    [],
        "by_id_re": re.compile(
            r"^usb-Arduino.*GUN4IR.*-if00-port0$",
            re.IGNORECASE,
        ),
    },

    # --- Fusion lightgun (OpenFire-based firmware, CDC ACM, if00) ---
    # Covers Fusion Mini P1/P2 and Fusion Piggie variants.
    # Baud FUSIONBAUD=0 → 115200.
    "fusion": {
        "type_num": 4,
        "name":     "Fusion",
        "serial":   (115200, 8, 0, 1, 0),
        "extra":    [],
        "by_id_re": re.compile(
            r"^usb-Fusion.*-if00-port0$",
            re.IGNORECASE,
        ),
    },

    # --- Blamcon (Props3D, CDC ACM, if00) ---
    # Product: "Props3D Blamcon Lightgun - P1" etc.
    # Baud BLAMCONBAUD=4 → 9600.
    "blamcon": {
        "type_num": 5,
        "name":     "Blamcon",
        "serial":   (9600, 8, 0, 1, 0),
        "extra":    [],
        "by_id_re": re.compile(
            r"^usb-Props3D_Blamcon.*-if00-port0$",
            re.IGNORECASE,
        ),
    },

    # --- OpenFire FIRECon (CDC ACM, if00) ---
    # Product: "OpenFIRE FIRECon P1" etc.
    # Baud OPENFIREBAUD=4 → 9600.
    "openfire": {
        "type_num": 6,
        "name":     "OpenFire",
        "serial":   (9600, 8, 0, 1, 0),
        "extra":    [],
        "by_id_re": re.compile(
            r"^usb-OpenFIRE.*-if00-port0$",
            re.IGNORECASE,
        ),
    },

    # --- X-Gunner (HONGWEIHUA, CDC ACM, if00) ---
    # Product: "HONGWEIHUA XGUNNER-P1" etc.
    # Baud XGUNNERBAUD=4 → 9600.
    "xgunner": {
        "type_num": 8,
        "name":     "X-Gunner",
        "serial":   (9600, 8, 0, 1, 0),
        "extra":    [],
        "by_id_re": re.compile(
            r"^usb-HONGWEIHUA.*XGUNNER.*-if00-port0$",
            re.IGNORECASE,
        ),
    },

    # --- Xenas Gun (CDC ACM, if00) ---
    # Baud XENASBAUD=0 → 115200.
    "xenas": {
        "type_num": 10,
        "name":     "Xenas Gun",
        "serial":   (115200, 8, 0, 1, 0),
        "extra":    [],
        "by_id_re": re.compile(
            r"^usb-Xenas.*-if00-port0$",
            re.IGNORECASE,
        ),
    },
}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _resolve(path):
    return os.path.exists(path)


def _config_has_guns():
    """Return True if lightguns.hor exists and declares at least one gun."""
    if not os.path.isfile(LIGHTGUNS_FILE):
        return False
    try:
        with open(LIGHTGUNS_FILE) as f:
            lines = [l.strip() for l in f if l.strip()]
        # Second non-header line is the gun count
        if len(lines) >= 2 and lines[1].isdigit() and int(lines[1]) > 0:
            return True
    except OSError:
        pass
    return False


def _get_by_path(by_id_path):
    """
    Return the /dev/serial/by-path equivalent of a /dev/serial/by-id path.
    Both are symlinks to the same actual device (e.g. /dev/ttyACM0).
    by-path is keyed to the physical USB port, so it survives reboots even
    when device numbers shift.  Falls back to the by-id path if no by-path
    entry is found.
    """
    actual = os.path.realpath(by_id_path)
    by_path_dir = "/dev/serial/by-path"
    if os.path.isdir(by_path_dir):
        for entry in sorted(os.listdir(by_path_dir)):
            candidate = os.path.join(by_path_dir, entry)
            if os.path.realpath(candidate) == actual:
                return candidate
    return by_id_path


# ---------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------

def detect_via_hotr_symlinks():
    """
    Primary path for RS3 guns: /dev/hotr/<type>-gun<N> symlinks created by the
    udev rules in 99-hotr.rules.  Returns list of (gun_type, by_path_path).
    """
    found = []
    for gun_type in sorted(GUN_DEFINITIONS, key=lambda t: GUN_DEFINITIONS[t]["type_num"]):
        for link in sorted(glob.glob(f"/dev/hotr/{gun_type}-gun*")):
            if _resolve(link):
                # The udev symlink points to ttyUSB; get the by-path equivalent.
                found.append((gun_type, _get_by_path(os.path.realpath(link))))
    return found


def detect_via_by_id():
    """
    Scan /dev/serial/by-id/ against all GUN_DEFINITIONS patterns.
    Returns list of (gun_type, by_path_path) sorted by type_num then name.
    """
    by_id_dir = "/dev/serial/by-id"
    if not os.path.isdir(by_id_dir):
        return []

    entries = sorted(os.listdir(by_id_dir))
    found = []

    # Iterate definitions in type_num order so player assignments are consistent
    for gun_type, defn in sorted(GUN_DEFINITIONS.items(),
                                  key=lambda kv: kv[1]["type_num"]):
        rx = defn.get("by_id_re")
        if not rx:
            continue
        for entry in entries:
            if rx.match(entry):
                by_id_path = os.path.join(by_id_dir, entry)
                if _resolve(by_id_path):
                    stable_path = _get_by_path(by_id_path)
                    found.append((gun_type, stable_path))

    return found


def detect_guns():
    """
    Try udev symlinks first (RS3 primary path), then fall back to by-id scan
    for everything.  Deduplicate by resolved device path so a gun isn't added
    twice if it appears in both detection paths.
    """
    seen_devices = set()
    result = []

    for gun_type, path in detect_via_hotr_symlinks():
        real = os.path.realpath(path)
        if real not in seen_devices:
            seen_devices.add(real)
            result.append((gun_type, path))

    for gun_type, path in detect_via_by_id():
        real = os.path.realpath(path)
        if real not in seen_devices:
            seen_devices.add(real)
            result.append((gun_type, path))

    return result


# ---------------------------------------------------------------------------
# Config writers
# ---------------------------------------------------------------------------

def write_lightguns_hor(guns):
    lines = ["Light Gun Data File V3", str(len(guns))]
    for i, (gun_type, device_path) in enumerate(guns):
        d = GUN_DEFINITIONS[gun_type]
        baud, data, parity, stop, flow = d["serial"]
        lines += [
            f"Light Gun #{i}",
            str(i),
            f"{d['name']} P{i + 1}",
            "1",
            str(d["type_num"]),
            "0", "1", "2", "3",
            "1", "1", "1", "1",
            "END_GENERAL_SETTINGS",
            str(i),
            device_path,
            str(baud), str(data), str(parity), str(stop), str(flow),
        ]
        for val in d.get("extra", []):
            lines.append(str(val))
    lines.append("END_OF_FILE")
    with open(LIGHTGUNS_FILE, "w") as f:
        f.write("\n".join(lines) + "\n")


def write_players_hor(guns):
    assignments = [UNASSIGN] * MAX_PLAYERS
    for i in range(min(len(guns), MAX_PLAYERS)):
        assignments[i] = i
    lines = ["Player Assignments"] + [str(a) for a in assignments] + ["END_OF_FILE"]
    with open(PLAYERS_FILE, "w") as f:
        f.write("\n".join(lines) + "\n")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    force = "--force" in sys.argv

    if not os.path.isdir(HOTR_DATA_DIR):
        print(f"hotr-autoconfig: {HOTR_DATA_DIR} not ready, skipping")
        sys.exit(0)

    if not force and _config_has_guns():
        print("hotr-autoconfig: existing gun config found, skipping "
              "(use --force to rescan)")
        sys.exit(0)

    guns = detect_guns()

    if not guns:
        if force:
            # Write empty config so HOTR starts clean for manual setup via UI.
            print("hotr-autoconfig: no supported guns detected — "
                  "writing empty config for manual setup via HOTR UI")
            write_lightguns_hor([])
            write_players_hor([])
        else:
            print("hotr-autoconfig: no supported guns detected, "
                  "leaving existing config")
        sys.exit(0)

    print(f"hotr-autoconfig: detected {len(guns)} gun(s):")
    for i, (gun_type, path) in enumerate(guns):
        d = GUN_DEFINITIONS[gun_type]
        print(f"  Player {i + 1}: {d['name']} -> {path}")

    write_lightguns_hor(guns)
    write_players_hor(guns)
    print("hotr-autoconfig: config written successfully")


if __name__ == "__main__":
    main()
