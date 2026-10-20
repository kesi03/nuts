using Nuts.Driver.Protocol;

namespace Nuts.Driver.Midi;

/// <summary>
/// Wire-level MIDI mapping between the Nocturn surface and a Windows MIDI
/// Services loopback endpoint ("Nocturn"). Everything is MIDI 1.0 channel
/// voice on channel 1 (zero-based channel 0), carried as UMP 32-bit words.
///
/// Which CC numbers are used is configurable through
/// <see cref="MidiMappingOptions"/> (appsettings "Midi:Mapping"), so the
/// layout can be re-picked without rebuilding. Controls that bank go through
/// <see cref="PageModel"/> (appsettings "Midi:Paging") instead: the same
/// physical dial or switch sends a different CC depending on the active
/// page. Whatever is configured here must match the Reason codec's tables -
/// remote/mapping/nocturn-controls.json and the lookups at the top of
/// Nocturn.lua. The defaults are documented in docs/midi-mapping.md.
/// </summary>
public sealed class MidiMapping
{
    public const byte Channel = 0; // MIDI channel 1 in 1-based terms

    private readonly byte[] _encoderCcs;
    private readonly byte[] _encoderTouchCcs;
    private readonly byte[] _buttonCcs;
    private readonly byte[] _ringValueCcs;
    private readonly byte[] _ringModeCcs;

    /// <summary>Page/banking model; owns every banked CC number.</summary>
    public PageModel Pages { get; }

    public byte SpeedDialCc { get; }
    public byte SpeedDialTouchCc { get; }
    public byte SpeedDialButtonCc { get; }
    public byte XfaderCcMsB { get; }
    public byte XfaderCcLsB { get; }
    public byte XfaderTouchCc { get; }
    public byte SpeedDialRingCc { get; }

    public MidiMapping(MidiMappingOptions options, PagingOptions paging)
    {
        _encoderCcs = ReadList(
            options.EncoderCcs ?? MidiMappingOptions.DefaultEncoderCcs, 8, "Midi:Mapping:EncoderCcs");
        _encoderTouchCcs = ReadList(
            options.EncoderTouchCcs ?? MidiMappingOptions.DefaultEncoderTouchCcs, 8, "Midi:Mapping:EncoderTouchCcs");
        _buttonCcs = ReadList(
            options.ButtonCcs ?? MidiMappingOptions.DefaultButtonCcs, 16, "Midi:Mapping:ButtonCcs");
        _ringValueCcs = ReadList(
            options.RingValueCcs ?? MidiMappingOptions.DefaultRingValueCcs, 8, "Midi:Mapping:RingValueCcs");
        _ringModeCcs = ReadList(
            options.RingModeCcs ?? MidiMappingOptions.DefaultRingModeCcs, 8, "Midi:Mapping:RingModeCcs");

        SpeedDialCc = ReadNumber(options.SpeedDialCc, "Midi:Mapping:SpeedDialCc");
        SpeedDialButtonCc = ReadNumber(options.SpeedDialButtonCc, "Midi:Mapping:SpeedDialButtonCc");
        SpeedDialTouchCc = ReadNumber(options.SpeedDialTouchCc, "Midi:Mapping:SpeedDialTouchCc");
        SpeedDialRingCc = ReadNumber(options.SpeedDialRingCc, "Midi:Mapping:SpeedDialRingCc");
        XfaderTouchCc = ReadNumber(options.XfaderTouchCc, "Midi:Mapping:XfaderTouchCc");

        var xfaderCcs = options.XfaderCcs ?? MidiMappingOptions.DefaultXfaderCcs;
        if (xfaderCcs.Length != 2)
            throw new InvalidOperationException(
                $"Midi:Mapping:XfaderCcs must contain exactly two CC numbers [MSB, LSB] (bound {xfaderCcs.Length}).");
        XfaderCcMsB = ReadNumber(xfaderCcs[0], "Midi:Mapping:XfaderCcs");
        XfaderCcLsB = ReadNumber(xfaderCcs[1], "Midi:Mapping:XfaderCcs");

        Pages = PageModel.Create(paging, _encoderCcs, _buttonCcs);
        Pages.ValidateAgainst(SharedCcs());
    }

