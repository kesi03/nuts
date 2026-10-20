namespace Nuts.Driver.Midi;

/// <summary>
/// Paging / banking configuration (appsettings section "Midi:Paging").
///
/// This is the surface-independent half of the driver: it describes a
/// surface that has some controls which bank (a page swaps their CCs) and
/// some which do not (shared by every page). The Nocturn instantiates it as
/// 8 banked dials and 8 banked page-row switches with the crossfader, speed
/// dial, touches and PermaBar shared - but the shape is the same for any
/// other surface, and for any other Reason device mapped onto it.
///
/// Every page gets the same number of slots: PageCount x BankedEncoders
/// encoder CCs and PageCount x BankedButtons button CCs, listed page-major
/// (all of page 1, then all of page 2). Fixed stride is what keeps an
/// incoming CC decodable by arithmetic instead of by search, and it is why
/// the tables must be complete.
///
/// The numbers are a three-way contract with remote/mapping/
/// nocturn-controls.json and the lookup tables in Nocturn.lua; change all
/// three together. Defaults are documented in docs/midi-mapping.md.
/// </summary>
public sealed class PagingOptions
{
    /// <summary>
    /// false = one unbanked page: encoders and page-row switches use the
    /// shared Midi:Mapping tables unchanged, and no page CCs are emitted.
    /// </summary>
    public bool Enabled { get; set; }

    /// <summary>How many pages exist. 1 is legal and means "nothing banks".</summary>
    public int PageCount { get; set; } = 1;

    /// <summary>How many encoders bank. The rest are shared across all pages.</summary>
    public int BankedEncoders { get; set; }

    /// <summary>How many page-row switches bank. The rest (PermaBar) are shared.</summary>
    public int BankedButtons { get; set; }

    /// <summary>
    /// CC the driver uses to tell the DAW which page is active (1-based page
    /// number). This is how the codec knows what to repaint; the same number
    /// is reserved in the other two tables.
    /// </summary>
    public int EchoCc { get; set; } = 119;

    /// <summary>Shared switch index that steps to the previous page, or -1 for none.</summary>
    public int PrevButton { get; set; } = -1;

    /// <summary>Shared switch index that steps to the next page, or -1 for none.</summary>
    public int NextButton { get; set; } = -1;

    /// <summary>
    /// One shared switch per page, in step order, each jumping straight to
    /// its page. These are also the page indicators: the driver lights the
    /// one for the active page. Every page needs its own, or paging by
    /// stepping gives no feedback about where you are.
    /// </summary>
    public int[] JumpButtons { get; set; } = [];

    /// <summary>
    /// Display names, one per page, for the startup log only. Wrong length
    /// falls back to "Page n".
    /// </summary>
    public string[] Names { get; set; } = [];

    /// <summary>
    /// Encoder CCs, page-major: PageCount x BankedEncoders, all of page 1
    /// first. null = no banking (single page of the shared table).
    /// </summary>
    public int[]? EncoderCcs { get; set; }

    /// <summary>
    /// Page-row switch CCs, page-major: PageCount x BankedButtons. null as above.
    /// </summary>
    public int[]? ButtonCcs { get; set; }

    /// <summary>
    /// Ring modes, page-major: PageCount x BankedEncoders, as names from
    /// RingMode (Fill, CentreBoth, SingleDot, ...). The driver repaints the
    /// rings with these on a page change; the DAW can still override any of
    /// them afterwards with a ring-mode CC. null = all Fill.
    /// </summary>
    public string[]? RingModes { get; set; }
}
