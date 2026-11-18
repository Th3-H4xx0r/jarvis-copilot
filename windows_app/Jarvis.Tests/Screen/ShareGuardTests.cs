using Jarvis.Core.Http;
using Jarvis.Core.Link;
using Jarvis.Core.Model;
using Jarvis.Core.Screen;
using Jarvis.Tests.Fakes;

namespace Jarvis.Tests.Screen;

public sealed class FakeSession : IShareSession
{
    public string Id { get; init; } = "";
    public string Reason { get; init; } = "";
    public bool Stopped;
    public string? StoppedWhy;
    public int Viewers { get; set; } = 1;
    public void Stop(string? error) { Stopped = true; StoppedWhy = error; }
}

public sealed class FakeFactory : IShareSessionFactory
{
    public readonly List<FakeSession> Started = new();
    public IShareSession Start(string id, string reason, bool recordReplay, IInputGate input)
    {
        var s = new FakeSession { Id = id, Reason = reason };
        Started.Add(s);
        Replays[id] = recordReplay;
        Gates[id] = input;
        return s;
    }
    public readonly Dictionary<string, bool> Replays = new();
    public readonly Dictionary<string, IInputGate> Gates = new();
}

public sealed class RecordingSink : IInputSink
{
    public int Calls;
    public void Send(IReadOnlyList<InputEvent> inputs) => Calls++;
}

public class ShareGuardTests
{
    private const string Refusal = "Pranav is in a game (fullscreen); computer control is paused until he leaves it.";
    private readonly FakeFactory _factory = new();
    private GameMode _mode = GameMode.Off;
    private string _shares = "{\"shares\":[{\"id\":\"s1\",\"device_id\":\"pc1\",\"reason\":\"anytime\"}]}";
    private string? _notReady;
    private readonly FakeHttp _http;
    private readonly ManualTime _time = new();
    private readonly ScreenShareService _svc;

    public ShareGuardTests()
    {
        _http = new FakeHttp(r => r.Path.StartsWith("/api/screen/shares?") ? FakeHttp.Json(_shares) : FakeHttp.Json("{\"ok\":true}"));
        _svc = new ScreenShareService(new ApiClient(() => "http://o", _http), () => "pc1", () => _mode, _factory, () => _notReady, _time);
    }

    /// Lets time pass and waits for the grace re-check it fires.
    private async Task Pass(double seconds)
    {
        _time.Advance(TimeSpan.FromSeconds(seconds));
        await _svc.GraceCheck;
    }

    [Fact]
    public async Task Poll_StartsOnlyOwnShares_ListsWithDevice()
    {
        _shares = "{\"shares\":[{\"id\":\"s1\",\"device_id\":\"pc1\"},{\"id\":\"s2\",\"device_id\":\"mac1\"}]}";
        await _svc.PollAsync();
        Assert.Equal(new[] { "s1" }, _factory.Started.Select(s => s.Id));
        Assert.Equal("/api/screen/shares?active=1&from=mac&device=pc1", _http.Requests[0].Path);
        await _svc.PollAsync();
        Assert.Single(_factory.Started);
    }

    [Fact]
    public async Task Poll_EndedOnServer_StopsLocally()
    {
        await _svc.PollAsync();
        _shares = "{\"shares\":[]}";
        await _svc.PollAsync();
        Assert.True(_factory.Started[0].Stopped);
        Assert.Equal(0, _svc.Viewers);
    }

    [Fact]
    public async Task Share_RefusedToStartInGameMode_AfterTheGrace_PostsStopWithReason()
    {
        _mode = new GameMode(true, "fullscreen", false);
        await _svc.PollAsync();
        Assert.Empty(_factory.Started);
        Assert.Empty(_http.To("/api/screen/shares/s1/stop"));   // a flicker gets its grace first
        await Pass(ShareGameGrace.Window.TotalSeconds);
        Assert.Empty(_factory.Started);
        var stop = Assert.Single(_http.To("/api/screen/shares/s1/stop"));
        Assert.Equal("{\"error\":\"" + Refusal + "\"}", J.SortedJson(J.Parse(stop.Body!)));
        await _svc.PollAsync();
        Assert.Single(_http.To("/api/screen/shares/s1/stop"));
    }

    [Fact]
    public async Task Share_RequestedDuringAGameFlicker_StartsOnceItClears()
    {
        _mode = new GameMode(true, "fullscreen textinputhost.exe", false);
        await _svc.PollAsync();
        Assert.Empty(_factory.Started);
        _mode = GameMode.Off;
        await _svc.GameModeChangedAsync(_mode);
        await _svc.GraceCheck;
        Assert.Equal(new[] { "s1" }, _factory.Started.Select(s => s.Id));
        Assert.Empty(_http.To("/api/screen/shares/s1/stop"));
    }

