using Jarvis.Core.Model;

namespace Jarvis.Core.Ui;

/// How the Jarvis orb moves (port of the Mac's OrbMotion / OrbView): never redrawn while nothing
/// happens (a still frame), a gentle 12 fps while agents work or wait, 30 fps for listening and
/// music, and the voice stage at the display's rate. The mood shows as a soft ring and a breathing
/// pulse, never by recolouring the orb.
public static class OrbMotion
{
    /// The shader's flow repeats every 38.4 s (its breathing every 9.6 s).
    public const double Loop = 38.4;
    /// The visible sphere fills 53% of the shader's surface.
    public const double SphereShare = 0.53;

    /// Seconds between frames, or null for a still frame.
    public static double? Interval(OrbMood mood, bool listening, bool dancing)
    {
        if (dancing || listening) return 1.0 / 30;
        return mood == OrbMood.Idle ? null : 1.0 / 12;
    }

    public static bool Pulses(OrbMood mood, bool listening) =>
        listening || mood is OrbMood.Working or OrbMood.Waiting;

    /// The breathing pulse, 0…1: out and back every 2 × 1.1 s (2 × 0.7 s while waiting), eased.
    public static double Pulse(double elapsed, OrbMood mood)
    {
        var half = mood == OrbMood.Waiting ? 0.7 : 1.1;
        return (1 - Math.Cos(Math.PI * elapsed / half)) / 2;
    }

    /// The music beat, 0…1, at 0.9 Hz.
    public static double Beat(double elapsed) => 0.5 + 0.5 * Math.Sin(elapsed * 2 * Math.PI * 0.9);

    /// The orb's scale: a breath while it pulses, a bounce with the music.
    public static double Scale(bool pulses, double pulse, double beat) =>
        (pulses ? 0.96 + 0.09 * pulse : 1) + 0.08 * beat;

    /// The ring's colour key (Theme.xaml) for a mood, or null for no ring.
    public static string? TintKey(OrbMood mood) => mood switch
    {
        OrbMood.Waiting => "JcAmber",
        OrbMood.Finished => "JcGreen",
        OrbMood.Error => "JcOrbRed",
        OrbMood.RateLimit => "JcOrange",
        _ => null,
    };

    /// The ring's opacity at `pulse` (0.55 at rest, up to 0.95 at the top of a breath).
    public static double RingOpacity(double pulse) => 0.55 + 0.4 * pulse;

    /// The ring's stroke for an orb of `size`.
    public static double RingWidth(double size) => Math.Max(1.2, size * 0.07);

    /// The shader's clock for `elapsed` seconds.
    public static double ShaderTime(double elapsed) => elapsed % Loop;

    /// The voice stage's audio swell (LiquidGlassOrb: 1 + 0.10 × the smoothed level).
    public static double SpeechScale(double level) => 1 + 0.10 * Math.Clamp(level, 0, 1);
}

/// The orb's flight between the compact island's ear and its place in the open island (port of
/// the Mac's OrbPath): it drops out of the ear, then glides into place along a curve bent through
/// the point under the ear at home's height, growing from the ear's size to home's.
public static class OrbPath
{
    public static (double X, double Y, double Side) At(double t, (double X, double Y, double Side) ear, (double X, double Y, double Side) home)
    {
        var s = Math.Clamp(t, 0, 1);
        var u = 1 - s;
        var x = u * u * ear.X + 2 * u * s * ear.X + s * s * home.X;
        var y = u * u * ear.Y + 2 * u * s * home.Y + s * s * home.Y;
        var side = ear.Side + (home.Side - ear.Side) * t;
        return (x, y, Math.Max(1, side));
    }

    /// The soft light it carries: none at either end, brightest mid-flight.
    public static double Glow(double t) => Math.Sin(Math.PI * Math.Clamp(t, 0, 1));
}
