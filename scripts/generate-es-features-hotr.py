#!/usr/bin/env python3
"""Create HOTR ES features by cloning Batocera stock features and merging the
known-working PCSX2 LightGun option set from the old Batocera package.
"""
from copy import deepcopy
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

SOURCE = Path('/usr/share/emulationstation/es_features.cfg')
DEST = Path('/userdata/system/configs/emulationstation/es_features_hotr.cfg')
LEGACY = Path(sys.argv[1]) if len(sys.argv) > 1 else Path('/userdata/system/hotr/install/pcsx2_legacy_features.xml')

if not SOURCE.exists():
    raise SystemExit(f'Stock ES features not found: {SOURCE}')
stock = ET.parse(SOURCE).getroot()
out = ET.Element('features')

def find_core(emu_name, preferred):
    emu = stock.find(f".//emulator[@name='{emu_name}']")
    if emu is None:
        raise RuntimeError(f"stock emulator '{emu_name}' not found")
    clone = deepcopy(emu)
    cores = clone.find('cores')
    if cores is None:
        raise RuntimeError(f"stock emulator '{emu_name}' has no cores")
    selected = None
    for c in list(cores):
        if c.get('name') == preferred:
            selected = c
        else:
            cores.remove(c)
    if selected is None:
        remain=list(cores)
        if len(remain)==1: selected=remain[0]
        else: raise RuntimeError(f"core '{preferred}' not found for '{emu_name}'")
    return clone, selected

def add_output_switch(core, setting):
    if any(x.get('value') == setting for x in core.findall('feature')):
        return
    f=ET.SubElement(core,'feature',{
      'name':'MAMEHOOKER / HOTR OUTPUT','group':'LIGHT GUN','value':setting,
      'description':'Send emulator output events to MameOutputSender and Hook of the Reaper.'})
    ET.SubElement(f,'choice',{'name':'Enabled','value':'true'})
    ET.SubElement(f,'choice',{'name':'Disabled','value':'false'})

def append_feature_flags(core, flags):
    current=core.get('features','').split()
    for flag in flags:
        if flag and flag not in current: current.append(flag)
    core.set('features',' '.join(current))

# DuckStation: clone every stock option, rename only the core.
duck, dcore = find_core('duckstation','duckstation')
duck.set('name','duckstation')
dcore.set('name','duckstation-lightgun')
append_feature_flags(dcore,['use_guns'])
add_output_switch(dcore,'duckstation_mamehooker')
out.append(duck)

# PCSX2: start from current Batocera 43 PCSX2 options.
pcsx, pcore = find_core('pcsx2','pcsx2')
pcsx.set('name','pcsx2-lightgun')
pcore.set('name','pcsx2-lightgun')
append_feature_flags(pcore,['use_guns'])

# Merge the old known-working LightGun package's 31 custom options. Current
# stock options win when the same setting key exists, so this also survives
# small Batocera 43 option changes.
if LEGACY.exists():
    legacy=ET.parse(LEGACY).getroot()
    append_feature_flags(pcore, legacy.get('features','').split())
    existing={f.get('value') for f in pcore.findall('feature')}
    for feature in legacy.findall('feature'):
        if feature.get('value') not in existing:
            pcore.append(deepcopy(feature)); existing.add(feature.get('value'))
add_output_switch(pcore,'pcsx2_mamehooker')
out.append(pcsx)

DEST.parent.mkdir(parents=True, exist_ok=True)
ET.indent(out,space='  ')
ET.ElementTree(out).write(DEST,encoding='UTF-8',xml_declaration=True)
print(f'Wrote {DEST}')
