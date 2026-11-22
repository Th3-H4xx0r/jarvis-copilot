using System.Collections.Concurrent;
using Jarvis.Core.GlassesCamera;
using Jarvis.Core.Http;
using Jarvis.Core.Link;
using Jarvis.Core.Screen;
using Jarvis.Tests.Fakes;

namespace Jarvis.Tests.GlassesCamera;

/// The PC's side of the glasses video (the Mac's GlassesCameraService): asks the server with a
/// "glasses" share only while an app uses the camera (+15 s), answers the phone's offer, keeps the
/// newest phone, and never loops on a share that keeps ending.
public class GlassesCameraServiceTests
{
    private sealed class Host : IGlassesCamHost
    {
        public bool IsInstalled = true;
        public int? Count;
        public string? Problem;
        public bool Installed() => IsInstalled;
        public int? Clients() => Count;
        public string? Failure() => Problem;
    }

    private sealed class Peer : IGlassesCamPeer
    {
        public Peer(string viewer, Action<JsonObject> send, Action<GlassesCamPeerState> state, Action frame)
        {
            Viewer = viewer;
            Send = send;
            State = state;
            Frame = frame;
        }

        public string Viewer { get; }
        public readonly Action<JsonObject> Send;
        public readonly Action<GlassesCamPeerState> State;
        public readonly Action Frame;
        public string? Offer;
        public readonly List<ShareInbound.Candidate> Candidates = new();
        public bool Closed;

        public void Accept(string offerSdp)
        {
            Offer = offerSdp;
            Send(new JsonObject { ["type"] = "answer", ["sdp"] = "answer-" + Viewer });
        }

        public void AddCandidate(ShareInbound.Candidate c) => Candidates.Add(c);
        public void Close() => Closed = true;
    }

    private sealed class Peers : IGlassesCamPeerFactory
    {
        public readonly List<Peer> Made = new();
        public IReadOnlyList<ShareSignal.IceServer>? Ice;

        public IGlassesCamPeer Create(string viewer, IReadOnlyList<ShareSignal.IceServer> ice, Action<JsonObject> send,
            Action<GlassesCamPeerState> state, Action frame)
        {
            Ice = ice;
            var p = new Peer(viewer, send, state, frame);
            lock (Made) Made.Add(p);
            return p;
        }
    }

    /// The server: numbered shares, a queue of long-poll answers per share (empty when none).
    private sealed class Server
    {
        public int Next;
        public readonly ConcurrentDictionary<string, ConcurrentQueue<string>> Polls = new();
        public readonly FakeHttp Http;
        public bool FailAsks;

        public Server()
        {
            Http = new FakeHttp(seen =>
            {
                if (seen.Method == "POST" && seen.Path == "/api/screen/shares")
                {
                    if (FailAsks) return FakeHttp.Json("{\"error\":\"down\"}", System.Net.HttpStatusCode.BadGateway);
                    var id = "scr_" + Interlocked.Increment(ref Next);
                    return FakeHttp.Json($"{{\"id\":\"{id}\",\"status\":\"requested\",\"ice_servers\":[{{\"urls\":\"turn:t\",\"username\":\"u\",\"credential\":\"c\"}}]}}");
                }
                if (seen.Method == "GET" && seen.Path.Contains("/signal?"))
                {
                    var id = seen.Path.Split('/')[4];
                    return FakeHttp.Json(Polls.GetOrAdd(id, _ => new()).TryDequeue(out var r) ? r : "{\"messages\":[]}");
                }
                return FakeHttp.Json("{\"ok\":true}");
            });
        }

        public void Say(string id, string replyJson) => Polls.GetOrAdd(id, _ => new()).Enqueue(replyJson);

        public IReadOnlyList<FakeHttp.Seen> Asks => Http.Requests.Where(r => r.Method == "POST" && r.Path == "/api/screen/shares").ToList();
        public IReadOnlyList<FakeHttp.Seen> Stops => Http.Requests.Where(r => r.Path.EndsWith("/stop", StringComparison.Ordinal)).ToList();
        public IReadOnlyList<FakeHttp.Seen> Posted => Http.Requests.Where(r => r.Method == "POST" && r.Path.EndsWith("/signal", StringComparison.Ordinal)).ToList();
    }

    private sealed record Rig(GlassesCameraService Service, Host Host, Peers Peers, Server Server, ManualTime Time, bool[] Online);

    private static Rig Make(int? clients = 1)
    {
        var server = new Server();
        var time = new ManualTime();
        var host = new Host { Count = clients };
        var peers = new Peers();
        var online = new[] { true };
        var api = new ApiClient(() => "http://127.0.0.1:9", server.Http);
        var service = new GlassesCameraService(api, () => "pc-1", () => online[0], host, peers, time);
        return new Rig(service, host, peers, server, time, online);
    }

    private static async Task Until(Func<bool> condition)
    {
        for (var i = 0; i < 300 && !condition(); i++) await Task.Delay(10);
        Assert.True(condition(), "timed out waiting");
    }

