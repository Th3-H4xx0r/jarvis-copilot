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

    /// "3:07" or "1:02:03" (the Mac's NowPlaying.clock).
    public static string Clock(double seconds)
    {
        var s = Math.Max(0, (int)Math.Floor(seconds));
        int h = s / 3600, m = s % 3600 / 60, sec = s % 60;
        return h > 0 ? $"{h}:{m:00}:{sec:00}" : $"{m}:{sec:00}";
    }

    /// "-1:12": what's left, rounded up; blank without a duration.
    public static string Remaining(double duration, double position) =>
        duration > 0 ? "-" + Clock(Math.Ceiling(duration - position)) : "";
}
