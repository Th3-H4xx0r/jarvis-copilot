using Jarvis.Core.Link;
using Jarvis.Core.Model;
using Jarvis.Core.State;
using Jarvis.Tests.Fakes;
using static Jarvis.Tests.Fakes.TestClock;

namespace Jarvis.Tests.State;

public class AppStateTests
{
    private readonly FakeLink _link = new();
    private readonly ManualTime _time = new();
    private readonly AppState _state;

    public AppStateTests() => _state = new AppState(_link, _time);

    private static JsonObject Sessions(params (string Key, string State)[] items)
    {
        var arr = new JsonArray();
        foreach (var (k, s) in items) arr.Add(new JsonObject { ["key"] = k, ["state"] = s, ["project"] = "p" });
        return new JsonObject { ["type"] = "sessions", ["sessions"] = arr };
    }

    private static JsonObject Pending(params string[] fps)
    {
        var arr = new JsonArray();
        foreach (var f in fps) arr.Add(new JsonObject { ["fingerprint"] = f, ["key"] = "s1", ["kind"] = "permission" });
        return new JsonObject { ["type"] = "pending", ["pending"] = arr };
    }

    [Fact]
    public void OnConnection_SubscribesTopics()
    {
        _state.OnConnection(true);
        Assert.True(_state.Connected);
        Assert.Equal("{\"topics\":{\"app_update\":0,\"harness_jobs\":0,\"power\":0,\"screen_shares\":0},\"type\":\"subscribe\"}",
            J.SortedJson(_link.SentOfType("subscribe").Single()));
        Assert.Single(_link.SentOfType("roster"));
    }

    [Fact]
    public void Hello_ReadsEverything()
    {
        var hello = J.Parse("""
        {"type":"hello","api":"http://127.0.0.1:8787","device_id":"pc1","device_name":"Gaming PC","platform":"windows",
         "approvals":true,"instructions":true,
         "game_mode":{"on":true,"reason":"fullscreen","anticheat":false},
         "sessions":[{"key":"s1","state":"working"}],
         "pending":[{"fingerprint":"fp1","key":"s1"}],
         "usage":{"five_hour":{"used_percentage":40}},
         "usage_codex":{"rate_limits":{"seven_day":{"used_percentage":7}}},
         "moved":[{"ckey":"c1","title":"Fix CI","project":"api"}]}
        """);
        var updates = 0;
        _state.AppUpdateSignal += d => { if (d == null) updates++; };
        _state.Handle(hello);
        Assert.Equal("http://127.0.0.1:8787", _state.ApiOrigin);
        Assert.Equal("pc1", _state.DeviceId);
        Assert.Equal("Gaming PC", _state.DeviceName);
        Assert.Equal("windows", _state.Platform);
        Assert.True(_state.ApprovalsOn);
        Assert.True(_state.InstructionsOn);
        Assert.Equal(new GameMode(true, "fullscreen", false), _state.GameMode);
        Assert.Single(_state.Sessions);
        Assert.Equal("fp1", _state.Pending.Single().Fingerprint);
        Assert.Equal(40, _state.Usage!.Five!.Used);
        Assert.Equal(7, _state.CodexUsage!.Week!.Used);
        Assert.Equal("Fix CI", _state.OnServer.Single().Title);
        Assert.Equal(1, updates);
    }

    [Fact]
    public void Hello_WithoutDeviceId_KeepsLast()
    {
        _state.Handle(J.Parse("{\"type\":\"hello\",\"device_id\":\"pc1\"}"));
        _state.Handle(J.Parse("{\"type\":\"hello\",\"api\":\"\"}"));
        Assert.Equal("pc1", _state.DeviceId);
        Assert.Null(_state.ApiOrigin);
    }

    [Fact]
    public void GameModeBroadcast_RaisesChange()
    {
        var raised = 0;
        _state.GameModeChanged += _ => raised++;
        var msg = J.Parse("{\"type\":\"game_mode\",\"on\":true,\"reason\":\"VALORANT-Win64-Shipping.exe\",\"anticheat\":true}");
        _state.Handle(msg);
        Assert.True(_state.GameMode.On);
        Assert.True(_state.GameMode.AntiCheat);
        Assert.Equal(1, raised);
        _state.Handle(msg);
        Assert.Equal(1, raised);
    }

    [Fact]
    public void ApprovalTransition_RaisesNeedsYou_WhenNoPending()
    {
        var moments = new List<(Moment, string?)>();
        _state.MomentRaised += (m, s) => moments.Add((m, s?.Key));
        _state.Handle(Sessions(("s1", "working")));
        _state.Handle(Sessions(("s1", "approval")));
        Assert.Contains((Moment.NeedsYou, "s1"), moments);

        moments.Clear();
        _state.Handle(Pending("fp9"));
        moments.Clear();
        _state.Handle(Sessions(("s1", "working")));
        _state.Handle(Sessions(("s1", "question")));
        Assert.DoesNotContain(moments, m => m.Item1 == Moment.NeedsYou);
    }

