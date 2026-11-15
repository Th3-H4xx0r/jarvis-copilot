using System.Net;
using Jarvis.Core.Admin;
using Jarvis.Core.Gaming;
using Jarvis.Core.Holo;
using Jarvis.Core.Http;
using Jarvis.Core.Link;
using Jarvis.Core.Model;
using Jarvis.Tests.Fakes;
using Jarvis.Tests.Gaming;

namespace Jarvis.Tests.Holo;

public sealed class FakeReceiver : IHoloReceiver
{
    public List<string> Opened { get; } = new();
    public List<(string Id, string? Local)> Copied { get; } = new();
    public bool Open(string target) { lock (Opened) Opened.Add(target); return true; }
    public bool Copy(HoloDropRecord drop, string? localFile) { lock (Copied) Copied.Add((drop.Id, localFile)); return true; }
}

public sealed class FakeCards : IHoloCards
{
    public List<HoloArrival> Shown { get; } = new();
    public List<string> Toasts { get; } = new();
    public void Show(HoloArrival card) { lock (Shown) Shown.Add(card); }
    public void Toast(string line, bool failed) { lock (Toasts) Toasts.Add(line); }
}

public sealed class FakeBeacons : IHoloBeacons
{
    public List<string> Calls { get; } = new();
    public void Chirp(string nonce) => Calls.Add("chirp:" + nonce);
    public void Flash(string nonce) => Calls.Add("flash:" + nonce);
    public void Stop() => Calls.Add("stop");
}

public sealed class FakeScreen : IHoloScreenReport
{
    public HoloScreen Current() => new(2560, 1440, 1.5, new[] { new HoloWindowOutline(0, 0, 0.5, 0.5, "Code") });
}

public sealed class FakeBle : IHoloBleBeacon
{
    public string? Advertising { get; private set; }
    public void Start(string deviceId) => Advertising = deviceId;
    public void Stop() => Advertising = null;
}

public sealed class FakeFirewall : IHoloFirewall
{
    public bool Exists { get; set; } = true;
    public bool RuleExists() => Exists;
}

/// A service wired to fakes: the server answers through FakeHttp, the gate's probe and game mode
/// are the test's to flip.
internal sealed class Rig : IDisposable
{
    public FakeHttp Http { get; }
    public FakeProbe Probe { get; } = new();
    public ManualTime Time { get; } = new();
    public FakeReceiver Receiver { get; } = new();
    public FakeCards Cards { get; } = new();
    public FakeBeacons Beacons { get; } = new();
    public FakeBle Ble { get; } = new();
    public FakeFirewall Firewall { get; } = new();
    public FakeLink Link { get; } = new();
    public GameMode Mode { get; set; } = GameMode.Off;
    public string SaveFolder { get; } = Path.Combine(Tmp.Dir(), "Holo Drop");
    public PresentationGate Gate { get; }
    public HoloDropService Service { get; }
    public Func<FakeHttp.Seen, HttpResponseMessage?>? Extra { get; set; }

    public const string Exe = @"C:\Program Files\Jarvis\Jarvis.exe";

    public Rig()
    {
        Http = new FakeHttp(Route);
        Gate = new PresentationGate(Probe, Time);
        var api = new HoloDropApi(new ApiClient(() => "http://127.0.0.1:8787", Http));
        Service = new HoloDropService(api, Gate,
            new HoloPorts(Receiver, Cards, Beacons, new FakeScreen(), Ble, Firewall),
            new HoloDropOptions
            {
                SaveFolder = SaveFolder,
                TempRoot = Tmp.Dir(),
                BindAddress = IPAddress.Loopback,
                LanAddress = () => "192.168.1.20",
                Time = Time,
                GameMode = () => Mode,
                DeviceId = () => "pc-1",
                Admin = new AdminRunner(Link),
                ExePath = Exe,
            });
    }

