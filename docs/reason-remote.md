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
(notes 0–15 on/off, CC 32–40 values 0–11, CC 48–55 modes) happens in
the codec.

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
| CC 16–23 relative rotation | `input="delta"` items + `remote_process_midi` converting the two's-complement byte (`x < 64 and x or x-128`) and handing Reason the signed delta in `remote.handle_input` — Reason accumulates and clamps, so no manual `get_item_value` loop is needed (this is the factory AlphaTrack idiom). `gEncoderDirection` flips the sign in one line if a unit runs backwards. |
| notes 0–15 buttons | `remote_process_midi` (`<100x>? yy zz`) → button items (notes 0–7 = the page row, notes 10/11 = PermaBar Page −/+). Auto-inputs are *not* used: the same table drives item *and* LED, and the codec must also consume the reserved PermaBar notes. |
| CC 24 speed dial, CC 80–89 touches | Speed dial = `input="delta"` item; the touch CCs are consumed and ignored — still the reserved hook for soft takeover. |
| CC 8 + CC 9 crossfader (14-bit) | one absolute value item fed from CC 8 (MSB = 128 positions, plenty for scrolling); CC 9 is consumed and ignored. |
| **out** notes 0–7 button LEDs | auto-output `90 <note> xx` with `x="127*value"` — on/off only (hardware). |
| **out** CC 32–39 / CC 40 ring values | auto-output `b0 <cc> 0<00xx>` with `x="value*11/127"` (item 0–127 → 11 segments; the driver also clamps). |
| **out** CC 48–55 ring modes | emitted from `remote_prepare_for_use` (per-dial constant modes; empty rings + dark LEDs), and `remote_release_from_use` darkens the surface when Reason closes. |

Driver-side M3 work still open: the `SurfaceContext` state machine (User/Fx/Inst/Mixer,
Learn/View), indication rendering (pages, armed), **note echo suppression**
(the loopback echoes to the sender — `midi-mapping.md`), and feeding codec
feedback into `ILedManager`.

## Channel navigation: base channel, not pages/groups (`Define Group`)

The user rejected banks/pages for scope #1 ("we have no banks we have 1-8
dials, 1-8 buttons"), and later settled the model as **"a page represents a
channel"**: the surface is one mixer channel at a time — the 8 dials are that
channel's parameters, the 8 buttons its switches — and moving channels is the
only navigation. Verified options, from every factory map in
`%ProgramData%\Propellerhead Software\Remote\Maps\`:

- `Define Group <Name> <var…>` + a trailing column on each `Map` line creates
  switchable *variations* (pages). They can be switched with
  Ctrl+Alt+<number> only when the group is called exactly
  `Keyboard Shortcut Variations`, or from a physical control with
  `Map <item> <Group>=<Variation>` (nanoKONTROL2, UR-80, AlphaTrack's
  `Ch1`…`Ch14` channel groups). Powerful, but 14 channels would mean ~14
  duplicated pages of 15 lines — and it is a *codec/map* answer to a
  navigation problem.
- **`Remote Base Channel` + `Previous/Next Remote Base Channel`** are valid
  only in a master-section scope (`Reason Master Section`,
  `Record Master Section`, `Reason Essentials Master Section`). They rebase
  every `Channel N <param>` line by the base channel: Livid OhmRGB binds
  `Crossfader → Remote Base Channel`, `Xfade Button Left/Right →
  Previous/Next Remote Base Channel` and `Fader 1…7 → Channel 1…7
  Level/Pan/EQ`; Edirol UR-80 adds the `Previous/Next 8 Remote Base Channel`
  block variants.

**Chosen:** the base channel *is* the page. Every line of the scope targets
`Channel 1 <param>`, so all 8 dials/buttons follow the selected channel, and
one flat table replaces 14 pages:

| Physical | Item | Remotable |
|---|---|---|
| Dial 1–8 | `Knob 1`–`Knob 8` | `Channel 1 Level`, `Pan`, `HF/HMF/LMF/LF Gain`, `FX1/FX2 Send Level` |
| Button 1–8 | `Button 1`–`Button 8` | `Channel 1 Mute`, `Solo`, `EQ On`, `Comp On`, `Gate On`, `FX1/FX2 Send On`, `Bypass Insert FX` |
| PermaBar Page −/+ | `Page Left/Right` | `Previous/Next Remote Base Channel` |
| Crossfader | `Crossfader` | `Remote Base Channel` (sweep the window) |
| Speed Dial | `Speed Dial` | `Master Level` |

Target names were checked against the full set of `Channel 1 …` remotables
actually used by factory maps inside the `Reason Master Section` scope (88
distinct targets, including the SS L 4000 channel strip: EQ, comp/gate, eight
FX sends, insert bypass). Ring modes match the layout (dial 2 + dials 3–6 =
centre mode 3, Level/sends = fill mode 0) and live in `gRingModes`.

Note: the 14:2's own parameters (`Channel N Aux 1 Send`, `Bass Amount`,
`Treble Amount`) only exist in the `Mixer 14:2` scope, so they are *not*
reachable from the master-section channel strip; the SS L 4000's FX sends and
4-band EQ are. That is what the strip exposes.

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