    [Fact]
    public void FreshPendingFingerprint_RaisesNeedsYou_OnceOnly()
    {
        var needs = 0;
        _state.MomentRaised += (m, _) => { if (m == Moment.NeedsYou) needs++; };
        _state.Handle(Pending("fp1"));
        _state.Handle(Pending("fp1"));
        Assert.Equal(1, needs);
        _state.Handle(Pending("fp1", "fp2"));
        Assert.Equal(2, needs);
    }

    [Fact]
    public void StartedFromIdle_RaisesStarted()
    {
        var moments = new List<Moment>();
        _state.MomentRaised += (m, _) => moments.Add(m);
        _state.Handle(Sessions(("s1", "idle")));
        _state.Handle(Sessions(("s1", "thinking")));
        Assert.Equal(new[] { Moment.Started }, moments);
    }

    [Fact]
    public void Finished_FlashesFiveSeconds()
    {
        var moments = new List<Moment>();
        _state.MomentRaised += (m, _) => moments.Add(m);
        _state.Handle(Sessions(("s1", "working")));
        _state.Handle(Sessions(("s1", "finished")));
        Assert.Equal("s1", _state.Flash?.Key);
        Assert.Contains(Moment.Finished, moments);
        _time.Advance(TimeSpan.FromSeconds(4.9));
        Assert.NotNull(_state.Flash);
        _time.Advance(TimeSpan.FromSeconds(0.2));
        Assert.Null(_state.Flash);
    }

    [Fact]
    public void Error_RaisesFailedAndFlashes()
    {
        var moments = new List<Moment>();
        _state.MomentRaised += (m, _) => moments.Add(m);
        _state.Handle(Sessions(("s1", "working")));
        _state.Handle(Sessions(("s1", "error")));
        Assert.Contains(Moment.Failed, moments);
        Assert.NotNull(_state.Flash);
    }

    [Fact]
    public void CodexUsage_GoesToCodex()
    {
        _state.Handle(J.Parse("{\"type\":\"usage\",\"rate_limits\":{\"five_hour\":{\"used_percentage\":50}}}"));
        _state.Handle(J.Parse("{\"type\":\"usage\",\"agent\":\"codex\",\"rate_limits\":{\"five_hour\":{\"used_percentage\":12}}}"));
        Assert.Equal(12, _state.CodexUsage!.Five!.Used);
        Assert.Equal(50, _state.Usage!.Five!.Used);
    }

    [Fact]
    public async Task Decide_SendsExactBody_AndRemovesOptimistically()
    {
        _state.Handle(Pending("fp1"));
        _link.Hold = new TaskCompletionSource();
        var t = _state.DecideAsync(_state.Pending[0], "deny", "no");
        Assert.Empty(_state.Pending);
        Assert.Equal("{\"decision\":\"deny\",\"fingerprint\":\"fp1\",\"message\":\"no\",\"type\":\"decide\"}",
            J.SortedJson(_link.SentOfType("decide").Single()));
        _link.Hold.SetResult();
        Assert.True(await t);
    }

    [Fact]
    public async Task Decide_WithAnswers()
    {
        _state.Handle(Pending("fp1"));
        await _state.DecideAsync(_state.Pending[0], "answer", answers: new JsonObject { ["q"] = "A" });
        Assert.Equal("{\"answers\":{\"q\":\"A\"},\"decision\":\"answer\",\"fingerprint\":\"fp1\",\"type\":\"decide\"}",
            J.SortedJson(_link.SentOfType("decide").Single()));
    }

    [Fact]
    public void IslandMessage_RaisesTabAndDraft()
    {
        (string, string?)? got = null;
        _state.IslandRequested += (tab, text) => got = (tab, text);
        _state.Handle(J.Parse("{\"type\":\"island\",\"tab\":\"chat\",\"text\":\"hi\"}"));
        Assert.Equal(("chat", "hi"), got);
        _state.Handle(J.Parse("{\"type\":\"island\"}"));
        Assert.Equal(("agents", (string?)null), got);
    }

    private static JsonObject JobsTopic(string jobsJson, string? speak = null) =>
        J.Parse("{\"type\":\"topic\",\"topic\":\"harness_jobs\",\"data\":{\"jobs\":" + jobsJson + (speak != null ? ",\"speak\":" + speak : "") + "}}");

    [Fact]
    public void JobsTopic_ExpiresEndedAfter15Min()
    {
        var t = T0.ToUnixTimeSeconds();
        _state.Handle(JobsTopic("[{\"id\":\"a\",\"status\":\"running\",\"started_at\":" + t + "},{\"id\":\"b\",\"status\":\"done\",\"started_at\":" + t + ",\"completed_at\":" + t + "},{\"id\":\"\"}]"));
        Assert.Equal(new[] { "a", "b" }, _state.Jobs.Select(j => j.Id));
        Assert.Equal(1, _state.WorkingCount);
        _time.Advance(TimeSpan.FromMinutes(15) + TimeSpan.FromSeconds(2));
        Assert.Equal(new[] { "a" }, _state.Jobs.Select(j => j.Id));
    }

