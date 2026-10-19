using LibUsbDotNet.Main;
using Microsoft.Extensions.Logging;
using Nuts.Driver.Device;
using Nuts.Driver.Protocol;

namespace Nuts.Driver.Probe;

/// <summary>
/// Milestone-1 hardware probe (`nuts-driver --probe`).
/// Answers the questions docs/protocol.md could not resolve statically:
///   1. Button index → physical position/name (press each button, watch log).
///   2. Button LED color encoding (sweeps candidate byte values per index).
///   3. Ring mode/value behaviour per encoder (sweeps modes and segments).
/// </summary>
public sealed class ProbeTool
{
    private readonly NocturnDevice _device;
    private readonly ILogger<ProbeTool> _log;

    public ProbeTool(NocturnDevice device, ILogger<ProbeTool> log)
    {
        _device = device;
        _log = log;
    }

    public async Task Run(CancellationToken ct, bool inputsOnly = false)
    {
        if (!_device.TryConnect())
        {
            _log.LogError("Probe aborted: device not reachable.");
            return;
        }

        _log.LogInformation("=== Phase 1: input identification (45s) ===");
        _log.LogInformation("Press EVERY button in order; touch every encoder; move faders.");
        var parser = new InputParser();
        var buffer = new byte[64];
        var events = new List<InputEvent>();
        var deadline = DateTime.UtcNow.AddSeconds(45);
        while (DateTime.UtcNow < deadline && !ct.IsCancellationRequested)
        {
            var read = _device.Read(buffer, 250);
            if (read <= 0)
                continue;
            _log.LogInformation("RAW {Hex}",
                Convert.ToHexString(buffer.AsSpan(0, read)));
            events.Clear();
            parser.Push(buffer.AsSpan(0, read), events);
            foreach (var ev in events)
                _log.LogInformation("INPUT {Kind} idx {Index} val {Value}", ev.Kind, ev.Index, ev.Value);
        }

        if (inputsOnly)
        {
            _log.LogInformation("Input-only probe complete.");
            return;
        }

        _log.LogInformation("=== Phase 2: button LED color sweep ===");
        _log.LogInformation("Watch the buttons: note which values light green vs red, then record them in NocturnProtocol.EncodeLedState.");
        // Candidate encodings seen in the wild: 0/1 on-off, 0x7F classic MIDI,
        // and possible color bytes. Sweep per index so the mapping is per-button.
        byte[] candidates = [0x00, 0x01, 0x02, 0x03, 0x07, 0x0F, 0x10, 0x20, 0x40, 0x7F];
        for (var index = 0; index < NocturnProtocol.ButtonCount; index++)
        {
            _log.LogInformation("Button index {Index} (0x{Ctrl:X2}): sweeping values...", index,
                NocturnProtocol.ButtonLedBase + index);
            foreach (var value in candidates)
            {
                _device.WritePairs(
                    [new KeyValuePair<byte, byte>((byte)(NocturnProtocol.ButtonLedBase + index), value)], 4);
                await Task.Delay(600, ct);
            }
            _device.WritePairs(
                [new KeyValuePair<byte, byte>((byte)(NocturnProtocol.ButtonLedBase + index), 0x00)], 4);
            await Task.Delay(300, ct);
        }

        _log.LogInformation("=== Phase 3: ring mode sweep ===");
        _log.LogInformation("Each encoder cycles modes 0-5 with a mid-ring value; note which mode matches which display.");
        for (var encoder = 0; encoder < NocturnProtocol.EncoderCount; encoder++)
        {
            _log.LogInformation("Encoder {Encoder}: sweeping ring modes...", encoder);
            for (byte mode = 0; mode <= 5; mode++)
            {
                _device.WritePairs(
                [
                    new KeyValuePair<byte, byte>((byte)(NocturnProtocol.RingModeBase + encoder), (byte)(mode << 4)),
                    new KeyValuePair<byte, byte>((byte)(NocturnProtocol.RingValueBase + encoder), 5),
                ], 4);
                await Task.Delay(800, ct);
            }
        }

        _log.LogInformation("=== Phase 4: segment granularity check ===");
        _log.LogInformation("Encoder 0 fills 0..11 to confirm the 11-segment model visually.");
        for (byte value = 0; value <= NocturnProtocol.RingSegments; value++)
        {
            _device.WritePairs(
            [
                new KeyValuePair<byte, byte>(NocturnProtocol.RingModeBase, 0x00), // Fill
                new KeyValuePair<byte, byte>(NocturnProtocol.RingValueBase, value),
            ], 4);
            await Task.Delay(400, ct);
        }

        _log.LogInformation("=== Phase 5: speed dial ring (value only, no mode) ===");
        for (byte value = 0; value <= NocturnProtocol.RingSegments; value++)
        {
            _device.WritePairs([new KeyValuePair<byte, byte>(NocturnProtocol.SpeedDialRingValue, value)], 4);
            await Task.Delay(400, ct);
        }

        _log.LogInformation("Probe complete. All outputs reset to off.");
        for (var i = 0; i < NocturnProtocol.ButtonCount; i++)
            _device.WritePairs([new KeyValuePair<byte, byte>((byte)(NocturnProtocol.ButtonLedBase + i), 0x00)], 4);
    }
}
