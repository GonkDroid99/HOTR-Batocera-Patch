#!/usr/bin/env python3
"""
hotr-autoconfig: Detect connected light guns and write HOTR config files.

Usage:
  hotr-autoconfig          # scans when no valid gun configuration exists
  hotr-autoconfig --force  # always rescans and rewrites all detected guns

Detection works by scanning /dev/serial/by-id/ against known product name patterns.
Detected guns are resolved to their actual /dev/tty* device node before being
written. HOTR's serial parser rejects /dev/serial/by-path symlinks even though
Linux itself can open them, so the boot service force-rescans every boot to
refresh tty numbering.

Supported detection:
  Serial guns: RS3 Reaper, JB Gun4IR, Fusion, Blamcon, OpenFire, X-Gunner, Xenas
  HID: Alien USB, AimTrak, Custom USB
  MX24 hubs are identified and reported, but their HOTR entry remains manual
    because player numbering comes from the physical DIP switches.
  Sinden (TCP), RKADE, and Xenas BTLE remain manual.

To add a new auto-detectable gun: add an entry to GUN_DEFINITIONS with a by_id_re
that matches its /dev/serial/by-id/ name.  Baud rates from Global.h BAUDDATA_ARRAY:
  index 0=115200  1=57600  2=38400  3=19200  4=9600  5=4800  6=2400  7=1200
"""
import glob
import os
import re
import sys

HOTR_DATA_DIR  = os.environ.get("HOTR_DATA_DIR", "/userdata/system/hook-of-the-reaper/data")
LIGHTGUNS_FILE = os.path.join(HOTR_DATA_DIR, "lightguns.hor")
PLAYERS_FILE   = os.path.join(HOTR_DATA_DIR, "playersAss.hor")
SERIAL_BY_ID_DIR = os.environ.get("HOTR_SERIAL_BY_ID", "/dev/serial/by-id")
SERIAL_BY_PATH_DIR = os.environ.get("HOTR_SERIAL_BY_PATH", "/dev/serial/by-path")
HOTR_SYMLINK_DIR = os.environ.get("HOTR_DEVICE_DIR", "/dev/hotr")
HIDRAW_DIR = os.environ.get("HOTR_HIDRAW_DIR", "/dev")
HID_SYSFS_DIR = os.environ.get("HOTR_HID_SYSFS", "/sys/class/hidraw")
INPUT_BY_ID_DIR = os.environ.get("HOTR_INPUT_BY_ID", "/dev/input/by-id")
SINDEN_RUN_DIR = os.environ.get("HOTR_SINDEN_RUN", "/var/run")
UNASSIGN       = 69
MAX_PLAYERS    = 8

# Exit status used by hotr-service.  A missing gun is expected during early
# boot while USB devices are still enumerating and is not a configuration
# failure.
NO_GUNS        = 10
CONFIG_ERROR   = 1

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

HID_DEFINITIONS = {
    ("04b4", "6870"): "Alien USB",
    ("d209", "1601"): "AimTrak",
    ("1b4f", "9206"): "Custom USB",
}

MX24_RE = re.compile(r"MX24|Mayflash.*MX", re.IGNORECASE)


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


def _config_paths_available():
    """Return whether every saved serial device path still exists.

    A by-path name is stable for a physical USB port, but the PCI portion can
    change when a VM is restarted or its USB controller is re-enumerated.  In
    that case the old HOTR config is syntactically valid but unusable, so boot
    autoconfiguration must rescan instead of treating it as complete.
    """
    if not os.path.isfile(LIGHTGUNS_FILE):
        return False
    try:
        paths = []
        with open(LIGHTGUNS_FILE) as config:
            for line in config:
                line = line.strip()
                if line.startswith("/dev/"):
                    paths.append(line)
        return bool(paths) and all(os.path.exists(path) for path in paths)
    except OSError:
        return False


def _get_by_path(by_id_path):
    """
    Resolve a /dev/serial/by-id or /dev/hotr link to the actual tty node.
    HOTR requires the device node itself rather than a /dev/serial symlink.
    """
    actual = os.path.realpath(by_id_path)
    return actual


