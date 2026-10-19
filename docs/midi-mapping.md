# MIDI mapping — Nocturn ⇄ Windows MIDI Services ⇄ DAW

Milestone 2: the driver bridges the surface to the DAW over **Windows MIDI
Services** (Milestone 1's hardware findings live in [`protocol.md`](protocol.md)).

```
Nocturn ──USB/WinUSB──▶ nuts-driver ──WMS basic-loopback "Nocturn"──▶ DAW
   ▲                         │                                        │
   └── LED writes ◀── ILedManager ◀────────── note/CC feedback ◀──────┘
```

Both sides connect to the **same** WMS basic-loopback endpoint (default name
`Nocturn`): it is a single bidirectional endpoint whose clients all receive
each other's messages. The driver owns one connection (send surface input,
receive LED commands), the DAW opens the same endpoint as its MIDI input +
output port.

## Prerequisites

1. **Windows MIDI Services Transports package** — the basic MIDI 1.0 loopback
   transport is not part of Windows yet. Tools + Transports preview 11 /
   1.0.41-preview.9 from <https://github.com/microsoft/MIDI/releases>
   (this PC: Tools installed at `C:\Program Files\Windows MIDI Services`).
2. The driver **creates the loopback itself** at startup when it is missing
   (`Midi:CreateLoopbackIfMissing`, default `true`). Transient loopbacks do
   not survive a MIDI service restart; the self-healing creation makes that a
   non-issue. Manual alternative:

   ```
   "C:\Program Files\Windows MIDI Services\Tools\midi.exe" basic-loopback create -n Nocturn -s
   ```

   (a configuration file must be registered with the service for `-s` to
   persist; otherwise the endpoint lives until the service restarts).
3. **Reason 10 / classic WinMM apps** — *verified working 2026-10-19*: Reason
   10 enumerates the `Nocturn` loopback as an ordinary WinMM MIDI
   input+output pair and reports it as such on the Remote control-surface
   port pickers, so the November-2026 rollout that was expected to be
   required is **not** a prerequisite for this loopback (that wave is the
   broader in-box MIDI 1.0 port support for WMS endpoints; this PC already
   has it, or the loopback transport already provided it). No driver change
   is needed.

## Channel and format

Everything is **MIDI 1.0 channel voice**, carried as UMP 32-bit words
(message type 2, group 0) by the WMS API. The driver transmits on **channel 1**
(zero-based channel 0); on receive the channel bits are stripped (any channel
is accepted, so a DAW configured to transmit on 2–16 still drives the LEDs).
See `Midi/MidiMapping.cs` — the tables below are that file in prose form.

### The numbers are configurable — and a three-way contract

Every number in the tables below has a default in
`Midi/MidiMappingOptions.cs` and can be overridden without recompiling in
`appsettings.json` → `Midi:Mapping` (arrays, lengths validated: 8 encoders,
8 touches, 16 switches, 2 crossfader CCs):

```jsonc
"Midi": {
  "Mapping": {
    "EncoderCcs":      [ 16, 17, 18, 19, 20, 21, 22, 23 ],
    "EncoderTouchCcs": [ 80, 81, 82, 83, 84, 85, 86, 87 ],
    "ButtonCcs":       [ 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 113, 114, 115, 116, 117 ],
    "SpeedDialCc": 24, "SpeedDialButtonCc": 118, "SpeedDialTouchCc": 88,
    "XfaderCcs": [ 8, 9 ], "XfaderTouchCc": 89,
    "RingValueCcs": [ 32, 33, 34, 35, 36, 37, 38, 39 ], "SpeedDialRingCc": 40,
    "RingModeCcs": [ 48, 49, 50, 51, 52, 53, 54, 55 ],
    "ButtonKinds": { "PageRow": "toggle", "PermaBar": "momentary" }
  }
}
```

A partially configured section is fine: the arrays default to `null`, and
`null` means "use the `Default*` table" (the configuration binder *appends*
to pre-existing collections, which is why the options do not come
prefilled). Errors name the setting and the number of entries seen.

Any change here must be mirrored in the Reason codec, so the same contract
exists in three places — change all three together:

