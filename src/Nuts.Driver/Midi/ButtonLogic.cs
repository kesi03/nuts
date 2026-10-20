using Nuts.Driver.Led;
using Nuts.Driver.Protocol;

namespace Nuts.Driver.Midi;

/// <summary>
/// Per-button wire behaviour (see <see cref="ButtonKind"/>). Owns the
/// driver-side latch for every button and is the only place that decides the
/// value of a switch message, so the two button kinds differ here and nowhere
/// else.
///
/// Latches for banked switches are kept per page: the same physical switch
/// drives a different item on each page, so it has a different state on each
/// page, and flipping pages must not carry a latch over. Shared switches
/// (PermaBar) have one latch, keyed on page 0.
///
/// The latch is written by two callers on different threads: the input pump
/// (a physical press) and the MIDI connection (feedback from the DAW). Both
/// go through the same gate, and the DAW's word is always the last one, so a
/// host-driven state can never be silently out of step with what the next
/// press will send.
/// </summary>
public sealed class ButtonLogic
{
    private readonly object _gate = new();
    private readonly MidiMapping _mapping;
    private readonly ILedManager _leds;
    private readonly ButtonKind[] _kinds = new ButtonKind[NocturnProtocol.ButtonCount];

    // [page, button]. Only page 0 is used for shared switches.
    private readonly bool[,] _latched;

    public ButtonLogic(MidiMapping mapping, MidiMappingOptions options, ILedManager leds)
    {
        _mapping = mapping;
        _leds = leds;
        _latched = new bool[mapping.Pages.PageCount, NocturnProtocol.ButtonCount];

        var pageRow = ButtonKinds.Parse(
            options.ButtonKinds.PageRow, "Midi:Mapping:ButtonKinds:PageRow");
        var permaBar = ButtonKinds.Parse(
            options.ButtonKinds.PermaBar, "Midi:Mapping:ButtonKinds:PermaBar");

        for (var i = 0; i < _kinds.Length; i++)
            _kinds[i] = i < NocturnProtocol.PermaBarButtonFirst ? pageRow : permaBar;

        // Per-button overrides, keyed by surface button number 1-16 in
        // surface order (1-8 page row, 9-16 PermaBar). Mute and Solo are
        // two-state targets, so they are latching switches on our surface.
        foreach (var pair in options.ButtonKinds.PerButton)
        {
            if (!int.TryParse(pair.Key, out var number)
                || number < 1 || number > NocturnProtocol.ButtonCount)
                throw new InvalidOperationException(
                    $"Midi:Mapping:ButtonKinds:PerButton key \"{pair.Key}\" must be a button " +
                    $"number 1..{NocturnProtocol.ButtonCount}.");

            _kinds[number - 1] = ButtonKinds.Parse(
                pair.Value, $"Midi:Mapping:ButtonKinds:PerButton:{pair.Key}");
        }
    }

    /// <summary>Kind of one button, for logging and for the LED decision above.</summary>
    public ButtonKind KindOf(int index) => _kinds[index];

    /// <summary>
    /// Translates a physical press/release into the CC to send over MIDI.
    /// Returns false when nothing should be sent: a toggle button's release
    /// is not an event, because the latched value IS the message.
    /// </summary>
    public bool TryHandleInput(int index, bool pressed, out uint word)
    {
        var page = _mapping.Pages.IsBankedButton(index) ? _mapping.Pages.Current : 0;

        lock (_gate)
        {
            if (_kinds[index] == ButtonKind.Toggle)
            {
                if (!pressed)
                {
                    word = 0;
                    return false;
                }

                var on = !_latched[page, index];
                _latched[page, index] = on;

                // Light it from the latch immediately; DAW feedback corrects
                // it right after if the host disagrees.
                _leds.SetButtonLed(index, on ? LedState.On : LedState.Off);
                word = _mapping.ButtonCc(index, on ? (byte)127 : (byte)0);
                return true;
            }

            // Momentary: the edge is the message. The latch is kept only as
            // bookkeeping (so the state is honest if this button is ever
            // switched to "toggle" in configuration), and the LED is left to
            // the DAW - the host's target state is the truth.
            _latched[page, index] = pressed;
            word = _mapping.ButtonCc(index, pressed ? (byte)127 : (byte)0);
            return true;
        }
    }

    /// <summary>
    /// Applies a button-LED CC received from the DAW: it overwrites the
    /// latch and the LED. Banked switches land on the active page's latch,
    /// which is the only page the DAW can be talking about.
    /// </summary>
    public void HandleFeedback(int index, bool on)
    {
        var page = _mapping.Pages.IsBankedButton(index) ? _mapping.Pages.Current : 0;

        lock (_gate)
        {
            _latched[page, index] = on;
        }

        _leds.SetButtonLed(index, on ? LedState.On : LedState.Off);
    }

    /// <summary>
    /// Repaints every banked switch's LED from the latch cache of one page.
    /// Called when the page changes: the DAW has no idea the surface moved,
    /// so the driver has to restore each switch's own state rather than show
    /// the previous page's. Shared switches are left alone - they mean the
    /// same thing on every page.
    /// </summary>
    public void RepaintPage(int page)
    {
        lock (_gate)
        {
            for (var index = 0; index < _mapping.Pages.BankedButtons; index++)
                _leds.SetButtonLed(index, _latched[page, index] ? LedState.On : LedState.Off);
        }
    }

    /// <summary>One-line summary of the active kinds, for the startup log.</summary>
    public string Describe()
    {
        var toggles = new List<string>();
        for (var i = 0; i < _kinds.Length; i++)
        {
            if (_kinds[i] == ButtonKind.Toggle)
                toggles.Add((i + 1).ToString());
        }

        return toggles.Count == 0
            ? "momentary everywhere"
            : $"toggle on button(s) {string.Join(", ", toggles)}, momentary everywhere else";
    }
}
