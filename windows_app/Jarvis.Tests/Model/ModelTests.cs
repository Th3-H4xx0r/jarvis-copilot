using Jarvis.Core.Link;
using Jarvis.Core.Model;
using static Jarvis.Tests.Fakes.TestClock;

namespace Jarvis.Tests.Model;

public class ModelTests
{
    private static JsonObject Session(string key, string state, double t) =>
        new() { ["key"] = key, ["state"] = state, ["last_event_at"] = T0.ToUnixTimeSeconds() + t };

    [Fact]
    public void Sorted_ByUrgencyThenNewest()
    {
        var raw = new[] { Session("working5", "working", 5), Session("approval", "approval", 1), Session("idle", "idle", 9), Session("working7", "working", 7) };
        Assert.Equal(new[] { "approval", "working7", "working5", "idle" }, AgentSession.Sorted(raw.Select(AgentSession.FromJson)).Select(s => s.Key));
    }

    [Fact]
    public void Session_FromJson_ReadsWindowsTerminal()
    {
        var s = AgentSession.FromJson(J.Parse("{\"key\":\"local|claude|s1\",\"state\":\"working\",\"cwd\":\"C:\\\\src\\\\jarvis\",\"terminal\":{\"exe\":\"WindowsTerminal.exe\",\"window_pid\":812,\"wt_session\":\"g\"}}"));
        Assert.Equal("jarvis", s.Project);
        Assert.Equal(812, s.Terminal.WindowPid);
        Assert.Equal(SessionState.Working, s.State);
        Assert.Equal("WindowsTerminal.exe", s.Terminal.Exe);
        Assert.Equal("g", s.Terminal.WtSession);
    }

    [Fact]
    public void Session_FromJson_Defaults()
    {
        var s = AgentSession.FromJson(J.Parse("{\"key\":\"k\",\"state\":\"weird\",\"cwd\":\"/Users/p/proj\",\"turn\":{\"prompt\":\"do it\",\"files\":[{\"path\":\"/a/b.cs\",\"added\":3,\"removed\":1,\"lines\":[{\"k\":\"+\",\"t\":\"x\"}]}]},\"pending\":{\"fingerprint\":\"fp\"},\"steps\":[{\"t\":\"one\"}]}"));
        Assert.Equal("claude", s.Agent);
        Assert.Equal(SessionState.Idle, s.State);
        Assert.Equal("proj", s.Project);
        Assert.Equal("fp", s.PendingFingerprint);
        Assert.Equal("do it", s.Prompt);
        Assert.Equal(new[] { "one" }, s.Steps);
        Assert.Equal("b.cs", s.Files[0].Name);
        Assert.Equal('+', s.Files[0].Lines[0].Kind);
    }

    [Theory]
    [InlineData("claude", "Claude Code")]
    [InlineData("codex", "Codex")]
    [InlineData("", "Agent")]
    [InlineData("zed", "Zed")]
    public void DisplayName(string agent, string name) => Assert.Equal(name, AgentSession.DisplayName(agent));

    [Fact]
    public void State_UrgencyAndMood()
    {
        Assert.Equal(0, SessionState.Question.Urgency());
        Assert.Equal(5, SessionState.Idle.Urgency());
        Assert.Equal(OrbMood.Waiting, SessionState.Approval.Mood());
        Assert.Equal("Rate-limited", SessionState.RateLimit.Label());
        Assert.Equal(SessionState.RateLimit, SessionStates.Parse("ratelimit"));
    }

    [Fact]
    public void Pending_FromJson()
    {
        var p = PendingRequest.FromJson(J.Parse("{\"fingerprint\":\"f\",\"kind\":\"ask\",\"cwd\":\"C:\\\\x\\\\api\",\"questions\":[{\"question\":\"Which?\",\"multiSelect\":true,\"options\":[{\"label\":\"A\",\"description\":\"d\"}]}]}"))!;
        Assert.True(p.IsQuestion);
        Assert.Equal("api", p.Project);
        Assert.True(p.Questions[0].MultiSelect);
        Assert.Equal(new[] { "A" }, p.Questions[0].Options);
        Assert.Null(PendingRequest.FromJson(J.Parse("{\"kind\":\"ask\"}")));
    }

    [Fact]
    public void UsageWindow_UsedNowIsZeroAfterReset() => Assert.Equal(0, new UsageWindow(80, T0.AddMinutes(-1)).UsedNow(T0));