    /// Moves the clock a second at a time (waking the long-poll loop) until `condition` holds.
    private static async Task Pump(Rig r, Func<bool> condition)
    {
        for (var i = 0; i < 300 && !condition(); i++)
        {
            r.Time.Advance(TimeSpan.FromSeconds(1));
            await Task.Delay(10);
        }
        Assert.True(condition(), "timed out waiting");
    }

    private static string Offer(string viewer, int seq = 1) =>
        $"{{\"messages\":[{{\"seq\":{seq},\"from\":\"viewer\",\"viewer\":\"{viewer}\",\"type\":\"offer\",\"sdp\":\"offer-{viewer}\"}}]}}";

    [Fact]
    public async Task AsksOnceWhileAnAppUsesTheCamera()
    {
        var r = Make();
        for (var i = 0; i < 5; i++)
        {
            await r.Service.TickAsync();
            r.Time.Advance(TimeSpan.FromSeconds(1));
        }
        var ask = Assert.Single(r.Server.Asks);
        var body = J.Parse(ask.Body!);
        Assert.Equal("glasses", J.S(body["reason"]));
        Assert.Equal("pc-1", J.S(body["device_id"]));
        // It long-polls the share as the sharer (the Mac's role).
        await Until(() => r.Server.Http.Requests.Any(q => q.Path.StartsWith("/api/screen/shares/scr_1/signal?for=mac&after=0", StringComparison.Ordinal)));
        Assert.Equal(GlassesCamPhase.WaitingForPhone, r.Service.Phase);
    }

    [Fact]
    public async Task NoServerTrafficWhileNoAppUsesIt()
    {
        var r = Make(clients: 0);
        for (var i = 0; i < 30; i++)
        {
            await r.Service.TickAsync();
            r.Time.Advance(TimeSpan.FromSeconds(1));
        }
        r.Host.IsInstalled = false;
        r.Host.Count = 3;
        r.Service.Refresh();
        await r.Service.TickAsync();
        Assert.Empty(r.Server.Http.Requests);
        Assert.Equal(GlassesCamPhase.NotInstalled, r.Service.Phase);
    }

    [Fact]
    public async Task IdleIsReady()
    {
        var r = Make(clients: 0);
        await r.Service.TickAsync();
        Assert.Equal(GlassesCamPhase.Idle, r.Service.Phase);
        Assert.StartsWith("Ready.", r.Service.PhaseText);
    }

    [Fact]
    public async Task OfflineAsksNothing()
    {
        var r = Make();
        r.Online[0] = false;
        await r.Service.TickAsync();
        Assert.Empty(r.Server.Http.Requests);
        Assert.Equal(GlassesCamPhase.Offline, r.Service.Phase);
    }

    [Fact]
    public async Task StopsTheShareAfterTheLinger()
    {
        var r = Make();
        await r.Service.TickAsync();
        Assert.Single(r.Server.Asks);
        r.Host.Count = 0;
        r.Time.Advance(TimeSpan.FromSeconds(14));
        await r.Service.TickAsync();
        Assert.Empty(r.Server.Stops);
        r.Time.Advance(TimeSpan.FromSeconds(1));
        await r.Service.TickAsync();
        Assert.Equal("/api/screen/shares/scr_1/stop", Assert.Single(r.Server.Stops).Path);
        Assert.Equal(GlassesCamPhase.Idle, r.Service.Phase);
        // And nothing more after that.
        r.Time.Advance(TimeSpan.FromSeconds(30));
        await r.Service.TickAsync();
        Assert.Single(r.Server.Asks);
    }

    [Fact]
    public async Task NewestOfferReplacesThePeer()
    {
        var r = Make();
        await r.Service.TickAsync();
        r.Server.Say("scr_1", "{\"messages\":[{\"seq\":1,\"from\":\"viewer\",\"viewer\":\"ph2\",\"type\":\"candidate\",\"candidate\":{\"candidate\":\"candidate:early\",\"sdpMLineIndex\":0,\"sdpMid\":\"0\"}}]}");
        r.Server.Say("scr_1", Offer("ph1", 2));
        r.Server.Say("scr_1", Offer("ph2", 3));
        await Pump(r, () => r.Peers.Made.Count == 2);
        var (first, second) = (r.Peers.Made[0], r.Peers.Made[1]);
        await Until(() => first.Closed);
        Assert.Equal("offer-ph2", second.Offer);
        Assert.Equal(new[] { "turn:t" }, r.Peers.Ice![0].Urls);   // the share's TURN relay reaches the phone on cellular
        Assert.False(second.Closed);
        // The candidate that came before ph2's offer went to ph2's peer once it existed.
        Assert.Equal("candidate:early", Assert.Single(second.Candidates).Cand);
        // Answers go back as the Mac would send them: from "mac", to that viewer.
        await Until(() => r.Server.Posted.Count >= 2);
        var answer = r.Server.Posted.Select(p => J.Parse(p.Body!)).Last(m => J.S(m["viewer"]) == "ph2");
        Assert.Equal("mac", J.S(answer["from"]));
        Assert.Equal("answer", J.S(answer["type"]));
        Assert.Equal("answer-ph2", J.S(answer["sdp"]));
    }

