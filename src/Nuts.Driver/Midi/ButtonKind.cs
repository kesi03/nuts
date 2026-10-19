namespace Nuts.Driver.Midi;

/// <summary>
/// Wire behaviour of a physical button, and therefore who owns its state and
/// its LED.
///
/// This is the "hardware half" of the driver/codec split: the driver knows
/// what a button IS (a momentary switch, or a latching one it keeps state
/// for), the Reason codec knows what it DRIVES (a Toggle remotable, a Trig
/// navigation target, ...). Keeping the two apart means the surface can be
/// retuned from configuration on both halves without rebuilding.
/// </summary>
public enum ButtonKind
{
    /// <summary>
    /// 127 on press, 0 on release - a plain momentary switch. The DAW owns
    /// the latched state (Reason's Toggle remotables switch on the 0 -> 1
    /// edge, so one press = one toggle) and drives the LED from its own
    /// feedback. Every factory Reason surface uses buttons this way.
    /// </summary>
    Momentary,

    /// <summary>
    /// The driver owns a latch: a press flips it and sends the new state
    /// (127 on / 0 off), a release sends nothing, and the LED mirrors the
    /// latch. DAW feedback still overwrites the latch, so the host's state
    /// stays the truth. (The ahihi/autocrap OnOff{Toggle} model.)
    /// </summary>
    Toggle,
}

/// <summary>Parses configuration strings into <see cref="ButtonKind"/> values.</summary>
public static class ButtonKinds
{
    public static ButtonKind Parse(string? raw, string key) =>
        raw?.Trim().ToLowerInvariant() switch
        {
            null or "" or "momentary" => ButtonKind.Momentary,
            "toggle" => ButtonKind.Toggle,
            _ => throw new InvalidOperationException(
                $"{key} must be \"momentary\" or \"toggle\" (saw \"{raw}\")."),
        };
}
