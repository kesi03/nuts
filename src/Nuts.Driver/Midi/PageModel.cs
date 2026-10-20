using Nuts.Driver.Led;
using Nuts.Driver.Protocol;

namespace Nuts.Driver.Midi;

/// <summary>
/// Paged (banked) control sets. This is the model shared by every surface
/// the driver can drive and by every Reason device scope mapped onto it: it
/// knows how many banked encoders and buttons a surface has and which CC
/// each one sends on each page, and nothing about the surface itself.
///
/// A page is a set of CC assignments for the controls that bank. The same
/// physical dial or switch sends a different CC depending on the active
/// page, so the DAW sees a different item on the same control. Controls
/// that are not banked - speed dial, crossfader, touches, the PermaBar -
/// never appear in these tables; they are shared by every page.
///
/// The DAW side of the contract is a page-aware codec. The driver echoes
/// the current page (1-based) on <see cref="EchoCc"/> whenever it changes,
/// and the codec uses that to select the right item table and to repaint
/// rings and button LEDs for the new page. Distinct CCs per page are what
/// makes an incoming message decodable without trusting that state.
/// </summary>
public sealed class PageModel
{
    private readonly object _gate = new();
    private readonly byte[][] _encoderCcs;
    private readonly byte[][] _buttonCcs;
    private readonly RingMode[][] _ringModes;
    private readonly int[] _jumpButtons;
    private readonly string[] _names;
    private int _current;

    private PageModel(
        int pageCount,
        int bankedEncoders,
        int bankedButtons,
        byte echoCc,
        int prevButton,
        int nextButton,
        byte[][] encoderCcs,
        byte[][] buttonCcs,
        RingMode[][] ringModes,
        int[] jumpButtons,
        string[] names)
    {
        PageCount = pageCount;
        BankedEncoders = bankedEncoders;
        BankedButtons = bankedButtons;
        EchoCc = echoCc;
        PrevButton = prevButton;
        NextButton = nextButton;
        _encoderCcs = encoderCcs;
        _buttonCcs = buttonCcs;
        _ringModes = ringModes;
        _jumpButtons = jumpButtons;
        _names = names;
    }

    /// <summary>Number of pages; 1 means nothing banks.</summary>
    public int PageCount { get; }

    /// <summary>How many of the surface's encoders bank (the rest are shared).</summary>
    public int BankedEncoders { get; }

    /// <summary>How many of the surface's switches bank (the rest are shared).</summary>
    public int BankedButtons { get; }

    /// <summary>CC the driver uses to tell the DAW the current page (1-based).</summary>
    public byte EchoCc { get; }

    /// <summary>Shared switch index that steps to the previous page, or -1.</summary>
    public int PrevButton { get; }

    /// <summary>Shared switch index that steps to the next page, or -1.</summary>
    public int NextButton { get; }

    /// <summary>One shared switch per page that jumps straight to it, in step order.</summary>
    public IReadOnlyList<int> JumpButtons => _jumpButtons;

    /// <summary>Active page, 0-based. Thread-safe.</summary>
    public int Current
    {
        get
        {
            lock (_gate)
                return _current;
        }
    }

    /// <summary>CC an encoder sends on a page.</summary>
    public byte EncoderCc(int page, int encoder) => _encoderCcs[page][encoder];

    /// <summary>CC a banked switch sends on a page.</summary>
    public byte ButtonCc(int page, int button) => _buttonCcs[page][button];

    /// <summary>Ring mode to show for an encoder on a page, before any DAW override.</summary>
    public RingMode RingModeFor(int page, int encoder) => _ringModes[page][encoder];

    public bool IsBankedEncoder(int index) => index >= 0 && index < BankedEncoders;

    public bool IsBankedButton(int index) => index >= 0 && index < BankedButtons;

    /// <summary>
    /// True for switches the driver consumes itself (page stepping and page
    /// jumps) instead of forwarding to the DAW: the DAW has no idea which
    /// page the surface is on unless the driver tells it.
    /// </summary>
    public bool IsInternalButton(int index) =>
        index == PrevButton || index == NextButton || Array.IndexOf(_jumpButtons, index) >= 0;

    /// <summary>Page a jump switch selects, or -1 when it is not one.</summary>
    public int PageOfJumpButton(int button) => Array.IndexOf(_jumpButtons, button);

    /// <summary>Resolves a banked encoder's CC back to its index on a page.</summary>
    public bool TryMapEncoderCc(int page, byte cc, out int encoder)
    {
        var table = _encoderCcs[page];
        for (var i = 0; i < table.Length; i++)
        {
            if (table[i] == cc)
            {
                encoder = i;
                return true;
            }
        }

        encoder = -1;
        return false;
    }

