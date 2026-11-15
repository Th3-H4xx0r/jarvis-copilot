using System.Net.Http;
using System.Net.Http.Json;
using Jarvis.Core.Model;
using Jarvis.Sounds;

namespace Jarvis.Voice;

/// Reads a harness job's result aloud: POST /api/voice/synthesize (text → MP3) through the
/// loopback origin, then plays it once. Nothing stays open.
public sealed class SpeakBack
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(30) };
    private readonly Func<string?> _origin;
    private readonly SoundPlayer _player = new();

    public SpeakBack(Func<string?> origin) => _origin = origin;

    public async Task SpeakAsync(HarnessJob job)
    {
        if (_origin() is not { } origin || job.Result.Length == 0) return;
        try
        {
            using var r = await Http.PostAsJsonAsync(origin.TrimEnd('/') + "/api/voice/synthesize", new { text = job.Result });
            if (!r.IsSuccessStatusCode) return;
            var path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"jarvis-speak-{job.Id}.mp3");
            await System.IO.File.WriteAllBytesAsync(path, await r.Content.ReadAsByteArrayAsync());
            _player.Play(path, 1.0);
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or System.IO.IOException) { }
    }
}
