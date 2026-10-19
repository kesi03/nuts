namespace Nuts.Driver.Led;

/// <summary>
/// On/off state of a Nocturn button LED. CONFIRMED by hardware probe
/// (2026-10-19): LED color is fixed per button row by the hardware —
/// the assignable page buttons are green, the PermaBar buttons are red —
/// and the wire value only selects on/off. No color mixing is possible.
/// </summary>
public enum LedState
{
    Off,
    On,
}
