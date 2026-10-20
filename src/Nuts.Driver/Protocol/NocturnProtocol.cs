namespace Nuts.Driver.Protocol;

/// <summary>
/// Raw wire constants for the Novation Nocturn (VID 0x1235 / PID 0x000A).
/// Sources: docs/protocol.md, ahihi/autocrap, dewert/nocturn-linux-midi.
/// </summary>
public static class NocturnProtocol
{
    public const int VendorId = 0x1235;
    public const int ProductId = 0x000A;

    // ---- framing ----

    /// <summary>
    /// Status byte at the start of every input report: [0xB0] then one or
    /// more [num, val] pairs (not a prefix per pair). Confirmed by capture.
    /// </summary>
    public const byte InputStatusPrefix = 0xB0;

    /// <summary>Bytes per [ctrl,val] output pair.</summary>
    public const int PairSize = 2;

    /// <summary>Max pairs per 8-byte interrupt transfer.</summary>
    public const int MaxPairsPerTransfer = 4;

    // ---- input controls (device -> host) ----

    public const byte EncoderBase = 64;        // 64-71: encoders 0-7 (relative)

    /// <summary>
    /// Crossfader coarse byte: the top 7 bits of the 8-bit position. The
    /// device sends the pair coarse-then-fine (confirmed by capture
    /// "B0-48-xx-B0-49-yy").
    /// </summary>
    public const byte XfaderMsb = 72;

    /// <summary>
    /// Crossfader fine byte. The hardware position is 8-bit, split as
    /// coarse + fine: ahihi/autocrap's EightBit kind composes it as
    /// "msb &lt;&lt; 1 | (lsb != 0)". The fine byte is therefore 0 or 1.
    /// </summary>
    public const byte XfaderLsb = 73;

    public const byte SpeedDial = 74;          // horizontal speed dial
    public const byte SpeedDialButton = 81;      // speed dial click (not part of the 16-button block)
    public const byte SpeedDialTouch = 82;
    public const byte XfaderTouch = 83;
    public const byte EncoderTouchBase = 96;   // 96-103: encoder touch (not press)
    public const byte ButtonBase = 112;        // 112-127: buttons 0-15

    public const int EncoderCount = 8;
    public const int ButtonCount = 16;

    /// <summary>Buttons 0-7: assignable "page" buttons under the encoders.</summary>
    public const int PageButtonFirst = 0;

    /// <summary>How many of the 16 switches are page buttons (the rest are PermaBar).</summary>
    public const int PageRowCount = PermaBarButtonFirst;

    /// <summary>Buttons 8-15: fixed system "PermaBar" buttons.</summary>
    public const int PermaBarButtonFirst = 8;

    // ---- output controls (host -> device) ----

    public const byte RingValueBase = 64;      // 64-71: encoder ring LED values
    public const byte RingModeBase = 72;       // 72-79: encoder ring modes (mode << 4)
    public const byte SpeedDialRingValue = 80; // speed dial ring: fill only, no mode
    public const byte ButtonLedBase = 112;     // 112-127: button LEDs

    /// <summary>Each encoder ring has 11 LEDs.</summary>
    public const int RingSegments = 11;

    /// <summary>Ring mode value is stored in the high nibble: [ctrl, mode &lt;&lt; 4].</summary>
    public const int RingModeShift = 4;

    // ---- init sequence ----

    /// <summary>Raw 3-byte reset, sent before any pairs: B0 00 00.</summary>
    public static readonly byte[] ResetPacket = [0xB0, 0x00, 0x00];

    /// <summary>
    /// Undocumented config pairs observed in dewert/nocturn-linux-midi.
    /// Not strictly required (autocrap omits them) but sent by default.
    /// </summary>
    public static readonly (byte Ctrl, byte Val)[] FactoryConfigPairs =
    [
        (0x28, 0x00), (0x2B, 0x4A), (0x2C, 0x00), (0x2E, 0x35),
        (0x2A, 0x02), (0x2C, 0x72), (0x2E, 0x30),
        (0x7F, 0x00),
    ];

    /// <summary>
    /// Button LED wire values. CONFIRMED by hardware probe (2026-10-19):
    /// the sweep of 0x01-0x7F lit every button with the same color, so the
    /// byte is on/off only and color is fixed per row by hardware (page
    /// buttons green, PermaBar red). 0x7F is used for "on" (full-level MIDI
    /// convention; every non-zero value lit).
    /// </summary>
    public static byte EncodeLedState(Led.LedState state) => state switch
    {
        Led.LedState.Off => 0x00,
        Led.LedState.On => 0x7F,
        _ => 0x00,
    };
}
