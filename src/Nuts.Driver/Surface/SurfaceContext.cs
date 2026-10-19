namespace Nuts.Driver.Surface;

/// <summary>
/// The four soft-panel contexts of the Reason workflow the spec targets.
/// Which context is active drives what the page buttons and rings control.
/// </summary>
public enum SurfaceContext
{
    User,
    Fx,
    Inst,
    Mixer,
}
