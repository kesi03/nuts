#!/usr/bin/env python
"""Shared knowledge about Reason scopes.

A "scope" is a device that a control surface can map to. Reason describes
one in two places:

  * remote/remote-info/**.txt - the authoritative definition: the exact
    Scope line (manufacturer + model) and the COMPLETE list of remotables
    with their range and input type.
  * Reason's factory .remotemap files - what real surfaces actually map.
    A subset of the above, but the only source for scopes that have no
    remote-info file (the Reason Main Mixer Channel is one), and the
    source of the display name that goes in the "Map _Scope ..." line.

The factory maps also contain two kinds of target that are NOT parameters:

  * LCD strings - quoted fragments like "\"Bypas\"". A surface writes
    them to a display; they are never a parameter.
  * variation selectors - "TheGroup=Pan", "Layer=EQ", "Dyn_vars=Comp",
    "ShiftState=ShiftON". They pick a variation, they do not carry a
    value.

Both are legal map targets, but neither is a sane choice for a dial or a
switch, so the tools treat them as unknown.
"""

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
    """A variation selector rather than a parameter."""
    return any(target.startswith(p) for p in SELECTOR_PREFIXES)


def is_parameter(target):
    return not is_lcd_string(target) and not is_selector(target)


def usable_targets(entry):
    """The targets of a scope that are real parameters."""
    names = set(entry.get('remotables') or {})
    names |= {t for t in (entry.get('factoryTargets') or [])
              if is_parameter(t)}
    return names
