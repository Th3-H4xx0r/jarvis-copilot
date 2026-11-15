using Jarvis.Core.Island;
using Jarvis.Core.Model;
using Jarvis.Core.Ui;

namespace Jarvis.Tests.Ui;

/// The island's motion and look rules, ported from the Mac: the morph spring, the orb's frame
/// rate and pulse, the orb shader's shape, and the Mac's layout sums.
public class IslandMotionTests
{
    private static double Run(Spring s, double seconds, double fps = 60)
    {
        var peak = s.Value;
        for (var t = 0.0; t < seconds; t += 1 / fps)
        {
            s.Step(1 / fps);
            peak = Math.Max(peak, s.Value);
        }
        return peak;
    }

    [Fact]
    public void Spring_SettlesOnTargetWithinASecond()
    {
        var s = new Spring(IslandLayout.MorphResponse, IslandLayout.MorphDamping, 32) { Target = 480 };
        Run(s, 1.0);
        Assert.True(s.IsSettled(), $"value {s.Value} velocity {s.Velocity}");
    }

    [Fact]
    public void Spring_Underdamped_OvershootsALittle()
    {
        var s = new Spring(IslandLayout.MorphResponse, IslandLayout.MorphDamping, 0) { Target = 100 };
        var peak = Run(s, 1.0);
        Assert.InRange(peak, 100.1, 106);
    }

    [Fact]
    public void Spring_CriticallyDamped_NeverOvershoots()
    {
        var s = new Spring(0.4, 1.0, 0) { Target = 100 };
        Assert.True(Run(s, 2.0) <= 100.0001);
    }

    [Fact]
    public void Spring_RetargetKeepsVelocity()
    {
        var s = new Spring(0.36, 0.84, 0) { Target = 100 };
        Run(s, 0.1);
        var v = s.Velocity;
        s.Target = 200;
        Assert.Equal(v, s.Velocity);
        Run(s, 1.5);
        Assert.True(s.IsSettled());
        Assert.Equal(200, s.Value, 0);
    }

    [Fact]
    public void Spring_LongFrameDoesNotExplode()
    {
        var s = new Spring(0.36, 0.84, 0) { Target = 100 };
        s.Step(0.5);
        Assert.InRange(s.Value, 0, 120);
    }

    [Fact]
    public void Spring_Snap()
    {
        var s = new Spring(0.36, 0.84, 0) { Target = 100 };
        s.Step(0.05);
        s.Snap(40);
        Assert.True(s.IsSettled());
        Assert.Equal(40, s.Value);
    }

    [Fact]
    public void Easing_FadeWaitsForItsDelay()
    {
        Assert.Equal(0, Easing.Fade(0.05, 0.18, 0.07));
        Assert.Equal(1, Easing.Fade(0.30, 0.18, 0.07));
        Assert.InRange(Easing.Fade(0.12, 0.18, 0.07), 0.01, 0.99);
    }

    [Fact] public void OrbMotion_IdleIsAStillFrame() => Assert.Null(OrbMotion.Interval(OrbMood.Idle, false, false));
    [Fact] public void OrbMotion_WorkingIs12Fps() => Assert.Equal(1.0 / 12, OrbMotion.Interval(OrbMood.Working, false, false));
    [Fact] public void OrbMotion_ListeningIs30Fps() => Assert.Equal(1.0 / 30, OrbMotion.Interval(OrbMood.Idle, true, false));
    [Fact] public void OrbMotion_MusicIs30Fps() => Assert.Equal(1.0 / 30, OrbMotion.Interval(OrbMood.Idle, false, true));

    [Fact]
    public void OrbMotion_PulseBreathesFasterWhileWaiting()
    {
        Assert.Equal(0, OrbMotion.Pulse(0, OrbMood.Working), 6);
        Assert.Equal(1, OrbMotion.Pulse(1.1, OrbMood.Working), 6);
        Assert.Equal(1, OrbMotion.Pulse(0.7, OrbMood.Waiting), 6);
        Assert.Equal(0, OrbMotion.Pulse(1.4, OrbMood.Waiting), 6);
    }

    [Fact]
    public void OrbMotion_RingOnlyForMoodsThatNeedOne()
    {
        Assert.Null(OrbMotion.TintKey(OrbMood.Idle));
        Assert.Null(OrbMotion.TintKey(OrbMood.Working));
        Assert.Equal("JcAmber", OrbMotion.TintKey(OrbMood.Waiting));
        Assert.Equal("JcGreen", OrbMotion.TintKey(OrbMood.Finished));
        Assert.NotNull(OrbMotion.TintKey(OrbMood.Error));
        Assert.NotNull(OrbMotion.TintKey(OrbMood.RateLimit));
    }