    private HttpResponseMessage Route(FakeHttp.Seen s)
    {
        if (Extra?.Invoke(s) is { } r) return r;
        if (s.Path == "/api/power") return FakeHttp.Json("{\"integrations\":[{\"id\":\"holo-drop\",\"enabled\":true}]}");
        if (s.Path == "/api/holo-drop/pending") return FakeHttp.Json("{\"drops\":[]}");
        if (s.Path == "/api/holo-drop/devices") return FakeHttp.Json("{\"devices\":[{\"id\":\"iphone-1\",\"name\":\"iPhone\",\"kind\":\"iphone\"}]}");
        if (s.Path.EndsWith("/content", StringComparison.Ordinal))
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent("JPEGBYTES"u8.ToArray()) };
        return FakeHttp.Json("{\"ok\":true}");
    }

    public static JsonObject DropFrame(string json) => J.Parse("{\"type\":\"holo_drop\",\"event\":\"drop\",\"drop\":" + json + "}");

    public void Dispose() => Service.Dispose();
}

public class HoloReceiveTests
{
    private const string ImageSave = "{\"id\":\"d9\",\"kind\":\"image\",\"name\":\"p.jpg\",\"action\":\"save\",\"from_name\":\"iPhone\"}";

    [Fact]
    public async Task Drop_Image_Save_WritesToDownloadsHoloDrop_ReportsLanded()
    {
        using var rig = new Rig();
        await rig.Service.HandleAsync(Rig.DropFrame(ImageSave));
        var saved = Path.Combine(rig.SaveFolder, "p.jpg");
        Assert.True(File.Exists(saved));
        Assert.Equal("JPEGBYTES", File.ReadAllText(saved));
        var landed = Assert.Single(rig.Http.To("/api/holo-drop/drops/d9/landed"));
        Assert.Equal("POST", landed.Method);
        Assert.Equal("{\"outcome\":\"saved\"}", landed.Body);
        var card = Assert.Single(rig.Cards.Shown);
        Assert.Equal(saved, card.SavedFile);
        Assert.Equal(HoloOutcome.Saved, card.Outcome);
        Assert.Equal("From iPhone · just now", card.FromLine(rig.Time.GetUtcNow()));
        Assert.Empty(rig.Receiver.Opened);
    }

    [Fact]
    public async Task Drop_SameIdTwice_LandsOnce()
    {
        using var rig = new Rig();
        var frame = Rig.DropFrame("{\"id\":\"t1\",\"kind\":\"text\",\"text\":\"hello\",\"action\":\"copy\"}");
        await rig.Service.HandleAsync(frame);
        await rig.Service.HandleAsync(frame);
        Assert.Single(rig.Receiver.Copied);
        var landed = Assert.Single(rig.Http.To("/api/holo-drop/drops/t1/landed"));
        Assert.Equal("{\"outcome\":\"copied\"}", landed.Body);
        Assert.Single(rig.Cards.Shown);
    }

    [Fact]
    public async Task Drop_LinkOpen_OpensWebLink_SaveWritesUrlFile()
    {
        using var rig = new Rig();
        await rig.Service.HandleAsync(Rig.DropFrame("{\"id\":\"l1\",\"kind\":\"link\",\"url\":\"https://github.com/x\",\"title\":\"Repo\",\"action\":\"save_open\"}"));
        Assert.Equal(new[] { "https://github.com/x" }, rig.Receiver.Opened);
        var url = Path.Combine(rig.SaveFolder, "Repo.url");
        Assert.Equal("[InternetShortcut]\r\nURL=https://github.com/x\r\n", File.ReadAllText(url));
        Assert.Equal("{\"outcome\":\"saved_opened\"}", Assert.Single(rig.Http.To("/api/holo-drop/drops/l1/landed")).Body);
    }

    [Fact]
    public async Task Drop_ExecutableOpen_HeldForTheCard()
    {
        using var rig = new Rig();
        await rig.Service.HandleAsync(Rig.DropFrame("{\"id\":\"x1\",\"kind\":\"file\",\"name\":\"setup.exe\",\"action\":\"open\"}"));
        Assert.Empty(rig.Receiver.Opened);
        var card = Assert.Single(rig.Cards.Shown);
        Assert.Equal("Click Open to open it", card.Note);
        Assert.Equal("{\"outcome\":\"shown\"}", Assert.Single(rig.Http.To("/api/holo-drop/drops/x1/landed")).Body);
    }

