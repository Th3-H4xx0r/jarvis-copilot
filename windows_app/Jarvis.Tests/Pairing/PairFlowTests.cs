using Jarvis.Core.Link;
using Jarvis.Core.Pairing;
using Jarvis.Tests.Fakes;
using static Jarvis.Tests.Fakes.TestClock;

namespace Jarvis.Tests.Pairing;

/// The "Pair with your iPhone" screen's logic (contract: docs/superpowers/plans/2026-11-23-qr-pairing.md):
/// pair_status → pair_qr_start → a QR with a countdown that renews itself at expiry, pair_state
/// broadcasts, and the "Type a code instead" fallback (pair_manual).
public class PairFlowTests : IDisposable
{
    private const string Payload1 = "jarvis://pair-computer?v=1&host=192.168.1.23&port=50001&key=AAAA&name=Gaming%20PC&os=windows";
    private const string Payload2 = "jarvis://pair-computer?v=1&host=192.168.1.23&port=50002&key=BBBB&name=Gaming%20PC&os=windows";

    private readonly FakeLink _link = new();
    private readonly ManualTime _time = new();
    private readonly PairFlow _flow;
    private readonly Queue<string> _payloads = new(new[] { Payload1, Payload2, Payload1 + "3", Payload1 + "4" });
    private JsonObject _status = new() { ["ok"] = true, ["paired"] = false, ["server"] = "https://jarvis.example.com", ["device_name"] = "Gaming PC" };
    private JsonObject? _qrFailure;
    private JsonObject _manual = new() { ["ok"] = true };
    private long _ttl = 600;

    public PairFlowTests()
    {
        _link.Reply = body => J.S(body["type"]) switch
        {
            "pair_status" => (JsonObject)_status.DeepClone(),
            "pair_qr_start" => _qrFailure != null ? (JsonObject)_qrFailure.DeepClone() : new JsonObject
            {
                ["ok"] = true,
                ["payload"] = _payloads.Count > 0 ? _payloads.Dequeue() : "jarvis://pair-computer?v=1",
                ["expires_at"] = _time.GetUtcNow().ToUnixTimeSeconds() + _ttl,
                ["host"] = "192.168.1.23",
                ["port"] = 50001,
            },
            "pair_manual" => (JsonObject)_manual.DeepClone(),
            _ => new JsonObject { ["ok"] = false, ["error"] = "unexpected" },
        };
        _flow = new PairFlow(_link, _time);
    }

    public void Dispose() => _flow.Dispose();

    private int QrStarts => _link.SentOfType("pair_qr_start").Count;

    private static JsonObject State(string state, string? deviceName = null, string? error = null)
    {
        var m = new JsonObject { ["type"] = "pair_state", ["state"] = state };
        if (deviceName != null) m["device_name"] = deviceName;
        if (error != null) m["error"] = error;
        return m;
    }

    // ── when the screen shows itself ──

    [Fact]
    public void NeedsPairing_OnlyWhenJcClientSaysUnpaired()
    {
        Assert.True(PairFlow.NeedsPairing(J.Parse("""{"ok":true,"paired":false,"server":"","device_name":""}""")));
        Assert.False(PairFlow.NeedsPairing(J.Parse("""{"ok":true,"paired":true,"server":"https://j.example","device_name":"PC"}""")));
        // An older jc-client (no pair_status yet) or a link that's down: never pop the screen on a guess.
        Assert.False(PairFlow.NeedsPairing(J.Parse("""{"ok":false,"error":"unknown request 'pair_status'"}""")));
        Assert.False(PairFlow.NeedsPairing(J.Parse("""{"ok":false,"error":"Jarvis isn't running on this PC"}""")));
        Assert.False(PairFlow.NeedsPairing(J.Parse("""{"ok":true}""")));
    }

    [Fact]
    public async Task Check_AsksPairStatus_AndKeepsTheServerAndName()
    {
        var reply = await _flow.CheckAsync();
        Assert.Equal("""{"type":"pair_status"}""", J.SortedJson(_link.Sent.Single()));
        Assert.True(PairFlow.NeedsPairing(reply));
        Assert.False(_flow.IsPaired);
        Assert.Equal("https://jarvis.example.com", _flow.Server);
        Assert.Equal("Gaming PC", _flow.DeviceName);
    }

    // ── the QR and its countdown ──

    [Fact]
    public async Task Open_ShowsTheQrFromPairQrStart_WithItsCountdown()
    {
        var changes = 0;
        _flow.Changed += () => changes++;
        await _flow.OpenAsync();
        Assert.Equal(new[] { "pair_status", "pair_qr_start" }, _link.Sent.Select(m => J.S(m["type"])));
        Assert.Equal("""{"type":"pair_qr_start"}""", J.SortedJson(_link.Sent[1]));
        Assert.Equal(PairStage.Waiting, _flow.Stage);
        Assert.Equal(Payload1, _flow.Payload);
        Assert.Equal("192.168.1.23", _flow.Host);
        Assert.Equal(50001, _flow.Port);
        Assert.Equal(600, _flow.SecondsLeft);
        Assert.Equal("10:00", _flow.Countdown);
        Assert.True(changes > 0);
    }

