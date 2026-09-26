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

def clone_feature_target(emu_name, preferred_core=None):
    """Clone a stock emulator and return the node which owns its features.

    Batocera 43.1 DuckStation stores features directly on <emulator>, while
    PCSX2 stores them on a nested <core>. Support both layouts.
    """
    emu = stock.find(f".//emulator[@name='{emu_name}']")
    if emu is None:
        raise RuntimeError(f"stock emulator '{emu_name}' not found")
    clone = deepcopy(emu)
    cores = clone.find('cores')
    if cores is None:
        return clone, clone

    selected = None
    for c in list(cores):
        if c.get('name') == preferred_core:
            selected = c
        else:
            cores.remove(c)
    if selected is None:
        remain = list(cores)
        if len(remain) == 1:
            selected = remain[0]
        else:
            raise RuntimeError(f"core '{preferred_core}' not found for '{emu_name}'")
    return clone, selected

def add_output_switch(core, setting):
    if any(x.get('value') == setting for x in core.findall('feature')):
        return
    f=ET.SubElement(core,'feature',{
      'name':'MAMEHOOKER / HOTR OUTPUT','group':'LIGHT GUN','value':setting,
      'description':'Send emulator output events to MameOutputSender and Hook of the Reaper.'})
    ET.SubElement(f,'choice',{'name':'Enabled','value':'true'})
    ET.SubElement(f,'choice',{'name':'Disabled','value':'false'})



def add_hotr_button_feature(core, emulator, player, action, label, default_label):
    key = f"hotr_{emulator}_p{player}_{action}"
    if any(x.get('value') == key for x in core.findall('feature')):
        return
    f = ET.SubElement(core, 'feature', {
        'name': f'P{player} {label}',
        'group': f'HOTR P{player} CONTROLS',
        'value': key,
        'description': 'Map this emulator action to a friendly physical light-gun control. HOTR translates it to the detected gun SDL device.'
    })
    # Values remain stable logical identifiers; only the ES labels expose the
    # physical RS3 names confirmed during live testing. This lets additional
    # gun layouts reuse the same emulator-facing settings later.
    choices = [
        (f'Default ({default_label})', 'default'),
        ('Trigger', 'trigger'),
        ('Rear / Thumb', 'action'),
        ('Front Left', 'start'),
        ('Front Right', 'select'),
        ('Palm', 'sub1'),
        ('Stick Press', 'sub2'),
        ('D-Pad Up', 'up'),
        ('D-Pad Down', 'down'),
        ('D-Pad Left', 'left'),
        ('D-Pad Right', 'right'),
        ('Disabled', 'disabled'),
    ]
    for name, value in choices:
        ET.SubElement(f, 'choice', {'name': name, 'value': value})


def add_hotr_axis_feature(core, emulator, player, axis):
    key = f"hotr_{emulator}_p{player}_aim_{axis}"
    if any(x.get('value') == key for x in core.findall('feature')):
        return
    f = ET.SubElement(core, 'feature', {
        'name': f'P{player} AIM {axis.upper()}',
        'group': f'HOTR P{player} CONTROLS',
        'value': key,
        'description': f'Bind relative aiming to SDL Axis {0 if axis == "x" else 1}.'
    })
    ET.SubElement(f, 'choice', {'name': 'Normal (Default)', 'value': 'normal'})
    ET.SubElement(f, 'choice', {'name': 'Inverted', 'value': 'inverted'})
    ET.SubElement(f, 'choice', {'name': 'Disabled', 'value': 'disabled'})


def add_duckstation_hotr_controls(core):
    actions = [
        ('trigger', 'TRIGGER', 'Trigger'),
        ('shootoffscreen', 'SHOOT OFFSCREEN / RELOAD', 'Rear / Thumb'),
        ('a', 'GUNCON A', 'Front Left'),
        ('b', 'GUNCON B', 'Front Right'),
    ]
    for player in (1, 2):
        for action, label, default_label in actions:
            add_hotr_button_feature(core, 'duckstation', player, action, label, default_label)
        add_hotr_axis_feature(core, 'duckstation', player, 'x')
        add_hotr_axis_feature(core, 'duckstation', player, 'y')


def add_pcsx2_hotr_controls(core):
    actions = [
        ('trigger', 'TRIGGER', 'Trigger'),
        ('shootoffscreen', 'SHOOT OFFSCREEN', 'Disabled'),
        ('a', 'GUNCON A', 'Front Left'),
        ('b', 'GUNCON B', 'Front Right'),
        ('c', 'GUNCON C / PEDAL', 'Rear / Thumb'),
        ('recalibrate', 'RECALIBRATE', 'Palm'),
        ('start', 'GUNCON START', 'Stick Press'),
        ('select', 'GUNCON SELECT', 'Front Right'),
        ('up', 'GUNCON UP', 'D-Pad Up'),
        ('down', 'GUNCON DOWN', 'D-Pad Down'),
        ('left', 'GUNCON LEFT', 'D-Pad Left'),
        ('right', 'GUNCON RIGHT', 'D-Pad Right'),
    ]
    for player in (1, 2):
        for action, label, default_label in actions:
            add_hotr_button_feature(core, 'pcsx2', player, action, label, default_label)
        add_hotr_axis_feature(core, 'pcsx2', player, 'x')
        add_hotr_axis_feature(core, 'pcsx2', player, 'y')

def append_feature_flags(core, flags):
    current=core.get('features','').split()
    for flag in flags:
        if flag and flag not in current: current.append(flag)
    core.set('features',' '.join(current))

# DuckStation: clone every stock option and keep Batocera 43.1's direct emulator feature layout.
duck, dcore = clone_feature_target('duckstation')
# Keep the stock emulator name: es_systems_hotr selects emulator=duckstation
# and core=duckstation-lightgun only for configgen dispatch. Batocera 43.1's
# DuckStation feature options live directly on the emulator node.
duck.set('name','duckstation')
append_feature_flags(dcore,['use_guns'])
add_output_switch(dcore,'duckstation_mamehooker')
add_duckstation_hotr_controls(dcore)
out.append(duck)

# PCSX2: start from current Batocera 43 PCSX2 options.
pcsx, pcore = clone_feature_target('pcsx2','pcsx2')
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
add_pcsx2_hotr_controls(pcore)
out.append(pcsx)

DEST.parent.mkdir(parents=True, exist_ok=True)
ET.indent(out,space='  ')
ET.ElementTree(out).write(DEST,encoding='UTF-8',xml_declaration=True)
print(f'Wrote {DEST}')