    [Fact]
    public void OrbMotion_ScaleStaysNearOne()
    {
        Assert.Equal(1, OrbMotion.Scale(false, 0, 0));
        Assert.InRange(OrbMotion.Scale(true, 0, 0), 0.95, 0.97);
        Assert.InRange(OrbMotion.Scale(true, 1, 1), 1.12, 1.14);
    }

    [Fact]
    public void OrbMotion_ShaderClockWraps() => Assert.Equal(1.6, OrbMotion.ShaderTime(OrbMotion.Loop + 1.6), 6);

    [Fact]
    public void OrbPath_StartsAtTheEarEndsAtHome_GlowsMidFlight()
    {
        var ear = (10.0, 16.0, 18.0);
        var home = (300.0, 80.0, 22.0);
        Assert.Equal(ear, OrbPath.At(0, ear, home));
        Assert.Equal(home, OrbPath.At(1, ear, home));
        var mid = OrbPath.At(0.5, ear, home);
        Assert.True(mid.Y > 16 && mid.Y <= 80, "drops before it glides");
        Assert.Equal(0, OrbPath.Glow(0), 6);
        Assert.Equal(1, OrbPath.Glow(0.5), 6);
        Assert.True(OrbPath.At(1.1, ear, home).Side > 22, "the overshoot swells it");
    }

    [Fact]
    public void OrbShader_ClearOutsideTheGlow_OpaqueInside()
    {
        const float side = 200;
        Assert.Equal(0, OrbShader.SetupOrb(1, 1, side, 3).A);
        var centre = OrbShader.SetupOrb(100, 100, side, 3);
        Assert.Equal(1, centre.A, 3);
        Assert.True(centre.R <= centre.A && centre.G <= centre.A && centre.B <= centre.A, "premultiplied");
    }

    [Fact]
    public void OrbShader_SphereFillsAboutHalfTheSurface()
    {
        const int side = 200;
        var px = OrbShader.RenderBgra(side, 0);
        var opaque = 0;
        for (var i = 3; i < px.Length; i += 4) if (px[i] > 250) opaque++;
        var share = Math.Sqrt(opaque / (double)(side * side) / Math.PI) * 2;   // diameter / side
        Assert.InRange(share, OrbMotion.SphereShare - 0.04, OrbMotion.SphereShare + 0.04);
    }

    [Fact]
    public void OrbShader_HasItsBlueBody()
    {
        // Somewhere inside, the blue liquid light outweighs red: it's the Jarvis orb, not a grey ball.
        const int side = 160;
        var px = OrbShader.RenderBgra(side, 5);
        long blue = 0, red = 0;
        for (var i = 0; i < px.Length; i += 4) { blue += px[i]; red += px[i + 2]; }
        Assert.True(blue > red * 1.3, $"blue {blue} red {red}");
    }

    [Fact]
    public void Layout_CompactIsTheNotchWithTwoEars() =>
        Assert.Equal(IslandLayout.NotchWidth + 2 * IslandLayout.EarWidth, IslandLayout.CompactWidth);

    [Fact]
    public void Layout_MusicIsAsTallAsItsRows() =>
        Assert.Equal(IslandLayout.MusicArtwork + IslandLayout.MusicProgress + IslandLayout.MusicControls + 2 * IslandLayout.MusicGap,
            IslandLayout.PaneHeight(IslandLayout.MusicHeight));

    [Fact]
    public void Layout_VoiceHoldsTheStage() =>
        Assert.Equal(IslandLayout.VoicePanelHeight, IslandLayout.PaneHeight(IslandLayout.VoiceHeight));

    [Fact]
    public void Layout_MeasuredAgentsCapsAtMax()
    {
        Assert.Equal(IslandLayout.MaxHeight, IslandLayout.AgentsHeight(300, 2000));
        var small = IslandLayout.AgentsHeight(40, 58);
        Assert.Equal(40 + 58, IslandLayout.PaneHeight(small) - IslandLayout.Gap);
    }

    [Fact]
    public void Layout_ScrollThumb()
    {
        Assert.Null(IslandLayout.ScrollThumb(100, 200, 0));
        var t = IslandLayout.ScrollThumb(400, 200, 200)!.Value;
        Assert.Equal(100, t.Length);
        Assert.Equal(100, t.Start);
    }

    [Theory]
    [InlineData(6, "JcSysGreen")]
    [InlineData(64, "JcSysOrange")]
    [InlineData(100, "JcSysRed")]
    public void Layout_UsagePillColours(int pct, string key) => Assert.Equal(key, IslandLayout.UsageColorKey(pct));

    [Fact]
    public void Layout_LimitBarColours()
    {
        Assert.Equal("JcAccent", IslandLayout.LimitColorKey(10));
        Assert.Equal("JcAmber", IslandLayout.LimitColorKey(80));
        Assert.Equal("JcOrbRed", IslandLayout.LimitColorKey(95));
    }
}
