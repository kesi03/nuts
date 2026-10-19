namespace Nuts.Driver.Led;

/// <summary>
/// Display modes for an encoder ring (11 LEDs).
/// Values 0-5 are firmware modes (register 72-79, written as mode &lt;&lt; 4);
/// <see cref="Vumeter"/> is host-computed and maps onto SingleDot on the wire.
/// </summary>
public enum RingMode : byte
{
    /// <summary>Firmware mode 0: fill clockwise from minimum.</summary>
    Fill = 0,

    /// <summary>Firmware mode 1: fill counter-clockwise from maximum.</summary>
    FillFromMax = 1,

    /// <summary>Firmware mode 2: centre-anchored, single direction.</summary>
    CentreSingle = 2,

    /// <summary>Firmware mode 3: centre-anchored, both directions.</summary>
    CentreBoth = 3,

    /// <summary>Firmware mode 4: single dot at value position.</summary>
    SingleDot = 4,

    /// <summary>Firmware mode 5: single dot, inverted.</summary>
    SingleDotInverted = 5,

    /// <summary>
    /// Host-driven VU meter. The firmware has no VU mode; the host recomputes
    /// the dot/fill value each flush tick (see <see cref="VuMeter"/>).
    /// </summary>
    Vumeter = 6,
}

public static class RingModeExtensions
{
    /// <summary>Wire encoding: high nibble of the mode byte.</summary>
    public static byte ToWireValue(this RingMode mode)
    {
        var firmware = mode == RingMode.Vumeter ? RingMode.SingleDot : mode;
        return (byte)((byte)firmware << Protocol.NocturnProtocol.RingModeShift);
    }
}
