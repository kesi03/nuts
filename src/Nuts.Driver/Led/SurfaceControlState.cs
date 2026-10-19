namespace Nuts.Driver.Led;

/// <summary>
/// Desired LED state of one surface "column": an encoder ring plus the
/// button below it. Buttons 8-15 (PermaBar) have no ring and are driven
/// individually via <see cref="ILedManager.SetButtonLed"/>.
/// </summary>
public readonly record struct SurfaceControlState(
    LedState ButtonLed = LedState.Off,
    RingMode RingMode = RingMode.Fill,
    byte RingValue = 0)
{
    public static SurfaceControlState Off { get; } = new();

    /// <summary>Ring state for VU-style monitoring of a channel level.</summary>
    public static SurfaceControlState Vu(byte level) =>
        new(LedState.Off, RingMode.Vumeter, level);
}
