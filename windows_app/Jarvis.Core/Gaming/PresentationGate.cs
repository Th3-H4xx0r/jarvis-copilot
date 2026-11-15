using Jarvis.Core.Model;

namespace Jarvis.Core.Gaming;

/// Everything that draws (cards, arrivals, toasts) goes through here. Nothing shows while game
/// mode is on or, before jc-client's 2 s broadcast lands, while a fullscreen window is in front.
/// Held items flush in order (same key: latest wins, first position kept). The 2 s recheck timer
/// exists only while something is queued and game mode is off: no idle polling.
public sealed class PresentationGate
{
    private static readonly TimeSpan Recheck = TimeSpan.FromSeconds(2);

    private readonly IForegroundProbe _probe;
    private readonly TimeProvider _time;
    private readonly List<(string Key, Action Show)> _queue = new();
    private GameMode _mode = GameMode.Off;
    private ITimer? _timer;

    public PresentationGate(IForegroundProbe probe, TimeProvider? time = null)
    {
        _probe = probe;
        _time = time ?? TimeProvider.System;
    }

    public bool CanPresent => !_mode.On && !_probe.ForegroundIsFullscreen();
    public int QueuedCount => _queue.Count;
    public event Action? Flushed;

    public void SetGameMode(GameMode m)
    {
        _mode = m;
        if (m.On) { StopTimer(); return; }
        if (_queue.Count == 0) return;
        if (CanPresent) Flush(); else EnsureTimer();
    }

    public void Present(string key, Action show)
    {
        if (_queue.Count == 0 && CanPresent)
        {
            show();
            return;
        }
        var i = _queue.FindIndex(q => q.Key == key);
        if (i >= 0) _queue[i] = (key, show); else _queue.Add((key, show));
        if (!_mode.On && CanPresent) Flush();
        else if (!_mode.On) EnsureTimer();
    }

    private void EnsureTimer() =>
        _timer ??= _time.CreateTimer(_ => Tick(), null, Recheck, Recheck);

    private void StopTimer()
    {
        _timer?.Dispose();
        _timer = null;
    }

    private void Tick()
    {
        if (_mode.On || _queue.Count == 0) { StopTimer(); return; }
        if (CanPresent) Flush();
    }

    private void Flush()
    {
        StopTimer();
        var items = _queue.ToList();
        _queue.Clear();
        foreach (var (_, show) in items) show();
        Flushed?.Invoke();
    }
}