    [Fact]
    public async Task Arrival_DuringLocalFullscreen_QueuedNotShown()
    {
        using var rig = new Rig();
        rig.Probe.Fullscreen = true;
        await rig.Service.HandleAsync(Rig.DropFrame(ImageSave));
        Assert.Empty(rig.Cards.Shown);
        Assert.True(File.Exists(Path.Combine(rig.SaveFolder, "p.jpg")));
        Assert.Single(rig.Http.To("/api/holo-drop/drops/d9/landed"));
        rig.Probe.Fullscreen = false;
        rig.Time.Advance(TimeSpan.FromSeconds(2));
        Assert.Single(rig.Cards.Shown);
    }

    [Fact]
    public async Task Arrival_OpenDeferredUntilGateAllows()
    {
        using var rig = new Rig();
        rig.Probe.Fullscreen = true;
        await rig.Service.HandleAsync(Rig.DropFrame("{\"id\":\"l2\",\"kind\":\"link\",\"url\":\"https://a.com/\",\"action\":\"open\"}"));
        Assert.Empty(rig.Receiver.Opened);
        Assert.Single(rig.Http.To("/api/holo-drop/drops/l2/landed"));
        rig.Probe.Fullscreen = false;
        rig.Time.Advance(TimeSpan.FromSeconds(2));
        Assert.Equal(new[] { "https://a.com/" }, rig.Receiver.Opened);
        Assert.Single(rig.Cards.Shown);
    }

    [Fact]
    public async Task WakeOrNetworkChange_NeverCallsMoved()
    {
        using var rig = new Rig();
        await rig.Service.ServerReadyAsync();
        var adverts = rig.Http.To("/api/holo-drop/lan").Count;
        Assert.True(adverts >= 1);
        await rig.Service.DidWakeAsync();
        await rig.Service.NetworkChangedAsync();
        Assert.Empty(rig.Http.To("/api/holo-drop/moved"));
        Assert.True(rig.Http.To("/api/holo-drop/lan").Count >= adverts + 2);
        Assert.Equal(2, rig.Http.To("/api/holo-drop/pending").Count);
    }

    [Fact]
    public async Task ServerReady_StartsLanAndBle_AdvertisesLanUrl()
    {
        using var rig = new Rig();
        await rig.Service.ServerReadyAsync();
        Assert.Equal("pc-1", rig.Ble.Advertising);
        Assert.NotNull(rig.Service.LanPort);
        var advert = J.Parse(rig.Http.To("/api/holo-drop/lan").Last().Body!);
        Assert.Equal($"http://192.168.1.20:{rig.Service.LanPort}", J.S(advert["url"]));
        Assert.Equal(48, J.S(advert["token"]).Length);
        Assert.Equal(TestClock.T0.AddMinutes(15).ToUnixTimeSeconds(), J.L(advert["expires"]));
        var before = rig.Http.To("/api/holo-drop/lan").Count;
        rig.Time.Advance(HoloDropService.LanAdvertEvery);
        await rig.Service.WhenIdleAsync();
        Assert.Equal(before + 1, rig.Http.To("/api/holo-drop/lan").Count);
    }

    [Fact]
    public async Task NoFirewallRule_LanStaysDown_ButtonNeeded()
    {
        using var rig = new Rig();
        rig.Firewall.Exists = false;
        await rig.Service.ServerReadyAsync();
        Assert.Null(rig.Service.LanPort);
        Assert.True(rig.Service.FirewallNeeded);
        Assert.Empty(rig.Http.To("/api/holo-drop/lan"));
    }

    [Fact]
    public async Task PowerOff_StopsEverything()
    {
        using var rig = new Rig();
        await rig.Service.ServerReadyAsync();
        rig.Extra = s => s.Path == "/api/power" ? FakeHttp.Json("{\"integrations\":[{\"id\":\"holo-drop\",\"enabled\":false}]}") : null;
        await rig.Service.PowerTopicAsync();
        Assert.False(rig.Service.On);
        Assert.Null(rig.Service.LanPort);
        Assert.Null(rig.Ble.Advertising);
        Assert.Contains("stop", rig.Beacons.Calls);
        await rig.Service.HandleAsync(Rig.DropFrame(ImageSave));
        Assert.Empty(rig.Http.To("/api/holo-drop/drops/d9"));
    }

