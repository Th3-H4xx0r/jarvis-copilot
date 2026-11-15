namespace Jarvis.Core.Ui;

/// SwiftUI's `.spring(response:dampingFraction:)` as a value you step: a unit mass on a spring
/// of stiffness (2π/response)² with damping 4π·ζ/response. Retargeting keeps the velocity, so a
/// change mid-flight bends the motion instead of restarting it (as SwiftUI does). The island's
/// shape, its orb flight and the voice stage all move on one of these.
public sealed class Spring
{
    /// The longest step integrated in one go; longer frames are split so a hitch can't explode it.
    private const double MaxStep = 1.0 / 240;

    public Spring(double response, double dampingFraction, double value = 0)
    {
        Response = response;
        DampingFraction = dampingFraction;
        Value = value;
        Target = value;
    }

    public double Response { get; set; }
    public double DampingFraction { get; set; }
    public double Value { get; private set; }
    public double Velocity { get; private set; }
    public double Target { get; set; }

    /// Close enough to call it still: within `epsilon` of the target and barely moving.
    public bool IsSettled(double epsilon = 0.25) =>
        Math.Abs(Value - Target) <= epsilon && Math.Abs(Velocity) <= epsilon * 4;

    /// Jump straight to `value` (a state reached without motion).
    public void Snap(double value)
    {
        Value = value;
        Target = value;
        Velocity = 0;
    }

    /// Advance `dt` seconds (semi-implicit Euler in sub-steps).
    public void Step(double dt)
    {
        if (dt <= 0) return;
        var omega = 2 * Math.PI / Math.Max(Response, 1e-3);
        var k = omega * omega;
        var c = 2 * DampingFraction * omega;
        while (dt > 0)
        {
            var h = Math.Min(dt, MaxStep);
            var a = -k * (Value - Target) - c * Velocity;
            Velocity += a * h;
            Value += Velocity * h;
            dt -= h;
        }
    }
}

/// Easing curves the island uses beside its springs (SwiftUI's easeOut / easeInOut).
public static class Easing
{
    public static double EaseOut(double t)
    {
        t = Math.Clamp(t, 0, 1);
        return 1 - (1 - t) * (1 - t) * (1 - t);
    }

    public static double EaseInOut(double t)
    {
        t = Math.Clamp(t, 0, 1);
        return t < 0.5 ? 4 * t * t * t : 1 - Math.Pow(-2 * t + 2, 3) / 2;
    }

    /// A fade that waits `delay` then runs `duration` (0…1), eased out.
    public static double Fade(double elapsed, double duration, double delay = 0) =>
        duration <= 0 ? (elapsed >= delay ? 1 : 0) : EaseOut((elapsed - delay) / duration);
}