    /// <summary>Resolves a banked switch's CC back to its index on a page.</summary>
    public bool TryMapButtonCc(int page, byte cc, out int button)
    {
        var table = _buttonCcs[page];
        for (var i = 0; i < table.Length; i++)
        {
            if (table[i] == cc)
            {
                button = i;
                return true;
            }
        }

        button = -1;
        return false;
    }

    /// <summary>
    /// Selects a page. Returns false (and leaves the page alone) when the
    /// page is out of range or already current, so a held repeat or a
    /// duplicate press never causes a repaint.
    /// </summary>
    public bool TrySetPage(int page, out int previous)
    {
        lock (_gate)
        {
            previous = _current;
            if (page < 0 || page >= PageCount || page == _current)
                return false;

            _current = page;
            return true;
        }
    }

    /// <summary>Steps relative to the current page, wrapping at both ends.</summary>
    public bool TryStep(int delta, out int page)
    {
        lock (_gate)
        {
            var next = ((_current + delta) % PageCount + PageCount) % PageCount;
            page = next;
            return TrySetPage(next, out _);
        }
    }

    /// <summary>One-line summary of the active page, for the startup log.</summary>
    public string DescribeCurrent()
    {
        var page = Current;
        return $"page {page + 1} of {PageCount} ({_names[page]})";
    }

    /// <summary>Full CC table dump, so any CC in a trace decodes from the log.</summary>
    public string Describe()
    {
        var lines = new List<string>
        {
            $"Paging: {PageCount} page(s), banked encoders 0..{BankedEncoders - 1}, " +
            $"banked buttons 0..{BankedButtons - 1}, page echo CC {EchoCc}, " +
            $"step buttons {PrevButton}/{NextButton}.",
        };

        for (var page = 0; page < PageCount; page++)
        {
            lines.Add(
                $"  page {page + 1} {_names[page]}: encoders {Join(_encoderCcs[page])}, " +
                $"buttons {Join(_buttonCcs[page])}, ring modes {JoinModes(_ringModes[page])}, " +
                $"jump button {_jumpButtons[page]}");
        }

        return string.Join(Environment.NewLine, lines);
    }

    private static string Join(byte[] values) => string.Join(" ", values);

    private static string JoinModes(RingMode[] modes) =>
        string.Join(" ", modes.Select(mode => mode.ToString()));

    /// <summary>
    /// Builds the model from configuration. When paging is disabled the
    /// surface keeps its single, unbanked page: encoders and page-row
    /// switches use the shared tables unchanged.
    /// </summary>
    public static PageModel Create(
        PagingOptions options, byte[] encoderCcs, byte[] buttonCcs)
    {
        const string key = "Midi:Paging";

        if (!options.Enabled)
        {
            var pageButtons = buttonCcs.Take(NocturnProtocol.PageRowCount).ToArray();
            return new PageModel(
                1, encoderCcs.Length, pageButtons.Length,
                (byte)options.EchoCc, -1, -1,
                [encoderCcs],
                [pageButtons],
                [new RingMode[encoderCcs.Length]],
                [-1],
                ["Default"]);
        }

        if (options.PageCount < 1)
            throw new InvalidOperationException($"{key}:PageCount must be at least 1.");

        if (options.BankedEncoders < 0 || options.BankedEncoders > NocturnProtocol.EncoderCount)
            throw new InvalidOperationException(
                $"{key}:BankedEncoders must be 0..{NocturnProtocol.EncoderCount}.");

        if (options.BankedButtons < 0 || options.BankedButtons > NocturnProtocol.PageRowCount)
            throw new InvalidOperationException(
                $"{key}:BankedButtons must be 0..{NocturnProtocol.PageRowCount}.");

        var encoderTable = ReadFlat(
            options.EncoderCcs, options.PageCount * options.BankedEncoders,
            $"{key}:EncoderCcs", options.PageCount, options.BankedEncoders);
        var buttonTable = ReadFlat(
            options.ButtonCcs, options.PageCount * options.BankedButtons,
            $"{key}:ButtonCcs", options.PageCount, options.BankedButtons);

        var ringModes = ReadRingModes(
            options.RingModes, options.PageCount, options.BankedEncoders);

        if (options.JumpButtons.Length != options.PageCount)
            throw new InvalidOperationException(
                $"{key}:JumpButtons must contain one button index per page " +
                $"(bound {options.JumpButtons.Length}, expected {options.PageCount}).");

        for (var page = 0; page < options.PageCount; page++)
        {
            var button = options.JumpButtons[page];
            if (button < 0 || button >= NocturnProtocol.ButtonCount)
                throw new InvalidOperationException(
                    $"{key}:JumpButtons[{page}] = {button} is not a button index " +
                    $"0..{NocturnProtocol.ButtonCount - 1}.");
        }

        for (var i = 0; i < options.JumpButtons.Length; i++)
        {
            for (var j = i + 1; j < options.JumpButtons.Length; j++)
            {
                if (options.JumpButtons[i] == options.JumpButtons[j])
                    throw new InvalidOperationException(
                        $"{key}:JumpButtons contains duplicate button {options.JumpButtons[i]} " +
                        "- each page needs its own indicator.");
            }
        }

        var names = options.Names.Length == options.PageCount
            ? options.Names
            : Enumerable.Range(1, options.PageCount).Select(n => $"Page {n}").ToArray();

        var model = new PageModel(
            options.PageCount, options.BankedEncoders, options.BankedButtons,
            (byte)options.EchoCc, options.PrevButton, options.NextButton,
            Split(encoderTable, options.BankedEncoders, options.PageCount),
            Split(buttonTable, options.BankedButtons, options.PageCount),
            Split(ringModes, options.BankedEncoders, options.PageCount),
            options.JumpButtons, names);

        model.ValidateNoDuplicates();
        return model;
    }

