using System.Diagnostics;
using Jarvis.Core.Startup;

namespace Jarvis.Platform;

/// One Jarvis per user session. A second launch pokes the first (which opens the island, then says so) and
/// exits — unless the first doesn't answer: a stuck one (its UI thread gone) is ended and replaced.
public sealed class SingleInstance : IDisposable
{
    private const string MutexName = @"Local\JarvisForWindows";
    private const string ShowEventName = @"Local\JarvisForWindows.Show";
    private const string ShownEventName = @"Local\JarvisForWindows.Shown";

    private readonly Mutex _mutex;
    private readonly EventWaitHandle _show;
    private readonly EventWaitHandle _shown;
    private RegisteredWaitHandle? _wait;

    public bool IsFirst { get; private set; }

    public SingleInstance()
    {
        _mutex = new Mutex(true, MutexName, out var created);
        IsFirst = created;
        _show = new EventWaitHandle(false, EventResetMode.AutoReset, ShowEventName);
        _shown = new EventWaitHandle(false, EventResetMode.AutoReset, ShownEventName);
    }

    /// The second instance: ask the first to show the island; true when it said it did within `wait`.
    public bool SignalFirstAndWait(TimeSpan wait)
    {
        _shown.Reset();
        _show.Set();
        return _shown.WaitOne(wait);
    }

    /// The first instance, once the island is up: the launch that asked can go.
    public void Acknowledge() => _shown.Set();

    /// The first didn't answer: end it (when it's not just starting up) and take the lock.
    public bool TakeOverFromStuck(Action<string> log)
    {
        var self = Process.GetCurrentProcess();
        var exe = Environment.ProcessPath;
        var others = new List<(int, DateTime)>();
        foreach (var p in Process.GetProcessesByName("Jarvis"))
        {
            using (p)
            {
                try
                {
                    if (p.Id == self.Id || p.SessionId != self.SessionId) continue;
                    if (!string.Equals(p.MainModule?.FileName, exe, StringComparison.OrdinalIgnoreCase)) continue;
                    others.Add((p.Id, p.StartTime.ToUniversalTime()));
                }
                catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception) { }
            }
        }
        var ended = StuckInstance.TakeOver(false, others, DateTime.UtcNow,
            pid => { using var p = Process.GetProcessById(pid); p.Kill(entireProcessTree: true); },
            pid =>
            {
                try { using var p = Process.GetProcessById(pid); return p.WaitForExit(10000); }
                catch (ArgumentException) { return true; }
            }, log);
        if (!ended) return false;
        try { IsFirst = _mutex.WaitOne(TimeSpan.FromSeconds(5)); }
        catch (AbandonedMutexException) { IsFirst = true; }   // the stuck one died holding it: ours now
        return IsFirst;
    }

    /// The first instance: run `onShow` (on a pool thread) whenever a later launch signals.
    public void ListenForShow(Action onShow) =>
        _wait = ThreadPool.RegisterWaitForSingleObject(_show, (_, _) => onShow(), null, Timeout.Infinite, executeOnlyOnce: false);

    public void Dispose()
    {
        _wait?.Unregister(null);
        _show.Dispose();
        _shown.Dispose();
        if (IsFirst) { try { _mutex.ReleaseMutex(); } catch (ApplicationException) { } }
        _mutex.Dispose();
    }
}
