using Nuts.Driver.Protocol;

namespace Nuts.Driver.Led;

/// <summary>
/// Diffing LED state cache. Desired state lives in per-control arrays; a
/// parallel "sent" cache records what the device is believed to show.
/// <see cref="CollectDirtyPairs"/> diffs the two at segment granularity
/// (ring values are quantized to 11 segments before comparison, so
/// sub-segment churn never reaches the wire).
/// </summary>
public sealed class LedManager : ILedManager
{
    private readonly object _gate = new();

    // Column model: 8 encoders, each with a ring and a button below it.
    private readonly SurfaceControlState[] _desired = new SurfaceControlState[NocturnProtocol.EncoderCount];
    private readonly SurfaceControlState?[] _sent = new SurfaceControlState?[NocturnProtocol.EncoderCount];

    // PermaBar LEDs (buttons 8-15) are independent of any ring.
    private readonly LedState[] _permaDesired = new LedState[NocturnProtocol.ButtonCount - NocturnProtocol.PermaBarButtonFirst];
    private readonly LedState?[] _permaSent = new LedState?[NocturnProtocol.ButtonCount - NocturnProtocol.PermaBarButtonFirst];

    private byte _speedDialDesired;
    private byte? _speedDialSent;

    public void SetColumn(int column, SurfaceControlState state)
    {
        CheckColumn(column);
        lock (_gate)
        {
            _desired[column] = state with { RingValue = QuantizeRing(state.RingValue) };
        }
    }

    public void SetButtonLed(int index, LedState state)
    {
        if (index < 0 || index >= NocturnProtocol.ButtonCount)
            throw new ArgumentOutOfRangeException(nameof(index));

        lock (_gate)
        {
            if (index < NocturnProtocol.PermaBarButtonFirst)
                _desired[index] = _desired[index] with { ButtonLed = state };
            else
                _permaDesired[index - NocturnProtocol.PermaBarButtonFirst] = state;
        }
    }

    public void SetRing(int encoder, RingMode mode, byte value)
    {
        CheckColumn(encoder);
        lock (_gate)
        {
            _desired[encoder] = _desired[encoder] with { RingMode = mode, RingValue = QuantizeRing(value) };
        }
    }

    public void SetSpeedDialRing(byte value)
    {
        lock (_gate)
        {
            _speedDialDesired = QuantizeRing(value);
        }
    }

    public void MarkAllDirty()
    {
        lock (_gate)
        {
            Array.Clear(_sent);
            Array.Clear(_permaSent);
            _speedDialSent = null;
        }
    }

    public IReadOnlyList<KeyValuePair<byte, byte>> CollectDirtyPairs()
    {
        var pairs = new List<KeyValuePair<byte, byte>>(NocturnProtocol.EncoderCount * 2 + 9);

        lock (_gate)
        {
            for (var i = 0; i < NocturnProtocol.EncoderCount; i++)
            {
                var desired = _desired[i];
                var sent = _sent[i];

                if (sent is null || sent.Value.RingMode != desired.RingMode)
                {
                    pairs.Add(new KeyValuePair<byte, byte>(
                        (byte)(NocturnProtocol.RingModeBase + i), desired.RingMode.ToWireValue()));
                }

                if (sent is null || sent.Value.RingValue != desired.RingValue)
                {
                    pairs.Add(new KeyValuePair<byte, byte>(
                        (byte)(NocturnProtocol.RingValueBase + i), desired.RingValue));
                }

                if (sent is null || sent.Value.ButtonLed != desired.ButtonLed)
                {
                    pairs.Add(new KeyValuePair<byte, byte>(
                        (byte)(NocturnProtocol.ButtonLedBase + i), NocturnProtocol.EncodeLedState(desired.ButtonLed)));
                }

                _sent[i] = desired;
            }

            for (var j = 0; j < _permaDesired.Length; j++)
            {
                if (_permaSent[j] == _permaDesired[j])
                    continue;

                var index = NocturnProtocol.PermaBarButtonFirst + j;
                pairs.Add(new KeyValuePair<byte, byte>(
                    (byte)(NocturnProtocol.ButtonLedBase + index),
                    NocturnProtocol.EncodeLedState(_permaDesired[j])));
                _permaSent[j] = _permaDesired[j];
            }

            if (_speedDialSent != _speedDialDesired)
            {
                pairs.Add(new KeyValuePair<byte, byte>(
                    NocturnProtocol.SpeedDialRingValue, _speedDialDesired));
                _speedDialSent = _speedDialDesired;
            }
        }

        return pairs;
    }

    /// <summary>Ring values are 11 discrete segments; clamp before diffing.</summary>
    private static byte QuantizeRing(byte value) =>
        (byte)Math.Clamp(value, (byte)0, (byte)NocturnProtocol.RingSegments);

    private static void CheckColumn(int column)
    {
        if (column < 0 || column >= NocturnProtocol.EncoderCount)
            throw new ArgumentOutOfRangeException(nameof(column));
    }
}
