namespace Nuts.Driver.Midi;

/// <summary>
/// MIDI numbers used between the Nocturn surface and the loopback endpoint
/// (appsettings section "Midi:Mapping"). All defaults match the tables in
/// docs/midi-mapping.md.
///
/// These numbers are a three-way contract: whatever is configured here must
/// also be used by the Reason codec — see remote/mapping/nocturn-controls.json
/// (source-of-truth table) and the lookup tables at the top of
/// remote/Codecs/Lua Codecs/Nuts/Nocturn.lua. Change all three together.
///
/// The arrays default to null ("use the Default* table") rather than to
/// prefilled arrays: the configuration binder appends to pre-existing
/// collections, so prefilled defaults would double up whenever the section
/// is present. A partially configured section leaves the remaining arrays
/// null and therefore at their defaults.
/// </summary>
public sealed class MidiMappingOptions
{
    public static readonly int[] DefaultEncoderCcs = [16, 17, 18, 19, 20, 21, 22, 23];
    public static readonly int[] DefaultEncoderTouchCcs = [80, 81, 82, 83, 84, 85, 86, 87];
    public static readonly int[] DefaultButtonCcs =
        [102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 113, 114, 115, 116, 117];
    public static readonly int[] DefaultXfaderCcs = [8, 9];
    public static readonly int[] DefaultRingValueCcs = [32, 33, 34, 35, 36, 37, 38, 39];
    public static readonly int[] DefaultRingModeCcs = [48, 49, 50, 51, 52, 53, 54, 55];

    /// <summary>Encoder rotations, one CC per encoder 0-7. Relative (two's complement). null = default.</summary>
    public int[]? EncoderCcs { get; set; }

    /// <summary>Encoder touch, one CC per encoder 0-7 (127 down / 0 up). Reserved for soft takeover. null = default.</summary>
    public int[]? EncoderTouchCcs { get; set; }

    /// <summary>
    /// Switches 0-15 (page row 0-7, PermaBar 8-15): one CC per index. The
    /// same CCs are the button-LED commands the DAW sends back, so this one
    /// table covers both directions. CCs rather than notes because a CC
    /// carries an absolute value - which is exactly what a switch state is -
    /// and it keeps the whole note range on the loopback free for a keyboard.
    /// null = default.
    /// </summary>
    public int[]? ButtonCcs { get; set; }

    /// <summary>Speed dial rotation: relative CC.</summary>
    public int SpeedDialCc { get; set; } = 24;

    /// <summary>Speed dial click switch: CC.</summary>
    public int SpeedDialButtonCc { get; set; } = 118;

    /// <summary>Speed dial touch: CC (127 down / 0 up). Reserved.</summary>
    public int SpeedDialTouchCc { get; set; } = 88;

    /// <summary>Crossfader: 14-bit CC pair [MSB, LSB]. null = default.</summary>
    public int[]? XfaderCcs { get; set; }

    /// <summary>Crossfader touch: CC (127 down / 0 up). Reserved.</summary>
    public int XfaderTouchCc { get; set; } = 89;

    /// <summary>Encoder ring values 0-11, one CC per encoder 0-7 (DAW → surface). null = default.</summary>
    public int[]? RingValueCcs { get; set; }

    /// <summary>Speed dial ring value 0-11 (DAW → surface).</summary>
    public int SpeedDialRingCc { get; set; } = 40;

    /// <summary>Encoder ring modes 0-5, one CC per encoder 0-7 (DAW → surface). null = default.</summary>
    public int[]? RingModeCcs { get; set; }

    /// <summary>
    /// Button behaviour per group (appsettings "Midi:Mapping:ButtonKinds"):
    /// "momentary" or "toggle", so the semantics can be re-picked without
    /// rebuilding. See <see cref="ButtonKind"/> and docs/midi-mapping.md.
    /// </summary>
    public ButtonKindsOptions ButtonKinds { get; set; } = new();
}

public sealed class ButtonKindsOptions
{
    /// <summary>
    /// Default kind for the 8 page-row buttons (green, under the encoders):
    /// "momentary" = press/release edges with the DAW owning the state and
    /// the LED; "toggle" = the driver latches and lights them.
    /// </summary>
    public string PageRow { get; set; } = "momentary";

    /// <summary>
    /// Default kind for the 8 PermaBar buttons (red, along the bottom).
    /// Kept at momentary; none of them are mapped yet except Page -/+.
    /// </summary>
    public string PermaBar { get; set; } = "momentary";

    /// <summary>
    /// Per-button overrides, keyed by surface button number 1-16 in surface
    /// order: 1-8 = page row (above the dials), 9-16 = PermaBar (Learn, View,
    /// Page-, Page+, User, FX, INST, MIXER). Overrides the group default, so
    /// e.g. "1": "toggle" makes button 1 a latching switch.
    /// </summary>
    public Dictionary<string, string> PerButton { get; set; } = new();
}