    /// <summary>
    /// Every CC number that stays meaningful whatever the page is. A banked
    /// CC colliding with one of these would make an incoming message
    /// ambiguous, so the overlap is a configuration error rather than a
    /// silent misroute.
    ///
    /// The leading entries of the encoder and switch tables are excluded:
    /// when those controls bank, the page tables replace them, and page 1 is
    /// deliberately the same layout they used to describe.
    /// </summary>
    private byte[] SharedCcs()
    {
        var shared = new List<byte>
        {
            SpeedDialCc, SpeedDialButtonCc, SpeedDialTouchCc, SpeedDialRingCc,
            XfaderCcMsB, XfaderCcLsB, XfaderTouchCc,
        };
        shared.AddRange(_encoderCcs.Skip(Pages.BankedEncoders));
        shared.AddRange(_encoderTouchCcs);
        shared.AddRange(_ringValueCcs);
        shared.AddRange(_ringModeCcs);
        shared.AddRange(_buttonCcs.Skip(Pages.BankedButtons));
        return shared.Distinct().ToArray();
    }

    /// <summary>
    /// Builds the UMP word for a MIDI 1.0 channel-voice message.
    /// UMP message type 2 (MIDI 1.0 CV), group 0: word = 0x20ssdd00 where
    /// ss = status byte (channel in low nibble), dd = data bytes.
    /// </summary>
    public static uint ChannelVoice(byte status, byte data1, byte data2) =>
        0x2000_0000u | ((uint)(status | Channel) << 16) | ((uint)data1 << 8) | data2;

    /// <summary>
    /// CC number an encoder sends: banked (page-dependent) when the surface
    /// banks it, otherwise the fixed shared table.
    /// </summary>
    public byte EncoderCcNumber(int index) =>
        Pages.IsBankedEncoder(index) ? Pages.EncoderCc(Pages.Current, index) : _encoderCcs[index];

    /// <summary>
    /// CC number a switch sends: banked when the surface banks it, otherwise
    /// the fixed shared table. The shared table's leading entries are only
    /// consulted when paging is off - with paging on they are superseded by
    /// the page tables.
    /// </summary>
    public byte ButtonCcNumber(int index) =>
        Pages.IsBankedButton(index) ? Pages.ButtonCc(Pages.Current, index) : _buttonCcs[index];

    /// <summary>
    /// Translates one surface input event into zero, one, or two UMP words to
    /// send to the DAW (the crossfader is the only two-word message: 14-bit
    /// CC pair MSB+LSB). Returns the number of words written.
    /// </summary>
    public int MapInput(InputEvent ev, Span<uint> words)
    {
        switch (ev.Kind)
        {
            case InputEventKind.Encoder when ev.Index < 8:
                words[0] = ChannelVoice(0xB0, EncoderCcNumber(ev.Index), ev.Value);
                return 1;

            case InputEventKind.EncoderTouch when ev.Index < 8:
                words[0] = ChannelVoice(0xB0, _encoderTouchCcs[ev.Index], ev.Value);
                return 1;

            // Page/PermaBar switches are deliberately NOT translated here: the
            // bridge routes them through ButtonLogic first, which decides the
            // value from the switch's kind (momentary vs toggle).
            case InputEventKind.Button when ev.Index == NocturnProtocol.SpeedDialButton:
                words[0] = ChannelVoice(0xB0, SpeedDialButtonCc, (byte)(ev.Value != 0 ? 127 : 0));
                return 1;

            case InputEventKind.SpeedDial:
                words[0] = ChannelVoice(0xB0, SpeedDialCc, ev.Value);
                return 1;

            case InputEventKind.SpeedDialTouch:
                words[0] = ChannelVoice(0xB0, SpeedDialTouchCc, ev.Value);
                return 1;

            case InputEventKind.Xfader:
                words[0] = ChannelVoice(0xB0, XfaderCcMsB, (byte)((ev.WideValue >> 7) & 0x7F));
                words[1] = ChannelVoice(0xB0, XfaderCcLsB, (byte)(ev.WideValue & 0x7F));
                return 2;

            case InputEventKind.XfaderTouch:
                words[0] = ChannelVoice(0xB0, XfaderTouchCc, ev.Value);
                return 1;

            default:
                return 0; // Unknown / crossfader coarse-byte bookkeeping events
        }
    }

