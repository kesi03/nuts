namespace Nuts.Driver.Protocol;

public enum InputEventKind
{
    /// <summary>Encoder rotation, Index 0-7, Value = relative steps.</summary>
    Encoder,

    /// <summary>Encoder touch, Index 0-7, Value = 1 down / 0 up.</summary>
    EncoderTouch,

    /// <summary>Button press/release, Index 0-15, Value = 1/0.</summary>
    Button,

    /// <summary>Speed dial rotation, Value = relative steps.</summary>
    SpeedDial,

    /// <summary>Speed dial touch.</summary>
    SpeedDialTouch,

    /// <summary>Crossfader position, WideValue = 14-bit value.</summary>
    Xfader,

    /// <summary>Crossfader touch.</summary>
    XfaderTouch,

    /// <summary>Control number we don't know about yet (probe target).</summary>
    Unknown,
}

public readonly record struct InputEvent(
    InputEventKind Kind,
    int Index,
    byte Value,
    ushort WideValue = 0);
