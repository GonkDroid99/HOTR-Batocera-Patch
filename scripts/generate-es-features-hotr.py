#!/usr/bin/env python3
"""Clone Batocera's stock DuckStation/PCSX2 ES features for HOTR cores.

This avoids maintaining a tiny custom feature list which hides all normal PCSX2
advanced settings. It copies the stock feature definitions from the installed
Batocera version and only renames the emulator/core plus adds the HOTR output
switch.
"""
from copy import deepcopy
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

SOURCE = Path("/usr/share/emulationstation/es_features.cfg")
DEST = Path("/userdata/system/configs/emulationstation/es_features_hotr.cfg")

if not SOURCE.exists():
    raise SystemExit(f"Stock ES features not found: {SOURCE}")

src_root = ET.parse(SOURCE).getroot()
out_root = ET.Element("features")


def clone_core(emulator_name: str, stock_core: str, new_emulator: str, new_core: str, setting: str, label: str):
    src_emulator = src_root.find(f".//emulator[@name='{emulator_name}']")
    if src_emulator is None:
        raise SystemExit(f"Could not find stock emulator '{emulator_name}' in {SOURCE}")

    emu = deepcopy(src_emulator)
    emu.set("name", new_emulator)

    cores = emu.find("cores")
    if cores is None:
        raise SystemExit(f"Stock emulator '{emulator_name}' has no <cores> section")

    chosen = None
    for core in list(cores):
        if core.get("name") == stock_core:
            chosen = core
        else:
            cores.remove(core)

    if chosen is None:
        remaining = list(cores)
        if len(remaining) == 1:
            chosen = remaining[0]
        else:
            raise SystemExit(f"Could not identify stock core '{stock_core}' for '{emulator_name}'")

    chosen.set("name", new_core)
    features_attr = chosen.get("features", "").split()
    if "use_guns" not in features_attr:
        features_attr.append("use_guns")
    chosen.set("features", " ".join(x for x in features_attr if x))

    # Avoid adding it twice if this script is adapted/re-run against an already-custom source.
    for feature in chosen.findall("feature"):
        if feature.get("value") == setting:
            break
    else:
        feature = ET.SubElement(chosen, "feature", {
            "name": label,
            "group": "LIGHT GUN",
            "value": setting,
            "description": "Send emulator output events to MameOutputSender and Hook of the Reaper.",
        })
        ET.SubElement(feature, "choice", {"name": "Enabled", "value": "true"})
        ET.SubElement(feature, "choice", {"name": "Disabled", "value": "false"})

    out_root.append(emu)


clone_core("duckstation", "duckstation", "duckstation", "duckstation-lightgun", "duckstation_mamehooker", "MAMEHOOKER / HOTR OUTPUT")
clone_core("pcsx2", "pcsx2", "pcsx2-lightgun", "pcsx2-lightgun", "pcsx2_mamehooker", "MAMEHOOKER / HOTR OUTPUT")

DEST.parent.mkdir(parents=True, exist_ok=True)
ET.indent(out_root, space="  ")
ET.ElementTree(out_root).write(DEST, encoding="UTF-8", xml_declaration=True)
print(f"Wrote {DEST}")
