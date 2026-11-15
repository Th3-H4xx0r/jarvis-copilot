using Jarvis.Core.Gaming;
using Jarvis.Core.Island;
using Jarvis.Core.Model;
using Jarvis.Core.Prefs;
using Jarvis.Core.State;
using Jarvis.Core.Ui;
using Jarvis.Tests.Fakes;
using Jarvis.Tests.Gaming;
using static Jarvis.Core.Island.IslandStateMachine.State;
using static Jarvis.Tests.Fakes.TestClock;

namespace Jarvis.Tests.Island;

public class IslandLogicTests
{
    [Fact]
    public void Expanded_FoldsToCompactAfter8sUntouched()
    {
        var m = new IslandStateMachine();
        m.Attention(0);
        m.Tick(7.9, false, false, true);
        Assert.Equal(Expanded, m.Current);
        m.Tick(8.1, false, false, true);
        Assert.Equal(Compact, m.Current);
    }

    [Fact]
    public void Compact_HidesAfter6sWithNoSessions()
    {
        var m = new IslandStateMachine();
        m.Activity(0);
        m.Tick(5.9, false, false, false);
        Assert.Equal(Compact, m.Current);
        m.Tick(6.1, false, false, false);
        Assert.Equal(Hidden, m.Current);
    }

    [Fact]
    public void Hidden_WithSessions_GoesCompact()
    {
        var m = new IslandStateMachine();
        m.Tick(1, false, false, true);
        Assert.Equal(Compact, m.Current);
    }

    [Fact]
    public void Hovering_HoldsExpanded()
    {
        var m = new IslandStateMachine();
        m.Attention(0);
        m.Tick(30, true, false, false);
        Assert.Equal(Expanded, m.Current);
        m.Tick(38.1, false, false, false);
        Assert.Equal(Compact, m.Current);
    }

    [Fact]
    public void ClickedOutside_FoldsOnlyExpanded()
    {
        var m = new IslandStateMachine();
        m.ClickedOutside(0);
        Assert.Equal(Hidden, m.Current);
        m.Attention(0);
        m.ClickedOutside(1);
        Assert.Equal(Compact, m.Current);
    }

    [Fact] public void ForIslandClick_FromVoiceGoesToLastOther() => Assert.Equal(IslandTab.Chat, IslandTabs.ForIslandClick(IslandTab.Voice, IslandTab.Chat));
    [Fact] public void ForIslandClick_VoiceVoiceGoesToAgents() => Assert.Equal(IslandTab.Agents, IslandTabs.ForIslandClick(IslandTab.Voice, IslandTab.Voice));
    [Fact] public void TabBar_ExcludesVoice() => Assert.DoesNotContain(IslandTab.Voice, IslandTabs.TabBar);
    [Fact] public void Placement_TopCentreHangingFromTop() => Assert.Equal(new RectI(1180, 0, 1380, 32), IslandPlacement.Frame(new(0, 0, 2560, 1440), 200, 32));
    [Fact] public void Placement_NegativeMonitor() => Assert.Equal(new RectI(-1060, 0, -860, 32), IslandPlacement.Frame(new(-1920, 0, 0, 1080), 200, 32));
    [Fact] public void AgentsHeight_Approval() => Assert.Equal(IslandLayout.AgentsHeight(3, null, false) + 160, IslandLayout.AgentsHeight(3, PendingKind.Approval, false));
    [Fact] public void AgentsHeight_Caps() => Assert.Equal(IslandLayout.MaxHeight, IslandLayout.AgentsHeight(10, PendingKind.Question, true));

    [Fact]
    public void ArmGate_HalfSecond()
    {
        var g = new ArmGate(T0);
        Assert.False(g.IsArmed(T0.AddMilliseconds(499)));
        Assert.True(g.IsArmed(T0.AddMilliseconds(500)));
    }

    private static readonly IReadOnlyList<(string, RectI, bool)> Monitors = new[]
    {
        (@"\\.\DISPLAY1", new RectI(0, 0, 2560, 1440), true),
        (@"\\.\DISPLAY2", new RectI(-1920, 0, 0, 1080), false),
    };

    [Fact] public void ChooseMonitor_Primary() => Assert.Equal(new RectI(0, 0, 2560, 1440), IslandPlacement.ChooseMonitor("primary", Monitors, new PointD(-5, 5)));
    [Fact] public void ChooseMonitor_FollowMouse() => Assert.Equal(new RectI(-1920, 0, 0, 1080), IslandPlacement.ChooseMonitor("followMouse", Monitors, new PointD(-5, 5)));
    [Fact] public void ChooseMonitor_ByName() => Assert.Equal(new RectI(-1920, 0, 0, 1080), IslandPlacement.ChooseMonitor(@"display:\\.\DISPLAY2", Monitors, new PointD(5, 5)));
    [Fact] public void ChooseMonitor_UnknownNameFallsBackToPrimary() => Assert.Equal(new RectI(0, 0, 2560, 1440), IslandPlacement.ChooseMonitor(@"display:\\.\DISPLAY9", Monitors, new PointD(5, 5)));

    [Theory]
    [InlineData(true, false, false, true, true)]
    [InlineData(false, true, false, true, false)]
    [InlineData(false, true, true, true, true)]
    [InlineData(false, false, false, false, true)]
    public void KeepsTab(bool needsYou, bool working, bool showWhileWorking, bool hideWhenIdle, bool expected) =>
        Assert.Equal(expected, IslandVisibility.KeepsTab(needsYou, working, showWhileWorking, hideWhenIdle));
}

