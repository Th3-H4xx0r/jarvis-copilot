using Jarvis.Core.Gaming;
using Jarvis.Core.Model;
using Jarvis.Tests.Fakes;

namespace Jarvis.Tests.Gaming;

public sealed class FakeProbe : IForegroundProbe
{
    public bool Fullscreen { get; set; }
    public bool ForegroundIsFullscreen() => Fullscreen;
}

public class GamingGuardTests
{
    private static PresentationGate GateWith(GameMode m, FakeProbe? probe = null, ManualTime? time = null)
    {
        var g = new PresentationGate(probe ?? new FakeProbe(), time ?? new ManualTime());
        g.SetGameMode(m);
        return g;
    }

    private static readonly GameMode On = new(true, "fullscreen", false);

    [Fact] public void Covers_WindowFillingMonitor() => Assert.True(FullscreenRule.Covers(new(0, 0, 2560, 1440), new(0, 0, 2560, 1440), false));
    [Fact] public void Covers_BorderlessLargerThanMonitor() => Assert.True(FullscreenRule.Covers(new(-8, -8, 2568, 1448), new(0, 0, 2560, 1440), false));
    [Fact] public void Covers_MaximisedWithTaskbar_IsNot() => Assert.False(FullscreenRule.Covers(new(0, 0, 2560, 1392), new(0, 0, 2560, 1440), false));
    [Fact] public void Covers_Desktop_IsNot() => Assert.False(FullscreenRule.Covers(new(0, 0, 2560, 1440), new(0, 0, 2560, 1440), true));
    [Fact] public void Covers_OtherMonitor_IsNot() => Assert.False(FullscreenRule.Covers(new(2560, 0, 5120, 1440), new(0, 0, 2560, 1440), false));

    [Fact]
    public void Present_WhenClear_RunsAtOnce()
    {
        var ran = new List<string>();
        var g = GateWith(GameMode.Off);
        g.Present("a", () => ran.Add("a"));
        Assert.Equal(new[] { "a" }, ran);
        Assert.Equal(0, g.QueuedCount);
    }

    [Fact]
    public void Present_WhileGameModeOn_QueuesThenFlushesInOrder()
    {
        var ran = new List<string>();
        var g = GateWith(On);
        var flushed = 0;
        g.Flushed += () => flushed++;
        g.Present("a", () => ran.Add("a"));
        g.Present("b", () => ran.Add("b"));
        Assert.Empty(ran);
        Assert.Equal(2, g.QueuedCount);
        g.SetGameMode(GameMode.Off);
        Assert.Equal(new[] { "a", "b" }, ran);
        Assert.Equal(1, flushed);
        Assert.Equal(0, g.QueuedCount);
    }

    [Fact]
    public void Present_SameKeyQueued_LatestWinsKeepsFirstPosition()
    {
        var ran = new List<string>();
        var g = GateWith(On);
        g.Present("a", () => ran.Add("a1"));
        g.Present("b", () => ran.Add("b"));
        g.Present("a", () => ran.Add("a2"));
        g.SetGameMode(GameMode.Off);
        Assert.Equal(new[] { "a2", "b" }, ran);
    }

    [Fact]
    public void Present_LocalFullscreenBeforeBroadcast_Queues()
    {
        var probe = new FakeProbe { Fullscreen = true };
        var time = new ManualTime();
        var g = GateWith(GameMode.Off, probe, time);
        var ran = false;
        g.Present("card", () => ran = true);
        Assert.False(ran);
        Assert.False(g.CanPresent);
        probe.Fullscreen = false;
        time.Advance(TimeSpan.FromSeconds(2));
        Assert.True(ran);
    }

    [Fact]
    public void Present_StillFullscreenAtRecheck_StaysQueued()
    {
        var probe = new FakeProbe { Fullscreen = true };
        var time = new ManualTime();
        var g = GateWith(GameMode.Off, probe, time);
        var ran = false;
        g.Present("card", () => ran = true);
        time.Advance(TimeSpan.FromSeconds(4));
        Assert.False(ran);
        Assert.Equal(1, time.ActiveTimers);
        probe.Fullscreen = false;
        time.Advance(TimeSpan.FromSeconds(2));
        Assert.True(ran);
        Assert.Equal(0, time.ActiveTimers);
    }

    [Fact]
    public void Gate_NoTimerWhenNothingQueued()
    {
        var probe = new FakeProbe { Fullscreen = true };
        var time = new ManualTime();
        var g = GateWith(GameMode.Off, probe, time);
        Assert.Equal(0, time.ActiveTimers);
        g.Present("a", () => { });
        Assert.Equal(1, time.ActiveTimers);
        probe.Fullscreen = false;
        time.Advance(TimeSpan.FromSeconds(2));
        Assert.Equal(0, time.ActiveTimers);
    }

    [Fact]
    public void Gate_NoTimerWhileGameModeOn()
    {
        var time = new ManualTime();
        var g = GateWith(On, null, time);
        g.Present("a", () => { });
        Assert.Equal(0, time.ActiveTimers);
    }

    [Fact]
    public void AntiCheatInBackground_AllowsPresent_RefusesControl()
    {
        var m = new GameMode(false, "VALORANT-Win64-Shipping.exe", true);
        Assert.True(GateWith(m).CanPresent);
        Assert.Equal("Pranav is in a game (VALORANT-Win64-Shipping.exe); computer control is paused until he leaves it.", ComputerControlGuard.Refusal(m));
    }

    [Fact]
    public void Refusal_NullWhenNoGame() => Assert.Null(ComputerControlGuard.Refusal(GameMode.Off));

    [Fact]
    public void Refusal_FullscreenGame() =>
        Assert.Equal("Pranav is in a game (fullscreen); computer control is paused until he leaves it.", ComputerControlGuard.Refusal(On));
}