    /// <summary>
    /// Builds the CC for one surface switch (press, release, or a latched
    /// toggle state). The value is supplied by the caller because the switch's
    /// kind decides it - see <see cref="ButtonLogic"/>. Switches are CCs and
    /// not notes so that the whole note range on the loopback stays free for a
    /// keyboard, and because a CC is a value, which is what a state is.
    /// </summary>
    public uint ButtonCc(int index, byte value) =>
        ChannelVoice(0xB0, ButtonCcNumber(index), value);

    /// <summary>
    /// Maps a DAW-sent button-LED CC back to the surface button index.
    /// Banked switches resolve against the active page only: the codec is
    /// expected to speak about the page the surface is on, and a CC from
    /// another page has no meaning here.
    /// </summary>
    public bool TryMapButtonCc(byte cc, out int index)
    {
        if (Pages.TryMapButtonCc(Pages.Current, cc, out index))
            return true;

        // Shared switches (PermaBar): the tail of the shared table.
        for (var i = Pages.BankedButtons; i < _buttonCcs.Length; i++)
        {
            if (_buttonCcs[i] == cc)
            {
                index = i;
                return true;
            }
        }

        index = -1;
        return false;
    }

    /// <summary>Maps a DAW-sent ring-value CC back to the encoder index.</summary>
    public bool TryMapRingValueCc(byte cc, out int encoder)
    {
        encoder = Array.IndexOf(_ringValueCcs, cc);
        return encoder >= 0;
    }

    /// <summary>Maps a DAW-sent ring-mode CC back to the encoder index.</summary>
    public bool TryMapRingModeCc(byte cc, out int encoder)
    {
        encoder = Array.IndexOf(_ringModeCcs, cc);
        return encoder >= 0;
    }

    /// <summary>
    /// Decodes a received UMP word as a MIDI 1.0 channel-voice message.
    /// Returns false for anything that is not a 32-bit MIDI 1.0 CV message
    /// (system messages, MIDI 2.0 messages, other groups).
    /// </summary>
    public static bool TryDecodeChannelVoice(uint word, out byte status, out byte data1, out byte data2)
    {
        if ((word & 0xF000_0000u) == 0x2000_0000u)
        {
            status = (byte)((word >> 16) & 0xFF);
            data1 = (byte)((word >> 8) & 0xFF);
            data2 = (byte)(word & 0xFF);
            return true;
        }

        status = 0;
        data1 = 0;
        data2 = 0;
        return false;
    }

    private static byte[] ReadList(int[]? values, int expected, string key)
    {
        if (values is null || values.Length != expected)
            throw new InvalidOperationException(
                $"{key} must contain exactly {expected} MIDI numbers (bound {values?.Length ?? -1}).");

        var result = new byte[expected];
        for (var i = 0; i < expected; i++)
            result[i] = ReadNumber(values[i], key);

        for (var i = 0; i < expected; i++)
        {
            for (var j = i + 1; j < expected; j++)
            {
                if (result[i] == result[j])
                    throw new InvalidOperationException($"{key} contains duplicate MIDI number {result[i]}.");
            }
        }

        return result;
    }

    private static byte ReadNumber(int value, string key)
    {
        if (value is < 0 or > 127)
            throw new InvalidOperationException($"{key} value {value} is out of range 0..127.");
        return (byte)value;
    }
}