    [Fact]
    public void PlanUsage_FromJson_ClampsAndRounds()
    {
        var u = PlanUsage.FromJson(J.Parse("{\"rate_limits\":{\"five_hour\":{\"used_percentage\":12.6,\"resets_at\":1800000000},\"seven_day\":{\"used_percentage\":140}}}"))!;
        Assert.Equal(13, u.Five!.Used);
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1800000000), u.Five.ResetsAt);
        Assert.Equal(100, u.Week!.Used);
        Assert.Null(u.Week.ResetsAt);
        Assert.Null(PlanUsage.FromJson(J.Parse("{\"rate_limits\":{}}")));
    }

    [Fact]
    public void Pace_HalfwayAtHalfUsed_IsZero() => Assert.Equal(0.0, UsagePace.Pace(50, T0.AddHours(2.5), TimeSpan.FromHours(5), T0), 6);

    [Theory]
    [InlineData(9000, "2h 30m")]
    [InlineData(97200, "1 day 3h")]
    [InlineData(-5, "now")]
    [InlineData(30, "1 min")]
    public void ResetsIn_Formats(int seconds, string text) => Assert.Equal(text, UsagePace.ResetsIn(T0.AddSeconds(seconds), T0));

    [Fact]
    public void QuestionAnswers_SingleStringMultiList()
    {
        var qs = new[]
        {
            new Question("q1", "", false, new[] { "A", "B" }, new[] { "", "" }),
            new Question("q2", "", true, new[] { "X", "Z" }, new[] { "", "" }),
            new Question("q3", "", false, new[] { "M" }, new[] { "" }),
        };
        var picks = new Dictionary<string, IReadOnlyList<string>> { ["q1"] = new[] { "A" }, ["q2"] = new[] { "X" } };
        var typed = new Dictionary<string, string> { ["q2"] = " Y " };
        Assert.Equal("{\"q1\":\"A\",\"q2\":[\"X\",\"Y\"]}", J.SortedJson(QuestionAnswers.Build(qs, picks, typed)));
    }

    [Fact]
    public void QuestionAnswers_TypedReplacesSinglePick()
    {
        var qs = new[] { new Question("q1", "", false, new[] { "A" }, new[] { "" }) };
        var picks = new Dictionary<string, IReadOnlyList<string>> { ["q1"] = new[] { "A" } };
        var typed = new Dictionary<string, string> { ["q1"] = "other" };
        Assert.Equal("{\"q1\":\"other\"}", J.SortedJson(QuestionAnswers.Build(qs, picks, typed)));
    }

    [Fact]
    public void Job_ExpiredAndLabels()
    {
        var j = HarnessJob.FromJson(J.Parse("{\"id\":\"j1\",\"label\":\"claude\",\"model\":\"@anthropic:claude-sonnet-5-5\",\"status\":\"done\",\"started_at\":" + T0.ToUnixTimeSeconds() + ",\"completed_at\":" + T0.ToUnixTimeSeconds() + ",\"result\":\"First line\\nSecond\",\"surface\":\"voice\",\"device\":\"PC\"}"));
        Assert.False(j.Expired(T0.AddMinutes(14)));
        Assert.True(j.Expired(T0.AddMinutes(16)));
        Assert.Equal("Claude", j.AgentName);
        Assert.Equal("claude-sonnet-5-5", j.ModelName);
        Assert.Equal("First line", j.Line);
        Assert.Equal("By voice on PC", j.Origin);
        Assert.Equal(SessionState.Finished, j.State);
        Assert.Equal("job:j1", j.Key);
    }

    [Fact]
    public void Moved_TitleFallsBackToProject() =>
        Assert.Equal("api", MovedSession.FromJson(J.Parse("{\"ckey\":\"c\",\"project\":\"api\"}")).Title);

    [Fact]
    public void Roster_StatusLine()
    {
        Assert.Equal("Not paired", Roster.FromJson(new JsonObject()).StatusLine);
        Assert.Equal("Connected to jarvis.example", Roster.FromJson(J.Parse("{\"server\":\"jarvis.example\",\"connected\":true}")).StatusLine);
        Assert.Equal("Reconnecting to jarvis.example…", Roster.FromJson(J.Parse("{\"server\":\"jarvis.example\"}")).StatusLine);
    }

    [Fact]
    public void Recap_UrlAndDuration()
    {
        Assert.Equal("https://j.example/api/coding/agents/recap?days=7&tz=-300", Recap.Url("https://j.example", -300)!.ToString());
        Assert.Equal("1h 5m", Recap.Duration(65));
        Assert.Equal("2h", Recap.Duration(120));
        var r = Recap.FromJson(J.Parse("{\"minutes\":90,\"top_agent\":{\"agent\":\"codex\"},\"busiest_day\":{\"weekday\":\"Mon\",\"minutes\":30}}"));
        Assert.Equal("1h 30m", r.Time);
        Assert.Equal("Codex", r.Highlights[0].Value);
        Assert.Equal("Mon · 30m", r.Highlights[1].Value);
    }

    [Fact]
    public void GameMode_FromJson()
    {
        var g = GameMode.FromJson(J.Parse("{\"on\":true,\"reason\":\"fullscreen\",\"anticheat\":false}"));
        Assert.Equal(new GameMode(true, "fullscreen", false), g);
        Assert.Equal(GameMode.Off, GameMode.FromJson(null));
    }
}