def _stable_links_for(device_path):
    """Return stable links which resolve to the selected tty node.

    The HOTR config deliberately receives the real /dev/ttyUSB* or
    /dev/ttyACM* node, but reporting the links here makes it possible to
    verify which persistent USB identity led to that node.
    """
    actual = os.path.realpath(device_path)
    links = []
    for directory in (HOTR_SYMLINK_DIR,
                      SERIAL_BY_ID_DIR,
                      SERIAL_BY_PATH_DIR):
        for link in sorted(glob.glob(os.path.join(directory, "*"))):
            if os.path.islink(link) and os.path.realpath(link) == actual:
                links.append(link)
    return links


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
        for link in sorted(glob.glob(f"{HOTR_SYMLINK_DIR}/{gun_type}-gun*")):
            if _resolve(link):
                # The udev symlink points to ttyUSB; get the by-path equivalent.
                found.append((gun_type, _get_by_path(os.path.realpath(link))))
    return found


def detect_via_by_id():
    """
    Scan /dev/serial/by-id/ against all GUN_DEFINITIONS patterns.
    Returns list of (gun_type, by_path_path) sorted by type_num then name.
    """
    by_id_dir = SERIAL_BY_ID_DIR
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


def detect_hid_guns():
    """Return supported HID guns as (name, hidraw path, VID, PID).

    HID configuration is intentionally not synthesized yet: HOTR's HID
    blocks contain device-specific command settings which must be preserved
    from a user-created profile.  Discovery is still useful for diagnostics
    and for selecting those existing blocks.
    """
    found = []
    for node in sorted(glob.glob(os.path.join(HIDRAW_DIR, "hidraw*"))):
        name = os.path.basename(node)
        uevent = os.path.join(HID_SYSFS_DIR, name, "device", "uevent")
        values = {}
        try:
            with open(uevent) as source:
                for line in source:
                    if "=" in line:
                        key, value = line.strip().split("=", 1)
                        values[key] = value
        except OSError:
            continue
        hid_id = values.get("HID_ID", "").split(":")
        if len(hid_id) != 3:
            continue
        vid, pid = hid_id[1].lower().zfill(8)[-4:], hid_id[2].lower().zfill(8)[-4:]
        gun_name = HID_DEFINITIONS.get((vid, pid))
        if gun_name:
            found.append((gun_name, node, vid, pid))
    return found


def detect_mx24_hubs():
    """Find MX24 serial hubs without guessing their DIP-switch player IDs."""
    found = []
    if not os.path.isdir(SERIAL_BY_ID_DIR):
        return found
    for entry in sorted(os.listdir(SERIAL_BY_ID_DIR)):
        if not MX24_RE.search(entry):
            continue
        path = os.path.join(SERIAL_BY_ID_DIR, entry)
        if os.path.exists(path):
            found.append(_get_by_path(path))
    return found


def detect_sinden_inputs():
    """Report Sinden devices managed by Batocera's runtime.

    Batocera owns the camera/serial connection through LightgunMono and
    exposes a virtual ``Sinden lightgun`` input. HOTR must not open the same
    tty or rewrite the Sinden TCP/profile settings, so this is status-only.
    """
    found = []
    if os.path.isdir(INPUT_BY_ID_DIR):
        found.extend(
            os.path.join(INPUT_BY_ID_DIR, entry)
            for entry in sorted(os.listdir(INPUT_BY_ID_DIR))
            if "sinden" in entry.lower() and
            os.path.exists(os.path.join(INPUT_BY_ID_DIR, entry))
        )

    for pidfile in sorted(glob.glob(
            os.path.join(SINDEN_RUN_DIR,
                         "virtual-sindenlightgun-devices*.pid"))):
        try:
            with open(pidfile) as source:
                pid = int(source.read().strip())
            if os.path.isdir(f"/proc/{pid}"):
                found.append(f"{pidfile} (pid {pid})")
        except (OSError, ValueError):
            continue

    for config in sorted(glob.glob(
            os.path.join(SINDEN_RUN_DIR, "sinden", "p*",
                         "LightgunMono-*.exe.config"))):
        if os.path.isfile(config):
            found.append(config)

    return sorted(set(found))


