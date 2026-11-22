using Jarvis.Core.Link;
using Jarvis.Core.Power;
using Jarvis.Core.Settings;
using Jarvis.Core.State;
using Jarvis.Tests.Fakes;

namespace Jarvis.Tests.Settings;

public class SettingsTests
{
    [Fact]
    public void ServerUrl_SectionAndEmbed()
    {
        Assert.Equal("http://127.0.0.1:8765/?panel=settings&section=providers", ServerSettingsUrl.For("http://127.0.0.1:8765", "providers").ToString());
        Assert.Equal("http://127.0.0.1:8765/?panel=tasks&section=integrations&embed=mac-regular",
            ServerSettingsUrl.For("http://127.0.0.1:8765", "integrations", "tasks", "mac-regular").ToString());
    }

    [Fact]
    public void Panes_HaveMacNativeIdsInOrder() =>
        Assert.Equal(new[] { "general", "agents", "pc-power", "talk", "flow", "shortcuts", "power", "glasses-camera" },
            SettingsPanes.All.Where(p => p.ServerSection is null).Select(p => p.Id));

    [Fact]
    public void Panes_ServerSectionsInOrder_IntegrationsOnTasksPanel()
    {
        Assert.Equal(new[] { "voice", "live", "speech", "voices", "conversation", "providers", "appearance", "preferences", "plugins", "integrations", "system" },
            SettingsPanes.All.Where(p => p.ServerSection != null).Select(p => p.Id));
        var i = SettingsPanes.Find("integrations")!;
        Assert.Equal("tasks", i.Panel);
        Assert.Equal("mac-regular", i.Embed);
        Assert.All(SettingsPanes.All, p => Assert.Equal(p.Native, p.ServerSection == null));
    }

    [Fact]
    public async Task AgentsPane_PreviewThenInstallWithToken()
    {
        var link = new FakeLink();
        var stale = "Your settings changed since the preview. Look again before installing.";
        var installs = 0;
        link.Reply = m => J.S(m["action"]) switch
        {
            "preview" => new JsonObject { ["ok"] = true, ["diff"] = "+ hook", ["token"] = "t1" },
            "install" => ++installs == 1 ? new JsonObject { ["ok"] = false, ["error"] = stale } : new JsonObject { ["ok"] = true },
            _ => new JsonObject { ["ok"] = true, ["agents"] = new JsonObject() },
        };
        var flow = new HooksFlow(new AppState(link, new ManualTime()));
        await flow.PreviewAsync();
        Assert.Equal("{\"action\":\"preview\",\"agent\":\"claude\",\"statusline\":true,\"type\":\"hooks\"}", J.SortedJson(link.Sent[0]));
        Assert.Equal("+ hook", flow.Diff);
        Assert.False(await flow.InstallAsync());
        Assert.Equal("{\"action\":\"install\",\"agent\":\"claude\",\"statusline\":true,\"token\":\"t1\",\"type\":\"hooks\"}", J.SortedJson(link.Sent[1]));
        Assert.Equal(stale, flow.Error);
        Assert.Equal("preview", J.S(link.Sent[2]["action"]));   // diff refreshed
        Assert.True(await flow.InstallAsync());
        Assert.Null(flow.Error);
    }

    [Fact]
    public async Task AgentsPane_AllStatusForOtherAgents()
    {
        var link = new FakeLink
        {
            Reply = _ => new JsonObject
            {
                ["ok"] = true,
                ["agents"] = new JsonObject
                {
                    ["claude"] = new JsonObject { ["installed"] = true }, ["codex"] = "not installed",
                    ["gemini"] = new JsonObject { ["state"] = "partly installed" }, ["copilot"] = false,
                },
            },
        };
        var flow = new HooksFlow(new AppState(link, new ManualTime()));
        await flow.RefreshStatusAsync();
        Assert.Equal("{\"action\":\"status\",\"agent\":\"all\",\"statusline\":true,\"type\":\"hooks\"}", J.SortedJson(link.Sent[0]));
        Assert.Equal(new[] { "claude", "codex", "copilot", "gemini" }, flow.Status.Keys.OrderBy(k => k, StringComparer.Ordinal));
        Assert.Equal("installed", flow.Status["claude"]);
        Assert.Equal("not installed", flow.Status["codex"]);
        Assert.Equal("partly installed", flow.Status["gemini"]);
        Assert.Equal("not installed", flow.Status["copilot"]);
    }

