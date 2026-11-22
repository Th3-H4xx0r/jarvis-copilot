using System.Text.Json.Nodes;
using Jarvis.Core.Http;
using Jarvis.Core.Screen;

namespace Jarvis.Core.GlassesCamera;

/// The machine side of the camera, for the service: is it installed, how many apps use it, and
/// anything wrong on this PC that Settings should say (the frame file can't be written…).
public interface IGlassesCamHost
{
    /// Cheap: called every 10 s (and when Settings asks).
    bool Installed();
    /// Apps using the camera now; null when it can't be read. Called every second.
    int? Clients();
    string? Failure();
}

/// The phone's WebRTC peer (the app's SIPSorcery adapter): receives the glasses' video, decodes
/// it and writes each frame into the camera's frame file.
public interface IGlassesCamPeer
{
    string Viewer { get; }
    /// Answers the phone's offer; the answer and our candidates go out through `send`.
    void Accept(string offerSdp);
    void AddCandidate(ShareInbound.Candidate candidate);
    void Close();
}

public interface IGlassesCamPeerFactory
{
    /// `send`: a signalling body (answer, candidate) for the phone. `state`: the connection's
    /// changes. `frame`: a frame went into the camera.
    IGlassesCamPeer Create(string viewer, IReadOnlyList<ShareSignal.IceServer> ice, Action<JsonObject> send,
        Action<GlassesCamPeerState> state, Action frame);
}

/// The Jarvis Glasses camera's live side on this PC (the Mac's GlassesCameraService). Once a
/// second: is an app using the camera? While one is (and 15 s after) it ASKS for the glasses'
/// video — a share with reason "glasses" and this PC's device id on the Jarvis server, the screen
/// share signalling run in reverse: the iPhone joins as the viewer and offers send-only video, this
/// PC answers, and the frames go into the camera. When no app uses the camera it stops asking (the
/// phone then stops sending): nothing decodes or talks to the server while he games.
///
/// One phone at a time: the newest offer replaces the peer. A share the server ends is asked for
/// again on the next tick; two that end within seconds of asking (another computer took the
/// video) pause asking for a minute, so two computers never ping-pong the phone.
public sealed class GlassesCameraService : IDisposable
{
    public static readonly TimeSpan TickEvery = TimeSpan.FromSeconds(1);
    public static readonly TimeSpan LookEvery = TimeSpan.FromSeconds(10);
    public static readonly TimeSpan ShortLived = TimeSpan.FromSeconds(30);
    public static readonly TimeSpan CoolDown = TimeSpan.FromSeconds(60);

    private readonly ApiClient _api;
    private readonly Func<string?> _deviceId;
    private readonly Func<bool> _online;
    private readonly IGlassesCamHost _host;
    private readonly IGlassesCamPeerFactory _peers;
    private readonly TimeProvider _time;
    private readonly Action<string> _log;
    private readonly GlassesCamDemand _demand = new();
    private readonly EarlyCandidates _early = new();
    private readonly object _lock = new();

    private ITimer? _timer;
    private int _ticking;
    private bool? _installed;
    private DateTimeOffset _lookedAt = DateTimeOffset.MinValue;
    private string? _shareId;
    private CancellationTokenSource? _signal;
    private IReadOnlyList<ShareSignal.IceServer> _ice = Array.Empty<ShareSignal.IceServer>();
    private DateTimeOffset _askedAt;
    private DateTimeOffset _nextAskAt = DateTimeOffset.MinValue;
    private int _askFailures;
    private int _shortEnds;
    private DateTimeOffset _coolUntil = DateTimeOffset.MinValue;
    private IGlassesCamPeer? _peer;
    private GlassesCamPeerState? _peerState;
    private long _lastFrameTicks;
    private Task _outbox = Task.CompletedTask;
    private string? _failure;

    public GlassesCameraService(ApiClient api, Func<string?> deviceId, Func<bool> online, IGlassesCamHost host,
        IGlassesCamPeerFactory peers, TimeProvider? time = null, Action<string>? log = null)
    {
        _api = api;
        _deviceId = deviceId;
        _online = online;
        _host = host;
        _peers = peers;
        _time = time ?? TimeProvider.System;
        _log = log ?? (_ => { });
    }

    public GlassesCamPhase Phase { get; private set; } = GlassesCamPhase.NotInstalled;
    public string PhaseText => Phase.Text(_failure);
    /// The phase changed (raised on any thread).
    public event Action? Changed;

    /// The share being asked for now (tests).
    internal string? ShareId { get { lock (_lock) return _shareId; } }

    public void Start() => _timer ??= _time.CreateTimer(_ => _ = TickAsync(), null, TimeSpan.Zero, TickEvery);

