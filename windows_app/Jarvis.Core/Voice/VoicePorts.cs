using Jarvis.Core.Http;
using Jarvis.Core.Link;

namespace Jarvis.Core.Voice;

/// The default speaker and mic, and when either changes (headset plugged in mid-game).
public interface IAudioEndpoints
{
    (string RenderId, string CaptureId) Defaults();
    event Action? DefaultsChanged;
}

/// Echo-cancelled mic capture (the Windows Voice Capture DSP): 10 ms frames of 16 kHz mono PCM16.
public interface IAecCapture
{
    void Start(string renderId, string captureId);
    void Stop();
    event Action<ReadOnlyMemory<short>>? Frame;
}

/// The reply's speaker: queued PCM or MP3 clips, a played-samples clock for karaoke, and a duck.
public interface IReplyPlayer
{
    void Start(string renderId);
    void Enqueue(string format, int rate, ReadOnlyMemory<byte> data);
    /// The server finished this clip's audio.
    void EndSegment();
    /// Drop everything queued (an interrupt); the device stays open.
    void Flush();
    void Stop();
    /// Milliseconds of reply audio actually played (samples consumed by the device).
    long PlayedMs { get; }
    /// Milliseconds of reply audio received and decoded so far.
    long QueuedMs { get; }
    void SetVolume(float v);
    /// Audio is still queued or playing.
    bool Draining { get; }
    /// The queue ran dry after playing something.
    event Action? Drained;
}

/// The realtime voice socket (`/api/voice/s2s/ws`).
public interface IVoiceSocket
{
    Task ConnectAsync(Uri url, CancellationToken ct);
    Task SendTextAsync(string text);
    Task SendBinaryAsync(ReadOnlyMemory<byte> data);
    Task CloseAsync();
    event Action<string>? Text;
    event Action<byte[]>? Binary;
    /// The socket closed (null = closed by us).
    event Action<string?>? Closed;
}

/// An on-device recogniser for the words check during a reply (System.Speech). Optional: without
/// one the check is energy-only, as on the phone.
public interface IWordsRecognizer
{
    void Begin();
    void Feed(ReadOnlyMemory<short> pcm);
    /// The latest hypothesis since Begin, or null when nothing new.
    string? TakeLatest();
    void End();
}

/// Capture and playback follow the Windows defaults while a conversation runs: a change restarts
/// both on the new devices, so a headset plugged in mid-game takes over the mic and the reply.
public sealed class DeviceRoutes
{
    private readonly IAudioEndpoints _endpoints;
    private readonly IAecCapture _capture;
    private readonly IReplyPlayer _player;
    private (string RenderId, string CaptureId)? _current;

    public DeviceRoutes(IAudioEndpoints endpoints, IAecCapture capture, IReplyPlayer player)
    {
        _endpoints = endpoints;
        _capture = capture;
        _player = player;
        endpoints.DefaultsChanged += OnChanged;
    }

    public bool Active => _current != null;
    public event Action<string>? Log;

    public void Begin()
    {
        if (_current != null) return;
        var d = _endpoints.Defaults();
        _current = d;
        _capture.Start(d.RenderId, d.CaptureId);
        _player.Start(d.RenderId);
    }

    public void End()
    {
        if (_current == null) return;
        _current = null;
        _capture.Stop();
        _player.Stop();
    }

    private void OnChanged()
    {
        if (_current is not { } old) return;
        var d = _endpoints.Defaults();
        if (d == old) return;
        Log?.Invoke($"devices changed {old.RenderId}→{d.RenderId}");
        _current = d;
        _capture.Stop();
        _capture.Start(d.RenderId, d.CaptureId);
        _player.Stop();
        _player.Start(d.RenderId);
    }
}

/// `GET /api/voice/session` (the daily voice session) and the socket URL from `hello.api`.
public sealed class VoiceSessionApi
{
    private readonly ApiClient _api;

    public VoiceSessionApi(ApiClient api) => _api = api;

    public async Task<string?> SessionIdAsync()
    {
        try
        {
            var r = await _api.GetAsync("/api/voice/session", TimeSpan.FromSeconds(10));
            return J.StrOrNull(r["session_id"]) is { Length: > 0 } id ? id : null;
        }
        catch (ApiException)
        {
            return null;
        }
    }

    /// http://host:port → ws://host:port/api/voice/s2s/ws (https → wss).
    public static Uri? SocketUrl(string? origin)
    {
        if (origin == null || !Uri.TryCreate(origin, UriKind.Absolute, out var o)) return null;
        var scheme = o.Scheme == "https" ? "wss" : "ws";
        return new Uri($"{scheme}://{o.Authority}/api/voice/s2s/ws");
    }
}
