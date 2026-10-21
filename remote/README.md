# Nocturn — Reason Remote codec + map

Reason 10 integration for the Novation Nocturn, part of the `nuts` project.
The C# driver (`src/Nuts.Driver`) owns the USB device and exposes a MIDI
loopback endpoint called **Nocturn**; Reason sees that as an ordinary MIDI
in/out port, and this folder supplies the Remote codec and mapping it loads.

The surface is registered under the manufacturer **Nuts** (not "Novation"),
so it is always obvious in Reason's device list — look for
**Nuts > Nocturn**.

Layout mirrors the `akaii-mdk-play-remote` project:

| Path | What it is |
|---|---|
| `Codecs/Lua Codecs/Nuts/Nocturn.luacodec` | Surface declaration (ports, picture, `has_keyboard=false`) |
| `Codecs/Lua Codecs/Nuts/Nocturn.lua` | Codec: items, LED feedback, MIDI decoding |
| `Codecs/Lua Codecs/Nuts/Nocturn.png` | Surface picture |
| `Maps/Nuts/Nocturn.remotemap` | Remote mapping — **generated** from `../pages/*.yaml` |
| `mapping/nocturn-controls.json` | Source-of-truth CC table (driver ⇄ codec) |
| `mapping/scope-index.json` | Which targets are real for which Reason scope |
| `scripts/generate_map.py` | `pages/*.yaml` → `Maps/Nuts/Nocturn.remotemap` |
| `scripts/verify-map.ps1` | Checks the whole contract (templates → map ↔ codec ↔ driver) |
| `scripts/deploy.ps1` | Copies everything into `%ProgramData%\Propellerhead Software\Remote` |
| `remote-info/` | Reason Remote Info reference notes (factory API reference) |

The page templates live in `../pages/` — one YAML per device, one scope per
file. `scripts/generate_map.py` validates them against Reason's own scope
definitions and writes the map; `deploy.ps1` runs it first, so a deploy can
never ship a map that no longer matches the templates. See
`../docs/pages-templates.md`.

## The control contract

MIDI numbers are shared by the driver and the codec. The three copies must
agree — change them together:

1. `src/Nuts.Driver/appsettings.json` (`Midi:Mapping` + `Midi:Paging`)
2. `remote/mapping/nocturn-controls.json`
3. The lookup tables at the top of `Nocturn.lua`

Run `./scripts/verify-map.ps1` after changing any of them: it re-checks the
whole contract — every scope in the map, every remotable name against
Reason's own scope definitions, the driver's page tables against the codec's,
and the committed map against the generator's output (a misspelled target
fails silently).

Shared defaults: dial touch CC80–87, Speed Dial CC24 + click CC118 + touch
CC88, crossfader CC8/CC9 + touch CC89, knob ring values CC32–39, speed dial
ring CC40, knob ring modes CC48–55, PermaBar CC110–117. Everything is MIDI
channel 1.

The **8 dials and the 8 page-row buttons bank** (4 pages), and the driver owns
the paging; the page echo goes out on CC119. Page 1 uses the original verified
CCs — dials CC16–23, page row CC102–109 — and the other pages use the rest:
dials 56–63 / 72–79 / 0–7, page row 64–71 / 90–97 / 25–31 + 41. That is 104 of
CC 0–119 used, leaving 16 spare.

Switches are CCs and not notes on the loopback, so the whole note range stays
free for a keyboard if this surface ever gains a keybed. The hardware's own
buttons/LEDs are notes on its USB wire; the driver translates.

## The pages: one channel strip in four page slots

The surface is **one device at a time**, and its parameters are split across
four pages on the same 8 dials and 8 buttons. The page *slots* are generic —
what a slot means is decided by the focused device's scope in the map. For
the mixer channel the slots are the four sections of the channel:

