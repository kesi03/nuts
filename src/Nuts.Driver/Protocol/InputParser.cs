namespace Nuts.Driver.Protocol;

/// <summary>
/// Turns raw IN-endpoint chunks into <see cref="InputEvent"/>s.
///
/// Wire format (CONFIRMED by hardware capture 2026-10-19): a report is a
/// status byte (0xB0, bit 7 set) followed by one or more [ctrl, val] pairs,
/// every pair byte having bit 7 clear. So the prefix belongs to the REPORT,
/// not to each pair. A single USB read may coalesce several reports
/// (e.g. B0-48-30-B0-49-40 is two one-pair reports) or carry several pairs
/// under one status byte (e.g. B0-48-2E-49-00-42-01 is three pairs). Reads
/// may also split a report, so the trailing half-pair is buffered until the
/// next chunk.
/// </summary>
public sealed class InputParser
{
    private readonly byte[] _pair = new byte[2];
    private int _pairLen;

    private byte? _xfaderMsb;

    public void Push(ReadOnlySpan<byte> chunk, List<InputEvent> output)
    {
        foreach (var b in chunk)
        {
            if ((b & 0x80) != 0)
            {
                // Status byte: starts a new report. Drop any half pair so a
                // report split across chunks cannot misalign the stream.
                _pairLen = 0;
                continue;
            }

            _pair[_pairLen++] = b;
            if (_pairLen == 2)
            {
                Translate(_pair[0], _pair[1], output);
                _pairLen = 0;
            }
        }
    }

    private void Translate(byte num, byte val, List<InputEvent> output)
    {
        switch (num)
        {
            case >= NocturnProtocol.EncoderBase
                 and < NocturnProtocol.EncoderBase + NocturnProtocol.EncoderCount:
                output.Add(new InputEvent(
                    InputEventKind.Encoder, num - NocturnProtocol.EncoderBase, val));
                break;

            case NocturnProtocol.XfaderMsb:
                _xfaderMsb = val;
                break;

            case NocturnProtocol.XfaderLsb:
                if (_xfaderMsb is { } msb)
                {
                    // The pair is coarse-then-fine: an 8-bit position split as
                    // "msb << 1 | fine". Widened to 14-bit so the DAW pair
                    // (CC msb/lsb) keeps its shape: high 7 bits = coarse.
                    var wide = (ushort)((msb << 7) | (val != 0 ? 1 : 0));
                    output.Add(new InputEvent(InputEventKind.Xfader, 0, msb, wide));
                }
                _xfaderMsb = null;
                break;

            case NocturnProtocol.SpeedDial:
                output.Add(new InputEvent(InputEventKind.SpeedDial, 0, val));
                break;

            case NocturnProtocol.SpeedDialTouch:
                output.Add(new InputEvent(InputEventKind.SpeedDialTouch, 0, val));
                break;

            case NocturnProtocol.XfaderTouch:
                output.Add(new InputEvent(InputEventKind.XfaderTouch, 0, val));
                break;

            case NocturnProtocol.SpeedDialButton:
                output.Add(new InputEvent(InputEventKind.Button, 81, val));
                break;

            case >= NocturnProtocol.EncoderTouchBase
                 and < NocturnProtocol.EncoderTouchBase + NocturnProtocol.EncoderCount:
                output.Add(new InputEvent(
                    InputEventKind.EncoderTouch, num - NocturnProtocol.EncoderTouchBase, val));
                break;

            case >= NocturnProtocol.ButtonBase
                 and < NocturnProtocol.ButtonBase + NocturnProtocol.ButtonCount:
                output.Add(new InputEvent(
                    InputEventKind.Button, num - NocturnProtocol.ButtonBase, val));
                break;

            default:
                output.Add(new InputEvent(InputEventKind.Unknown, num, val));
                break;
        }
    }
}
