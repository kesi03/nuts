namespace Nuts.Driver.Led;

/// <summary>
/// Software VU meter: attack/release envelope over an input level, mapped to
/// the ring's 11 segments. The firmware has no VU mode — the host owns the
/// animation and feeds the result in via <see cref="ILedManager.SetRing"/>
/// with <see cref="RingMode.Vumeter"/>.
/// </summary>
public sealed class VuMeter
{
    private readonly byte _segments;
    private readonly float _attack;
    private readonly float _release;

    private float _smoothed;

    public VuMeter(byte segments = 11, float attack = 0.6f, float release = 0.08f)
    {
        _segments = segments;
        _attack = Math.Clamp(attack, 0f, 1f);
        _release = Math.Clamp(release, 0f, 1f);
    }

    /// <summary>
    /// Advance with a new input level (0.0-1.0) and return the segment count
    /// to display (0-11). Call at a steady rate (e.g. every flush tick).
    /// </summary>
    public byte Update(float level)
    {
        level = Math.Clamp(level, 0f, 1f);
        var coefficient = level > _smoothed ? _attack : _release;
        _smoothed += (level - _smoothed) * coefficient;
        return (byte)Math.Clamp(
            (int)MathF.Round(_smoothed * _segments), 0, _segments);
    }

    public void Reset() => _smoothed = 0f;
}