    [Fact]
    public async Task ScreenRequest_PostsReport()
    {
        using var rig = new Rig();
        await rig.Service.HandleAsync(J.Parse("{\"type\":\"holo_drop\",\"event\":\"screen_request\",\"request\":\"r1\"}"));
        var post = Assert.Single(rig.Http.To("/api/holo-drop/screen/r1"));
        Assert.Equal("POST", post.Method);
        Assert.Equal("{\"height\":1440,\"scale\":1.5,\"width\":2560,\"windows\":[{\"app\":\"Code\",\"h\":0.5,\"w\":0.5,\"x\":0,\"y\":0}]}",
            J.SortedJson(J.Parse(post.Body!)));
    }

    [Fact]
    public async Task Beacon_IgnoredInGameMode()
    {
        using var rig = new Rig();
        rig.Mode = new GameMode(true, "fullscreen", false);
        await rig.Service.HandleAsync(J.Parse("{\"type\":\"holo_drop\",\"event\":\"beacon\",\"mode\":\"chirp\",\"nonce\":\"0x1234\"}"));
        await rig.Service.HandleAsync(J.Parse("{\"type\":\"holo_drop\",\"event\":\"beacon\",\"mode\":\"flash\",\"nonce\":\"0x1234\"}"));
        Assert.Empty(rig.Beacons.Calls);
        rig.Mode = GameMode.Off;
        await rig.Service.HandleAsync(J.Parse("{\"type\":\"holo_drop\",\"event\":\"beacon\",\"mode\":\"chirp\",\"nonce\":\"0x1234\"}"));
        Assert.Equal(new[] { "chirp:0x1234" }, rig.Beacons.Calls);
    }

    [Fact]
    public async Task Landed_ToastsOnce()
    {
        using var rig = new Rig();
        var frame = J.Parse("{\"type\":\"holo_drop\",\"event\":\"landed\",\"drop\":{\"id\":\"s1\",\"kind\":\"text\",\"target\":\"iphone-1\",\"outcome\":\"copied\"}}");
        await rig.Service.ServerReadyAsync();
        await rig.Service.HandleAsync(frame);
        await rig.Service.HandleAsync(frame);
        Assert.Equal(new[] { "Landed on iPhone · Copied" }, rig.Cards.Toasts);
    }

    [Fact]
    public async Task LanDrop_LandsThroughService()
    {
        using var rig = new Rig();
        await rig.Service.ServerReadyAsync();
        var token = J.S(J.Parse(rig.Http.To("/api/holo-drop/lan").Last().Body!)["token"]);
        var meta = HoloWire.Meta(new JsonObject { ["kind"] = "text", ["text"] = "hi", ["action"] = "copy" });
        var r = await HoloLanServerTests.Raw(rig.Service.LanPort!.Value,
            $"POST /holo-drop HTTP/1.1\r\nX-Holo-Token: {token}\r\nX-Holo-Meta: {meta}\r\nContent-Length: 13\r\n\r\n", "{\"text\":\"hi\"}"u8.ToArray());
        Assert.Equal(200, r.Status);
        Assert.Equal("copied", J.S(J.Parse(r.Body)["outcome"]));
        Assert.Single(rig.Receiver.Copied);
    }

    [Fact]
    public async Task FirewallButton_SendsAdminRun()
    {
        using var rig = new Rig();
        rig.Firewall.Exists = false;
        await rig.Service.ServerReadyAsync();
        rig.Link.Reply = _ => { rig.Firewall.Exists = true; return new JsonObject { ["ok"] = true, ["status"] = "approved" }; };
        var result = await rig.Service.AllowFirewallAsync();
        Assert.True(result.Ok);
        var sent = Assert.Single(rig.Link.SentOfType("admin_run"));
        Assert.Equal("netsh advfirewall firewall add rule name=\"Jarvis Holo Drop\" dir=in action=allow program=\"" + Rig.Exe + "\" profile=private enable=yes",
            J.S(sent["command"]));
        Assert.Equal(HoloFirewall.AddRuleCommand(Rig.Exe), J.S(sent["command"]));
        Assert.False(rig.Service.FirewallNeeded);
        Assert.NotNull(rig.Service.LanPort);
    }

    [Fact]
    public void Firewall_ShowRuleCommand() =>
        Assert.Equal("netsh advfirewall firewall show rule name=\"Jarvis Holo Drop\"", HoloFirewall.ShowRuleCommand);
}