    [Fact]
    public async Task Countdown_TicksEverySecond()
    {
        await _flow.OpenAsync();
        var changes = 0;
        _flow.Changed += () => changes++;
        _time.Advance(TimeSpan.FromSeconds(3));
        Assert.Equal(597, _flow.SecondsLeft);
        Assert.Equal("9:57", _flow.Countdown);
        Assert.True(changes >= 3);
    }

    [Fact]
    public async Task AtExpiry_ANewCodeReplacesTheOldOne()
    {
        await _flow.OpenAsync();
        _time.Advance(TimeSpan.FromSeconds(599));
        Assert.Equal(1, QrStarts);
        _time.Advance(TimeSpan.FromSeconds(1));
        await Task.Yield();
        Assert.Equal(2, QrStarts);
        Assert.Equal(Payload2, _flow.Payload);
        Assert.Equal(600, _flow.SecondsLeft);
        Assert.Equal(PairStage.Waiting, _flow.Stage);
    }

    [Fact]
    public async Task ExpiredBroadcast_RenewsOnce_EvenIfTheTimerAgrees()
    {
        await _flow.OpenAsync();
        _time.Advance(TimeSpan.FromSeconds(600));   // the timer renews…
        _flow.Handle(State("expired"));              // …and the old listener's "expired" must not renew again
        await Task.Yield();
        Assert.Equal(2, QrStarts);
    }

    [Fact]
    public async Task ExpiredBroadcast_RenewsTheCode()
    {
        await _flow.OpenAsync();
        _time.Advance(TimeSpan.FromSeconds(30));
        _flow.Handle(State("expired"));
        await Task.Yield();
        Assert.Equal(2, QrStarts);
        Assert.Equal(Payload2, _flow.Payload);
    }

    [Fact]
    public async Task ACodeWithNoExpiry_IsNeverRenewedInALoop()
    {
        _ttl = -5;   // a reply already past its time (or none): the timer leaves it alone
        await _flow.OpenAsync();
        _time.Advance(TimeSpan.FromSeconds(10));
        await Task.Yield();
        Assert.Equal(1, QrStarts);
        Assert.Equal("", _flow.Countdown);
    }

    // ── live state from jc-client ──

    [Fact]
    public async Task Pairing_ThenPaired()
    {
        await _flow.OpenAsync();
        _flow.Handle(State("pairing"));
        Assert.Equal(PairStage.Pairing, _flow.Stage);
        _time.Advance(TimeSpan.FromSeconds(700));   // no new code mid-claim
        await Task.Yield();
        Assert.Equal(1, QrStarts);
        _flow.Handle(State("paired", deviceName: "Pranav's PC"));
        Assert.Equal(PairStage.Paired, _flow.Stage);
        Assert.True(_flow.IsPaired);
        Assert.Equal("Pranav's PC", _flow.DeviceName);
        Assert.Equal(0, _time.ActiveTimers);
    }

    [Fact]
    public async Task ErrorBroadcast_ShowsIt_AndTryAgainGetsANewCode()
    {
        await _flow.OpenAsync();
        _flow.Handle(State("error", error: "the server refused the code"));
        Assert.Equal(PairStage.Failed, _flow.Stage);
        Assert.Equal("the server refused the code", _flow.Error);
        _time.Advance(TimeSpan.FromSeconds(700));   // a failed screen waits for him
        await Task.Yield();
        Assert.Equal(1, QrStarts);
        await _flow.NewCodeAsync();
        Assert.Equal(PairStage.Waiting, _flow.Stage);
        Assert.Null(_flow.Error);
        Assert.Equal(Payload2, _flow.Payload);
    }

    [Fact]
    public async Task WaitingBroadcast_AfterAnErrorDoesNotHideIt()
    {
        await _flow.OpenAsync();
        _flow.Handle(State("pairing"));
        _flow.Handle(State("waiting"));   // the phone's request failed, the listener is still up
        Assert.Equal(PairStage.Waiting, _flow.Stage);
        Assert.Equal(Payload1, _flow.Payload);
    }

    [Fact]
    public async Task OtherMessages_AreIgnored()
    {
        await _flow.OpenAsync();
        _flow.Handle(new JsonObject { ["type"] = "sessions", ["state"] = "paired" });
        Assert.Equal(PairStage.Waiting, _flow.Stage);
    }

