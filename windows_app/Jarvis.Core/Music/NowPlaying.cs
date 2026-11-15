namespace Jarvis.Core.Music;

/// What's playing (from Windows' media sessions). Position runs on from `AnchorAt` while playing.
public sealed record NowPlaying(string App, string Title, string Artist, string Album, double Duration, double Position,
    DateTimeOffset AnchorAt, bool IsPlaying)
{
    public double PositionAt(DateTimeOffset now)
    {
        var p = IsPlaying ? Position + (now - AnchorAt).TotalSeconds : Position;
        return Duration > 0 ? Math.Clamp(p, 0, Duration) : Math.Max(0, p);
    }
}
