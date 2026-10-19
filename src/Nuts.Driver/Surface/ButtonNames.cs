using Nuts.Driver.Protocol;

namespace Nuts.Driver.Surface;

/// <summary>Names of the fixed PermaBar buttons (indices 8-15).</summary>
public enum PermaBarButton
{
    Learn = NocturnProtocol.PermaBarButtonFirst,
    View,
    PageMinus,
    PagePlus,
    User,
    Fx,
    Inst,
    Mixer,
}

/// <summary>
/// Human-readable names for input button indices. CONFIRMED by hardware
/// probe (2026-10-19): pressing buttons in surface order produced wire
/// indices 0-15 left-to-right, with the PermaBar row running
/// Learn, View, Page-, Page+, User, FX, Inst, Mixer on indices 8-15.
/// Control 81 is the speed dial's click button (74 = rotation, 82 = touch).
/// </summary>
public static class ButtonNames
{
    /// <summary>Names for indices 0-7: the assignable page buttons (under the encoders).</summary>
    public static readonly string[] PageButtons =
        ["Page1", "Page2", "Page3", "Page4", "Page5", "Page6", "Page7", "Page8"]; // confirmed by probe

    public static string Describe(int index) => index switch
    {
        < NocturnProtocol.PermaBarButtonFirst => PageButtons[index],
        NocturnProtocol.SpeedDialButton => "SpeedDialClick", // control 81
        >= NocturnProtocol.PermaBarButtonFirst and < NocturnProtocol.ButtonCount =>
            ((PermaBarButton)index).ToString(),
        _ => $"Button{index}",
    };
}
