using System.Windows.Interop;

namespace Jarvis.Platform;

/// A window that only receives messages: hotkeys (WM_HOTKEY), Raw Input (WM_INPUT) and power
/// broadcasts. Message-only windows (HWND_MESSAGE) don't get broadcasts, so the power watcher
/// asks for a hidden top-level one instead. Never visible, never activated.
public sealed class MessageWindow : IDisposable
{
    private readonly HwndSource _source;
    private readonly List<Func<int, IntPtr, IntPtr, IntPtr?>> _handlers = new();

    public MessageWindow(string name, bool topLevel = false)
    {
        var p = new HwndSourceParameters(name)
        {
            Width = 0,
            Height = 0,
            WindowStyle = topLevel ? unchecked((int)0x80000000) /* WS_POPUP */ : 0,
            ExtendedWindowStyle = Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE,
        };
        if (!topLevel) p.ParentWindow = new IntPtr(-3);   // HWND_MESSAGE
        _source = new HwndSource(p);
        _source.AddHook(Hook);
    }

    public IntPtr Handle => _source.Handle;

    /// A handler returns a result to mark the message handled, or null to pass it on.
    public void Add(Func<int, IntPtr, IntPtr, IntPtr?> handler) => _handlers.Add(handler);

    private IntPtr Hook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        foreach (var h in _handlers)
        {
            if (h(msg, wParam, lParam) is { } result)
            {
                handled = true;
                return result;
            }
        }
        return IntPtr.Zero;
    }

    public void Dispose() => _source.Dispose();
}
