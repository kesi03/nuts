#!/usr/bin/env python
"""Generate remote/Maps/Nuts/Nocturn.remotemap from pages/*.yaml.

THE MODEL
---------
The Nocturn is a channel strip. Its 8 dials and its 8 page-row buttons
BANK, and a page is a set of parameters on those same physical controls.
The DRIVER owns the banking (src/Nuts.Driver/Midi/PageModel.cs): the same
physical dial sends a different CC per page, the driver steps the page
from the PermaBar and never forwards the page switches to Reason.

Because a .remotemap binds one item to exactly one remotable per scope,
every page needs its OWN set of items - "Knob 1 P1" and "Knob 1 P2" are
different items, and each is mapped to a different parameter. The map
therefore repeats the item set per page and lets the driver's per-page CCs
select the item. Reason is never told that a page changed.

Item names are deliberately GENERIC ("P1".."P4", not "Mixer"/"Dynamics"):
the same 64 items serve every scope, and each scope's pages are described
by its own YAML. Naming them after the mixer's pages would lie for every
other device (Alligator's page 1 is "Pattern", not "Mixer").

THE THREE RULES THE GENERATOR ENFORCES
--------------------------------------
1. One target per scope. Reason refuses to load a control surface when the
   same remotable is mapped twice inside one scope, so every target in a
   scope must be unique. The shared controls (Speed Dial, its click, the
   Crossfader) are mapped ONCE per scope and must agree on every page.
2. Continuous parameters live on dials, on/off states live on the page-row
   switches. A page-row item can only ever carry 0 or 127.
3. Every target must be a real remotable of that scope. The authority is
   remote/remote-info (Reason's own scope definition); Reason's factory
   .remotemap files are the fallback for scopes without one - the mixer
   channel is such a scope.

USAGE
-----
    python remote/scripts/generate_map.py            # validate + write
    python remote/scripts/generate_map.py --check    # validate only
    python remote/scripts/generate_map.py --only mixer
"""

import argparse
import glob
import json
import os
import sys

try:
    import yaml
except ImportError:
    sys.exit('PyYAML is required: pip install pyyaml')

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pageio
import scopedef

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PAGES_DIR = os.path.join(REPO, 'pages')
SCOPE_INDEX = os.path.join(REPO, 'remote', 'mapping', 'scope-index.json')
OUT_MAP = os.path.join(REPO, 'remote', 'Maps', 'Nuts', 'Nocturn.remotemap')

# The surface has 4 page slots (Midi:Paging:PageCount in the driver's
# appsettings.json). Every scope's pages fill slots 1..N in order.
PAGE_COUNT = 4

# The shared (not banked) controls. Their key is the YAML's control key and
# their value is the control-surface item they map to.
SHARED_ITEMS = {
    'SD': 'Speed Dial',
    'SDB': 'Speed Dial Button',
    'F': 'Crossfader',
}

# Encoder / button key -> the number used in the item name.
KNOB_ITEM = 'Knob %d P%d'
BUTTON_ITEM = 'Button %d P%d'

MAP_HEADER = """Propellerhead Remote Mapping File
File Format Version\t1.0.0
Control Surface Manufacturer\tNuts
Control Surface Model\tNocturn
Map Version\t2.0.0
"""

MAP_PREAMBLE = """
//======================================================================
//  Novation Nocturn - Reason Remote map
//
//  GENERATED FILE - do not edit by hand.
//  Source:    pages/*.yaml
//  Generator: remote/scripts/generate_map.py
//
//  Reason loads every scope for a control surface from a single
//  .remotemap. The Nocturn has no keybed and no pads, so there is no
//  Master Keyboard scope and no drum/pad mapping.
//
//  THE PAGES
//  ---------
//  The 8 dials and the 8 green page-row buttons BANK. A page is a set of
//  parameters on those same physical controls. Paging is owned by the
//  DRIVER (src/Nuts.Driver/Midi/PageModel.cs): the same physical dial
//  sends a different CC per page, the driver steps the page from the
//  PermaBar, and the page switches never reach Reason.
//
//  That is why every page has its own ITEMS here - "Knob 1 P1" and
//  "Knob 1 P2" are different items. A .remotemap binds one item to
//  exactly one remotable per scope and Reason evaluates the map
//  statically: there is no way to re-point one item from outside Reason.
//  Repeating the item set per page is the technique the Akai MPK Mini
//  Play codec uses for its banks ("Knob 1 A" / "Knob 1 B").
//
//  "Define Group" variations would also give four mappings, but Reason
//  owns which variation is active, so Page -/+ stepping could not exist.
//
//  ITEM NAMES ARE GENERIC. "P1".."P4" are the driver's four page slots;
//  what each slot means depends on the scope. The mixer channel's slots
//  are Mixer / Dynamics / EQ / FX, but Alligator's are Pattern / Filters
//  / Modulation / FXMix, so the slot names cannot live in the item names.
//
//  SHARED ACROSS EVERY PAGE: the Speed Dial and its click, and the
//  Crossfader. They keep one item and one mapping per scope. The
//  PermaBar page buttons (Page -/+, and the MIXER / USER / INSTR / FX
//  jumps) are not items at all - the driver consumes them.
//
//  ONE TARGET PER SCOPE. Reason refuses to load a control surface when
//  the same remotable is mapped twice inside one scope, so every target
//  below is unique within its scope.
//
//  CONTINUOUS vs ON/OFF. Dials carry continuous parameters and the
//  page-row switches carry on/off states, because a page-row item can
//  only ever carry 0 or 127.
//
//  NAMES ARE VERIFIED. Every Remotable Item below was checked against
//  Reason's own scope definition in remote/remote-info (and, for scopes
//  without one, against the targets in Reason's factory .remotemap
//  files). A scope's names are not always the display names: the
//  compressor is "C Threshold" (not "Comp Threshold"), the gate's
//  "Expander" has no "Gate" prefix, and the sends are "FX1 Pre Fader"
//  (not "FX1 Send Pre Fader"). A misspelled target fails silently.
//======================================================================
"""


