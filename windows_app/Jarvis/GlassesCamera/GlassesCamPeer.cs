using System.IO;
using System.Net;
using System.Text.Json.Nodes;
using Jarvis.Core.GlassesCamera;
using Jarvis.Core.Screen;
using Jarvis.Screen;
using SIPSorcery.Net;
using SIPSorceryMedia.Abstractions;

namespace Jarvis.GlassesCamera;

/// The iPhone's glasses video arriving on this PC (the Mac's GlassesCameraPeer): one WebRTC peer,
/// the answerer, like a screen share's viewer is answered (ScreenShareSession) — but here the
/// phone's offer SENDS video and this side receives one VP8 track. Each frame is decoded (libvpx),
/// drawn into the camera's 720×1280 BGRA frame (fitted, black around it) and written into the frame
/// file, where the camera's media source picks it up.
public sealed class GlassesCamPeer : IGlassesCamPeer
{
    private const int W = 720, H = 1280;

    private readonly RTCPeerConnection _pc;
    private readonly Vp8Decoder _decoder = new();
    private readonly Func<GlassesCamFrameFile?> _frames;
    private readonly Action<JsonObject> _send;
    private readonly Action<GlassesCamPeerState> _state;
    private readonly Action _frame;
    private readonly Action<string> _log;
    private readonly Vp8Decoder.Picture _onPicture;
    private readonly byte[] _bgra = new byte[W * H * 4];
    private uint _remoteSsrc;
    private long _lastKeyRequest;
    private long _pictures;
    private volatile bool _closed;

    public GlassesCamPeer(string viewer, IReadOnlyList<ShareSignal.IceServer> ice, Action<JsonObject> send,
        Action<GlassesCamPeerState> state, Action frame, Func<GlassesCamFrameFile?> frames, Action<string> log)
    {
        Viewer = viewer;
        _send = send;
        _state = state;
        _frame = frame;
        _frames = frames;
        _log = log;
        _onPicture = Write;
        var config = new RTCConfiguration
        {
            iceServers = ice.SelectMany(i => i.Urls.Select(u => new RTCIceServer { urls = u, username = i.Username, credential = i.Credential })).ToList(),
        };
        _pc = new RTCPeerConnection(config);
        _pc.addTrack(new MediaStreamTrack(new VideoFormat(VideoCodecsEnum.VP8, 96), MediaStreamStatusEnum.RecvOnly));
        _pc.onicecandidate += c =>
        {
            if (c == null || _closed) return;
            var line = c.ToString();
            if (!line.StartsWith("candidate:", StringComparison.Ordinal)) line = "candidate:" + line;
            _send(ShareSignal.Candidate(line, (int)c.sdpMLineIndex, c.sdpMid, viewer));
        };
        _pc.onconnectionstatechange += s =>
        {
            if (_closed) return;
            _log($"glasses camera: phone {viewer} {s}");
            switch (s)
            {
                case RTCPeerConnectionState.connected:
                    _state(GlassesCamPeerState.Connected);
                    RequestKeyFrame();
                    break;
                case RTCPeerConnectionState.disconnected:
                    _state(GlassesCamPeerState.Disconnected);
                    break;
                case RTCPeerConnectionState.failed or RTCPeerConnectionState.closed:
                    _state(GlassesCamPeerState.Failed);
                    break;
            }
        };
        _pc.OnRtpPacketReceived += (_, media, packet) =>
        {
            if (media == SDPMediaTypesEnum.video) _remoteSsrc = packet.Header.SyncSource;
        };
        _pc.OnVideoFrameReceived += OnVideoFrame;
    }

    public string Viewer { get; }

    public void Accept(string offerSdp) => _ = AcceptAsync(offerSdp);

    private async Task AcceptAsync(string offerSdp)
    {
        try
        {
            var result = _pc.setRemoteDescription(new RTCSessionDescriptionInit { type = RTCSdpType.offer, sdp = GlassesCamSdp.ForReceiving(offerSdp) });
            if (result != SetDescriptionResultEnum.OK)
            {
                _log($"glasses camera: offer from {Viewer} refused: {result}");
                _state(GlassesCamPeerState.Failed);
                return;
            }
            var answer = _pc.createAnswer();
            await _pc.setLocalDescription(answer);
            if (!_closed) _send(new JsonObject { ["type"] = "answer", ["sdp"] = answer.sdp });
        }
        catch (Exception e)
        {
            _log($"glasses camera: couldn't answer {Viewer}: {e.GetType().Name}: {e.Message}");
            _state(GlassesCamPeerState.Failed);
        }
    }

    public void AddCandidate(ShareInbound.Candidate c)
    {
        if (_closed) return;
        var cand = c.Cand.StartsWith("candidate:", StringComparison.Ordinal) ? c.Cand["candidate:".Length..] : c.Cand;
        try { _pc.addIceCandidate(new RTCIceCandidateInit { candidate = cand, sdpMid = c.Mid, sdpMLineIndex = (ushort)Math.Max(0, c.MLine) }); }
        catch (Exception e) when (e is ArgumentException or FormatException or InvalidOperationException) { _log($"glasses camera: bad candidate: {e.Message}"); }
    }

