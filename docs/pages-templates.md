# Page templates — `pages/*.yaml`

The Nocturn's Reason Remote map is **generated**, not hand-written.

```
pages/*.yaml
      │  remote/scripts/generate_map.py
      ▼
remote/Maps/Nuts/Nocturn.remotemap
      │
      ▼  remote/scripts/deploy.ps1
%ProgramData%\Propellerhead Software\Remote\Maps\Nuts\Nocturn.remotemap
```

One YAML file per device. One scope per file. The file's pages fill the
driver's four page slots in order, so page 1 of the YAML is the surface's
page 1, page 2 is the surface's page 2, and so on.

---

## The file format

```yaml
scope:
  manufacturer: Propellerheads        # exact Scope line, manufacturer part
  model: Thor Polysonic Synthesizer   # exact Scope line, model part
  display: Thor                       # the "Map _Scope" display name
  enabled: true                       # optional, default true

# The shared, NOT banked controls. Mapped ONCE per scope, and the target
# must be the same on every page - they are one physical control.
controls:
  SD:  { name: speedDial,       key: SpeedDialCc,       target: Master Level, min: 0, max: 127, input_type: Value }
  SDB: { name: speedDialButton, key: SpeedDialButtonCc, target: Note Trigger MIDI, min: 0, max: 1, input_type: Toggle }
  F:   { name: fader,           key: XfaderCcs,         target: Amplifier Pan, min: -64, max: 63, input_type: Value }

# The pages, in the order of the driver's page slots.
pages:
  OSC:
    encoders:
      E1: { name: encoder1, key: EncoderCcs, target: Osc 1 Type, min: 0, max: 6, input_type: Value }
    buttons:
      B1: { name: button1, key: ButtonCcs, target: Osc 2 Sync To Osc 1, min: 0, max: 1, input_type: Toggle }
```

| field | meaning |
|---|---|
| `scope.manufacturer` / `scope.model` | the **exact** pair from Reason's scope definition. A typo here means the scope never matches and the device is unreachable. |
| `scope.display` | what Reason shows for the scope, and what the codec reads back from the `_Scope` item. Defaults to `model`. |
| `scope.enabled` | `false` keeps the template out of the generated map without deleting it. |
| `controls` | the shared controls: `SD` = Speed Dial, `SDB` = Speed Dial click, `F` = Crossfader. Each is mapped **once per scope** and owns its target outright. |
| `pages` | ordered; `pages[0]` is driver page slot 1. Up to four. |
| `pages.*.encoders` | `E1`…`E8` → the dials. Continuous parameters live here. |
| `pages.*.buttons` | `B1`…`B8` → the page-row switches. On/off states live here. |
| `target` | the **remotable item's name** in that scope — the scope's own name, not its display name. |
| `min` / `max` | the parameter's range, as the scope declares it. |
| `input_type` | `Value` for a continuous parameter, `Toggle` for an on/off, `Trigger` for a momentary action. |

`name` and `key` document which physical control and which driver CC the
slot is; the generator does not need them, but `verify-map.ps1` and the
driver's own contract do.

---

## The three rules

The generator enforces the same three rules Reason enforces, and refuses to
write a map that breaks one.