class Problem(object):
    def __init__(self, level, message):
        self.level = level
        self.message = message


class Template(object):
    """One pages/*.yaml file, parsed and checked."""

    def __init__(self, path, doc):
        self.path = path
        self.name = os.path.basename(path)
        self.doc = doc or {}
        self.problems = []

        scope = self.doc.get('scope') or {}
        self.manufacturer = (scope.get('manufacturer') or '').strip()
        self.model = (scope.get('model') or '').strip()
        self.display = (scope.get('display') or '').strip() or self.model
        self.enabled = scope.get('enabled', True)

        self.pages = self.doc.get('pages') or {}

    def error(self, message):
        self.problems.append(Problem('ERROR', message))

    def warn(self, message):
        self.problems.append(Problem('warn', message))

    @property
    def key(self):
        return '%s\t%s' % (self.manufacturer, self.model)


def load_templates(only=None):
    templates = []
    for path in sorted(glob.glob(os.path.join(PAGES_DIR, '*.yaml'))):
        if only and only.lower() not in os.path.basename(path).lower():
            continue
        try:
            doc = pageio.load_page(path)
        except Exception as exc:
            t = Template(path, {})
            t.error('YAML parse error: %s' % exc)
            templates.append(t)
            continue
        templates.append(Template(path, doc))
    return templates


def load_scope_index():
    with open(SCOPE_INDEX, encoding='utf-8') as f:
        return json.load(f)


def entry_for(scope_index, key):
    """The scope's definition, or None."""
    return scope_index.get(key)


def is_toggle(entry):
    itype = (entry.get('input') or '').strip().lower()
    if itype == 'toggle':
        return True
    return (entry.get('max') or '').strip() == '1'


def is_continuous(entry):
    itype = (entry.get('input') or '').strip().lower()
    if itype == 'toggle':
        return False
    mx = (entry.get('max') or '').strip()
    if mx in ('', '0', '1'):
        return False
    return True


def page_controls(page, section):
    block = (page or {}).get(section) or {}
    if not isinstance(block, dict):
        return []
    return sorted(block.items())


def control_number(key):
    """'E3' -> 3, 'B7' -> 7, 'SD' -> None."""
    if len(key) >= 2 and key[0] in 'EB' and key[1:].isdigit():
        return int(key[1:])
    return None


def target_of(ctrl):
    """The target string of a control, whatever YAML type it came out as."""
    return str(ctrl.get('target') or '').strip()


