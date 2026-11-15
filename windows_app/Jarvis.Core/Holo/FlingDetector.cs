using Jarvis.Core.Model;
using Jarvis.Core.Ui;

namespace Jarvis.Core.Holo;

/// Mouse fling (Ctrl+Alt + left-drag): a long, fast drag gives the throw's angle.
public sealed class FlingDetector
{
    public const double MinPixels = 150;
    /// px/s, over the last `Window` of the drag (a slow start with a fast finish still counts).
    public const double MinSpeed = 1500;
    public const double Window = 0.1;

    private readonly List<(double T, PointD P)> _samples = new();

    public void Down(double t, PointD p)
    {
        _samples.Clear();
        _samples.Add((t, p));
    }

    public void Move(double t, PointD p)
    {
        if (_samples.Count == 0) return;
        _samples.Add((t, p));
        // Keep the start and the recent past only.
        while (_samples.Count > 2 && _samples[1].T < t - Window * 2) _samples.RemoveAt(1);
    }

    /// The angle in degrees (0 = right, 90 = up), or null when it wasn't a fling.
    public double? Up(double t, PointD p)
    {
        if (_samples.Count == 0) return null;
        var start = _samples[0].P;
        var dx = p.X - start.X;
        var dy = p.Y - start.Y;
        var from = _samples.Where(s => s.T >= t - Window - 1e-9).Select(s => ((double, PointD)?)s).FirstOrDefault()
                   ?? _samples[^1];
        _samples.Clear();
        if (Math.Sqrt(dx * dx + dy * dy) < MinPixels) return null;
        var dt = Math.Max(t - from.Item1, 1e-3);
        var speed = Math.Sqrt(Math.Pow(p.X - from.Item2.X, 2) + Math.Pow(p.Y - from.Item2.Y, 2)) / dt;
        if (speed < MinSpeed) return null;
        return HoloOrbitLayout.Normalise(Math.Atan2(-dy, dx) * 180 / Math.PI);
    }
}

/// When the Raw Input mouse watcher exists: only while Ctrl+Alt are held, only with
/// `holo.fling` on, and never while game mode is on.
public static class FlingWatchRule
{
    public static bool ShouldRegister(bool flingOn, bool ctrlAltDown, GameMode m) => flingOn && ctrlAltDown && !m.On;
}
