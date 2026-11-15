using Jarvis.Core.Music;
using Windows.Media.Control;

namespace Jarvis.Music;

/// What's playing, through Windows' media sessions (Spotify, browsers, any media app):
/// event-driven, no polling. Play/pause, next and previous act on the current session.
public sealed class MediaSessions
{
    private GlobalSystemMediaTransportControlsSessionManager? _manager;
    private GlobalSystemMediaTransportControlsSession? _session;

    public NowPlaying? Now { get; private set; }
    public byte[]? Artwork { get; private set; }
    public event Action? Changed;

    public async Task StartAsync()
    {
        try
        {
            _manager = await GlobalSystemMediaTransportControlsSessionManager.RequestAsync();
            _manager.CurrentSessionChanged += (_, _) => _ = AttachAsync();
            await AttachAsync();
        }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or UnauthorizedAccessException) { }
    }

    private async Task AttachAsync()
    {
        if (_session != null)
        {
            _session.MediaPropertiesChanged -= OnProps;
            _session.PlaybackInfoChanged -= OnPlayback;
            _session.TimelinePropertiesChanged -= OnPlayback;
        }
        _session = _manager?.GetCurrentSession();
        if (_session != null)
        {
            _session.MediaPropertiesChanged += OnProps;
            _session.PlaybackInfoChanged += OnPlayback;
            _session.TimelinePropertiesChanged += OnPlayback;
        }
        await RefreshAsync();
    }

    private void OnProps(GlobalSystemMediaTransportControlsSession s, MediaPropertiesChangedEventArgs e) => _ = RefreshAsync();
    private void OnPlayback(GlobalSystemMediaTransportControlsSession s, object e) => _ = RefreshAsync();

    private async Task RefreshAsync()
    {
        var s = _session;
        if (s == null) { Now = null; Artwork = null; Changed?.Invoke(); return; }
        try
        {
            var props = await s.TryGetMediaPropertiesAsync();
            var timeline = s.GetTimelineProperties();
            var playback = s.GetPlaybackInfo();
            var app = s.SourceAppUserModelId.Split('!')[0].Split('\\').Last().Replace(".exe", "", StringComparison.OrdinalIgnoreCase);
            Now = new NowPlaying(app, props.Title, props.Artist, props.AlbumTitle, timeline.EndTime.TotalSeconds, timeline.Position.TotalSeconds,
                timeline.LastUpdatedTime, playback.PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing);
            Artwork = await ReadThumbAsync(props);
        }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or InvalidOperationException) { }
        Changed?.Invoke();
    }

    private static async Task<byte[]?> ReadThumbAsync(GlobalSystemMediaTransportControlsSessionMediaProperties props)
    {
        if (props.Thumbnail == null) return null;
        using var stream = await props.Thumbnail.OpenReadAsync();
        using var net = System.IO.WindowsRuntimeStreamExtensions.AsStreamForRead(stream);
        using var ms = new System.IO.MemoryStream();
        await net.CopyToAsync(ms);
        return ms.ToArray();
    }

    public async Task PlayPauseAsync() { if (_session != null) await _session.TryTogglePlayPauseAsync(); }
    public async Task NextAsync() { if (_session != null) await _session.TrySkipNextAsync(); }
    public async Task PreviousAsync() { if (_session != null) await _session.TrySkipPreviousAsync(); }

    /// The Command Center's media keys ("play", "pause", "playpause", "next", "previous").
    public Task MediaKeyAsync(string key) => key switch
    {
        "next" => NextAsync(),
        "previous" or "prev" => PreviousAsync(),
        _ => PlayPauseAsync(),
    };
}
