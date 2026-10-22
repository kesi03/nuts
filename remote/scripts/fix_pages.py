#!/usr/bin/env python
"""Resolve the pages/*.yaml templates against Reason's scope definitions.

WHY THIS EXISTS
---------------
A .remotemap binds one item to exactly one remotable per scope, and Reason
refuses to load a control surface when the same remotable is mapped twice
inside one scope. The templates were written as VIEWS - each page showed
the parameters of a device section - so the same parameter appears on
several pages, and the shared controls (Speed Dial, its click, the
Crossfader) were pointed at parameters that the pages also carry.

This tool rewrites the templates so that every scope has:

  * exactly one slot per target,
  * only targets that really exist in the scope,
  * the shared controls owning their target outright.

It does NOT decide what should fill a slot it has to empty. That is a
design decision, so the holes are reported and left for a human.

THE RULES
---------
1. The shared controls own their target. A page slot that wants the same
   target loses.
2. Inside one page, a target that is both a dial and a switch keeps the
   switch when it is an on/off parameter (a switch can only send 0 or
   127), otherwise it keeps the dial. Ties keep the lower control number.
3. Across pages, the page whose NAME matches the target keeps it (e.g.
   "Sidechain Solo" stays on the Sidechain page). With no name match the
   earliest page keeps it.
4. Targets that do not exist in the scope are renamed to the closest real
   remotable when there is an obvious one, and removed otherwise.

Usage:
    python remote/scripts/fix_pages.py            # rewrite the templates
    python remote/scripts/fix_pages.py --dry-run  # report only
"""

import argparse
import glob
import os
import re
import sys

try:
    import yaml
except ImportError:
    sys.exit('PyYAML is required: pip install pyyaml')

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pageio
import scopedef
from reason_workbook import load_scope_index

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PAGES_DIR = os.path.join(REPO, 'pages')

SHARED_ITEMS = {'SD': 'Speed Dial', 'SDB': 'Speed Dial Button', 'F': 'Crossfader'}

# Remotables that are not parameters and must never be mapped.
NOT_A_PARAMETER = re.compile(
    r'^(device name|note on indicator|pitch bend|mod wheel|channel name|'
    r'vu meter|insert fx patch name)$', re.IGNORECASE)


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
    return mx not in ('', '0', '1')


def page_words(page_name):
    return set(re.findall(r'[a-z0-9]+', page_name.lower()))


def target_words(target):
    return set(re.findall(r'[a-z0-9]+', target.lower()))


def name_match_score(page_name, target):
    """How well a page's name matches a target's name."""
    pw = page_words(page_name)
    tw = target_words(target)
    if not pw or not tw:
        return 0
    if pw & tw:
        return len(pw & tw)
    # "FILTERAMP" vs "Filter Amp" - the page name may be run together.
    flat = re.sub(r'[^a-z0-9]', '', page_name.lower())
    if flat and flat in re.sub(r'[^a-z0-9]', '', target.lower()):
        return 2
    return 0


def slot_kind(entry):
    """'toggle' or 'value' for a scope's remotable."""
    if entry is None:
        return None
    return 'toggle' if is_toggle(entry) else 'value'


def _word_ok(haystack, needle):
    """Is the needle sitting on word boundaries inside the haystack?"""
    start = 0
    while True:
        i = haystack.find(needle, start)
        if i == -1:
            return False
        before = haystack[i - 1] if i > 0 else ' '
        after = haystack[i + len(needle)] if i + len(needle) < len(haystack) else ' '
        if not before.isalnum() and not after.isalnum():
            return True
        start = i + 1


def close_match(target, known):
    """The real remotable a mistyped target most likely meant.

    The candidates are tried shortest first, so a numbered family like
    Kong's "Drum 1 Level" / "Drum 11 Level" resolves to the first one.
    A candidate must sit on word boundaries and must be a real word, so
    "Aux 1 Send" does not match the "1" inside it.
    """
    low = target.lower()
    for name in known:
        if name.lower() == low:
            return name
    # normalise: drop spaces, underscores and punctuation
    flat = re.sub(r'[^a-z0-9]', '', low)
    for name in sorted(known, key=lambda n: (len(n), n)):
        if re.sub(r'[^a-z0-9]', '', name.lower()) == flat:
            return name
    # one contains the other, on word boundaries
    if len(target) >= 3:
        for name in sorted(known, key=lambda n: (len(n), n)):
            nl = name.lower()
            if len(nl) < 3 or not any(c.isalpha() for c in nl):
                continue
            if low in nl and _word_ok(nl, low):
                return name
            if nl in low and _word_ok(low, nl):
                return name
    return None