    [Fact]
    public void HarnessJobsSpeak_RaisesOncePerId()
    {
        var spoken = new List<string>();
        _state.Speak += j => spoken.Add(j.Id);
        var speak = "{\"id\":\"j1\",\"result\":\"Done.\"}";
        _state.Handle(JobsTopic("[]", speak));
        _state.Handle(JobsTopic("[]", speak));
        _state.Handle(JobsTopic("[]", "{\"id\":\"j2\",\"result\":\"\"}"));
        Assert.Equal(new[] { "j1" }, spoken);
    }

    [Fact]
    public void HoloDropFrame_PassesThrough()
    {
        JsonObject? got = null;
        _state.HoloFrame += f => got = f;
        var frame = J.Parse("{\"type\":\"holo_drop\",\"event\":\"drop\",\"drop\":{\"id\":\"d1\"}}");
        _state.Handle(frame);
        Assert.Equal("drop", J.S(got!["event"]));
    }

    [Fact]
    public void Topics_ScreenSharesPowerAppUpdate()
    {
        int pokes = 0, power = 0;
        JsonObject? update = null;
        _state.ScreenSharesPoke += () => pokes++;
        _state.PowerTopic += () => power++;
        _state.AppUpdateSignal += d => update = d;
        _state.Handle(J.Parse("{\"type\":\"topic\",\"topic\":\"screen_shares\",\"data\":{}}"));
        _state.Handle(J.Parse("{\"type\":\"topic\",\"topic\":\"power\",\"data\":{}}"));
        _state.Handle(J.Parse("{\"type\":\"topic\",\"topic\":\"app_update\",\"data\":{\"build\":5}}"));
        Assert.Equal(1, pokes);
        Assert.Equal(1, power);
        Assert.Equal(5, J.I(update!["build"]));
    }

    [Fact]
    public void BringBack_SendsAgentContinueMac()
    {
        _state.Handle(J.Parse("{\"type\":\"moved\",\"sessions\":[{\"ckey\":\"c1\"},{\"ckey\":\"c2\"}]}"));
        _state.BringBack("c1");
        Assert.Equal("{\"ckey\":\"c1\",\"type\":\"agent_continue_mac\"}", J.SortedJson(_link.SentOfType("agent_continue_mac").Single()));
        Assert.Equal(new[] { "c2" }, _state.OnServer.Select(m => m.Ckey));
    }

    [Fact]
    public void Config_UpdatesSwitches()
    {
        _state.Handle(J.Parse("{\"type\":\"config\",\"approvals\":true,\"instructions\":false}"));
        Assert.True(_state.ApprovalsOn);
        Assert.False(_state.InstructionsOn);
    }

    [Fact]
    public void Derived_LeadWaitingMood()
    {
        _state.Handle(Sessions(("a", "idle"), ("b", "working"), ("c", "approval")));
        Assert.Equal("c", _state.Lead!.Key);
        Assert.Equal(1, _state.WaitingCount);
        Assert.Equal(1, _state.WorkingCount);
        Assert.Equal(OrbMood.Waiting, _state.Mood);
    }

    [Fact]
    public async Task Roster_Tray_Hooks()
    {
        _link.Reply = req => J.S(req["type"]) == "roster"
            ? J.Parse("{\"ok\":true,\"server\":\"j.example\",\"connected\":true,\"rows\":[{\"name\":\"iPhone\",\"online\":true}]}")
            : new JsonObject { ["ok"] = true };
        await _state.RefreshRosterAsync();
        Assert.Equal("iPhone", _state.Roster!.Rows.Single().Name);
        await _state.TrayAsync("logs");
        Assert.Equal("{\"action\":\"logs\",\"type\":\"tray\"}", J.SortedJson(_link.SentOfType("tray").Single()));
        await _state.HooksAsync("install", "codex", "tok", statusline: false);
        Assert.Equal("{\"action\":\"install\",\"agent\":\"codex\",\"statusline\":false,\"token\":\"tok\",\"type\":\"hooks\"}",
            J.SortedJson(_link.SentOfType("hooks").Single()));
    }

    [Fact]
    public void Demo_IgnoresPushesUntilEnded()
    {
        _state.SetDemo(DemoData.Steps[0].Sessions, DemoData.Steps[0].Pending);
        Assert.NotEmpty(_state.Sessions);
        _state.Handle(Sessions());
        Assert.NotEmpty(_state.Sessions);
        _state.EndDemo();
        Assert.Empty(_state.Sessions);
        Assert.Single(_link.SentOfType("sessions"));
        Assert.Single(_link.SentOfType("pending"));
    }

    [Fact]
    public void Changed_RaisedOnHandle()
    {
        var changed = 0;
        _state.Changed += () => changed++;
        _state.Handle(Sessions(("s1", "working")));
        Assert.True(changed >= 1);
    }

    [Fact]
    public void PairState_IsPassedOnToThePairScreen()
    {
        JsonObject? got = null;
        _state.PairState += m => got = m;
        _state.Handle(new JsonObject { ["type"] = "pair_state", ["state"] = "paired", ["device_name"] = "Gaming PC" });
        Assert.Equal("paired", J.S(got?["state"]));
        Assert.Equal("Gaming PC", J.S(got?["device_name"]));
    }
}