1. `src/Nuts.Driver/appsettings.json` (`Midi:Mapping`)
2. `remote/mapping/nocturn-controls.json` (the readable source of truth)
3. the lookup tables at the top of
   `remote/Codecs/Lua Codecs/Nuts/Nocturn.lua`

### Switches are CCs, not notes

The Nocturn's own buttons are notes on its USB wire, but the driver re-publishes
them on the loopback as **CCs 102–117** (page row 102–109 — CC 112/113 being
Page −/+ — and PermaBar 110–117), plus **CC 118** for the Speed Dial click. Two
reasons:

* a CC *is* a value, and the page row is a latching switch whose message
  carries a state (127 / 0). A note would have to smuggle that state through
  velocity, where 0 also means note-off — the ambiguity the codec guard exists
  to paper over;
* notes are a single 128-slot namespace shared with any keyboard. Keeping the
  switches off it means a keyboard item (and 128 playable notes) can be added to
  this surface later without colliding with the buttons.

The hardware still addresses its LEDs by note number (controls 112–127); the
driver translates the LED CCs back to those addresses, so only the loopback
side carries CCs. The CC block sits in the unused tail: midi-mapping inputs use
8/9, 16–24 and 80–89, LED outputs 32–40 and 48–55, and 120–127 are channel-mode
messages.

### Button kinds - the driver owns the switch, the DAW owns the target

A physical button is not a single thing, so its wire behaviour is a setting
too (`Midi:Mapping:ButtonKinds`, default `momentary`):

| kind | press | release | LED | who owns the state |
|---|---|---|---|---|
| `momentary` | value 127 | value 0 | DAW feedback only | the DAW |
| `toggle` | flips a driver-side latch and sends the new state (127 / 0) | silent | mirrors the latch | the driver |

`momentary` is what the factory Reason surfaces use: a `button` surface item
sends one message when pressed and one when released (Remote SDK 5.1.2), and
the LED truth comes from Reason's own feedback - the same feedback that lights
the buttons when a mapped item is moved in the Reason GUI.

