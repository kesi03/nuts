#!/usr/bin/env python
"""Reading and writing the pages/*.yaml templates.

The templates are hand-edited, so they are written in a compact flow style
that stays readable:

    pages:
      Mixer:
        encoders:
          E1: { name: encoder1, key: EncoderCcs, target: Width, min: 0, max: 127, input_type: Value }

This module is the single place that knows how to read and write them, so
the tools (fix_pages.py, generate_map.py) and a human editor agree on the
format.
"""

import re

import yaml

PLAIN = re.compile(r'^[A-Za-z0-9_][A-Za-z0-9 _./+-]*$')

# YAML 1.1 reads these words as booleans. A target called "On" or "Off"
# is a perfectly ordinary Reason remotable, so those words are quoted on
# the way out and turned back into strings on the way in.
BOOL_WORDS = {'y', 'n', 'yes', 'no', 'true', 'false', 'on', 'off'}


def load_page(path):
    with open(path, encoding='utf-8') as f:
        doc = yaml.safe_load(f)
    return repair_bools(doc)


def repair_bools(doc):
    """Turn a target that YAML read as a boolean back into its word."""
    if isinstance(doc, dict):
        for key, value in doc.items():
            if key == 'target' and isinstance(value, bool):
                doc[key] = 'On' if value else 'Off'
            else:
                repair_bools(value)
    elif isinstance(doc, list):
        for value in doc:
            repair_bools(value)
    return doc


def target_of(ctrl):
    """The target string of a control, whatever YAML type it came out as."""
    if not isinstance(ctrl, dict):
        return ''
    value = ctrl.get('target')
    if isinstance(value, bool):
        return 'On' if value else 'Off'
    return str(value or '').strip()


def scalar(value):
    if isinstance(value, bool):
        return 'true' if value else 'false'
    if value is None:
        return '~'
    if isinstance(value, (int, float)):
        return str(value)
    text = str(value)
    if (text == '' or not PLAIN.match(text) or text.strip() != text
            or text.lower() in BOOL_WORDS):
        return '"%s"' % text.replace('\\', '\\\\').replace('"', '\\"')
    return text


def flow(mapping):
    parts = []
    for key, value in mapping.items():
        if isinstance(value, dict):
            parts.append('%s: %s' % (scalar(key), flow(value)))
        else:
            parts.append('%s: %s' % (scalar(key), scalar(value)))
    return '{ ' + ', '.join(parts) + ' }'


def emit(doc):
    out = []
    out.append('scope:')
    for key, value in (doc.get('scope') or {}).items():
        out.append('  %s: %s' % (key, scalar(value)))
    out.append('')

    shared = doc.get('controls') or {}
    if shared:
        out.append('# The shared, NOT banked controls: one item each, mapped once')
        out.append('# per scope. They must be the same on every page.')
        out.append('controls:')
        for key, ctrl in shared.items():
            out.append('  %s: %s' % (key, flow(ctrl)))
        out.append('')

    out.append('# The pages, in the order of the driver\'s page slots. A scope\'s')
    out.append('# page 1 is the driver\'s slot 1, and so on.')
    out.append('pages:')
    for page_name, page in (doc.get('pages') or {}).items():
        out.append('  %s:' % scalar(page_name))
        for section in ('encoders', 'buttons'):
            block = (page or {}).get(section) or {}
            if not block:
                continue
            out.append('    %s:' % section)
            for key, ctrl in block.items():
                out.append('      %s: %s' % (key, flow(ctrl)))
    out.append('')
    return '\n'.join(out)


def dump_page(doc, path):
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(emit(doc))
