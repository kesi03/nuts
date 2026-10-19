using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Nuts.Driver.Config;
using Nuts.Driver.Device;
using Nuts.Driver.Led;

namespace Nuts.Driver.Services;

/// <summary>
/// LED flusher: at a steady tick, collects dirty [ctrl,val] pairs from the
/// <see cref="ILedManager"/> cache and batch-writes them to the device.
/// Host-driven animation (e.g. VU meters) recomputes its ring values
/// before this tick.
/// </summary>
public sealed class LedFlushService : BackgroundService
{
    private readonly NocturnDevice _device;
    private readonly ILedManager _leds;
    private readonly LedOptions _options;
    private readonly ILogger<LedFlushService> _log;

    public LedFlushService(
        NocturnDevice device,
        ILedManager leds,
        DriverOptions options,
        ILogger<LedFlushService> log)
    {
        _device = device;
        _leds = leds;
        _options = options.Led;
        _log = log;
    }

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            await Task.Delay(_options.FlushIntervalMs, ct);
            if (!_device.IsConnected)
                continue;

            var pairs = _leds.CollectDirtyPairs();
            if (pairs.Count == 0)
                continue;

            _device.WritePairs(pairs, _options.MaxPairsPerTransfer);
            _log.LogDebug("Flushed {Count} LED pair(s).", pairs.Count);
        }
    }
}