1. **One target per scope.** Reason refuses to load a control surface when the
   same remotable is mapped twice inside one scope ("remotable item already
   mapped in this scope"), so every target in a scope must be unique — across
   *all* pages of that scope. A target used on page 1 cannot be used on page 2.
2. **Continuous parameters live on dials, on/off states live on the page-row
   switches.** A page-row item can only ever carry 0 or 127, so a continuous
   parameter on a switch would slam the parameter to one end.
3. **Every target must be a real remotable of that scope.**

A fourth check comes from the map itself: **a scope may only appear once in
the file.** Two templates with the same scope would put the scope in the map
twice, which Reason rejects.

---

## Where the target names come from

Two independent sources, both built into
`remote/mapping/scope-index.json`:

| source | what it gives | authority |
|---|---|---|
| `remote/remote-info/**.txt` | the **complete** remotable list of a scope, with min/max and input type | the primary authority |
| Reason's factory `.remotemap` files | what real surfaces actually map — a subset, plus the scope's display name | the fallback for scopes with no remote-info file (the mixer channel is one) |

Two kinds of factory target are **not** parameters and are rejected:

- **LCD strings** — quoted fragments (`"Bypas"`), used to drive a display.
- **Variation selectors** — `TheGroup=Pan`, `Layer=EQ`, `Dyn_vars=Comp`,
  `ShiftState=ShiftON`. They pick a variation; they do not carry a value.

Never normalise a target name by convention. `humana` genuinely uses
`Filter_Cutoff` and `Delay_Time`, while `dmfc` does not. Always look the
scope up.

### Rebuilding the index

```
python remote/scripts/parse_remote_info.py     # -> remote/mapping/remote-info-index.json
python remote/scripts/build_scope_index.py     # -> remote/mapping/scope-index.json
                                            #  + scope-index.list.json (for PowerShell)
```

`build_scope_index.py` skips the maps **we** deployed for our own surfaces
(`Nuts/Nocturn`, `Akai/MPK Mini Play`) — they are our work, not Reason's, and
they would otherwise pollute the index.

---

## The tools

| script | what it does |
|---|---|
| `remote/scripts/generate_map.py` | validate every template and write the map. `--check` validates only, `--only <name>` narrows to one device, `--out <path>` writes elsewhere. |
| `remote/scripts/fix_pages.py` | repair a template: rename a target to the closest real remotable, drop a duplicate, move a continuous parameter off a switch. `--dry-run` shows the plan, `--only <name>` narrows it. |
| `remote/scripts/build_scope_index.py` | rebuild the scope index from remote-info + the factory maps. |
| `remote/scripts/parse_remote_info.py` | parse `remote/remote-info/` into `remote-info-index.json`. |
| `remote/scripts/pageio.py` | shared YAML read/write for the templates. |
| `remote/scripts/scopedef.py` | LCD-string / variation-selector detection, the usable-target set of a scope. |
| `remote/scripts/verify-map.ps1` | the end-to-end check: templates → map ↔ codec ↔ `appsettings.json`. |

### Everyday loop

```
python remote/scripts/generate_map.py --check      # is everything valid?
python remote/scripts/generate_map.py              # write the map
pwsh -NoProfile -File remote/scripts/verify-map.ps1 # does it all still agree?
pwsh -NoProfile -File remote/scripts/deploy.ps1 -Backup
```

`deploy.ps1` regenerates the map first, so a deploy can never ship a map
that no longer matches the templates.

---

## Adding a device

1. Copy the nearest existing template, e.g. `pages/thor-polyphic-synthesizer.yaml`.
2. Set `scope.manufacturer` / `scope.model` to the **exact** pair from
   `remote/remote-info/` (or from a factory map, for the scopes that have no
   remote-info file).
3. Set `scope.display` to the name Reason shows.
4. Fill in the pages. **One target per scope** — if two pages want the same
   parameter, it belongs on one page only.
5. `python remote/scripts/generate_map.py --check --only <name>` and fix
   what it reports.
6. Deploy and test in Reason: *Preferences → Control Surfaces*, focus the
   device, and step through the pages with the PermaBar.

---

## Scopes with no factory map

A few scopes exist in `remote/remote-info/` but in **no** factory
`.remotemap`, so nothing in Reason's own surface library maps them. They are
still shipped — a scope Reason never activates is harmless — but they are
the least verified pages in the map:

| scope | what it is |
|---|---|
| `Groovy Melon / com.groovymelon.MorfinXF` | Morfin XF, a Reason **Player** device |
| `Propellerhead Software / se.propellerheads.NoteEcho` | Note Echo, a Reason **Player** device |
| `Propellerhead Software / se.propellerheads.ScalesAndChords` | Scales and Chords, a Reason **Player** device |

The Player devices are not part of a Reason installation, so they can only be
tested if the user has them. Set `scope.enabled: false` to keep them out of
the map.