# The natural parameter for each shared control. A shared control either
# keeps a target the scope really has, or it gets one of these, or it goes.
PREFERRED_TARGETS = {
    'F': ['Pan', 'Panning'],
    'SD': ['Master Volume', 'Master Level', 'Volume', 'Level',
           'Main Level'],
    'SDB': ['Enabled', 'Bypass', 'On', 'Enable'],
}


def fix_template(doc, scope_index, report):
    scope = doc.get('scope') or {}
    man = (scope.get('manufacturer') or '').strip()
    model = (scope.get('model') or '').strip()
    key = '%s\t%s' % (man, model)

    entry = scope_index.get(key)
    if entry is None:
        report.append('scope %r is not a known Reason scope - skipped' % key)
        return False

    remotables = entry.get('remotables') or {}
    known = scopedef.usable_targets(entry)

    pages = doc.get('pages') or {}
    if not pages:
        return False

    # ---- 1. rename or drop the targets that do not exist ---------------
    shared_block = doc.get('controls') or {}

    def resolve(target):
        if not target or target in known:
            return target
        fix = close_match(target, known)
        if fix:
            return fix
        return None

    for page_name, page in pages.items():
        for section in ('encoders', 'buttons'):
            block = (page or {}).get(section) or {}
            for ckey, ctrl in list(block.items()):
                if not isinstance(ctrl, dict):
                    continue
                target = pageio.target_of(ctrl)
                if not target or target in known:
                    continue
                fix = resolve(target)
                if fix:
                    ctrl['target'] = fix
                    report.append('%s/%s/%s: %r -> %r'
                                  % (page_name, section, ckey, target, fix))
                else:
                    del block[ckey]
                    report.append('%s/%s/%s: %r does not exist in the scope '
                                  '- removed' % (page_name, section, ckey, target))

    for ckey, ctrl in list(shared_block.items()):
        if not isinstance(ctrl, dict):
            continue
        target = pageio.target_of(ctrl)
        if not target or target in known:
            continue
        # A shared control does not get an arbitrary rename: it either
        # keeps a target the scope really has, or it gets the natural one
        # for that control, or it goes.
        fix = None
        for candidate in PREFERRED_TARGETS.get(ckey, []):
            if candidate in remotables:
                fix = candidate
                break
        if fix:
            ctrl['target'] = fix
            report.append('shared %s: %r does not exist - now %r'
                          % (ckey, target, fix))
        else:
            del shared_block[ckey]
            report.append('shared %s: %r does not exist in the scope - removed'
                          % (ckey, target))

    # ---- 2. the shared controls own their target -----------------------
    # If two shared controls want the same target, or a shared control
    # loses its target, it gets the natural parameter for that control
    # (the Crossfader wants Pan, the Speed Dial wants the level, its click
    # wants the on/off) - as long as the scope really has one and nothing
    # else in the scope uses it.

    def scope_parameters():
        return [name for name in remotables
                if not NOT_A_PARAMETER.match(name)]

    def free_target(ckey, used):
        for candidate in PREFERRED_TARGETS.get(ckey, []):
            if candidate in remotables and candidate not in used:
                return candidate
        return None

    shared_targets = {}
    for ckey, ctrl in sorted(shared_block.items()):
        target = pageio.target_of(ctrl)
        if not target:
            continue
        if target in shared_targets:
            other = shared_targets[target]
            used = set(shared_targets)
            replacement = free_target(ckey, used)
            if replacement:
                ctrl['target'] = replacement
                report.append('shared %s and shared %s both wanted %r - %s '
                              'now points at %r'
                              % (other, ckey, target, ckey, replacement))
                shared_targets[replacement] = ckey
                continue
            report.append('shared %s and shared %s both want %r - the second '
                          'loses' % (other, ckey, target))
            del shared_block[ckey]
            continue
        shared_targets[target] = ckey

    # A shared control left without a target gets the natural one.
    used_anywhere = set(shared_targets)
    for page_name, page in pages.items():
        for section in ('encoders', 'buttons'):
            for ckey, ctrl in ((page or {}).get(section) or {}).items():
                if isinstance(ctrl, dict):
                    used_anywhere.add(pageio.target_of(ctrl))
    for ckey, ctrl in sorted(shared_block.items()):
        if pageio.target_of(ctrl):
            continue
        replacement = free_target(ckey, used_anywhere)
        if replacement:
            ctrl['target'] = replacement
            used_anywhere.add(replacement)
            report.append('shared %s had no target - now %r'
                          % (ckey, replacement))

    shared_targets = {}
    for ckey, ctrl in sorted(shared_block.items()):
        target = pageio.target_of(ctrl)
        if target:
            shared_targets[target] = ckey

    for page_name, page in pages.items():
        for section in ('encoders', 'buttons'):
            block = (page or {}).get(section) or {}
            for ckey, ctrl in list(block.items()):
                if not isinstance(ctrl, dict):
                    continue
                target = pageio.target_of(ctrl)
                if target in shared_targets:
                    # The shared control owns the target outright.
                    del block[ckey]
                    report.append('%s/%s/%s: %r is already the shared %s - '
                                  'removed'
                                  % (page_name, section, ckey, target,
                                     SHARED_ITEMS.get(shared_targets[target],
                                                      shared_targets[target])))

    # The shared controls must not point at the same target as each other.
    seen_shared = {}
    for ckey, ctrl in sorted(shared_block.items()):
        target = pageio.target_of(ctrl)
        if not target:
            continue
        if target in seen_shared:
            report.append('shared %s and shared %s both want %r - the second '
                          'loses' % (seen_shared[target], ckey, target))
            del shared_block[ckey]
            shared_targets.pop(target, None)
        else:
            seen_shared[target] = ckey

    # ---- 3. resolve the duplicates between and inside the pages --------
    # Where does each target live?
    homes = {}
    for slot, (page_name, page) in enumerate(pages.items()):
        for section in ('encoders', 'buttons'):
            block = (page or {}).get(section) or {}
            for ckey, ctrl in block.items():
                if not isinstance(ctrl, dict):
                    continue
                target = pageio.target_of(ctrl)
                if not target:
                    continue
                homes.setdefault(target, []).append(
                    (slot, page_name, section, ckey))

    def kind_of(target):
        return slot_kind(remotables.get(target))

    for target, places in sorted(homes.items()):
        if len(places) < 2:
            continue
        # Rule 2: inside one page, a switch beats a dial for an on/off
        # parameter, otherwise the dial wins. The lowest control number
        # settles a tie.
        by_page = {}
        for p in places:
            by_page.setdefault(p[1], []).append(p)

        def page_rank(page_name):
            group = by_page[page_name]
            section_rank = {'encoders': 0, 'buttons': 1}
            if len(group) == 1:
                return (0, 0)
            kind = kind_of(target)
            # An on/off parameter belongs on a switch.
            prefer = 'buttons' if kind == 'toggle' else 'encoders'
            return (0 if group[0][2] == prefer else 1,
                    min(int(p[3][1:]) for p in group))

        # Rule 3: the page whose NAME matches the target keeps it, and
        # otherwise the earliest page does.
        def rank(place):
            slot, page_name, section, ckey = place
            group = by_page[page_name]
            best_in_page = min(group, key=lambda p: (
                0 if p[2] == ('buttons' if kind_of(target) == 'toggle'
                              else 'encoders') else 1,
                int(p[3][1:])))
            return (page_rank(page_name), slot, int(ckey[1:]))

        ordered = sorted(places, key=rank)
        winner = ordered[0]
        for loser in ordered[1:]:
            block = (pages[loser[1]].get(loser[2]) or {})
            ctrl = block.get(loser[3])
            if ctrl is not None:
                block.pop(loser[3], None)
            report.append('%r: kept on %s/%s, removed from %s/%s'
                          % (target, winner[1], winner[3], loser[1], loser[3]))

    # ---- 4. drop the empty pages ---------------------------------------
    for page_name in list(pages.keys()):
        page = pages[page_name]
        has_any = False
        for section in ('encoders', 'buttons'):
            if (page or {}).get(section):
                has_any = True
        if not has_any:
            del pages[page_name]
            report.append('page %r is now empty - removed' % page_name)

    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--only')
    args = ap.parse_args()

    scope_index = load_scope_index()

    total = 0
    for path in sorted(glob.glob(os.path.join(PAGES_DIR, '*.yaml'))):
        name = os.path.basename(path)
        if args.only and args.only.lower() not in name.lower():
            continue
        doc = pageio.load_page(path)

        report = []
        changed = fix_template(doc, scope_index, report)
        if not changed:
            print('%-40s SKIPPED' % name)
            for line in report:
                print('    %s' % line)
            continue

        total += len(report)
        print('%-40s %d change(s)' % (name, len(report)))
        for line in report:
            print('    %s' % line)

        if not args.dry_run:
            pageio.dump_page(doc, path)

    print()
    print('%d change(s) in total%s'
          % (total, ' (dry run - nothing written)' if args.dry_run else ''))


if __name__ == '__main__':
    main()