    [Fact]
    public async Task QrStartFailure_IsShown()
    {
        _qrFailure = new JsonObject { ["ok"] = false, ["error"] = "no network address for the phone to reach" };
        await _flow.OpenAsync();
        Assert.Equal(PairStage.Failed, _flow.Stage);
        Assert.Equal("no network address for the phone to reach", _flow.Error);
        Assert.Null(_flow.Payload);
    }

    [Fact]
    public async Task AnOlderJcClient_SaysToUpdateIt()
    {
        _qrFailure = new JsonObject { ["ok"] = false, ["error"] = "unknown request 'pair_qr_start'" };
        await _flow.OpenAsync();
        Assert.Equal(PairStage.Failed, _flow.Stage);
        Assert.Equal(PairFlow.OldClientError, _flow.Error);
    }

    [Fact]
    public async Task ClosedScreen_StopsEverything_AndIgnoresLateReplies()
    {
        var hold = new TaskCompletionSource();
        _link.Hold = hold;
        var open = _flow.OpenAsync();
        _flow.Dispose();
        hold.SetResult();
        await open;
        Assert.Null(_flow.Payload);
        Assert.Equal(0, _time.ActiveTimers);
        _flow.Handle(State("expired"));
        await Task.Yield();
        Assert.Equal(0, QrStarts);   // closed before pair_status answered: no listener is opened for nobody
    }

    // ── "Type a code instead" ──

    [Fact]
    public async Task Manual_ServerIsPrefilledFromPairStatus_NeverALanDefault()
    {
        _status = new JsonObject { ["ok"] = true, ["paired"] = false, ["server"] = "", ["device_name"] = "" };
        await _flow.OpenAsync();
        Assert.Equal("", _flow.Server);
        Assert.DoesNotContain("192.168", _flow.Server);
    }

    [Fact]
    public async Task Manual_SendsPairManual_Trimmed_WithoutEmptyCloudflareFields()
    {
        await _flow.OpenAsync();
        Assert.True(await _flow.ManualAsync("  https://jarvis.example.com  ", " ABC-123 "));
        Assert.Equal("""{"code":"ABC-123","server":"https://jarvis.example.com","type":"pair_manual"}""",
            J.SortedJson(_link.SentOfType("pair_manual").Single()));
        Assert.Equal(PairStage.Paired, _flow.Stage);
        Assert.True(_flow.IsPaired);
        Assert.Equal(0, _time.ActiveTimers);
    }

    [Fact]
    public async Task Manual_PassesTheCloudflareTokenWhenGiven()
    {
        await _flow.OpenAsync();
        await _flow.ManualAsync("https://jarvis.example.com", "ABC-123", " id.access ", " s3cret ");
        var sent = _link.SentOfType("pair_manual").Single();
        Assert.Equal("id.access", J.S(sent["cf_id"]));
        Assert.Equal("s3cret", J.S(sent["cf_secret"]));
    }

    [Fact]
    public async Task Manual_ShowsJcClientsError()
    {
        _manual = new JsonObject { ["ok"] = false, ["error"] = "HTTP 404 — code not found" };
        await _flow.OpenAsync();
        Assert.False(await _flow.ManualAsync("https://jarvis.example.com", "ABC-123"));
        Assert.Equal("HTTP 404 — code not found", _flow.ManualError);
        Assert.Equal(PairStage.Waiting, _flow.Stage);   // the QR stays up beside the form
        Assert.False(_flow.ManualBusy);
    }

    [Theory]
    [InlineData("", "ABC-123", "Type your Jarvis server's address.")]
    [InlineData("jarvis.example.com", "ABC-123", "The address starts with https:// (or http://).")]
    [InlineData("https://jarvis.example.com", "  ", "Type the code your iPhone shows.")]
    public async Task Manual_ChecksWhatHeTyped_BeforeAsking(string server, string code, string error)
    {
        await _flow.OpenAsync();
        Assert.False(await _flow.ManualAsync(server, code));
        Assert.Equal(error, _flow.ManualError);
        Assert.Empty(_link.SentOfType("pair_manual"));
    }

    [Theory]
    [InlineData(true, "https://jarvis.example.com", "Paired with jarvis.example.com")]
    [InlineData(true, "https://jarvis.example.com:8787/", "Paired with jarvis.example.com")]
    [InlineData(true, "", "Paired")]
    [InlineData(false, "https://jarvis.example.com", "Not paired")]
    [InlineData(null, "", "Jarvis isn't running on this PC")]
    public void Summary_ForSettings(bool? paired, string server, string line) => Assert.Equal(line, PairFlow.Summary(paired, server));

    [Theory]
    [InlineData(600, "10:00")]
    [InlineData(61, "1:01")]
    [InlineData(9, "0:09")]
    [InlineData(0, "0:00")]
    public void Countdown_Format(int seconds, string text) => Assert.Equal(text, PairFlow.FormatCountdown(seconds));
}