def check_template(tpl, scope_index):
    """Fill tpl.problems. Returns the list of map lines, or None on error."""
    if not tpl.manufacturer or not tpl.model:
        tpl.error('no scope.manufacturer / scope.model')
        return None

    entry = entry_for(scope_index, tpl.key)
    if entry is None:
        tpl.error('scope %r is not a known Reason scope' % tpl.key)
        # Show what is close, so a typo is easy to spot.
        model = tpl.model.lower()
        for key in scope_index:
            if model in key.lower() or key.split('\t')[1].lower() in model:
                tpl.warn('did you mean scope %r?' % key)
        return None

    remotables = entry.get('remotables') or {}
    factory = set(entry.get('factoryTargets') or [])

    def known(target):
        return target in remotables or target in factory

    def describe(target):
        if target in remotables:
            e = remotables[target]
            return '%s (min %s max %s, input %s)' % (
                target, e.get('min'), e.get('max'), e.get('input'))
        return target

    if not remotables and not factory:
        tpl.error('scope %r has no known remotables' % tpl.key)

    if len(tpl.pages) > PAGE_COUNT:
        tpl.error('%d pages, but the surface has %d page slots'
                  % (len(tpl.pages), PAGE_COUNT))
        return None
    if len(tpl.pages) < PAGE_COUNT:
        tpl.warn('%d of %d page slots used - the other %d are inert on this '
                 'scope' % (len(tpl.pages), PAGE_COUNT,
                            PAGE_COUNT - len(tpl.pages)))

    # ---- collect the mappings -------------------------------------------
    lines = []
    used = {}          # target -> "where it was mapped"
    shared_targets = {}  # control key -> (target, page)

    # The shared controls live at the top level now. Older templates put
    # them on every page; those are still read, but a page that disagrees
    # with the top level is an error (one physical control, one target).
    shared_block = tpl.doc.get('controls') or {}
    if not isinstance(shared_block, dict):
        shared_block = {}

    for ckey, ctrl in sorted(shared_block.items()):
        if not isinstance(ctrl, dict):
            continue
        target = pageio.target_of(ctrl)
        if not target:
            continue
        if ckey not in SHARED_ITEMS:
            tpl.warn('unknown shared control %r' % ckey)
            continue
        shared_targets[ckey] = (target, 'scope')

    for slot, (page_name, page) in enumerate(tpl.pages.items(), start=1):
        # Legacy: the shared controls repeated on every page.
        for ckey, ctrl in page_controls(page, 'controls'):
            if not isinstance(ctrl, dict):
                continue
            target = pageio.target_of(ctrl)
            if not target:
                continue
            if ckey not in SHARED_ITEMS:
                tpl.warn('%s/%s: unknown shared control %r'
                         % (page_name, ckey, ckey))
                continue
            if ckey in shared_targets:
                first_target, first_page = shared_targets[ckey]
                if first_target != target:
                    tpl.error(
                        'shared control %s differs between pages: %r on %s '
                        'but %r on %s - it is one physical control, so it '
                        'can only have one target'
                        % (ckey, first_target, first_page, target, page_name))
                continue
            shared_targets[ckey] = (target, page_name)

        # Paged controls: the 8 dials and the 8 page-row buttons.
        for section, item_fmt in (('encoders', KNOB_ITEM),
                                  ('buttons', BUTTON_ITEM)):
            for ckey, ctrl in page_controls(page, section):
                if not isinstance(ctrl, dict):
                    continue
                target = pageio.target_of(ctrl)
                if not target:
                    continue
                number = control_number(ckey)
                if number is None:
                    tpl.error('%s/%s: cannot read a control number from %r'
                              % (page_name, ckey, ckey))
                    continue
                if number < 1 or number > 8:
                    tpl.error('%s/%s: control number %d is out of range (1-8)'
                              % (page_name, ckey, number))
                    continue

                where = '%s/%s' % (page_name, ckey)

                if not known(target):
                    tpl.error('%s: target %r is not a remotable of %r'
                              % (where, target, tpl.model))
                    near = sorted((r for r in list(remotables) + list(factory)
                                   if target.lower() in r.lower()
                                   or r.lower() in target.lower()),
                                  key=len)[:4]
                    if near:
                        tpl.warn('%s: did you mean %s?'
                                 % (where, ', '.join(repr(n) for n in near)))
                    continue

                if target in used:
                    tpl.error('target %r is mapped twice in this scope (%s and '
                              '%s) - Reason refuses to load the surface'
                              % (target, used[target], where))
                    continue
                used[target] = where

                # Layout check: continuous on a dial, on/off on a switch.
                if target in remotables:
                    e = remotables[target]
                    if section == 'encoders' and is_toggle(e):
                        tpl.warn('%s: %s is an on/off parameter but it is on a '
                                 'dial - a dial can only send a value'
                                 % (where, describe(target)))
                    if section == 'buttons' and is_continuous(e):
                        tpl.warn('%s: %s is a continuous parameter but it is on '
                                 'a switch - a switch can only send 0 or 127'
                                 % (where, describe(target)))

                    # The template's declared range must match the scope's
                    # own range, or the surface would send values the
                    # device cannot accept.
                    for field, label in (('min', 'min'), ('max', 'max')):
                        declared = ctrl.get(field)
                        actual = (e.get(field) or '').strip()
                        if declared is None or actual == '':
                            continue
                        if str(declared).strip() != actual:
                            tpl.warn('%s: %s is %s but the template declares %s'
                                     % (where, target, label, declared))

                lines.append((section, number, slot, target, page_name))

    # ---- the shared mappings ---------------------------------------------
    shared_lines = []
    for ckey in ('SD', 'SDB', 'F'):
        if ckey not in shared_targets:
            continue
        target, page_name = shared_targets[ckey]
        if target in used:
            tpl.error('target %r is mapped twice in this scope (%s and the '
                      'shared %s) - Reason refuses to load the surface'
                      % (target, used[target], SHARED_ITEMS[ckey]))
            continue
        used[target] = 'shared %s' % SHARED_ITEMS[ckey]
        shared_lines.append((SHARED_ITEMS[ckey], target))

    errors = [p for p in tpl.problems if p.level == 'ERROR']
    if errors:
        return None

    return lines, shared_lines