# ---------------------------------------------------------------------------
# Config writers
# ---------------------------------------------------------------------------

def _read_existing_blocks():
    """Return existing HOTR gun blocks that are not managed by this scanner."""
    blocks = _read_all_blocks()
    if not blocks:
        return []

    managed_names = tuple(d["name"] for d in GUN_DEFINITIONS.values())
    preserved = []
    for block in blocks:
        name = block[2] if len(block) > 2 else ""
        managed_by_name = any(
            name == managed or name.startswith(managed + " ")
            for managed in managed_names
        )
        # Older generated files could contain unnamed serial blocks such as
        # "ttyUSB1" and "ttyUSB3". They are auto-managed serial entries, not
        # user HID/MX24/Sinden profiles, so remove them when a fresh serial
        # scan succeeds instead of carrying stale ports forward.
        managed_legacy_serial = any(
            re.match(r"^/?(?:dev/)?tty(?:USB|ACM)[0-9]+$", line.strip())
            for line in block
        )
        if not managed_by_name and not managed_legacy_serial:
            preserved.append(block)
    return preserved


def _read_all_blocks():
    """Read every lightgun block without classifying or changing it."""
    if not os.path.isfile(LIGHTGUNS_FILE):
        return []
    try:
        with open(LIGHTGUNS_FILE) as config:
            raw = config.read().splitlines()
    except OSError:
        return []

    blocks = []
    current = None
    for line in raw:
        if line.startswith("Light Gun #"):
            if current:
                blocks.append(current)
            current = [line]
        elif current is not None:
            if line == "END_OF_FILE":
                blocks.append(current)
                current = None
            else:
                current.append(line)
    if current:
        blocks.append(current)

    return blocks


def _write_all_blocks(blocks):
    """Write blocks without changing their settings or player numbering."""
    lines = ["Light Gun Data File V3", str(len(blocks))]
    for block in blocks:
        lines.extend(block)
    lines.append("END_OF_FILE")
    with open(LIGHTGUNS_FILE, "w") as config:
        config.write("\n".join(lines) + "\n")


def _replace_block_device_path(block, new_path):
    """Replace only the device path in a HOTR block."""
    try:
        start = block.index("END_GENERAL_SETTINGS") + 1
    except ValueError:
        return False
    device_re = re.compile(
        r"^/?(?:dev/)?(?:hidraw[0-9]+|tty(?:USB|ACM)[0-9]+)$"
    )
    for index in range(start, len(block)):
        if device_re.match(block[index].strip()):
            if block[index] != new_path:
                block[index] = new_path
                return True
            return False
    return False


def _refresh_manual_paths(blocks, hid_guns, mx24_hubs):
    """Refresh known HID/MX24 paths while retaining every other field."""
    changed = 0
    used = set()

    for gun_name, node, _vid, _pid in hid_guns:
        for index, block in enumerate(blocks):
            if index in used or len(block) < 3:
                continue
            if gun_name.casefold() in block[2].casefold():
                if _replace_block_device_path(block, node):
                    changed += 1
                used.add(index)
                break

    mx_blocks = [
        (index, block) for index, block in enumerate(blocks)
        if len(block) >= 3 and re.search(r"mx24|mayflash", block[2], re.IGNORECASE)
    ]
    for (index, block), node in zip(mx_blocks, mx24_hubs):
        if _replace_block_device_path(block, node):
            changed += 1

    return changed


def _renumber_block(block, index):
    """Renumber a preserved block without changing its HOTR settings."""
    result = list(block)
    if result:
        result[0] = f"Light Gun #{index}"
    if len(result) > 1 and result[1].isdigit():
        result[1] = str(index)
    try:
        general_end = result.index("END_GENERAL_SETTINGS")
        if general_end + 1 < len(result) and result[general_end + 1].isdigit():
            result[general_end + 1] = str(index)
    except ValueError:
        pass
    return result


