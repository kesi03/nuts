# Reason Remote integration (Milestone 3)

Scope #1 (the main mixer channel strip) is implemented in
[`../remote/`](../remote/README.md). This file keeps the research that got it
there and the findings that decide the remaining scopes.

How the Nocturn will drive Reason 10 with feedback, grounded in:

- the working reference project **akaii-mdk-play-remote**
  (`C:\Users\keste\Documents\projects\akaii-mdk-play-remote` — Akai MPK
  Mini Play Lua codec + remotemap + deploy script, same machine, same
  Reason 10),
- Reason 10's **factory codecs** in
  `%ProgramData%\Propellerhead Software\Remote\` — especially
  `Novation Automap Control.lua` (AutoMap's Reason-side half) and the
  LED-capable Launchpad/Mackie/Livid codecs,
- the **AutoMap 4.4 install** (`Unpacked\` setup guides + `.automap`
  mappings),
- **autocrap** (`src/autocrap/interpreter.rs`),
- web docs (linked at the bottom).

## Decision — custom Lua codec on the "Nocturn" port

| Option | Verdict |
|---|---|
| **1. Custom Lua codec + `.remotemap`** — our own `Nocturn` surface | **chosen.** The only path with native Reason → surface feedback (ring values, button LEDs, resync on device lock) over our single WMS loopback. |
| 2. Emulate AutoMap's dialect on a port named `Novation Automap Control` | rejected. Reason's shipped codec only consumes AutoMap's undocumented *server* protocol (pre-paged CCs + `F0 00 20 29 …` SysEx, identity probe `F0 66 66 06 02 41 62 …`). That means reimplementing the AutoMap host, and its generic item set is not ours anyway. |
| 3. Generic "Other" MIDI surface + Remote Overrides | rejected. Input-only in practice — no feedback channel at all, so no indication "without the screen" (see koshdukai link below). |

## Remote mechanics (verified locally)

**Three files per surface**, registered from the `.luacodec` descriptor —
Reason does **not** auto-detect the surface:

- `Codecs\Lua Codecs\<Mfr>\<Name>.luacodec` — `remote_supported_control_surfaces()`:
  manufacturer, model, `source` (the `.lua`), `picture` (a `.png`),
  `in_ports`, `out_ports`, optional `has_keyboard` + setup help text.
- `...\<Name>.lua` — the codec:
  - `remote_init()` — `remote.define_items`, `remote.define_auto_inputs`,
    `remote.define_auto_outputs`.
  - `remote_set_state(changed_items)` — observes Reason-side value/text
    changes, including the `_Scope` item (= which device is focused).
  - `remote_process_midi(event)` — custom MIDI → `remote.handle_input{…}`
    (return `false` to let auto-inputs try).
  - `remote_prepare_for_use()` / `remote_release_from_use()` — run when
    the surface is (un)locked to a device; **the hook for a full LED
    resync**.
  - `remote_deliver_midi()` + `remote.make_midi()` — emit SysEx/arbitrary
    MIDI out on demand.
- `Maps\<Mfr>\<Name>.remotemap` — one static text file: header
  (Format Version / Control Surface Manufacturer / Model / Map Version),
  then `Scope <mfr> <device>` sections of `Map <surface item> <remotable item>`
  lines. Reason auto-applies the scope of the **focused device** —
  focus-following *is* the native FX/INST/MIXER mechanism.

Add manually after install: *Preferences → Control Surfaces → Add →
<manufacturer> → <model>*, then select MIDI in + out (both = our single
`Nocturn` loopback endpoint).

**Deploy** (proven locally): copy the three codec files into
`%ProgramData%\Propellerhead Software\Remote\Codecs\Lua Codecs\<Mfr>\`
and the maps into `...\Remote\Maps\<Mfr>\` — see
`akaii-mdk-play-remote\scripts\deploy.ps1` (Reason closed; ProgramData
writes may need an elevated shell). `%APPDATA%\Propellerhead Software\Remote`
is also documented as a user-writable alternative.

**Feedback path:** an item with `output=` gets its value updated by
Reason; `remote.define_auto_outputs{name, pattern, x, y, port}` renders
that as MIDI on the out port (same pattern syntax as auto-inputs, with
`x`/`y` value formulas; ring `modes={"Single Dot", …}` on output items —
see the factory BCR2000-style codecs). Reason only ever sends
**parameter values** — rendering those to our wire protocol
(CC 102–117 switch LEDs on/off, CC 32–40 values 0–11, CC 48–55 modes) happens
in the codec.

## What AutoMap did (the precedent we replace)

- AutoMap hosted **two** surfaces in Reason — "Novation Automap Control"
  and "Novation Automap Mixer" (the mixer locked to the Master Fader;
  `Unpacked\Setup Guides\Reason\Nocturn\*.rtf`). Reason 10's ProgramData
  ships only **Automap Control** + Automap Keyboard — there is **no
  Nocturn codec** in the factory set (grep confirms).
- The factory `Novation Automap Control.lua` is a generic pipe: 512
  parameters (Pots 1–256, Buttons 1–256 addressed as CC number + MIDI
  channel), transport, Track Up/Down, a Preset delta, and 4 text items
  (Device/Instance/Document/Application name). Values, parameter names
  and names flow to the host as CC/SysEx; Reason's map binds
  `Pot N`/`Button N` per focused-device scope.
- **All** paging, banking, surface-lock, context and LED logic lived in
  the AutoMap *server* — not in Reason. The Nocturn `.automap` files
  (`Unpacked\Mappings\Nocturn\`) are XML parameter layouts only:
  *Reason Main Mixer Channel* has Mute id=86 / Solo id=87 on Page-2
  encoder buttons; *Reason Master Section* has Bank Up/Down 512/513,
  Track Up/Down 514/515, Master 516, All Mutes/Solo Off 176/177, 4 pages.
- ⇒ Our codec + driver split that host role: **codec** = Reason values ⇄
  wire protocol; **driver** = surface state machine (contexts, pages,
  indication rendering, LED plumbing).

## Wire ⇄ codec mapping (implemented — scope #1)

Files: `remote/Codecs/Lua Codecs/Nuts/{Nocturn.luacodec,Nocturn.lua}` and
`remote/Maps/Nuts/Nocturn.remotemap` (manufacturer **Nuts**, model
**Nocturn**, so the surface is unmistakable in Reason's list). Numbers come from
`remote/mapping/nocturn-controls.json` (see `midi-mapping.md` → "three-way
contract").

| Wire (see `midi-mapping.md`) | Codec side |
|---|---|
| CC per page, relative rotation | `input="delta"` items + `remote_process_midi` converting the two's-complement byte (`x < 64 and x or x-128`) and handing Reason the signed delta in `remote.handle_input` — Reason accumulates and clamps, so no manual `get_item_value` loop is needed (the factory AlphaTrack idiom). `gKnobNumberForCC` resolves the CC against the active page's table; `gEncoderDirection` flips the sign in one line if a unit runs backwards. |
| CC per page, page-row switches; CC 118 speed dial click | `remote_process_midi` (`b? yy xx`) → switch items. Auto-inputs are *not* used: the same CCs drive item *and* LED. The page row is declared `input="value"` because its targets are Toggle remotables — a `button` item carries only the press edge and Reason ignores the release (see `midi-mapping.md` → "Button kinds"). Page −/+ and the four page jumps never arrive: the driver consumes them. |
| CC 119 page echo | consumed in `remote_process_midi`; sets `gCurrentPage` (1-based, validated against `gPageCount`) so the lookups pick the right page's table. Not forwarded to Reason. |
| CC 24 speed dial, CC 80–89 touches | Speed dial = `input="delta"` item; the touch CCs are consumed and ignored — still the reserved hook for soft takeover. |
| CC 8 + CC 9 crossfader (14-bit) | one absolute value item fed from CC 8 (MSB = 128 positions); CC 9 is consumed and ignored. |
| **out** page-row switch LEDs | one auto-output per page item, `b0 <cc> 0<00xx>` with `x="value"` (items are 0–127, so on/off arrives as 127/0). Each item is fed back on its own page's CC; the driver resolves an incoming LED CC against the active page only, so inactive pages are ignored. |
| **out** CC 32–39 / CC 40 ring values | auto-output `b0 <cc> 0<00xx>` with `x="value*11/127"` (item 0–127 → 11 segments; the driver also clamps). One output per page's knob, all on the shared ring CC — only the current page's item is ever moved. |
| **out** CC 48–55 ring modes | emitted from `remote_prepare_for_use`; the driver repaints them on every page change from `Midi:Paging:RingModes`. `remote_release_from_use` darkens the surface when Reason closes. |

Driver-side M3 work still open: the `SurfaceContext` state machine (User/Fx/Inst/Mixer,
Learn/View), indication rendering (pages, armed), **self-echo suppression**
(the loopback echoes to the sender — `midi-mapping.md`), and feeding codec
feedback into `ILedManager`.

## Pages: the driver banks the CCs

The surface paged four ways — Mixer, Dynamics, EQ, FX — and **the driver owns
the paging**, not Reason. The 8 dials and the 8 page-row buttons send a
different CC per page; the driver steps the page from the PermaBar and echoes
the live page to the codec on CC 119. The page buttons are consumed
driver-side and never reach Reason, so paging is invisible to it.

**Why not Reason-side navigation.** Reason offers two mechanisms, and both
were verified against every factory map in
`%ProgramData%\Propellerhead Software\Remote\Maps\` before being rejected:

- **`Define Group` variations** create switchable pages, selected either by
  Ctrl+Alt+<n> (only when the group is named exactly `Keyboard Shortcut
  Variations`) or from a physical control (`Map <item> <Group>=<Variation>`,
  as the nanoKONTROL2 and AlphaTrack do). They work, but **Reason owns which
  variation is active**, so `Page −/+` stepping cannot exist — the groups are
  absolute.
- **`Remote Base Channel` + `Previous/Next Remote Base Channel`** rebase every
  `Channel N <param>` line. They are valid only in a master-section scope, and
  they move the *channel*, not a parameter page.

Neither can express "these four dials show Width on page 1 and HF Gain on
page 3, stepped with a wrap-around button". Driver-side CC banking can, so
that is what the design uses.

### What banks, and what does not

Only **8 dials + 8 page-row buttons** per page. Everything else is shared:
Speed Dial, its click and touch, the Crossfader and its touch, the ring
values, the ring modes, and the PermaBar itself.

| | Shared CCs | Page 1 | Page 2 | Page 3 | Page 4 |
|---|---|---|---|---|---|
| Dials 1–8 | — | 16–23 | 56–63 | 72–79 | 0–7 |
| Page-row buttons 1–8 | — | 102–109 | 64–71 | 90–97 | 25–31, 41 |
| Page echo (driver → codec) | 119 | | | | |

That is 40 shared + 64 banked = **104 of 0–119 used, 16 spare**
(`10–15`, `42–47`, `98–101`) — room enough for a fifth page.

### The four pages

Pages 1 and 3 place their parameters on the **odd dials** (E1/E3/E5/E7 on the
surface). The gap is deliberate: it separates the function groups. Pages 2 and
4 use **all 8 dials** — each has 8 continuous parameters and no spare dial to
leave a gap with. Pages 1 and 2 leave Button 8 spare.

Dials carry **continuous** parameters and the page-row switches carry **on/off**
states, because a page-row item is a Toggle and an on/off value is the only
thing it can set.

| | Page 1 Mixer | Page 2 Dynamics | Page 3 EQ | Page 4 FX |
|---|---|---|---|---|
| E1 | Width | C Threshold | HF Gain | Rotary 1 |
| E2 | — | C Ratio | — | Rotary 2 |
| E3 | Input Gain | C Release | HF Frequency | Rotary 3 |
| E4 | — | C Fast Atk | — | Rotary 4 |
| E5 | LPF Frequency | G Threshold | HMF Gain | FX1 Send Level |
| E6 | — | G Range | — | FX2 Send Level |
| E7 | HPF Frequency | G Release | HMF Frequency | FX3 Send Level |
| E8 | — | G Hold | — | FX4 Send Level |
| B1 | Mute | Comp On | EQ On | Button 1 |
| B2 | Invert Phase | C Peak | EQ E Mode | Button 2 |
| B3 | Insert Pre | Gate On | HF Bell | Button 3 |
| B4 | Dyn Post EQ | Expander | HF On | Button 4 |
| B5 | LPF On | G Fast Atk | HMF On | FX1 Pre Fader |
| B6 | HPF On | Key On | LMF On | FX2 Pre Fader |
| B7 | Filters Dyn S/C | Filters Dyn S/C | LF Bell | FX3 Pre Fader |
| B8 | — | — | LF On | FX4 Pre Fader |

Shared on every page: Speed Dial = `Level`, Speed Dial click = `Solo`,
Crossfader = `Pan`.

PermaBar mapping: **MIXER** → Mixer, **USER** → Dynamics, **INSTR** → EQ,
**FX** → FX, and **Page −/+** step in that order, wrapping. Learn and View are
spare. The unit has no display, so the only page indicator is the lit PermaBar
jump-button LED.

### The scope: `Reason Main Mixer Channel`

The map carries **one** scope. A channel strip needs `Reason Main Mixer
Channel`, which exposes every channel target in a single flat namespace
(`Width`, `C Threshold`, `FX1 Send Level`, …), so a page can pull from
anywhere.

`Reason Master Section` was considered and **rejected**: its channel targets
are partitioned by a `Define Group Target TheGroup` whose values are section
names (`Pan`, `EQ1`, `EQ2`, `Dyn1`, `Dyn2`, `Sends1`, `Sends2`, `Ins1`,
`Ins2`), and a Map line carries only *one* group value. Our pages draw from
several sections at once — the Mixer page needs Pan + EQ1 + EQ2 — so no single
group value can serve a page. `TheGroup` also gates `Shift=Channel`, which
Reason owns. The factory AlphaTrack map shows the consequence: it drives each
section from a separate physical button, one section at a time. The Master
Section scope is for the master bus and FX returns anyway, not a channel strip.

### Item sets: one per page

A `.remotemap` maps **one control-surface item to exactly one remotable per
scope**, evaluated statically — there is no way to re-point `Knob 1` from
outside Reason. So each page's controls are separate items: `Knob 1 Mixer` …
`Knob 8 FX`, `Button 1 Mixer` … `Button 8 FX`. The map gives each its own
target, and the driver's per-page CCs select the item without Reason ever
being told a page changed. This is the same technique the Akai MPK Mini Play
codec uses for its banks (`Knob 1 A` / `Knob 1 B`).

The codec therefore defines **69 items** — `_Scope`, `Page`, 4 × (8 knobs +
8 buttons), then `Speed Dial`, `Speed Dial Button`, `Crossfader` — and the
driver's per-page CCs are what route a physical dial to the right one.

### Ring feedback

Rings do **not** bank: there are only 8 ring CCs, shared by all four pages.
Each page's knob emits an output on the same ring CC, and only the current
page's item is ever moved, so the definitions cannot fight. The driver holds
one ring cache, which is why a page change blanks the rings until the new page
repaints. Ring *modes* are per page and owned by the driver
(`Midi:Paging:RingModes`); `gRingModes` in the codec is only the placeholder
used before the first echo arrives.

### Target names are verified

Every `Remotable Item` in the map was checked against the targets in Reason's
own factory `.remotemap` files. The scope's names are **not** always the
display names:

| Display name | Actual remotable |
|---|---|
| Comp Threshold / Ratio / Peak / Fast Attack | `C Threshold`, `C Ratio`, `C Peak`, `C Fast Atk` |
| Comp Release | `C Release` |
| Gate Threshold / Range / Fast Attack / Release / Hold | `G Threshold`, `G Range`, `G Fast Atk`, `G Release`, `G Hold` |
| Gate Expander, Gate Key On | `Expander`, `Key On` |
| LPF Freq, HPF Freq, HF Freq, HMF Freq | `LPF Frequency`, `HPF Frequency`, `HF Frequency`, `HMF Frequency` |
| FX1 Send Pre Fader | `FX1 Pre Fader` |

A misspelled target fails silently. `remote/scripts/verify-map.ps1` re-checks
the whole three-way contract (map ↔ codec ↔ `appsettings.json`) against the
factory maps and is the quickest way to catch a typo.
the whole three-way contract (map ↔ codec ↔ `appsettings.json`) against the
factory maps and is the quickest way to catch a typo.

### Verifying

```
pwsh -NoProfile -File remote/scripts/verify-map.ps1
```

It reports bad targets, items the codec doesn't define, and any CC mismatch
between the codec's page tables and the driver's `Midi:Paging` config.

## autocrap: what translates

- LED write dedupe when state is unchanged → already covered by
  `LedManager`'s dirty cache (segment-granularity dedupe).
- Relative accumulation + 11-segment quantization → already covered.
- Contexts / pages / PermaBar / VU / refresh → **not in autocrap at all**;
  genuinely new M3 code (spec-driven).

## Open questions

1. **Spec semantics** — what the USER context maps, the page model
   (what a "page" binds), and where the armed indication comes from.
   These determine the codec item set. (The LED State Architecture spec
   currently lives only in the original conversation — not yet a file in
   this repo.) Scope #1 no longer depends on the answer: the mixer channel
   strip is a plain base-channel layout with no groups.
2. Lua dialect: Reason's sandbox is Lua 5.1-era (factory codecs use
   `table.getn`, `math.mod`) — stick to those idioms. The codec kept clear of
   `math.*` inside auto-output formulas, because no factory codec uses
   functions there: only `value`, `x`, `y` and arithmetic.
3. ~~WinMM visibility~~ **resolved 2026-10-19**: Reason 10 sees the
   `Nocturn` loopback as a WinMM MIDI in+out pair today
   (`midi-mapping.md` → Prerequisites); no Windows-update prerequisite.
4. Relative-encoder UX: immediate write (the MPK project's philosophy) vs
   soft-takeover using encoder-touch CCs 80–87 — spec call. Scope #1 takes
   the delta-item route (`input="delta"`), which applies immediately, needs
   no pickup sweep and keeps the rings true; the touch CCs are consumed and
   reserved.
5. Ring scaling/truncation: `x="value*11/127"` assumes the formula engine
   truncates like the factory `value="x/127"` button formulas. First thing to
   watch when the surface is added — LED polish is deferred, so a
   one-segment rounding difference is not a blocker.

## Reference links

- Remote surfaces & overrides: <https://docs.propellerheads.se/reason10/Remote.23.3.html>
  (and `Remote.23.6.html` for Remote Override)
- Codec how-to: <https://refigur8tor.readthedocs.io/en/latest/reason.html>,
  <https://www.irregular-cluster.com/codec>
- Modern full codec example: <https://github.com/aMUSiC/keylab-mk3-reason-codec>
- Why generic codecs have no feedback: <https://koshdukaimusicreason.blogspot.com/2015/09/generic-midi-channel-aware-remote.html>
- Folder-layout precedent: <https://github.com/LividInstruments/ReasonRemoteScripts>