public class IslandPresenterTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "jc-island-" + Guid.NewGuid().ToString("N"));
    private readonly FakeLink _link = new();
    private readonly ManualTime _time = new();
    private readonly FakeProbe _probe = new();
    private readonly AppState _state;
    private readonly PresentationGate _gate;
    private readonly PrefsStore _prefs;

    public IslandPresenterTests()
    {
        _state = new AppState(_link, _time);
        _gate = new PresentationGate(_probe, _time);
        _state.GameModeChanged += _gate.SetGameMode;
        _prefs = new PrefsStore(Path.Combine(_dir, "prefs.json"));
    }

    public void Dispose() { try { Directory.Delete(_dir, true); } catch (IOException) { } }

    private IslandPresenter Make() => new(_state, _gate, _prefs, _time);

    private static JsonObject GameModeMsg(bool on) => new() { ["type"] = "game_mode", ["on"] = on, ["reason"] = "fullscreen", ["anticheat"] = false };

    private static JsonObject PendingMsg(string fp) => new()
    {
        ["type"] = "pending",
        ["pending"] = new JsonArray(new JsonObject { ["fingerprint"] = fp, ["key"] = "s1", ["kind"] = "permission", ["tool"] = "Bash" }),
    };

    [Fact]
    public void Starts_CompactTabByDefault()
    {
        var p = Make();
        Assert.Equal(Compact, p.State);
        Assert.True(p.Visible);
        Assert.Equal(IslandLayout.CompactWidth, p.Width);
    }

    [Fact]
    public void HideWhenIdle_StartsHidden_NoTimer()
    {
        _prefs.Set(PrefKeys.IslandHideWhenIdle, true);
        var p = Make();
        Assert.Equal(Hidden, p.State);
        Assert.False(p.Visible);
        Assert.False(p.TimerNeeded);
    }

    [Fact]
    public void GameModeOn_HidesIsland_ApprovalQueued_ThenShownExpanded()
    {
        var p = Make();
        _state.Handle(GameModeMsg(true));
        Assert.False(p.Visible);
        var before = p.State;
        _state.Handle(PendingMsg("fp1"));
        Assert.Equal(1, _gate.QueuedCount);
        Assert.Equal(before, p.State);
        _state.Handle(GameModeMsg(false));
        Assert.True(p.Visible);
        Assert.Equal(Expanded, p.State);
        Assert.Equal(IslandTab.Agents, p.Tab);
    }

    [Fact]
    public void LocalFullscreen_NotVisible_EvenWithoutBroadcast()
    {
        var p = Make();
        _probe.Fullscreen = true;
        Assert.False(p.Visible);
        _state.Handle(PendingMsg("fp1"));
        Assert.NotEqual(Expanded, p.State);
        _probe.Fullscreen = false;
        _time.Advance(TimeSpan.FromSeconds(2));
        Assert.Equal(Expanded, p.State);
    }

    [Fact]
    public void Attention_ExpandsOnAgents_ThenFoldsAfterHold()
    {
        var p = Make();
        p.SelectTab(IslandTab.Music);
        p.OnMoment(Moment.Finished, null);
        Assert.Equal(Expanded, p.State);
        Assert.Equal(IslandTab.Agents, p.Tab);
        _time.Advance(TimeSpan.FromSeconds(9));
        p.Tick();
        Assert.Equal(Compact, p.State);
    }

    [Fact]
    public void Attention_NeverRequestsTyping()
    {
        var p = Make();
        var typed = 0;
        p.TypingRequested += () => typed++;
        p.OnMoment(Moment.NeedsYou, null);
        _state.Handle(new JsonObject { ["type"] = "island", ["tab"] = "chat", ["text"] = "hi" });
        Assert.Equal(0, typed);
        Assert.Equal(IslandTab.Chat, p.Tab);
        Assert.Equal("hi", p.Draft);
    }

    [Fact]
    public void OpenForTyping_RequestsTypingOnce()
    {
        var p = Make();
        var typed = 0;
        p.TypingRequested += () => typed++;
        p.Open(IslandTab.Chat, typing: true);
        Assert.Equal(1, typed);
        Assert.True(p.Typing);
    }

    [Fact]
    public void PendingPins_Expanded()
    {
        var p = Make();
        _state.Handle(PendingMsg("fp1"));
        _time.Advance(TimeSpan.FromSeconds(30));
        p.Tick();
        Assert.Equal(Expanded, p.State);
        Assert.Equal(PendingKind.Approval, p.Pending);
    }

    [Fact]
    public void Click_FromVoiceOpensLastTab()
    {
        var p = Make();
        p.SelectTab(IslandTab.Chat);
        p.SelectTab(IslandTab.Voice);
        p.Close();
        p.Click();
        Assert.Equal(Expanded, p.State);
        Assert.Equal(IslandTab.Chat, p.Tab);
    }

    [Fact]
    public void Hover_OpensOnlyWhenPrefOn()
    {
        var p = Make();
        p.HoverChanged(true);
        Assert.Equal(Compact, p.State);
        p.HoverChanged(false);
        _prefs.Set(PrefKeys.IslandOpenOnHover, true);
        p.HoverChanged(true);
        Assert.Equal(Expanded, p.State);
    }

    [Fact]
    public void ExpandedHeight_FollowsSessionsAndPending()
    {
        var p = Make();
        _state.Handle(PendingMsg("fp1"));
        Assert.Equal(IslandLayout.AgentsHeight(0, PendingKind.Approval, false), p.Height);
    }
}