def write_lightguns_hor(guns, preserved_blocks=None):
    preserved_blocks = preserved_blocks or []
    lines = ["Light Gun Data File V3", str(len(guns) + len(preserved_blocks))]
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
    for offset, block in enumerate(preserved_blocks, start=len(guns)):
        lines.extend(_renumber_block(block, offset))
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
        return NO_GUNS

    if not force and _config_has_guns() and _config_paths_available():
        print("hotr-autoconfig: existing gun config found, skipping "
              "(use --force to rescan)")
        return 0

    if not force and _config_has_guns():
        print("hotr-autoconfig: saved device path is missing, rescanning")

    guns = detect_guns()
    hid_guns = detect_hid_guns()
    mx24_hubs = detect_mx24_hubs()
    sinden_inputs = detect_sinden_inputs()
    preserved_blocks = _read_existing_blocks()

    if not guns:
        all_blocks = _read_all_blocks()
        manual_paths = _refresh_manual_paths(all_blocks, hid_guns, mx24_hubs)
        if manual_paths:
            try:
                _write_all_blocks(all_blocks)
            except OSError as error:
                print(f"hotr-autoconfig: configuration error: {error}")
                return CONFIG_ERROR
            print(f"hotr-autoconfig: refreshed {manual_paths} manual device path(s)")

        if hid_guns or mx24_hubs or sinden_inputs:
            print("hotr-autoconfig: Batocera-managed/manual gun support detected; "
                  "preserved existing settings")
            return 0

        if force:
            # Never erase manually configured HID/MX24/Sinden entries just
            # because udev is still settling or a device is temporarily
            # disconnected during boot.  A later explicit setup/rescan can
            # remove those entries through HOTR itself.
            if _config_has_guns():
                print("hotr-autoconfig: no serial guns detected — "
                      "preserving existing manual configuration")
            else:
                print("hotr-autoconfig: no supported guns detected — "
                      "leaving an empty/manual configuration")
        else:
            print("hotr-autoconfig: no supported guns detected, "
                  "leaving existing config")
        return NO_GUNS

    print(f"hotr-autoconfig: detected {len(guns)} gun(s):")
    for i, (gun_type, path) in enumerate(guns):
        d = GUN_DEFINITIONS[gun_type]
        print(f"  Player {i + 1}: {d['name']} -> {path}")
        for link in _stable_links_for(path):
            print(f"    stable identity: {link}")
    for name, path, vid, pid in hid_guns:
        print(f"  HID detected: {name} ({vid}:{pid}) -> {path}; "
              "preserving HOTR HID configuration")
        for link in sorted(glob.glob(os.path.join(INPUT_BY_ID_DIR, "*"))):
            if os.path.islink(link) and os.path.realpath(link) == os.path.realpath(path):
                print(f"    stable identity: {link}")
    for path in mx24_hubs:
        print(f"  MX24 hub detected: {path}; preserving DIP/player assignment")
        for link in _stable_links_for(path):
            print(f"    stable identity: {link}")
    for path in sinden_inputs:
        print(f"  Sinden virtual input detected: {path}; "
              "leaving Batocera mono/TCP settings untouched")

    manual_paths = _refresh_manual_paths(preserved_blocks, hid_guns, mx24_hubs)
    try:
        write_lightguns_hor(guns, preserved_blocks)
        if not preserved_blocks:
            write_players_hor(guns)
        else:
            print("hotr-autoconfig: preserved existing player assignments")
        if manual_paths:
            print(f"hotr-autoconfig: refreshed {manual_paths} manual device path(s)")
    except OSError as error:
        print(f"hotr-autoconfig: configuration error: {error}")
        return CONFIG_ERROR

    print("hotr-autoconfig: config written successfully")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"hotr-autoconfig: configuration error: {error}")
        sys.exit(CONFIG_ERROR)
