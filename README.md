# nuts — a Novation Nocturn driver

C# driver for the Novation Nocturn (VID `0x1235` / PID `0x000A`), built around
the LED State Architecture spec and grounded in the protocol research in
[`docs/protocol.md`](docs/protocol.md).

## Layout

```
Nuts.sln
nuget.config                     NuGet feeds (nuget.org only, local ./packages cache)
Directory.Build.props            Shared build settings (net10.0, nullable, version)
src/Nuts.Driver/
  Program.cs                     Entry point (generic host, DI, --probe mode)
  appsettings.json               Runtime configuration (USB, LED, MIDI)
  Config/DriverOptions.cs        Typed config + validation (hex IDs supported)
  Protocol/NocturnProtocol.cs    Wire constants: control numbers, init sequence
  Protocol/InputParser.cs        [0xB0, num, val] triples -> InputEvents
  Device/NocturnDevice.cs        libusb/WinUSB open, init, reconnect, batched writes
  Led/                           LED State Architecture:
    LedState.cs                  Off / On (wire is on/off only; color is fixed per row)
    RingMode.cs                  6 firmware ring modes + host-driven Vumeter
    SurfaceControlState.cs       one surface "column" (ring + button)
    ILedManager.cs, LedManager.cs  diffing dirty-cache, segment-granularity dedupe
    VuMeter.cs                   attack/release envelope for software VU
  Surface/                       SurfaceContext (User/FX/Inst/Mixer), button names
  Services/NocturnListenerService.cs  input pump + LED replay after reconnect
  Services/LedFlushService.cs    periodic dirty-pair flush (<=4 pairs / transfer)
  Midi/MidiMapping.cs            surface <-> MIDI 1.0 UMP message tables
  Midi/MidiBridgeService.cs      Windows MIDI Services bridge (loopback endpoint)
  Probe/ProbeTool.cs             Milestone-1 hardware probe
lib/wms/                         vendored Windows MIDI Services projection (see csproj)
pages/                           Reason Remote page templates, one YAML per device scope
remote/                          Reason Remote codec + generated .remotemap + scripts
docs/protocol.md                 protocol reference + open questions
docs/midi-mapping.md             MIDI mapping tables, setup, Reason 10 notes
docs/reason-remote.md            Reason 10 Remote research + codec plan (Milestone 3)
docs/pages-templates.md          the page-template format and the map generator
```

## Prerequisites

1. .NET 10 SDK.
2. The Nocturn bound to **WinUSB** — one-time swap with
   [`driver/sign-and-install.ps1`](driver/sign-and-install.ps1)
   (revert: `driver/uninstall-restore.ps1`). No Zadig needed; the INF is
   self-signed against the nuts signing cert created by the script.
3. For DAW integration (Milestone 2): the **Windows MIDI Services Transports
   package** (<https://github.com/microsoft/MIDI/releases> — provides the
   basic MIDI 1.0 loopback transport; the driver creates the `Nocturn`
   loopback endpoint itself). Classic WinMM/MME apps such as Reason 10 see
   the port only after the Windows update enabling MIDI 1.0 ports for WMS
   endpoints (controlled rollout starting end of November 2026). Full setup
   notes and the message tables: [`docs/midi-mapping.md`](docs/midi-mapping.md).

## Run

```
dotnet build Nuts.sln
dotnet run --project src\Nuts.Driver                # run the driver
dotnet run --project src\Nuts.Driver -- --probe     # Milestone-1 hardware probe
```

Milestone-2 MIDI acceptance test (driver must be running):

```
powershell -ExecutionPolicy Bypass -File tools\midi-loop-test.ps1 -SendLedTest
```

The probe answers the questions static research could not
(`docs/protocol.md` → open questions):

1. **Phase 1** — press every button / touch every encoder; the log maps wire
   indices to physical controls. *(Done — confirmed button map in
   `docs/protocol.md`.)*
2. **Phase 2** — sweeps candidate LED byte values per button index.
   *(Done — the wire is on/off only, `0x7F`/`0x00`, with the color fixed per
   hardware row; recorded in `Protocol/NocturnProtocol.cs` → `EncodeLedState`.)*
3. **Phases 3–5** — ring modes 0–5 per encoder, 11-segment granularity check,
   and the speed-dial ring (value-only). *(Done — results in `docs/protocol.md`.)*

## Configuration

All runtime settings live in `src/Nuts.Driver/appsettings.json` (copied next
to the executable on build; the driver reads it from its own directory, so it
works from any working directory). Numeric fields accept hex (`"0x1235"`)
or decimal.

| Section | Key | Meaning |
|---|---|---|
| `Usb` | `VendorId` / `ProductId` | Device IDs (defaults are the Nocturn) |
| `Usb` | `OutEndpoint` / `InEndpoint` | Interrupt endpoints (`0x02` / `0x81`) |
| `Usb` | `ReadTimeoutMs` / `WriteTimeoutMs` | USB timeouts |
| `Usb` | `ReconnectIntervalMs` | Retry interval when unplugged |
| `Usb` | `SendFactoryInit` | Send reset + undocumented config pairs on open |
| `Led` | `FlushIntervalMs` | Dirty-LED flush tick |
| `Led` | `MaxPairsPerTransfer` | Pairs per 8-byte interrupt transfer (1–4) |
| `Midi` | `Enabled` | Bridge to a Windows MIDI Services loopback endpoint |
| `Midi` | `SessionName` / `EndpointName` | WMS session and loopback endpoint names |
| `Midi` | `CreateLoopbackIfMissing` | Self-heal the loopback after a MIDI service restart |
