using System.Text.Json.Nodes;
using Jarvis.Core.Gaming;
using Jarvis.Core.Http;
using Jarvis.Core.Link;
using Jarvis.Core.Screen;
using Jarvis.Platform;
using SIPSorcery.Net;
using SIPSorceryMedia.Abstractions;
using SIPSorceryMedia.Encoders;

namespace Jarvis.Screen;

/// One live share on the Mac's protocol (ScreenShareSession.swift): long-polls signalling, makes a
/// peer per viewer when it offers (candidates that came early are held), sends the display as
/// VP8, and takes the viewer's "input" data channel: input events go through the game gate,
/// `{"t":"cc"}` messages to the Command Center.
public sealed class ScreenShareSession : IShareSession
{
    private readonly ApiClient _api;
    private readonly IInputGate _gate;
    private readonly IInputSink _sink;
    private readonly IPcControls _pc;
    private readonly Action<string> _log;
    private readonly Action<ScreenShareSession> _ended;
    private readonly Dictionary<string, Peer> _peers = new();
    private readonly EarlyCandidates _early = new();
    private readonly CancellationTokenSource _cts = new();
    private readonly WgcCapture _capture = new();
    private readonly VpxVideoEncoder _encoder = new();
    private IReadOnlyList<ShareSignal.IceServer> _ice = Array.Empty<ShareSignal.IceServer>();
    private Monitors.Info? _display;
    private int _seq;
    private bool _stopped;

    public ScreenShareSession(string id, ApiClient api, IInputGate gate, IInputSink sink, IPcControls pc, Action<string> log, Action<ScreenShareSession> ended)
    {
        Id = id;
        _api = api;
        _gate = gate;
        _sink = sink;
        _pc = pc;
        _log = log;
        _ended = ended;
        _capture.Frame += OnFrame;
        _capture.Stopped += why => Stop(why);
    }

    public string Id { get; }
    public int Viewers { get { lock (_peers) return _peers.Count; } }
    public Monitors.Info? Display => _display;
    public event Action? ViewersChanged;

    public async Task StartAsync()
    {
        try { _ice = ShareSignal.IceServers(await _api.GetAsync(ShareSelection.IcePath, TimeSpan.FromSeconds(10))); }
        catch (ApiException) { _ice = ShareSignal.IceServers(null); }
        ShowDisplay(Monitors.Primary());
        _ = Task.Run(SignalLoop);
    }

