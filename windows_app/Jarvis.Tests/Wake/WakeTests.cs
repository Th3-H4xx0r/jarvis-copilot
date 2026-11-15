using Jarvis.Core.Gaming;
using Jarvis.Core.Link;
using Jarvis.Core.Ui;
using Jarvis.Core.Wake;

namespace Jarvis.Tests.Wake;

public class WakeTests
{
    private static float[,] Frames(int n) => new float[n, OwwFeatures.MelBins];

    [Fact]
    public void Oww_MelWindowsEvery8Frames()
    {
        var f = new OwwFeatures();
        f.PushMel(Frames(75));
        Assert.False(f.TryTakeMelWindow(out _));
        f.PushMel(Frames(1));
        Assert.True(f.TryTakeMelWindow(out var w));
        Assert.Equal(76 * 32, w.Length);
        Assert.False(f.TryTakeMelWindow(out _));
        f.PushMel(Frames(8));
        Assert.True(f.TryTakeMelWindow(out _));
        f.PushMel(Frames(7));
        Assert.False(f.TryTakeMelWindow(out _));
    }

    [Fact]
    public void Oww_WindowIsTheLatestFrames()
    {
        var f = new OwwFeatures();
        var mel = new float[80, 32];
        for (var i = 0; i < 80; i++) mel[i, 0] = i;
        f.PushMel(mel);
        Assert.True(f.TryTakeMelWindow(out var w));
        Assert.Equal(4f, w[0]);
        Assert.Equal(79f, w[75 * 32]);
    }

    [Fact]
    public void Oww_EmbeddingWindowNeeds16()
    {
        var f = new OwwFeatures();
        for (var i = 0; i < 15; i++) f.PushEmbedding(new float[96]);
        Assert.False(f.TryEmbeddingWindow(out _));
        f.PushEmbedding(Enumerable.Repeat(1f, 96).ToArray());
        Assert.True(f.TryEmbeddingWindow(out var w));
        Assert.Equal(16 * 96, w.Length);
        Assert.Equal(1f, w[^1]);
    }

    [Fact] public void Oww_Transform() => Assert.Equal(2.5f, OwwFeatures.Transform(5f));

    [Fact]
    public void WakeGate_ThresholdAndRateLimit()
    {
        var g = new WakeGate();
        Assert.False(g.Allow(0.49, 0));
        Assert.True(g.Allow(0.6, 0));
        Assert.False(g.Allow(0.9, 4.9));
        Assert.True(g.Allow(0.9, 5.1));
    }

    [Fact]
    public void WakeGate_FivePerMinute()
    {
        var g = new WakeGate();
        foreach (var t in new[] { 0.0, 6, 12, 18, 24 }) Assert.True(g.Allow(0.9, t));
        Assert.False(g.Allow(0.9, 30));
        Assert.True(g.Allow(0.9, 61));
    }

    [Fact]
    public void TalkKey_HoldStartsAfter150ms_OtherKeyCancelsWhileWaiting()
    {
        var k = new TalkKeyLogic();
        Assert.Equal(TalkKeyLogic.Action.None, k.KeyDown(0));
        Assert.Equal(TalkKeyLogic.Action.None, k.Tick(0.1));
        Assert.Equal(TalkKeyLogic.Action.Start, k.Tick(0.15));
        Assert.Equal(TalkKeyLogic.Action.None, k.OtherKey());   // typing doesn't stop a talk
        Assert.Equal(TalkKeyLogic.Action.Send, k.KeyUp(1));

        var typing = new TalkKeyLogic();
        typing.KeyDown(0);
        typing.OtherKey();
        Assert.Equal(TalkKeyLogic.Action.None, typing.Tick(0.2));
        Assert.Equal(TalkKeyLogic.Action.None, typing.KeyUp(0.3));
    }

    [Fact]
    public void TalkScreen_MessageAndPick()
    {
        var mons = new[] { (@"\\.\DISPLAY1", new RectI(0, 0, 2560, 1440)), (@"\\.\DISPLAY2", new RectI(2560, 0, 4480, 1080)) };
        var m = TalkScreen.Pick(mons, new PointD(3000, 10))!.Value;
        Assert.Equal(@"\\.\DISPLAY2", m.Name);
        Assert.Equal("{\"bounds\":[2560,0,1920,1080],\"name\":\"\\\\\\\\.\\\\DISPLAY2\",\"type\":\"talk_screen\"}", J.SortedJson(TalkScreen.Message(m.Bounds, m.Name)));
        Assert.Equal(@"\\.\DISPLAY1", TalkScreen.Pick(mons, new PointD(-50, 10))!.Value.Name);
    }

    [Fact]
    public void GlowHalf_StartsTopCentreEndsBottomCentre()
    {
        var p = EdgeGlowPath.Half(new(0, 0, 1920, 1080), 12, true);
        Assert.Equal(new PointD(960, 0), p[0]);
        Assert.Equal(new PointD(960, 1080), p[^1]);
        Assert.All(p, q => Assert.True(q.X >= 960 - 1e-9));
        var left = EdgeGlowPath.Half(new(0, 0, 1920, 1080), 12, false);
        Assert.All(left, q => Assert.True(q.X <= 960 + 1e-9));
    }
}
