using System.Runtime.InteropServices;

namespace Jarvis.Platform;

/// Tells the app the moment the foreground window changes, so the island, orb and glow hide as a
/// fullscreen game comes to the front instead of waiting for jc-client's 2 s game-mode check.
/// SetWinEventHook out of context (WINEVENT_OUTOFCONTEXT): Windows posts the event to this
/// thread's message loop; nothing is injected into any other process (unlike SetWindowsHookEx).
public sealed class ForegroundWatcher : IDisposable
{
    private const uint EVENT_SYSTEM_FOREGROUND = 0x0003;
    private const uint WINEVENT_OUTOFCONTEXT = 0x0000, WINEVENT_SKIPOWNPROCESS = 0x0002;

    private delegate void WinEventProc(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);

    [DllImport("user32.dll")]
    private static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr module, WinEventProc proc, uint pid, uint thread, uint flags);

    [DllImport("user32.dll")]
    private static extern bool UnhookWinEvent(IntPtr hook);

    private readonly WinEventProc _proc;   // kept alive for as long as the hook exists
    private readonly IntPtr _hook;

    public ForegroundWatcher()
    {
        _proc = (_, _, _, _, _, _, _) => Changed?.Invoke();
        _hook = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, _proc, 0, 0,
            WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
    }

    /// Raised on the UI thread (the one that created the watcher).
    public event Action? Changed;

    public void Dispose()
    {
        if (_hook != IntPtr.Zero) UnhookWinEvent(_hook);
    }
}