    /// The Command Center's display switch: capture another monitor.
    public string? ShowDisplay(Monitors.Info? m)
    {
        if (m == null) return "That display isn't connected.";
        _display = m;
        try { _capture.Start(m.Handle); }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or InvalidOperationException)
        {
            return "Windows wouldn't let Jarvis capture that display.";
        }
        _encoder.ForceKeyFrame();
        return null;
    }

    private async Task SignalLoop()
    {
        var failures = 0;
        while (!_stopped && !_cts.IsCancellationRequested)
        {
            JsonObject reply;
            try
            {
                reply = await _api.GetAsync(ShareSelection.SignalPath(Id, _seq), TimeSpan.FromSeconds(40));
                failures = 0;
            }
            catch (ApiException e) when (e.Status is 404 or 410) { Stop(null); return; }
            catch (ApiException)
            {
                failures++;
                await Task.Delay(TimeSpan.FromSeconds(Math.Min(5, failures)));
                continue;
            }
            var (seq, inbound, ended) = ShareSignal.Batch(reply, _seq);
            _seq = seq;
            foreach (var m in inbound) await HandleAsync(m);
            if (ended) { Stop(null); return; }
        }
    }

    private async Task HandleAsync(ShareInbound m)
    {
        switch (m)
        {
            case ShareInbound.Offer offer:
                Peer? old;
                lock (_peers) { _peers.Remove(offer.Viewer, out old); }
                old?.Close();
                var peer = new Peer(this, offer.Viewer);
                lock (_peers) _peers[offer.Viewer] = peer;
                await peer.AnswerAsync(offer.Sdp);
                foreach (var c in _early.Take(offer.Viewer)) peer.AddCandidate(c);
                ViewersChanged?.Invoke();
                break;
            case ShareInbound.Candidate cand:
                Peer? p;
                lock (_peers) _peers.TryGetValue(cand.Viewer, out p);
                if (p != null) p.AddCandidate(cand); else _early.Hold(cand);
                break;
            case ShareInbound.Bye bye:
                Peer? gone;
                lock (_peers) _peers.Remove(bye.Viewer, out gone);
                gone?.Close();
                _early.Drop(bye.Viewer);
                ViewersChanged?.Invoke();
                break;
        }
    }

    private void Post(JsonObject body)
    {
        _ = Task.Run(async () =>
        {
            try { await _api.PostAsync(ShareSelection.PostPath(Id), ShareSignal.Outbound(body), TimeSpan.FromSeconds(10)); }
            catch (ApiException e) { _log($"signal post failed: {e.Error}"); }
        });
    }

    private long _lastFrameTicks;

    private void OnFrame(byte[] i420, int w, int h)
    {
        Peer[] peers;
        lock (_peers) peers = _peers.Values.Where(p => p.Connected).ToArray();
        if (peers.Length == 0) return;
        var encoded = _encoder.EncodeVideo(w, h, i420, VideoPixelFormatsEnum.I420, VideoCodecsEnum.VP8);
        if (encoded == null || encoded.Length == 0) return;
        var now = Environment.TickCount64;
        var duration = (uint)(_lastFrameTicks == 0 ? 3000 : Math.Clamp((now - _lastFrameTicks) * 90, 900, 9000));   // 90 kHz clock
        _lastFrameTicks = now;
        foreach (var p in peers) p.SendVideo(duration, encoded);
    }

    public void Stop(string? error)
    {
        if (_stopped) return;
        _stopped = true;
        _cts.Cancel();
        _capture.Stop();
        Peer[] peers;
        lock (_peers) { peers = _peers.Values.ToArray(); _peers.Clear(); }
        foreach (var p in peers)
        {
            if (error != null) p.SendData(new JsonObject { ["t"] = "error", ["error"] = error });
            p.Close();
        }
        _early.Clear();
        _log($"share {Id} stopped{(error != null ? ": " + error : "")}");
        _ended(this);
    }

    /// One viewer's peer connection and its "input" data channel.
    private sealed class Peer
    {
        private readonly ScreenShareSession _s;
        private readonly string _viewer;
        private readonly RTCPeerConnection _pc;
        private readonly CcCommands _cc;
        private RTCDataChannel? _channel;

        public Peer(ScreenShareSession s, string viewer)
        {
            _s = s;
            _viewer = viewer;
            var config = new RTCConfiguration
            {
                iceServers = s._ice.SelectMany(i => i.Urls.Select(u => new RTCIceServer { urls = u, username = i.Username, credential = i.Credential })).ToList(),
            };
            _pc = new RTCPeerConnection(config);
            var track = new MediaStreamTrack(new VideoFormat(VideoCodecsEnum.VP8, 96), MediaStreamStatusEnum.SendOnly);
            _pc.addTrack(track);
            _pc.onicecandidate += c =>
            {
                if (c == null) return;
                var line = c.ToString();
                if (!line.StartsWith("candidate:", StringComparison.Ordinal)) line = "candidate:" + line;
                s.Post(ShareSignal.Candidate(line, (int)c.sdpMLineIndex, c.sdpMid, viewer));
            };
            _pc.onconnectionstatechange += state =>
            {
                if (state == RTCPeerConnectionState.connected) s._encoder.ForceKeyFrame();
                if (state is RTCPeerConnectionState.failed or RTCPeerConnectionState.closed) s.ViewersChanged?.Invoke();
            };
            _pc.ondatachannel += dc =>
            {
                if (dc.label != "input") return;
                _channel = dc;
                dc.onmessage += (_, _, data) => OnMessage(System.Text.Encoding.UTF8.GetString(data));
            };
            _cc = new CcCommands(s._pc, SendData, wait => Thread.Sleep(wait));
        }

        public bool Connected => _pc.connectionState == RTCPeerConnectionState.connected;

        public async Task AnswerAsync(string sdp)
        {
            var result = _pc.setRemoteDescription(new RTCSessionDescriptionInit { type = RTCSdpType.offer, sdp = sdp });
            if (result != SetDescriptionResultEnum.OK) { _s._log($"offer from {_viewer} refused: {result}"); return; }
            var answer = _pc.createAnswer();
            await _pc.setLocalDescription(answer);
            _s.Post(ShareSignal.Answer(answer.sdp, _viewer));
        }

        public void AddCandidate(ShareInbound.Candidate c)
        {
            var cand = c.Cand.StartsWith("candidate:", StringComparison.Ordinal) ? c.Cand["candidate:".Length..] : c.Cand;
            _pc.addIceCandidate(new RTCIceCandidateInit { candidate = cand, sdpMid = c.Mid, sdpMLineIndex = (ushort)Math.Max(0, c.MLine) });
        }

        public void SendVideo(uint duration, byte[] frame) => _pc.SendVideo(duration, frame);

        public void SendData(JsonObject body)
        {
            try { _channel?.send(body.ToJsonString()); }
            catch (Exception e) when (e is InvalidOperationException or ObjectDisposedException) { }
        }

        private void OnMessage(string text)
        {
            JsonObject m;
            try { m = J.Parse(text); }
            catch (Exception e) when (e is System.Text.Json.JsonException or InvalidOperationException) { return; }
            if (J.S(m["t"]) == "cc") { _ = _cc.HandleAsync(m); return; }
            if (InputMessage.Parse(m) is not { } input || _s._display is not { } d) return;
            var virt = Monitors.All().Aggregate(d.Bounds, (acc, x) => new RectI(Math.Min(acc.Left, x.Bounds.Left), Math.Min(acc.Top, x.Bounds.Top),
                Math.Max(acc.Right, x.Bounds.Right), Math.Max(acc.Bottom, x.Bounds.Bottom)));
            _s._gate.TrySend(_s._sink, InputMapper.Map(input, d.Bounds, virt));
        }

        public void Close()
        {
            try { _pc.close(); } catch (Exception e) when (e is InvalidOperationException or ObjectDisposedException) { }
        }
    }
}

/// Builds sessions for the Core ScreenShareService.
public sealed class ScreenShareFactory : IShareSessionFactory
{
    private readonly ApiClient _api;
    private readonly IInputSink _sink;
    private readonly IPcControls _pc;
    private readonly Action<string> _log;
    private readonly Action<string> _ended;

    public ScreenShareFactory(ApiClient api, IInputSink sink, IPcControls pc, Action<string> log, Action<string> ended)
    {
        _api = api;
        _sink = sink;
        _pc = pc;
        _log = log;
        _ended = ended;
    }

    public ScreenShareSession? Current { get; private set; }
    public event Action? CurrentChanged;

    public IShareSession Start(string id, string reason, bool recordReplay, IInputGate input)
    {
        var s = new ScreenShareSession(id, _api, input, _sink, _pc, _log, ended =>
        {
            if (Current == ended) { Current = null; CurrentChanged?.Invoke(); }
            _ended(ended.Id);
        });
        Current = s;
        CurrentChanged?.Invoke();
        _ = s.StartAsync();
        _log($"share {id} started ({reason}){(recordReplay ? ", replay not recorded on the PC yet" : "")}");
        return s;
    }
}