    [Fact]
    public void DiffLines_Kinds()
    {
        var lines = HooksFlow.DiffLines("--- a\n+++ b\n+add\n-del\n ctx");
        Assert.Equal(new[] { ' ', ' ', '+', '-', ' ' }, lines.Select(l => l.Kind));
    }

    [Fact] public void General_ExplainsIMessageDropped() =>
        Assert.Contains("iMessage isn't available on Windows: there is no way to read or send iMessages on a PC.", GeneralNotes.All);
}

public class PcPowerTests
{
    [Fact]
    public void PcPower_WakeSentence()
    {
        Assert.Equal("Wake from sleep works: the Mac or the Pod sends a wake-on-Wi-Fi packet.", new PcPowerState(false, false, "", "wowlan", "").WakeSentence);
        Assert.Equal("This Wi-Fi adapter can't wake the PC from sleep or off. Keep awake keeps it reachable with the screen off.",
            new PcPowerState(false, false, "", "none", "").WakeSentence);
    }

    [Fact]
    public void FromReply_ReadsJcClientsWakeShape()
    {
        var s = PcPowerState.FromReply(J.Parse("{\"ok\":true,\"keep_awake\":true,\"held\":true,\"reason\":\"manual\",\"wake\":{\"capable\":false,\"adapter\":\"Intel AX211\",\"reason\":\"this Wi-Fi adapter can't wake the PC\"}}"))!;
        Assert.True(s.KeepAwake);
        Assert.Equal("none", s.WakeMethod);
        Assert.Equal("this Wi-Fi adapter can't wake the PC", s.WakeDetail);
        Assert.Equal("Kept awake by you.", s.HeldLine);
        Assert.Equal("wowlan", PcPowerState.FromReply(J.Parse("{\"ok\":true,\"wake\":{\"capable\":true}}"))!.WakeMethod);
        Assert.Null(PcPowerState.FromReply(J.Parse("{\"ok\":false}")));
    }

    [Fact]
    public async Task KeepAwakeToggle_SendsMacPowerSet()
    {
        var link = new FakeLink { Reply = _ => new JsonObject { ["ok"] = true, ["keep_awake"] = true, ["wake"] = new JsonObject() } };
        var s = await new PcPowerClient(link).SetKeepAwakeAsync(true);
        Assert.Equal("{\"keep_awake\":true,\"type\":\"mac_power_set\"}", J.SortedJson(link.Sent[0]));
        Assert.Equal("{\"type\":\"mac_power_state\"}", J.SortedJson(link.Sent[1]));
        Assert.True(s!.KeepAwake);
    }

    [Fact]
    public async Task WillSleep_WaitsAtMost4s()
    {
        var link = new FakeLink { Hold = new TaskCompletionSource() };
        var time = new ManualTime();
        var task = new PowerRelay(link, time).WillSleepAsync();
        Assert.Equal("{\"event\":\"will_sleep\",\"type\":\"power\"}", J.SortedJson(link.Sent[0]));
        time.Advance(TimeSpan.FromSeconds(3.9));
        Assert.False(task.IsCompleted);
        time.Advance(TimeSpan.FromSeconds(0.2));
        await task.WaitAsync(TimeSpan.FromSeconds(2));
    }

    [Fact]
    public async Task WillSleep_ReturnsAsSoonAsJcClientAnswers()
    {
        var hold = new TaskCompletionSource();
        var link = new FakeLink { Hold = hold };
        var task = new PowerRelay(link, new ManualTime()).WillSleepAsync();
        hold.SetResult();
        await task.WaitAsync(TimeSpan.FromSeconds(2));
    }

    [Fact]
    public void DidWake_SendsEvent()
    {
        var link = new FakeLink();
        var relay = new PowerRelay(link, new ManualTime());
        relay.DidWake();
        Assert.Equal("{\"event\":\"did_wake\",\"type\":\"power\"}", J.SortedJson(link.Sent[0]));
        Assert.Equal("did_wake", relay.LastEvent);
    }
}