| Page | PermaBar jump | Dials | Buttons |
|---|---|---|---|
| Mixer | MIXER | E1 Width, E3 Input Gain, E5 LPF Frequency, E7 HPF Frequency | Mute, Invert Phase, Insert Pre, Dyn Post EQ, LPF On, HPF On, Filters Dyn S/C, (B8 spare) |
| Dynamics | USER | E1 C Threshold, E2 C Ratio, E3 C Release, E4 C Fast Atk, E5 G Threshold, E6 G Range, E7 G Release, E8 G Hold | Comp On, C Peak, Gate On, Expander, G Fast Atk, Key On, (B7/B8 spare) |
| EQ | INSTR | E1 HF Gain, E3 HF Frequency, E5 HMF Gain, E7 HMF Frequency | EQ On, EQ E Mode, HF Bell, HF On, HMF On, LMF On, LF Bell, LF On |
| FX | FX | E1–E4 Rotary 1–4, E5–E8 FX1–4 Send Level | Button 1–4, FX1–4 Pre Fader |

The other scopes fill the same four slots with their own pages — Thor with
OSC / FILTER / MOD / FXPERF, for instance. One codec serves all of them; only
the map changes.

Pages 1 and 3 put their parameters on the **odd dials** (E1/E3/E5/E7); the gap
is deliberate and separates the function groups. Pages 2 and 4 use **all 8
dials** — each has 8 continuous parameters and no spare dial to leave a gap
with. Button 8 is spare on pages 1 and 2.

The layout follows one rule: **continuous parameters go on dials, on/off
states go on the page-row switches**, because a page-row item is a Toggle and
an on/off value is the only thing it can set. That is why the compressor's
Release / Fast Attack and the gate's Range / Release / Hold are dials, and
`Comp On` / `Gate On` / `Key On` are switches.

Shared on every page: Speed Dial = `Level`, Speed Dial click = `Solo`,
Crossfader = `Pan`. **Page −/+** step Mixer → Dynamics → EQ → FX → wrap, and
the four PermaBar jumps select a page directly. The unit has no display, so
the lit PermaBar jump-button LED is the only page indicator. Learn and View
are spare.

Paging happens **in the driver**: it sends a different CC per page and never
forwards the page buttons, so Reason sees four separate item sets (`Knob 1
P1` … `Knob 8 P4`) and never learns a page changed. See
`../docs/reason-remote.md` → "Pages: the driver banks the CCs" for why this is
driver-side rather than `Define Group` or `Remote Base Channel`.

No keybed and no pads are mapped (the Nocturn has neither).

## Deploying and testing

1. Close Reason.
2. Make sure the driver is running (it creates the `Nocturn` loopback).
3. Elevated PowerShell: `./scripts/deploy.ps1 -Backup`. It regenerates the
   map from `../pages/*.yaml` first and refuses to deploy if a template is
   invalid.
4. Start Reason → Preferences → Control Surfaces → Add → **Nuts > Nocturn**,
   and select the **Nocturn** port for both MIDI Input and MIDI Output.
5. Verify: dial → the page's parameter, button → the page's switch plus LED,
   MIXER/USER/INSTR/FX → jump page with the LED following, Page −/+ → step
   and wrap, Speed Dial → level, Crossfader → pan.
6. Focus a device (e.g. a mixer channel, a Thor, an Europa) — Reason applies
   that device's scope from the map, and the four page slots fill with its
   own parameters. The scopes are all in one file; Reason uses the focused
   device's.

Ring values/modes and the LED behaviour are still being tuned; the two spare
PermaBar buttons (Learn, View) and the dial touch CCs are reserved for the
later LED/context phase.

### If the surface stops responding after a codec change

Reason binds the map's items to the codec's items **when the surface is
added**. Change the codec's item names (or its item count) and Reason keeps
the old binding until the surface is re-read — the surface then sits there
doing nothing, with no error.

The fix is *Preferences → Control Surfaces*: remove **Nuts > Nocturn** and
add it again, then select the **Nocturn** port for MIDI Input and MIDI
Output. Restarting Reason does the same thing. Do this after any change to
the codec's item list — and note that changing the item names also means the
map and the codec must be deployed together, or the map's items bind to
nothing at all.
