using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Nuts.Driver.Config;
using Nuts.Driver.Device;
using Nuts.Driver.Led;
using Nuts.Driver.Protocol;
using Nuts.Driver.Surface;

namespace Nuts.Driver.Services;

/// <summary>
/// Input pump: keeps the device connected, reads IN reports, parses them
/// into events, and replays LED state after a reconnect (the device loses
/// all LED state when it drops off the bus).
/// </summary>
public sealed class NocturnListenerService : BackgroundService
{
    private readonly NocturnDevice _device;
    private readonly ILedManager _leds;
    private readonly UsbOptions _options;
    private readonly ILogger<NocturnListenerService> _log;
    private readonly InputParser _parser = new();
    private readonly List<InputEvent> _events = new();
    private int _timeouts;

    /// <summary>
    /// Raised for every parsed input event (e.g. consumed by the MIDI bridge).
    /// </summary>
    public event Action<InputEvent>? InputReceived;

    public NocturnListenerService(
        NocturnDevice device,
        ILedManager leds,
        DriverOptions options,
        ILogger<NocturnListenerService> log)
    {
        _device = device;
        _leds = leds;
        _options = options.Usb;
        _log = log;

        _device.Reconnected += _leds.MarkAllDirty;
    }

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        var buffer = new byte[64];

        while (!ct.IsCancellationRequested)
        {
            if (!_device.IsConnected)
            {
                if (!_device.TryConnect())
                {
                    await Delay(_options.ReconnectIntervalMs, ct);
                    continue;
                }
            }

            var read = _device.Read(buffer, _options.ReadTimeoutMs);
            if (read <= 0)
            {
                // Heartbeat so "no data at all" is distinguishable from
                // "data arriving but not parsed" when diagnosing the USB path.
                _timeouts++;
                if (_timeouts % 20 == 0)
                    _log.LogDebug("IN idle: {Count} consecutive read timeouts.", _timeouts);
                continue;
            }

            _timeouts = 0;
            _log.LogTrace(
                "IN {Count} byte(s): {Hex}", read,
                BitConverter.ToString(buffer, 0, read));

            _events.Clear();
            _parser.Push(buffer.AsSpan(0, read), _events);
            foreach (var ev in _events)
            {
                InputReceived?.Invoke(ev);
                Handle(ev);
            }
        }
    }

    private void Handle(InputEvent ev)
    {
        switch (ev.Kind)
        {
            case InputEventKind.Button:
                _log.LogInformation(
                    "Button {Name} (idx {Index}) {Action}",
                    ButtonNames.Describe(ev.Index), ev.Index,
                    ev.Value != 0 ? "pressed" : "released");
                break;

            case InputEventKind.EncoderTouch:
            case InputEventKind.SpeedDialTouch:
            case InputEventKind.XfaderTouch:
                _log.LogDebug(
                    "Touch {Kind} idx {Index}: {Value}", ev.Kind, ev.Index, ev.Value);
                break;

            case InputEventKind.Xfader:
                _log.LogDebug("Xfader: {Value} (14-bit {Wide})", ev.Value, ev.WideValue);
                break;

            case InputEventKind.Unknown:
                _log.LogDebug("Unknown control {Num} = {Value}", ev.Index, ev.Value);
                break;

            default:
                _log.LogDebug(
                    "{Kind} idx {Index}: {Value}", ev.Kind, ev.Index, ev.Value);
                break;
        }
    }

    private static Task Delay(int ms, CancellationToken ct) =>
        Task.Delay(TimeSpan.FromMilliseconds(ms), ct);
}
