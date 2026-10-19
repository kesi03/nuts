# Nocturn USB Protocol Reference

Evidence gathered from `Unpacked\` (AutoMap 4.4.12), the `ahihi/autocrap` driver, and
other open-source drivers (`dewert/nocturn-linux-midi`, `11ols/11nocturn`,
`jeffgca/node-nocturn`). Confidence is noted per item.

## Device identity

| Item | Value | Confidence |
|---|---|---|
| VID | `0x1235` (Novation) | confirmed (autocrap) |
| PID | `0x000A` (Nocturn) | confirmed (autocrap) |
| Class | Non-class-compliant; requires WinUSB/libusb driver (Zadig) | confirmed |
| Interface | 1 IN + 1 OUT interrupt endpoint pair (EP 2 OUT observed) | confirmed (autocrap uses ep 2 OUT) |
| Packet format | Sequence of `[control, value]` byte pairs; no length prefix | confirmed (all drivers) |

`Unpacked\AutomapServerATL.dll` contains RTTI for `NocturnControlTable`,
`LEDButtonRow`, `LEDEncoderRow`, `LEDTouchpadRow`, `NocturnInput` / `NocturnOutput` —
the original driver used a control-table layout mirroring the physical surface.

## Reset / init

```
B0 00 00   // "reset" — first byte is treated as MIDI-status-like prefix by IN-side parsing
```

`dewert/nocturn-linux-midi` additionally sends undocumented config pairs
(likely brightness / mode configuration):

```
28 00  2b 4a  2c 00  2e 35
2a 02  2c 72  2e 30
7f 00
```

autocrap omits these and still works, so they are not required for basic
operation. Worth verifying with hardware probing (see Milestone 1).

## Input reports (device → host)

A report is a status byte `0xB0` followed by **one or more** `[num, val]`
pairs; the `0xB0` prefixes the report, not each pair. Capture (2026-10-19)
shows both a coalesced read `B0 48 2E 49 00 42 01` (one status, three pairs)
and `B0 48 30 B0 49 40` (two one-pair reports in one read), so a per-pair
prefix assumption desyncs the stream by one byte and silently drops
everything after the first multi-pair report. All pair bytes have bit 7
clear, which is how the parser tells a status byte from a pair byte.

| Control number | Meaning | Notes |
|---|---|---|
| 64–71 | Encoders 0–7 (rotation) | relative values |
| 72–73 | Crossfader | 8-bit position as a coarse + fine pair: 72 = top 7 bits, 73 = fine bit (0/1), sent 72 then 73. See `NocturnProtocol.XfaderMsb/XfaderLsb`. |
| 74 | Speed dial (horizontal encoder) | |
| 81 | Button (button 81) | part of the button block, see below |
| 82 | Speed dial touch | touch, not press |
| 83 | Crossfader touch | |
| 96–103 | Encoder touch (encoders 0–7) | touch, not press |
| 112–127 | Buttons 0–15 | 1 = pressed |

Button index split — **CONFIRMED by hardware probe (2026-10-19)**:

- **0–7** (control 112–119): assignable "page" buttons, in surface order
  left-to-right beneath the encoders.
- **8–15** (control 120–127): fixed "PermaBar" system buttons, in surface
  order: **Learn, View, Page−, Page+, User, FX, INST, MIXER**.
- **81**: the speed dial's **click button** (the speed dial is a clickable,
  touch-sensitive encoder: 74 = rotation, 82 = touch, 81 = click).

UI string fragments in `AutomapServerATL.dll` (`'  Learn '`, `'  View  '`,
`'|   User     FX      Inst.    Mixer  |'`) match the confirmed order.

## Output reports (host → device)

2-byte `[control, value]` pairs written to the OUT interrupt endpoint.
Maximum transfer is 8 bytes = 4 pairs per write; batching is safe but
not required (autocrap writes one pair at a time).

| Control number | Meaning | Value encoding |
|---|---|---|
| 64–71 | Encoder ring *values* (encoders 0–7) | 0–11 = LED segment count/position |
| 72–79 | Encoder ring *modes* (encoders 0–7) | `(mode << 4)` |
| 80 | Speed dial ring value | 0–11 fill only; **no mode register** |
| 112–127 | Button LEDs, indices 0–15 | 0 = off, 0x7F = on; **color fixed per row** (see below) |

### Ring segment model

Each encoder ring has **11 LEDs**. Verified in `11nocturn` and confirmed by
autocrap's `interpreter.rs`.

Firmware ring modes (from `NocturnHardware.py`, `ring_mode()`):

| Mode | Behavior | Use for |
|---|---|---|
| 0 | Fill from minimum (clockwise from bottom) | pan, frequency, general value |
| 1 | Fill from maximum (counter-clockwise from top) | inverse quantities |
| 2 | Centre, single direction | pan (single-centred) |
| 3 | Centre, both directions | pan (dual-sided), width, EQ gain |
| 4 | Single dot | **VU meter needle** |
| 5 | Single dot, inverted | dot from the other end |

`mode 4 + value n` positions one lit LED — this is the intended VU-meter
needle. **There is no firmware VU mode**: a smooth software-computed VU must
be driven from the host by recomputing fill/dot values at the animation
rate (autocrap's `RingMode::VUMeter` is software-only).

The speed dial ring (control 80) takes fill values only.

### Button LED values — CONFIRMED by hardware probe (2026-10-19)

A per-button sweep of the byte values `0x01, 0x02, 0x03, 0x07, 0x0F, 0x10,
0x20, 0x40, 0x7F` showed every button lighting its **own fixed color**
regardless of value. Color is hardwired per position; the byte is on/off
only (every non-zero value lit; `0x7F` is used for "on"):

| Control | Wire | LED color | Value semantics |
|---|---|---|---|
| Assignable page buttons (idx 0–7) | 112–119 | **green** | 0 / non-zero |
| PermaBar system buttons (idx 8–15) | 120–127 | **red** | 0 / non-zero |
| Encoder rings | 64–71 | **red** | fill 0–11, mode 72–79 |
| Speed dial ring | 80 | **green** | fill 0–11, no mode |

This resolves the review conflict: MusicRadar's "8 assignable buttons green,
8 system buttons red" matches the probe; there is **no color register** on
this hardware. Surface indication must use on/off patterns per row, not
colors.

**Observed but unmapped (open):** control **48** (`0x30`) was received with
value `0` twice, adjacent to crossfader activity during the probe. Not
present in any source table. Hypothesis: crossfader capacitive-touch
sensing (previously assumed to be ctrl 83 — unconfirmed). Input-only,
recorded for a follow-up probe.

*Milestone-2 update (2026-10-19):* control **83** is the one that behaves
like a touch sensor — it is mapped as `XfaderTouch` (→ MIDI CC 89) and in
the bridge acceptance run every CC 89 on/off pair bracketed a burst of
crossfader CC 8/9 movement (grab → move → release). Control **48** fired
exactly once in the same session — at the single device connect, value
`0`, not adjacent to fader activity — which fits a connect-time state
announce better than touch sensing. 83's role is now confirmed; 48 stays
open.

## AutoMap file format

`.automap` files (e.g. `Unpacked\Mappings\Nocturn\Reason Main Mixer Channel - {GUID}.automap`)
are **XML parameter/page layouts** for the Automap host application. They contain
control names, ranges, MIDI mappings — **no LED state or protocol data**.
Relevant only as a design precedent for how AutoMap exposed Reason's
Mute/Solo on encoder buttons (params 86/87 in the Reason Main Mixer map).

## Reason integration (from Unpacked\Setup Guides\Reason)

AutoMap exposed two Reason control surfaces: **Novation Automap Control** and
**Novation Automap Mixer**, configured in Reason's MIDI preferences. The
driver's job was to present the surface as a MIDI remote surface with paged
parameter banks — the architecture our spec's context/page model follows.

## Windows MIDI note

autocrap does not implement virtual MIDI ports on Windows. For a Windows
driver exposing virtual ports, use Windows MIDI Services (MIDI 2.0 API, the
Nocturn is USB HS and can use MIDI 2.0 packetization over a USB HS endpoint)
or fall back to loopMIDI for a classic MIDI 1.0 port.
