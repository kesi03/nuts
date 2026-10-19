using Nuts.Driver.Protocol;

namespace Nuts.Driver.Led;

/// <summary>
/// Authoritative model of the device's LED state. All writes go through here;
/// a dirty-tracking cache diffs desired vs. last-sent state so the flusher
/// only puts changed pairs on the wire.
/// </summary>
public interface ILedManager
{
    /// <summary>Set the full state of one encoder column (ring + its button).</summary>
    void SetColumn(int column, SurfaceControlState state);

    /// <summary>Set a single button LED, index 0-15 (0-7 page, 8-15 PermaBar).</summary>
    void SetButtonLed(int index, LedState state);

    /// <summary>Set ring mode + value for encoder 0-7.</summary>
    void SetRing(int encoder, RingMode mode, byte value);

    /// <summary>Set the speed dial ring (fill only; firmware has no mode register).</summary>
    void SetSpeedDialRing(byte value);

    /// <summary>
    /// Mark all state dirty so the next flush replays everything.
    /// Required after reconnect: the device loses all state on unplug/reset.
    /// </summary>
    void MarkAllDirty();

    /// <summary>
    /// Snapshot and clear dirty state, returning the [ctrl,val] pairs to send.
    /// Order: ring modes, ring values, button LEDs, speed dial.
    /// </summary>
    IReadOnlyList<KeyValuePair<byte, byte>> CollectDirtyPairs();
}
