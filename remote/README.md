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
| `Maps/Nuts/Nocturn.remotemap` | Remote mapping (control → Reason remotable) |
| `mapping/nocturn-controls.json` | Source-of-truth CC table (driver ⇄ codec) |
| `scripts/deploy.ps1` | Copies everything into `%ProgramData%\Propellerhead Software\Remote` |
| `remote-info/` | Reason Remote Info reference notes (factory API reference) |

## The control contract

MIDI numbers are shared by the driver and the codec. The three copies must
agree — change them together:

1. `src/Nuts.Driver/appsettings.json` (`Midi:Mapping` + `Midi:Paging`)
2. `remote/mapping/nocturn-controls.json`
3. The lookup tables at the top of `Nocturn.lua`

Run `./scripts/verify-map.ps1` after changing any of them: it re-checks the
whole contract against Reason's own factory maps, including every remotable
name in the `.remotemap` (a misspelled target fails silently).

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

## Current scope: the channel strip, in four pages

The surface is **one mixer channel at a time**, and the channel's parameters
are split across four pages on the same 8 dials and 8 buttons:

| Page | PermaBar jump | Dials | Buttons |
|---|---|---|---|
| Mixer | MIXER | E1 Width, E3 Input Gain, E5 LPF Frequency, E7 HPF Frequency | Mute, Invert Phase, Insert Pre, Dyn Post EQ, LPF On, HPF On, Filters Dyn S/C, (B8 spare) |
| Dynamics | USER | E1 C Threshold, E2 C Ratio, E3 C Release, E4 C Fast Atk, E5 G Threshold, E6 G Range, E7 G Release, E8 G Hold | Comp On, C Peak, Gate On, Expander, G Fast Atk, Key On, Filters Dyn S/C, (B8 spare) |
| EQ | INSTR | E1 HF Gain, E3 HF Frequency, E5 HMF Gain, E7 HMF Frequency | EQ On, EQ E Mode, HF Bell, HF On, HMF On, LMF On, LF Bell, LF On |
| FX | FX | E1–E4 Rotary 1–4, E5–E8 FX1–4 Send Level | Button 1–4, FX1–4 Pre Fader |

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
Mixer` … `Knob 8 FX`) and never learns a page changed. See
`../docs/reason-remote.md` → "Pages: the driver banks the CCs" for why this is
driver-side rather than `Define Group` or `Remote Base Channel`.

No keybed and no pads are mapped (the Nocturn has neither).

## Deploying and testing

1. Close Reason.
2. Make sure the driver is running (it creates the `Nocturn` loopback).
3. Elevated PowerShell: `./scripts/deploy.ps1 -Backup`.
4. Start Reason → Preferences → Control Surfaces → Add → **Nuts > Nocturn**,
   and select the **Nocturn** port for both MIDI Input and MIDI Output.
5. Verify: dial → the page's parameter, button → the page's switch plus LED,
   MIXER/USER/INSTR/FX → jump page with the LED following, Page −/+ → step
   and wrap, Speed Dial → level, Crossfader → pan.

Ring values/modes and the LED behaviour are still being tuned; the two spare
PermaBar buttons (Learn, View) and the dial touch CCs are reserved for the
later LED/context phase. Further scopes (combinator, synths, effects) get
added one at a time after the channel strip verifies.