    /// <summary>
    /// Checks the banked tables against every CC number that is not banked.
    /// A banked CC that is also a shared CC would make an incoming message
    /// ambiguous - the DAW could not tell which control reported - so an
    /// overlap is a configuration error rather than a silent misroute.
    /// </summary>
    public void ValidateAgainst(byte[] sharedCcs)
    {
        var owners = new Dictionary<byte, string>();
        foreach (var cc in sharedCcs)
            owners[cc] = "the shared tables";

        ClaimAll(owners);
    }

    /// <summary>A CC assigned to two banked controls is also a configuration error.</summary>
    private void ValidateNoDuplicates()
    {
        ClaimAll(new Dictionary<byte, string>());
    }

    private void ClaimAll(Dictionary<byte, string> owners)
    {
        for (var page = 0; page < PageCount; page++)
        {
            for (var encoder = 0; encoder < BankedEncoders; encoder++)
                Claim(owners, _encoderCcs[page][encoder], "encoder", page, encoder);

            for (var button = 0; button < BankedButtons; button++)
                Claim(owners, _buttonCcs[page][button], "button", page, button);
        }
    }

    private static void Claim(
        Dictionary<byte, string> owners, byte cc, string what, int page, int index)
    {
        if (owners.TryGetValue(cc, out var owner))
            throw new InvalidOperationException(
                $"{what} CC {cc} on page {page + 1} index {index} collides with {owner}.");

        owners[cc] = $"{what} on page {page + 1} index {index}";
    }

    private static byte[] ReadFlat(int[]? values, int expected, string key, int pages, int stride)
    {
        if (values is null || values.Length != expected)
            throw new InvalidOperationException(
                $"{key} must contain {pages} page(s) x {stride} value(s) = {expected} " +
                $"MIDI numbers (bound {values?.Length ?? -1}).");

        var result = new byte[expected];
        for (var i = 0; i < expected; i++)
            result[i] = ReadNumber(values[i], key);

        return result;
    }

    private static T[] ReadFlat<T>(string[]? values, int pages, int stride, string key)
        where T : struct, Enum
    {
        var expected = pages * stride;
        if (values is null)
        {
            var fallback = new T[expected];
            Array.Fill(fallback, default(T));
            return fallback;
        }

        if (values.Length != expected)
            throw new InvalidOperationException(
                $"{key} must contain {pages} page(s) x {stride} value(s) = {expected} " +
                $"entries (bound {values.Length}).");

        var result = new T[expected];
        for (var i = 0; i < expected; i++)
        {
            if (!Enum.TryParse<T>(values[i], true, out var parsed))
                throw new InvalidOperationException(
                    $"{key}[{i}] = \"{values[i]}\" is not one of " +
                    $"{string.Join(", ", Enum.GetNames<T>())}.");

            result[i] = parsed;
        }

        return result;
    }

    private static RingMode[] ReadRingModes(string[]? values, int pages, int stride)
    {
        const string key = "Midi:Paging:RingModes";
        return ReadFlat<RingMode>(values, pages, stride, key);
    }

    private static byte ReadNumber(int value, string key)
    {
        if (value is < 0 or > 127)
            throw new InvalidOperationException($"{key} value {value} is out of range 0..127.");
        return (byte)value;
    }

    /// <summary>Splits a page-major flat table into one row per page.</summary>
    private static T[][] Split<T>(T[] flat, int stride, int pages)
    {
        if (stride <= 0)
        {
            var empty = new T[pages][];
            for (var page = 0; page < pages; page++)
                empty[page] = [];
            return empty;
        }

        var rows = new T[pages][];
        for (var page = 0; page < pages; page++)
            rows[page] = flat[(page * stride)..((page + 1) * stride)];
        return rows;
    }
}