    /// Look at the camera again now (after Settings installed or removed it), and ask again at
    /// once if asking was paused.
    public void Refresh()
    {
        lock (_lock)
        {
            _lookedAt = DateTimeOffset.MinValue;
            _coolUntil = DateTimeOffset.MinValue;
            _shortEnds = 0;
            _nextAskAt = DateTimeOffset.MinValue;
        }
        _ = TickAsync();
    }

    public async Task TickAsync()
    {
        if (Interlocked.Exchange(ref _ticking, 1) == 1) return;
        try
        {
            var now = _time.GetUtcNow();
            if (_installed == null || now - _lookedAt >= LookEvery)
            {
                _installed = _host.Installed();
                _lookedAt = now;
            }
            var installed = _installed.Value;
            var clients = installed ? _host.Clients() : 0;
            var wanted = _demand.Wanted(installed, clients, now);
            var online = _online();
            bool asked, cooling;
            lock (_lock)
            {
                asked = _shareId != null;
                cooling = now < _coolUntil;
            }
            if (wanted && online)
            {
                if (!asked && !cooling && now >= _nextAskAt) await AskAsync(now).ConfigureAwait(false);
            }
            else if (!wanted)
            {
                if (asked) await EndShareAsync(tellServer: true).ConfigureAwait(false);
                lock (_lock)
                {
                    _shortEnds = 0;
                    _coolUntil = DateTimeOffset.MinValue;
                }
            }
            Update(installed, wanted, online, now);
        }
        finally
        {
            Volatile.Write(ref _ticking, 0);
        }
    }

    private void Update(bool installed, bool wanted, bool online, DateTimeOffset now)
    {
        GlassesCamPhase phase;
        string? failure;
        lock (_lock)
        {
            failure = installed ? _host.Failure() : null;
            var fresh = Interlocked.Read(ref _lastFrameTicks) is var t && t > 0 && now.UtcTicks - t < GlassesCamSpec.StaleAfter.Ticks;
            phase = GlassesCamPhases.Of(installed, wanted, online, _shareId != null || now < _coolUntil,
                _peer == null ? null : _peerState, fresh, failure);
        }
        if (phase == Phase && failure == _failure) return;
        Phase = phase;
        _failure = failure;
        Changed?.Invoke();
    }

    // ── The request ("glasses" share) ──

    private async Task AskAsync(DateTimeOffset now)
    {
        var body = new JsonObject { ["reason"] = "glasses" };
        if (_deviceId() is { Length: > 0 } device) body["device_id"] = device;
        JsonObject reply;
        try
        {
            reply = await _api.PostAsync("/api/screen/shares", body, TimeSpan.FromSeconds(15)).ConfigureAwait(false);
        }
        catch (ApiException e)
        {
            _askFailures++;
            _nextAskAt = now + TimeSpan.FromSeconds(Math.Min(30, 1 << Math.Min(5, _askFailures - 1)));
            _log($"glasses camera: couldn't ask for the video: {e.Error}");
            return;
        }
        var id = Link.J.S(reply["id"]);
        if (id.Length == 0)
        {
            _askFailures++;
            _nextAskAt = now + TimeSpan.FromSeconds(Math.Min(30, 1 << Math.Min(5, _askFailures - 1)));
            return;
        }
        _askFailures = 0;
        var cts = new CancellationTokenSource();
        lock (_lock)
        {
            _ice = ShareSignal.IceServers(reply);
            _shareId = id;
            _askedAt = now;
            _signal = cts;
            _early.Clear();
        }
        _log($"glasses camera: asked for the video ({id})");
        _ = Task.Run(() => SignalLoopAsync(id, cts.Token));
    }

    private bool IsCurrent(string id)
    {
        lock (_lock) return _shareId == id;
    }

    private async Task SignalLoopAsync(string id, CancellationToken ct)
    {
        var seq = 0;
        var failures = 0;
        while (!ct.IsCancellationRequested && IsCurrent(id))
        {
            var started = _time.GetUtcNow();
            JsonObject reply;
            try
            {
                reply = await _api.GetAsync(ShareSelection.SignalPath(id, seq), TimeSpan.FromSeconds(40)).ConfigureAwait(false);
                failures = 0;
            }
            catch (ApiException e) when (e.Status is 404 or 410)
            {
                ShareEnded(id);
                return;
            }
            catch (ApiException)
            {
                failures++;
                await DelayAsync(TimeSpan.FromSeconds(Math.Min(5, failures)), ct).ConfigureAwait(false);
                continue;
            }
            if (!IsCurrent(id)) return;
            var (next, inbound, ended) = ShareSignal.Batch(reply, seq);
            seq = next;
            foreach (var m in inbound) Handle(id, m);
            if (ended)
            {
                ShareEnded(id);
                return;
            }
            // A long poll that came straight back empty: don't spin.
            if (inbound.Count == 0 && _time.GetUtcNow() - started < TimeSpan.FromSeconds(1))
                await DelayAsync(TimeSpan.FromSeconds(1), ct).ConfigureAwait(false);
        }
    }

