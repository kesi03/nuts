#!/usr/bin/env python
"""Build the combined scope index used to validate pages/*.yaml.

Two independent sources describe a Reason "scope" (a device that can be
mapped from a control surface):

  1. remote/remote-info/**.txt  - Reason's own scope definition. It gives
     the EXACT Scope line (manufacturer + model) and the COMPLETE list of
     remotables with their min/max and input type. This is the authority.

  2. Reason's factory .remotemap files - what real control surfaces
     actually map. This is a subset of (1) (a surface only maps what it
     uses), but it is the ONLY source for scopes that have no remote-info
     file - the Reason Main Mixer Channel is one of them - and it also
     carries the display name that goes in the "Map _Scope ..." line.

The output, remote/mapping/scope-index.json, is keyed by "<manufacturer>\t
<model>" - the exact pair that goes in the map's Scope line.
"""

import glob
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from scopedef import is_parameter

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
INFO_INDEX = os.path.join(REPO, 'remote', 'mapping', 'remote-info-index.json')
FACTORY_MAPS = os.path.join(
    os.environ.get('ProgramData', r'C:\ProgramData'),
    'Propellerhead Software', 'Remote', 'Maps')
OUT = os.path.join(REPO, 'remote', 'mapping', 'scope-index.json')
OUT_LIST = os.path.join(REPO, 'remote', 'mapping', 'scope-index.list.json')


def usable_targets(entry):
    """The targets of a scope that are real parameters."""
    names = set(entry.get('remotables') or {})
    names |= {t for t in (entry.get('factoryTargets') or []) if is_parameter(t)}
    return names

# Targets that are really LCD strings or a variation selector rather than a
# parameter. They are legal map targets but never a sane choice for a dial
# or a switch, so the validator warns about them instead of accepting them
# silently.
SELECTOR_PREFIXES = (
    'Display=', 'Flip=', 'Shift=', 'Active=', 'ControlSet=', 'Variation=',
    'Varation=', 'Keyboard Shortcut Variations=', 'Parameters=',
    'TheGroup=', 'Layer=', 'Target=', 'Dyn_vars=', 'Send_vars=', 'Mixer_vars=',
    'Knobs=', 'button_vars=', 'ShiftState=',
)


def is_lcd_string(target):
    """A quoted fragment - the factory maps use these to drive a display."""
    return target.startswith('"') and target.endswith('"')


def is_selector(target):
    return any(target.startswith(p) for p in SELECTOR_PREFIXES)


# The factory map folder also holds the maps WE deployed for our own
# surfaces. They are not factory maps - they are our own work, and they
# would poison the index (the Akai MPK Mini Play map even carries a
# "Rytmik" display name on the DMFC scope). They are skipped by their
# control surface identity, so a map of ours can never be mistaken for
# Reason's.
OWN_SURFACES = [
    ('Nuts', 'Nocturn'),
    ('Akai', 'MPK Mini Play'),
]


def is_own_surface(path):
    """True if the map belongs to a surface we deployed ourselves."""
    with open(path, encoding='utf-8', errors='replace') as f:
        manufacturer = model = None
        for _ in range(10):
            line = f.readline()
            if not line:
                return False
            line = line.rstrip('\r\n')
            if line.startswith('Control Surface Manufacturer\t'):
                manufacturer = line.split('\t', 1)[1].strip()
            elif line.startswith('Control Surface Model\t'):
                model = line.split('\t', 1)[1].strip()
                break
        if manufacturer is None or model is None:
            return False
        # The model name may carry a suffix ("MPK Mini Play (players)"),
        # so the match is on the prefix.
        return any(manufacturer == m and model.startswith(md)
                   for m, md in OWN_SURFACES)


def load_factory_scopes():
    """(manufacturer, model) -> {'display': str, 'targets': set}."""
    scopes = {}
    if not os.path.isdir(FACTORY_MAPS):
        return scopes

    for path in sorted(glob.glob(os.path.join(FACTORY_MAPS, '**', '*.remotemap'),
                                 recursive=True)):
        if is_own_surface(path):
            continue
        scope = None
        with open(path, encoding='utf-8', errors='replace') as f:
            for line in f:
                line = line.rstrip('\r\n')
                if line.startswith('Scope\t'):
                    parts = line.split('\t')
                    if len(parts) >= 3:
                        scope = (parts[1].strip(), parts[2].strip())
                        scopes.setdefault(scope, {'display': None, 'targets': set()})
                    continue
                if not scope or not line.startswith('Map\t'):
                    continue
                parts = line.split('\t')
                if len(parts) < 4:
                    continue
                item = parts[1].strip()
                target = parts[3].strip()
                if item == '_Scope':
                    display = target.strip('"')
                    if scopes[scope]['display'] is None:
                        scopes[scope]['display'] = display
                    continue
                scopes[scope]['targets'].add(target)
    return scopes


def main():
    with open(INFO_INDEX, encoding='utf-8') as f:
        info = json.load(f)

    factory = load_factory_scopes()

    index = {}

    for key, entry in info.items():
        man, model = key.split('\t', 1)
        index[key] = {
            'manufacturer': man,
            'model': model,
            'display': None,
            'remotables': {r['name']: {'min': r['min'], 'max': r['max'],
                                       'input': r['input'], 'output': r['output']}
                           for r in entry.get('remotables') or []},
            'factoryTargets': [],
            'sources': ['remote-info'],
        }

    for (man, model), data in factory.items():
        key = '%s\t%s' % (man, model)
        if key not in index:
            index[key] = {
                'manufacturer': man,
                'model': model,
                'display': None,
                'remotables': {},
                'factoryTargets': [],
                'sources': ['factory-maps'],
            }
        else:
            if 'factory-maps' not in index[key]['sources']:
                index[key]['sources'].append('factory-maps')
        index[key]['display'] = data['display']
        index[key]['factoryTargets'] = sorted(data['targets'])

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, 'w', encoding='utf-8') as f:
        json.dump(index, f, indent=1, ensure_ascii=False, sort_keys=True)

    # A companion file in a shape PowerShell can read. ConvertFrom-Json is
    # case-insensitive about property names and refuses a document with two
    # keys that differ only in case - and Reason has scopes like
    # "se.propellerheads.PX7" and "se.propellerheads.px7". The dictionary
    # form above is the one Python wants; this list form is the one the
    # PowerShell checker wants.
    flat = {
        'scopes': [
            {
                'key': key,
                'manufacturer': entry['manufacturer'],
                'model': entry['model'],
                'display': entry['display'],
                'targets': sorted(usable_targets(entry)),
            }
            for key, entry in sorted(index.items())
        ],
    }
    with open(OUT_LIST, 'w', encoding='utf-8') as f:
        json.dump(flat, f, indent=1, ensure_ascii=False)

    both = sum(1 for v in index.values() if len(v['sources']) == 2)
    info_only = sum(1 for v in index.values() if v['sources'] == ['remote-info'])
    maps_only = sum(1 for v in index.values() if v['sources'] == ['factory-maps'])
    print('Wrote %s' % os.path.relpath(OUT, REPO))
    print('Wrote %s' % os.path.relpath(OUT_LIST, REPO))
    print('  %d scopes  (remote-info + factory maps: %d, remote-info only: %d, '
          'factory maps only: %d)' % (len(index), both, info_only, maps_only))


if __name__ == '__main__':
    main()