    /// SIPSorcery's receive thread: every frame is decoded in order (VP8's frames build on each
    /// other), then drawn and written. A broken frame asks the phone for a fresh keyframe.
    private void OnVideoFrame(IPEndPoint from, uint timestamp, byte[] frame, VideoFormat format)
    {
        if (_closed || format.Codec != VideoCodecsEnum.VP8) return;
        if (!_decoder.Decode(frame, _onPicture)) RequestKeyFrame();
    }

    private void Write(ReadOnlySpan<byte> y, int yStride, ReadOnlySpan<byte> u, int uStride, ReadOnlySpan<byte> v, int vStride, int width, int height)
    {
        if (_closed) return;
        GlassesCamPixels.I420ToBgraFit(y, yStride, u, uStride, v, vStride, width, height, _bgra, W, H, W * 4);
        if (_frames() is not { } file) return;
        file.WriteFrame(_bgra, W, H, W * 4, DateTime.UtcNow);
        if (Interlocked.Increment(ref _pictures) == 1) _log($"glasses camera: first frame from {Viewer} ({width}x{height})");
        _frame();
    }

    /// At most one every 500 ms (one loss can break several frames in a row).
    private void RequestKeyFrame()
    {
        var now = Environment.TickCount64;
        if (now - Interlocked.Read(ref _lastKeyRequest) < 500 || _remoteSsrc == 0) return;
        Interlocked.Exchange(ref _lastKeyRequest, now);
        try { _pc.SendRtcpFeedback(SDPMediaTypesEnum.video, new RTCPFeedback(_pc.VideoLocalTrack?.Ssrc ?? 0, _remoteSsrc, PSFBFeedbackTypesEnum.PLI)); }
        catch (Exception e) when (e is InvalidOperationException or ObjectDisposedException or System.Net.Sockets.SocketException) { }
    }

    public void Close()
    {
        if (_closed) return;
        _closed = true;
        try { _pc.close(); } catch (Exception e) when (e is InvalidOperationException or ObjectDisposedException) { }
        _decoder.Dispose();
    }
}

/// Makes the phone's peers for GlassesCameraService.
public sealed class GlassesCamPeers : IGlassesCamPeerFactory
{
    private readonly Func<GlassesCamFrameFile?> _frames;
    private readonly Action<string> _log;

    public GlassesCamPeers(Func<GlassesCamFrameFile?> frames, Action<string> log)
    {
        _frames = frames;
        _log = log;
    }

    public IGlassesCamPeer Create(string viewer, IReadOnlyList<ShareSignal.IceServer> ice, Action<JsonObject> send,
        Action<GlassesCamPeerState> state, Action frame) =>
        new GlassesCamPeer(viewer, ice, send, state, frame, _frames, _log);
}

/// The camera on this PC, for GlassesCameraService: installed (source registered, frame file made)
/// and how many apps use it (the frame file's count, while the source's heartbeat is fresh). Opens
/// the frame file once installed and keeps it; if it can't, Settings says so.
public sealed class GlassesCamHost : IGlassesCamHost, IDisposable
{
    private static readonly TimeSpan RetryOpen = TimeSpan.FromSeconds(10);

    private readonly object _lock = new();
    private GlassesCamFrameFile? _file;
    private string? _failure;
    private long _nextOpen;

    public bool Installed()
    {
        var installed = GlassesCamInstaller.Installed();
        if (!installed)
        {
            lock (_lock)
            {
                _file?.Dispose();
                _file = null;
                _failure = null;
                _nextOpen = 0;
            }
        }
        return installed;
    }

    /// Never null while the file can't be written: then nobody asks the phone for video it can't show.
    public int? Clients() => File()?.ClientsAt(DateTime.UtcNow) ?? 0;

    public string? Failure()
    {
        lock (_lock) return _failure;
    }

    public GlassesCamFrameFile? File()
    {
        lock (_lock)
        {
            if (_file != null) return _file;
            var now = Environment.TickCount64;
            if (now < _nextOpen) return null;
            _nextOpen = now + (long)RetryOpen.TotalMilliseconds;
            try
            {
                _file = GlassesCamFrameFile.Open(GlassesCamSpec.FrameFilePath, create: false);
                _failure = null;
            }
            catch (UnauthorizedAccessException)
            {
                _failure = "Jarvis isn't allowed to write the camera's video. Reinstall the camera.";
            }
            catch (InvalidDataException e)
            {
                _failure = e.Message;
            }
            catch (IOException)
            {
                _failure = "Jarvis can't open the camera's video file. Reinstall the camera.";
            }
            return _file;
        }
    }

    public void Dispose()
    {
        lock (_lock)
        {
            _file?.Dispose();
            _file = null;
        }
    }
}