    private async Task DelayAsync(TimeSpan by, CancellationToken ct)
    {
        try { await Task.Delay(by, _time, ct).ConfigureAwait(false); }
        catch (OperationCanceledException) { }
    }

    /// The server ended it (a restart, the phone stopped it, too old): asked again on the next tick,
    /// unless shares keep ending within seconds of asking (then a minute's pause).
    private void ShareEnded(string id)
    {
        IGlassesCamPeer? peer;
        lock (_lock)
        {
            if (_shareId != id) return;
            peer = TakePeerLocked();
            _shareId = null;
            _signal?.Cancel();
            _signal = null;
            var now = _time.GetUtcNow();
            _shortEnds = now - _askedAt < ShortLived ? _shortEnds + 1 : 0;
            if (_shortEnds >= 2)
            {
                _coolUntil = now + CoolDown;
                _shortEnds = 0;
            }
        }
        peer?.Close();
        _log($"glasses camera: the server ended {id}");
    }

    private async Task EndShareAsync(bool tellServer)
    {
        string? id;
        IGlassesCamPeer? peer;
        lock (_lock)
        {
            id = _shareId;
            if (id == null) return;
            _shareId = null;
            _signal?.Cancel();
            _signal = null;
            peer = TakePeerLocked();
        }
        peer?.Close();
        _log($"glasses camera: stopped asking ({id})");
        if (!tellServer) return;
        try { await _api.PostAsync(ShareSelection.StopPath(id), new JsonObject(), TimeSpan.FromSeconds(10)).ConfigureAwait(false); }
        catch (ApiException) { }
    }

    /// Stops asking and tells the server (the app is quitting).
    public Task StopAsync() => EndShareAsync(tellServer: true);

    // ── The phone's peer ──

    private void Handle(string id, ShareInbound m)
    {
        switch (m)
        {
            case ShareInbound.Offer offer:
            {
                IGlassesCamPeer? old;
                IGlassesCamPeer? made = null;
                lock (_lock)
                {
                    if (_shareId != id) return;
                    old = TakePeerLocked();
                    made = _peers.Create(offer.Viewer, _ice, body => Post(id, offer.Viewer, body),
                        state => PeerStateChanged(made, state), MarkFrame);
                    _peer = made;
                    _peerState = GlassesCamPeerState.Connecting;
                }
                old?.Close();
                made.Accept(offer.Sdp);
                foreach (var c in _early.Take(offer.Viewer)) made.AddCandidate(c);
                break;
            }
            case ShareInbound.Candidate cand:
            {
                IGlassesCamPeer? target;
                lock (_lock)
                {
                    target = _peer?.Viewer == cand.Viewer ? _peer : null;
                    if (target == null) _early.Hold(cand);
                }
                target?.AddCandidate(cand);
                break;
            }
            case ShareInbound.Bye bye:
            {
                IGlassesCamPeer? gone = null;
                lock (_lock)
                {
                    _early.Drop(bye.Viewer);
                    if (_peer?.Viewer == bye.Viewer) gone = TakePeerLocked();
                }
                gone?.Close();
                break;
            }
        }
    }

    private void PeerStateChanged(IGlassesCamPeer? peer, GlassesCamPeerState state)
    {
        IGlassesCamPeer? failed = null;
        lock (_lock)
        {
            if (peer == null || !ReferenceEquals(_peer, peer)) return;
            _peerState = state;
            if (state == GlassesCamPeerState.Failed) failed = TakePeerLocked();
        }
        failed?.Close();
    }

    private void MarkFrame() => Interlocked.Exchange(ref _lastFrameTicks, _time.GetUtcNow().UtcTicks);

    private IGlassesCamPeer? TakePeerLocked()
    {
        var p = _peer;
        _peer = null;
        _peerState = null;
        return p;
    }

    /// In order: a candidate never overtakes the answer.
    private void Post(string id, string viewer, JsonObject body)
    {
        var msg = ShareSignal.Outbound(body);
        if (viewer.Length > 0) msg["viewer"] = viewer;
        lock (_lock)
        {
            var previous = _outbox;
            _outbox = SendAfter(previous, id, msg);
        }
    }

    private async Task SendAfter(Task previous, string id, JsonObject msg)
    {
        await previous.ConfigureAwait(false);
        try { await _api.PostAsync(ShareSelection.PostPath(id), msg, TimeSpan.FromSeconds(10)).ConfigureAwait(false); }
        catch (ApiException e) { _log($"glasses camera: signal post failed: {e.Error}"); }
    }

    public void Dispose()
    {
        _timer?.Dispose();
        _timer = null;
        IGlassesCamPeer? peer;
        lock (_lock)
        {
            _signal?.Cancel();
            peer = TakePeerLocked();
        }
        peer?.Close();
    }
}