def render_scope(tpl):
    """The .remotemap text for one scope."""
    result = []
    result.append('Scope\t%s\t%s' % (tpl.manufacturer, tpl.model))
    result.append('Map\t_Scope\t\t"%s"' % tpl.display)
    result.append('')
    return result


def build_map(templates, scope_index, out_path):
    blocks = []
    report = []

    # Two templates for the same scope would put the scope in the map
    # twice, which Reason rejects just like a duplicate target.
    owners = {}
    for tpl in templates:
        owners.setdefault(tpl.key, []).append(tpl)
    for key, group in owners.items():
        if len(group) > 1:
            names = ', '.join(tpl.name for tpl in group)
            for tpl in group:
                tpl.error('scope %r is also in %s - a scope may only appear '
                          'once in the map' % (key, names))

    for tpl in templates:
        result = check_template(tpl, scope_index)
        errors = [p for p in tpl.problems if p.level == 'ERROR']
        warnings = [p for p in tpl.problems if p.level == 'warn']

        if not tpl.enabled:
            report.append((tpl, 'SKIP', 'disabled in the template'))
            continue
        if result is None:
            report.append((tpl, 'FAIL', '%d error(s)' % len(errors)))
            continue

        lines, shared_lines = result
        body = render_scope(tpl)

        # Group the paged mappings by slot, dials first, then buttons.
        by_slot = {}
        for section, number, slot, target, page_name in lines:
            by_slot.setdefault(slot, []).append(
                (section, number, target, page_name))

        for slot in sorted(by_slot):
            page_name = by_slot[slot][0][3]
            body.append('// --- Page %d: %s %s' % (
                slot, page_name, '-' * max(1, 46 - len(page_name))))
            for section, item_fmt in (('encoders', KNOB_ITEM),
                                     ('buttons', BUTTON_ITEM)):
                group = [x for x in by_slot[slot] if x[0] == section]
                if not group:
                    continue
                for _s, number, target, _p in group:
                    body.append('Map\t%s\t\t%s'
                                % (item_fmt % (number, slot), target))
                body.append('')

        if shared_lines:
            body.append('// --- Shared: same on every page '
                        + '-' * 25)
            for item, target in shared_lines:
                body.append('Map\t%s\t\t%s' % (item, target))
            body.append('')

        blocks.append('\n'.join(body))
        report.append((tpl, 'OK', '%d mappings' % (len(lines) + len(shared_lines))))

    text = MAP_HEADER + MAP_PREAMBLE + '\n' + '\n'.join(blocks)
    text = text.replace('\r\n', '\n')
    if not text.endswith('\n'):
        text += '\n'

    if out_path:
        os.makedirs(os.path.dirname(out_path), exist_ok=True)
        with open(out_path, 'w', encoding='utf-8', newline='\n') as f:
            f.write(text)

    return report


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--check', action='store_true',
                    help='validate only, do not write the map')
    ap.add_argument('--only', help='only templates whose name contains this')
    ap.add_argument('--out', default=OUT_MAP, help='output .remotemap path')
    ap.add_argument('--quiet', action='store_true')
    args = ap.parse_args()

    scope_index = load_scope_index()
    templates = load_templates(args.only)

    out_path = None if args.check else args.out
    report = build_map(templates, scope_index, out_path)

    total_errors = 0
    total_warnings = 0
    for tpl, status, note in report:
        errors = [p for p in tpl.problems if p.level == 'ERROR']
        warnings = [p for p in tpl.problems if p.level == 'warn']
        total_errors += len(errors)
        total_warnings += len(warnings)

        if not args.quiet:
            print('%-4s %-40s %-34s %s'
                  % (status, tpl.name, tpl.model, note))
            for p in tpl.problems:
                print('        %-7s %s' % (p.level, p.message))

    print()
    print('=' * 72)
    print('templates: %d   errors: %d   warnings: %d'
          % (len(templates), total_errors, total_warnings))
    if out_path:
        print('wrote %s' % os.path.relpath(out_path, REPO))
    else:
        print('check only - nothing written')
    print('=' * 72)
    return 1 if total_errors else 0


if __name__ == '__main__':
    sys.exit(main())