    [Fact]
    public async Task ByeClosesThatPhonesPeer()
    {
        var r = Make();
        await r.Service.TickAsync();
        r.Server.Say("scr_1", Offer("ph1"));
        await Pump(r, () => r.Peers.Made.Count == 1);
        r.Server.Say("scr_1", "{\"messages\":[{\"seq\":2,\"from\":\"viewer\",\"viewer\":\"ph1\",\"type\":\"bye\"}]}");
        await Pump(r, () => r.Peers.Made[0].Closed);
        await r.Service.TickAsync();
        Assert.Equal(GlassesCamPhase.WaitingForPhone, r.Service.Phase);
    }

    [Fact]
    public async Task PhaseGoesLiveWhenFramesArrive()
    {
        var r = Make();
        await r.Service.TickAsync();
        r.Server.Say("scr_1", Offer("ph1"));
        await Pump(r, () => r.Peers.Made.Count == 1);
        var peer = r.Peers.Made[0];
        await r.Service.TickAsync();
        Assert.Equal(GlassesCamPhase.Connecting, r.Service.Phase);
        peer.State(GlassesCamPeerState.Connected);
        await r.Service.TickAsync();
        Assert.Equal(GlassesCamPhase.Connected, r.Service.Phase);
        peer.Frame();
        await r.Service.TickAsync();
        Assert.Equal(GlassesCamPhase.Live, r.Service.Phase);
        Assert.Equal("Showing your glasses' live video.", r.Service.PhaseText);
        r.Time.Advance(TimeSpan.FromSeconds(2));
        await r.Service.TickAsync();
        Assert.Equal(GlassesCamPhase.Connected, r.Service.Phase);   // frames stopped: not live any more
        peer.State(GlassesCamPeerState.Failed);
        await Until(() => peer.Closed);
        await r.Service.TickAsync();
        Assert.Equal(GlassesCamPhase.WaitingForPhone, r.Service.Phase);
    }

    [Fact]
    public async Task AnEndedShareIsAskedAgainOnceNotInASpin()
    {
        var r = Make();
        await r.Service.TickAsync();
        r.Time.Advance(TimeSpan.FromSeconds(40));   // a share that lived a while (a server restart ends it)
        r.Server.Say("scr_1", "{\"status\":\"ended\",\"messages\":[]}");
        await Pump(r, () => r.Service.ShareId == null);
        for (var i = 0; i < 5; i++)
        {
            var before = r.Server.Asks.Count;
            await r.Service.TickAsync();
            Assert.True(r.Server.Asks.Count - before <= 1, "more than one ask in a tick");
            r.Time.Advance(TimeSpan.FromSeconds(1));
        }
        Assert.Equal(2, r.Server.Asks.Count);   // the first, and exactly one more
    }

    [Fact]
    public async Task SharesThatKeepEndingStopForAMinute()
    {
        var r = Make();
        await r.Service.TickAsync();
        for (var n = 1; n <= 2; n++)
        {
            var id = "scr_" + n;
            r.Server.Say(id, "{\"status\":\"ended\",\"messages\":[]}");
            await Until(() => r.Service.ShareId == id);
            r.Time.Advance(TimeSpan.FromSeconds(1));
            await Until(() => r.Service.ShareId == null);
            await r.Service.TickAsync();
        }
        // Two shares ended within seconds of asking: no third ask for a while (no ping-pong).
        Assert.Equal(2, r.Server.Asks.Count);
        for (var i = 0; i < 30; i++)
        {
            r.Time.Advance(TimeSpan.FromSeconds(1));
            await r.Service.TickAsync();
        }
        Assert.Equal(2, r.Server.Asks.Count);
        Assert.Equal(GlassesCamPhase.WaitingForPhone, r.Service.Phase);
        r.Time.Advance(TimeSpan.FromSeconds(31));
        await r.Service.TickAsync();
        Assert.Equal(3, r.Server.Asks.Count);
    }

    [Fact]
    public async Task AFailedAskBacksOff()
    {
        var r = Make();
        r.Server.FailAsks = true;
        for (var i = 0; i < 10; i++)
        {
            await r.Service.TickAsync();
            r.Time.Advance(TimeSpan.FromSeconds(1));
        }
        Assert.InRange(r.Server.Asks.Count, 2, 4);   // 1 s, 2 s, 4 s… not every tick
    }

    [Fact]
    public async Task AHostProblemShowsInSettings()
    {
        var r = Make(clients: 0);
        r.Host.Problem = "Jarvis can't write the camera's video. Reinstall the camera.";
        await r.Service.TickAsync();
        Assert.Equal(GlassesCamPhase.Failed, r.Service.Phase);
        Assert.Equal(r.Host.Problem, r.Service.PhaseText);
    }
}
