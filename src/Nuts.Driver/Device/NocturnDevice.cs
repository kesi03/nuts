using LibUsbDotNet;
using LibUsbDotNet.Main;
using Microsoft.Extensions.Logging;
using Nuts.Driver.Config;
using Nuts.Driver.Protocol;

namespace Nuts.Driver.Device;

/// <summary>
/// Owns the libusb handle to the Nocturn: connect/reconnect with backoff,
/// init sequence on open, chunked reads, and batched pair writes (max 4
/// pairs / 8 bytes per interrupt transfer).
/// </summary>
public sealed class NocturnDevice : IDisposable
{
    private readonly UsbOptions _options;
    private readonly ILogger<NocturnDevice> _log;
    private readonly object _writeGate = new();

    private UsbDevice? _device;
    private IUsbDevice? _wholeDevice;
    private UsbEndpointWriter? _writer;
    private UsbEndpointReader? _reader;

    public NocturnDevice(UsbOptions options, ILogger<NocturnDevice> log)
    {
        _options = options;
        _log = log;
    }

    public bool IsConnected => _device is { IsOpen: true };

    /// <summary>Raised after a successful (re)connect, init sequence included.</summary>
    public event Action? Reconnected;

    public bool TryConnect()
    {
        if (IsConnected)
            return true;

        var finder = new UsbDeviceFinder(_options.VendorId, _options.ProductId);
        UsbDevice? device = null;
        try
        {
            device = UsbDevice.OpenUsbDevice(finder);
            if (device is null)
            {
                _log.LogWarning(
                    "Nocturn not found (VID 0x{Vid:X4} / PID 0x{Pid:X4}). Is it plugged in and switched to WinUSB via Zadig?",
                    _options.VendorId, _options.ProductId);
                return false;
            }

            if (device is IUsbDevice whole)
            {
                whole.SetConfiguration(1);
                whole.ClaimInterface(0);
                _wholeDevice = whole;
            }

            _device = device;
            _writer = device.OpenEndpointWriter((WriteEndpointID)_options.OutEndpoint);
            _reader = device.OpenEndpointReader((ReadEndpointID)_options.InEndpoint, 64);

            if (_options.SendFactoryInit)
                SendInit();

            _log.LogInformation("Connected to Nocturn.");
            Reconnected?.Invoke();
            return true;
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Failed to open Nocturn.");
            device?.Close();
            _device = null;
            _wholeDevice = null;
            _writer = null;
            _reader = null;
            return false;
        }
    }

    /// <summary>Reset + factory config pairs (see docs/protocol.md).</summary>
    public void SendInit()
    {
        lock (_writeGate)
        {
            WriteRaw(NocturnProtocol.ResetPacket);
            WritePairs(NocturnProtocol.FactoryConfigPairs
                .Select(p => new KeyValuePair<byte, byte>(p.Ctrl, p.Val))
                .ToArray());
            _log.LogDebug("Init sequence sent.");
        }
    }

    /// <summary>Read one chunk from the IN endpoint. Returns 0 on timeout.</summary>
    public int Read(byte[] buffer, int timeoutMs)
    {
        var reader = _reader;
        if (reader is null)
            return 0;

        var ec = reader.Read(buffer, 0, buffer.Length, timeoutMs, out var transferred);
        if (ec != ErrorCode.Success && ec != ErrorCode.IoTimedOut)
        {
            _log.LogWarning("IN read failed: {Error}; treating as disconnect.", ec);
            Disconnect();
        }
        return (int)transferred;
    }

    /// <summary>Write [ctrl,val] pairs, chunked to MaxPairsPerTransfer.</summary>
    public void WritePairs(
        IReadOnlyList<KeyValuePair<byte, byte>> pairs,
        int maxPairsPerTransfer = NocturnProtocol.MaxPairsPerTransfer)
    {
        lock (_writeGate)
        {
            var buffer = new byte[pairs.Count * NocturnProtocol.PairSize];
            for (var i = 0; i < pairs.Count; i++)
            {
                buffer[i * 2] = pairs[i].Key;
                buffer[i * 2 + 1] = pairs[i].Value;
            }

            var chunk = maxPairsPerTransfer * NocturnProtocol.PairSize;
            for (var offset = 0; offset < buffer.Length; offset += chunk)
            {
                var length = Math.Min(chunk, buffer.Length - offset);
                WriteRaw(buffer.AsSpan(offset, length).ToArray());
            }
        }
    }

    private void WriteRaw(byte[] data)
    {
        var writer = _writer;
        if (writer is null)
            return;

        var ec = writer.Write(data, 0, data.Length, _options.WriteTimeoutMs, out _);
        if (ec != ErrorCode.Success)
        {
            _log.LogWarning("OUT write failed: {Error}; treating as disconnect.", ec);
            Disconnect();
        }
    }

    public void Disconnect()
    {
        lock (_writeGate)
        {
            if (_device is null)
                return;

            _log.LogInformation("Disconnected from Nocturn.");
            try
            {
                if (_wholeDevice is { } whole)
                {
                    whole.ReleaseInterface(0);
                    whole.ResetDevice();
                }
                _device.Close();
            }
            catch (Exception ex)
            {
                _log.LogDebug(ex, "Error while closing USB handle.");
            }

            _device = null;
            _wholeDevice = null;
            _writer = null;
            _reader = null;
        }
    }

    public void Dispose() => Disconnect();
}
