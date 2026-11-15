namespace Jarvis.Platform;

/// One Jarvis per user session. A second launch pokes the first (which opens the island) and exits.
public sealed class SingleInstance : IDisposable
{
    private const string MutexName = @"Local\JarvisForWindows";
    private const string ShowEventName = @"Local\JarvisForWindows.Show";

    private readonly Mutex _mutex;
    private readonly EventWaitHandle _show;
    private RegisteredWaitHandle? _wait;

    public bool IsFirst { get; }

    public SingleInstance()
    {
        _mutex = new Mutex(true, MutexName, out var created);
        IsFirst = created;
        _show = new EventWaitHandle(false, EventResetMode.AutoReset, ShowEventName);
    }

    /// The second instance: ask the first to show the island.
    public void SignalFirst() => _show.Set();

    /// The first instance: run `onShow` (on a pool thread) whenever a later launch signals.
    public void ListenForShow(Action onShow) =>
        _wait = ThreadPool.RegisterWaitForSingleObject(_show, (_, _) => onShow(), null, Timeout.Infinite, executeOnlyOnce: false);

    public void Dispose()
    {
        _wait?.Unregister(null);
        _show.Dispose();
        if (IsFirst) { try { _mutex.ReleaseMutex(); } catch (ApplicationException) { } }
        _mutex.Dispose();
    }
}