    [Fact]
    public async Task Share_GameModeOnMidShare_RefusesInputAtOnce_StopsAfterTheGrace()
    {
        await _svc.PollAsync();
        var gate = _factory.Gates["s1"];
        var sink = new RecordingSink();
        Assert.True(gate.TrySend(sink, new[] { new InputEvent() }));
        Assert.Equal(1, sink.Calls);
        _mode = new GameMode(true, "fullscreen", false);
        await _svc.GameModeChangedAsync(_mode);
        Assert.False(gate.TrySend(sink, new[] { new InputEvent() }));   // no input reaches a game, even in the grace
        Assert.Equal(1, sink.Calls);
        Assert.False(_factory.Started[0].Stopped);
        await Pass(4);
        Assert.False(_factory.Started[0].Stopped);
        await Pass(1);
        Assert.True(_factory.Started[0].Stopped);
        Assert.Equal(Refusal, _factory.Started[0].StoppedWhy);
        Assert.Single(_http.To("/api/screen/shares/s1/stop"));
    }

    [Fact]
    public async Task Share_GameFlickerShorterThanTheGrace_KeepsTheShare()
    {
        await _svc.PollAsync();
        _mode = new GameMode(true, "fullscreen textinputhost.exe", false);
        await _svc.GameModeChangedAsync(_mode);
        await Pass(2);
        _mode = GameMode.Off;
        await _svc.GameModeChangedAsync(_mode);
        await Pass(10);
        Assert.False(_factory.Started[0].Stopped);
        Assert.Empty(_http.To("/api/screen/shares/s1/stop"));
        Assert.True(_factory.Gates["s1"].TrySend(new RecordingSink(), new[] { new InputEvent() }));
    }

    [Fact]
    public async Task Share_AntiCheatMidShare_StopsAtOnce()
    {
        await _svc.PollAsync();
        _mode = new GameMode(false, "VALORANT-Win64-Shipping.exe", true);
        await _svc.GameModeChangedAsync(_mode);
        Assert.True(_factory.Started[0].Stopped);
        Assert.Single(_http.To("/api/screen/shares/s1/stop"));
    }

    [Fact]
    public async Task Share_SessionOffTheConsoleAfterRemoteDesktop_PostsTheReasonInsteadOfCapturing()
    {
        _notReady = ShareReadiness.SignInScreen;
        await _svc.PollAsync();
        Assert.Empty(_factory.Started);
        var stop = Assert.Single(_http.To("/api/screen/shares/s1/stop"));
        Assert.Contains("sign-in screen", stop.Body);
        _notReady = null;
        await _svc.PollAsync();
        Assert.Empty(_factory.Started);   // that share is over; the phone asks again
    }

    [Fact]
    public async Task Share_AntiCheatInBackground_RefusesCapture()
    {
        _mode = new GameMode(false, "VALORANT-Win64-Shipping.exe", true);
        await _svc.PollAsync();
        Assert.Empty(_factory.Started);
        Assert.Contains("VALORANT-Win64-Shipping.exe", _http.To("/api/screen/shares/s1/stop").Single().Body);
    }

    [Fact]
    public async Task TaskShare_UploadsReplay_AnytimeDoesNot()
    {
        _shares = "{\"shares\":[{\"id\":\"t1\",\"device_id\":\"pc1\",\"reason\":\"task\"},{\"id\":\"a1\",\"device_id\":\"pc1\",\"reason\":\"anytime\"}]}";
        await _svc.PollAsync();
        Assert.True(_factory.Replays["t1"]);
        Assert.False(_factory.Replays["a1"]);
    }

    [Fact]
    public async Task StopAll_StopsEverySession_AndTellsTheServerWhy()
    {
        await _svc.PollAsync();
        await _svc.StopAllAsync("Remote Desktop is in use");
        Assert.True(_factory.Started[0].Stopped);
        Assert.Contains("Remote Desktop is in use", Assert.Single(_http.To("/api/screen/shares/s1/stop")).Body);
    }

    [Fact]
    public async Task StopAll_WithoutAReason_IsLocalOnly()
    {
        await _svc.PollAsync();
        await _svc.StopAllAsync(null);
        Assert.True(_factory.Started[0].Stopped);
        Assert.Empty(_http.To("/api/screen/shares/s1/stop"));
    }

    [Fact]
    public async Task SessionFailedToStart_TellsTheServerAndIsNotRestarted()
    {
        await _svc.PollAsync();
        await _svc.SessionFailedAsync("s1", ShareReadiness.SignInScreen);
        Assert.Contains("sign-in screen", Assert.Single(_http.To("/api/screen/shares/s1/stop")).Body);
        await _svc.PollAsync();
        Assert.Single(_factory.Started);
    }

    [Fact]
    public async Task NoDeviceId_DoesNothing()
    {
        var svc = new ScreenShareService(new ApiClient(() => "http://o", _http), () => null, () => GameMode.Off, _factory);
        await svc.PollAsync();
        Assert.Empty(_http.Requests);
    }
}