`toggle` (the [autocrap](https://github.com/ahihi/autocrap) `OnOff{Toggle}`
model) makes the surface a latching switch: the driver flips its latch, lights
the LED and sends the resulting state, and the DAW follows. DAW feedback
overwrites the latch, so the host's state remains the truth and the next press
inverts it. Our surface uses it for the **whole page row (buttons 1-8)**:
every one of them drives a two-state target (Mute, Solo, EQ On, Comp On,
Gate On, the two send ons, Bypass Insert FX), so the page row is a row of
latching switches rather than a row of holds. The PermaBar stays momentary,
because its only mapped job is Page -/+, which are triggers - a trigger wants
a press, not a state.

**`toggle` only works because the codec declares those items as value items.**
The *item type* decides what Reason does with the number, not the remotable:

* `"button"` - "sends 1 when pressed, 0 when released" (Remote SDK 6.4.15).
  Reason's Toggle remotables act on the press edge alone, so the 0 is just the
  release and switches nothing. Measured on Reason 10 (2026-10-19) with button
  items: press 1 lit the LED and switched Mute on; press 2 darkened the LED and
  left Mute on - the latched 0 had nowhere to go.
* `"value"` - "sends the absolute value of the control surface". Both 0 and 127
  are real values, so Reason *sets* the Toggle from them. This is how the
  factory maps drive toggles from valued controls (Axiom Pro maps Knob 4 onto
  `LF On`).

The page row is therefore `input="value", min=0, max=127`, and the driver's
kind for that row is `toggle` - the two settings are **coupled**: with
`momentary` the item would receive an absolute 0 on release and switch the
target off while the button is held. Change them together. The PermaBar Page
−/+ items stay `input="button"`, because a trigger wants a press.

Configuration is per group, with optional per-button overrides
(`PerButton`, keyed by surface button number 1-16), so any button can be
re-picked without rebuilding:

```jsonc
"ButtonKinds": {
  "PageRow": "toggle",      // page row 1-8 (green, under the dials)
  "PermaBar": "momentary"   // PermaBar 9-16 (red, bottom row)
}
```

The Speed Dial click (CC 118) is fixed momentary - it is a click, not a
switch.

Button *semantics* and the loopback echo are separate problems. The echo -
Reason's own button-LED CCs re-entering its In Port on the shared endpoint
and looking like a second press - is handled on the codec side by the
duplicate-press guard in `Nocturn.lua`, not by a button kind. A toggle's "off"
arrives as a 0 that *must* reach the target, so the guard keys on "is this item
already down": a repeat 127 while the flag is set can only be our own LED echo,
and the following real press sends 0, which clears the flag and is delivered.

### Surface → DAW (the driver sends)

| Surface control | MIDI message | Notes |
|---|---|---|
| Encoders 1–8 (rotation) | **CC 16–23**, relative value | Two's-complement passthrough of the wire byte: `+n` = `n` (1–63), `−n` = `128−n` (65–127); center = 0 is never sent. 64±n deltas arrive as one message per step batch. |
| Encoder 1–8 (touch) | **CC 80–87**, 127 down / 0 up | For soft-takeover logic in the DAW or a Remote codec. |
| Page buttons 1-8 (under encoders) | **CC 102–109**, value 127 / 0 | Kind configurable (`Midi:Mapping:ButtonKinds:PageRow`, default `toggle`): a latching switch sends its new state on every press and nothing on release; `momentary` sends 127 on press and 0 on release. |
| PermaBar Learn/View/Page−/Page+/User/FX/INST/MIXER | **CC 110–117**, value 127 / 0 | Switch index 8–15 in surface order. |
| Speed dial rotation | **CC 24**, relative | Same two's-complement encoding as the encoders. |
| Speed dial click | **CC 118**, value 127 / 0 | Wire control 81; fixed momentary. |
| Speed dial (touch) | **CC 88**, 127 / 0 | |
| Crossfader | **CC 8 (MSB) + CC 9 (LSB)**, 14-bit | Sent as a two-word pair on every crossfader update. The wire sends the position as a coarse + fine pair (72 = top 7 bits, 73 = fine bit); the input parser composes `WideValue = coarse << 7 \| fine` and the codec reads the top 7 bits (128 positions, plenty for scrolling). |
| Crossfader (touch) | **CC 89**, 127 / 0 | Wire control 48/83 touch (see protocol.md open question). |

Unknown wire controls (e.g. the unmapped `0x30`) produce no MIDI.

### DAW → Surface (the driver receives; drives LEDs)

| MIDI message | Surface effect | Value ranges |
|---|---|---|
| **CC 102–117** | Page/PermaBar switch LED on/off | CC 0 = off, anything > 0 = on. Wire LEDs are on/off only, fixed color per row (page buttons green, PermaBar red); the same CCs the switches themselves send, so a press lights the button before the DAW answers. |
| **CC 32–39** | Ring *value* of encoders 1–8 | 0–11 (clamped; 11 = full ring). Mode is kept from `CC 48–55` (default `Fill`). |
| **CC 40** | Speed dial ring value | 0–11 (clamped). |
| **CC 48–55** | Ring *mode* of encoders 1–8 | 0–5 = firmware modes `Fill`, `FillFromMax`, `CentreSingle`, `CentreBoth`, `SingleDot`, `SingleDotInverted`. 6+ ignored. |

Value and mode updates are independent (a DAW may send only values), so the
bridge keeps the last mode per encoder and the last value per encoder and
recombines them. All LED traffic goes through the `ILedManager` dirty cache,
so it batches/flushes exactly like locally-driven LEDs.

## Testing without a DAW

The Windows MIDI Services PowerShell module (installed with the Tools) is a
complete harness. Driver running, then in one elevated PowerShell session:

```powershell
Import-Module 'C:\Program Files\Windows MIDI Services\PowerShell\WindowsMidiServices\WindowsMidiServices.psd1'

$session  = Start-MidiSession -Name 'test-client'
$endpoint = Get-MidiEndpointDeviceInfo | Where-Object Name -eq 'Nocturn'
$conn     = Open-MidiEndpointConnection -Session $session -EndpointDeviceId $endpoint.EndpointDeviceId

# DAW -> driver: light page button 1 (CC 102 on), full green ring on encoder 1
Send-MidiMessage -Connection $conn -Words 0x20B0667F   # CC 102 val 127
Send-MidiMessage -Connection $conn -Words 0x20B0200B   # CC 32 val 11
# turn it off again
Send-MidiMessage -Connection $conn -Words 0x20B06600   # CC 102 val 0
```

The word is a UMP message type 2 (MIDI 1.0 channel voice) word, laid out
`0x2` + `0` (group) + status + data1 + data2, so e.g. CC 32 = 11 on channel 1
is `0x20B0200B` (status `0xB0`) — **the group nibble is zero**. Putting the
`0xB0` in the group nibble (`0x2B00200B`) sends status `0x00` instead, which
the driver logs but cannot map.

The LED changes are visible on the hardware immediately.

Surface → DAW direction: watch the endpoint in a second terminal (no id
needed — an interactive picker appears; choose `Nocturn`), then turn an
encoder / press a button on the Nocturn:

```
"C:\Program Files\Windows MIDI Services\Tools\midi.exe" endpoint monitor
```

Messages print decoded (encoders as CC 16–23, switches as CC 102–117 and
CC 118, speed dial as CC 24). The same capture works through the PowerShell cmdlet by
giving it a capture file (`Receive-MidiMessage -Connection $conn -Path
capture.ump -MessageCount 5 -TimeoutSeconds 30`; `-Path` is mandatory — it
is where received messages are written).

## Verification status (2026-10-19)

**Both directions pass on this PC** with the driver running:

- **DAW → surface** — injected messages produced the exact `MIDI in:` +
  `Flushed N LED pair(s)` sequences and lit the hardware (page button 1
  and Learn confirmed visually; ring writes verified at the USB layer).
- **Surface → DAW** — a full manual pass over the hardware captured
  **2 264 messages** in `midi endpoint monitor`: CC 16–23 (all eight
  encoders), CC 24 (speed dial, 390 events), notes 0–15 (all sixteen
  buttons) and note 81 (speed dial click) — the loopback switch format at
  the time; switches are CC 102–117 / CC 118 now — CC 80–81/83–88 (encoder
  and speed-dial touches; encoder 3's CC 82 was simply never touched),
  CC 89 (crossfader touch, bracketing its CC 8/9 movement), and matched
  CC 8 + CC 9 pairs (32/32 — the 14-bit pair survives intact). The same
  run's 10 k-line driver log shows **zero USB write failures and zero
  warnings**.

### The loopback echoes to the sender

The basic loopback delivers every message to all clients **including the
sender** — the driver receives its own input straight back (74 of 76
button presses in the verification run appear as immediate `MIDI in:`
lines, which then drive that button's LED: momentary press-lit feedback).
Harmless, but a switch input and its LED command are the *same CC* now
(102–117), so the codec must suppress its own echo — an echoed absolute 0
would switch a mapped toggle straight back off. That is what the
duplicate-press guard in `Nocturn.lua` is for. (When the capture above was
taken the switches still used notes 0–15 and the collision was the same.)
See [`reason-remote.md`](reason-remote.md) for the M3 plan.

## The DAW side of the contract

Reason 10 consumes this endpoint through the custom Remote surface in
[`../remote/`](../remote/README.md) — `Nocturn.luacodec` + `Nocturn.lua` +
`Nocturn.remotemap`, deployed with `remote/scripts/deploy.ps1`. The surface is
added manually in *Preferences → Control Surfaces → Add → Nuts > Nocturn*,
with the `Nocturn` port selected for **both** MIDI Input and MIDI Output. The
codec decodes CC 16–23 / CC 24 as relative deltas, CC 102–117 / CC 118 as
switches, CC 8 as the crossfader, and renders feedback to CC 102–109 (button
LEDs) and CC 32–40 / CC 48–55 (rings).

## Why not the `Windows.Devices.Midi2` NuGet package directly?

The official consumption path (NuGet `Windows.Devices.Midi2` +
`Microsoft.Windows.CsWinRT`) builds the projection with `cswinrt.exe`, which
requires the Windows SDK registry on the build machine. The driver instead
references the **pre-generated projection assemblies** vendored in
`lib/wms/` (the same files the installed `WindowsMidiServices` PowerShell
module loads — hence the app-local activation path is proven). When the API
ships in-box with Windows (November 2026 wave), swap `lib/wms` references for
the official `PackageReference` and the in-box `Windows.Devices.Midi2.dll`
takes precedence at runtime.
