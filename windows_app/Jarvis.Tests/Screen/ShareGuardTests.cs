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
    private readonly FakeHttp _http;
    private readonly ScreenShareService _svc;

    public ShareGuardTests()
    {
        _http = new FakeHttp(r => r.Path.StartsWith("/api/screen/shares?") ? FakeHttp.Json(_shares) : FakeHttp.Json("{\"ok\":true}"));
        _svc = new ScreenShareService(new ApiClient(() => "http://o", _http), () => "pc1", () => _mode, _factory);
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
    public async Task Share_RefusedToStartInGameMode_PostsStopWithReason()
    {
        _mode = new GameMode(true, "fullscreen", false);
        await _svc.PollAsync();
        Assert.Empty(_factory.Started);
        var stop = Assert.Single(_http.To("/api/screen/shares/s1/stop"));
        Assert.Equal("{\"error\":\"" + Refusal + "\"}", J.SortedJson(J.Parse(stop.Body!)));
        await _svc.PollAsync();
        Assert.Single(_http.To("/api/screen/shares/s1/stop"));
    }

    [Fact]
    public async Task Share_GameModeOnMidShare_StopsAndRefusesInput()
    {
        await _svc.PollAsync();
        var gate = _factory.Gates["s1"];
        var sink = new RecordingSink();
        Assert.True(gate.TrySend(sink, new[] { new InputEvent() }));
        Assert.Equal(1, sink.Calls);
        _mode = new GameMode(true, "fullscreen", false);
        await _svc.GameModeChangedAsync(_mode);
        Assert.True(_factory.Started[0].Stopped);
        Assert.Equal(Refusal, _factory.Started[0].StoppedWhy);
        Assert.Single(_http.To("/api/screen/shares/s1/stop"));
        Assert.False(gate.TrySend(sink, new[] { new InputEvent() }));
        Assert.Equal(1, sink.Calls);
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
    public async Task StopAll_StopsEverySession()
    {
        await _svc.PollAsync();
        _svc.StopAll("bye");
        Assert.True(_factory.Started[0].Stopped);
    }

    [Fact]
    public async Task NoDeviceId_DoesNothing()
    {
        var svc = new ScreenShareService(new ApiClient(() => "http://o", _http), () => null, () => GameMode.Off, _factory);
        await svc.PollAsync();
        Assert.Empty(_http.Requests);
    }
}
