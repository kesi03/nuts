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

1. `src/Nuts.Driver/appsettings.json` (`Midi:Mapping`)
2. `remote/mapping/nocturn-controls.json`
3. The lookup tables at the top of `Nocturn.lua`

Defaults: dials CC16–23 (relative), dial touch CC80–87, switches CC102–117
(102–109 page row / 110–117 PermaBar) and Speed Dial click CC118, Speed Dial
CC24 + touch CC88, crossfader CC8/CC9 + touch CC89, knob ring values CC32–39,
speed dial ring CC40, knob ring modes CC48–55. Everything is MIDI channel 1.

Switches are CCs and not notes on the loopback, so the whole note range stays
free for a keyboard if this surface ever gains a keybed. The hardware's own
buttons/LEDs are notes on its USB wire; the driver translates.

## Current scope: the channel strip

The surface works as **one mixer channel at a time** — dials are that
channel's parameters, buttons its switches, and the channel itself is
Reason's `Remote Base Channel`:

- Dials: Level, Pan, HF/HMF/LMF/LF Gain, FX1/FX2 Send Level
- Buttons: Mute, Solo, EQ On, Comp On, Gate On, FX1/FX2 Send On, Bypass Insert FX
- Speed Dial: Master Level
- PermaBar Page −/+: previous/next channel; Crossfader: sweep channels

Because every line targets `Channel 1 …` and Reason re-bases those onto the
base channel, there is no per-channel page duplication: one flat table, and
moving channels *is* paging.

No keybed and no pads are mapped (the Nocturn has neither).

## Deploying and testing

1. Close Reason.
2. Make sure the driver is running (it creates the `Nocturn` loopback).
3. Elevated PowerShell: `./scripts/deploy.ps1 -Backup`.
4. Start Reason → Preferences → Control Surfaces → Add → **Nuts > Nocturn**,
   and select the **Nocturn** port for both MIDI Input and MIDI Output.
5. Verify: dial → channel level, button → mute plus LED, Page −/+ and the
   crossfader → move the selected channel, Speed Dial → master level.

Ring values/modes and the LED behaviour are still being tuned; the remaining
PermaBar buttons (Learn, View, User, FX, INST, MIXER) and the dial touch CCs
are reserved for the later LED/context phase. Further scopes (combinator,
synths, effects) get added one at a time after the channel strip verifies.
