using Jarvis.Core.Ui;

namespace Jarvis.Tests.Ui;

public class JcLoaderTests
{
    [Fact] public void Ring_StartsAtLeftEnd() { var p = JcLoaderGeometry.Ring(0)[0]; Assert.Equal(2.4, p.X, 3); Assert.Equal(12, p.Y, 3); }
    [Fact] public void Ring_QuarterIsBottom() { var p = JcLoaderGeometry.Ring(0, 96)[24]; Assert.Equal(12, p.X, 1); Assert.Equal(16.2, p.Y, 1); }
    [Fact] public void Ring_HalfIsRightEnd() { var p = JcLoaderGeometry.Ring(0, 96)[48]; Assert.Equal(21.6, p.X, 1); Assert.Equal(12, p.Y, 1); }
    [Fact] public void RingA_RotatedMinus38() { var p = JcLoaderGeometry.Ring(-38)[0]; Assert.Equal(4.435, p.X, 0.005); Assert.Equal(17.911, p.Y, 0.005); }
    [Fact] public void Segment_WrapsIntoTwoPolylines() => Assert.Equal(2, JcLoaderGeometry.Segment(JcLoaderGeometry.Ring(0), 0.9, 0.26).Count);
    [Fact] public void Segment_InsideIsOnePolyline() => Assert.Single(JcLoaderGeometry.Segment(JcLoaderGeometry.Ring(0), 0.1, 0.26));
    [Fact] public void StrokeWidth_FloorsAt1_2() { Assert.Equal(1.2, JcLoaderGeometry.StrokeWidth(12)); Assert.Equal(1.6, JcLoaderGeometry.StrokeWidth(24)); }
    [Fact] public void Period_PerStyle() { Assert.Equal(1.5, JcLoaderGeometry.Period(JcLoaderStyle.Trace)); Assert.Equal(2.6, JcLoaderGeometry.Period(JcLoaderStyle.Draw)); Assert.Equal(JcLoaderStyle.Trace, JcLoaderGeometry.Default); }

    [Fact]
    public void DrawTrim_Values()
    {
        Assert.Equal((0.0, 1.0), JcLoaderGeometry.DrawTrim(0.5, 0, 0.42, 0.60));
        Assert.Null(JcLoaderGeometry.DrawTrim(0.05, 0.12, 0.50, 0.66));
        Assert.Equal(0.5, JcLoaderGeometry.DrawTrim(0.21, 0, 0.42, 0.60)!.Value.To, 3);
    }

    [Fact]
    public void CubicBezier_Ends() { Assert.Equal(0, JcLoaderGeometry.CubicBezier(0, .65, 0, .35, 1)); Assert.Equal(1, JcLoaderGeometry.CubicBezier(1, .65, 0, .35, 1)); }

    [Fact]
    public void TraceFrame_TwoFaintRingsTwoBrightSegments()
    {
        var f = JcLoaderGeometry.Frame(JcLoaderStyle.Trace, 20, 0.25);
        Assert.Equal(2, f.Count(x => x.Opacity == 0.22));
        Assert.True(f.Count(x => x.Opacity == 1.0) >= 2);
        Assert.All(f.SelectMany(x => x.Points), p => Assert.InRange(p.X, 0, 20));
    }

    [Fact]
    public void DrawFrame_EarlyOnlyRingA()
    {
        var f = JcLoaderGeometry.Frame(JcLoaderStyle.Draw, 20, 0.05);
        Assert.Single(f);
    }
}
