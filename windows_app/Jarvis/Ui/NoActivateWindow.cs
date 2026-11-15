using System.Windows;
using System.Windows.Interop;
using Jarvis.Platform;

namespace Jarvis.Ui;

/// A topmost tool window that never takes focus unless clicked into a text field: the island,
/// cards and pills. Typing (the chat composer) switches activation on, then off again.
public abstract class NoActivateWindow : Window
{
    private const int NoActivateStyles = Native.WS_EX_NOACTIVATE | Native.WS_EX_TOOLWINDOW | Native.WS_EX_TOPMOST;
    private IntPtr _hwnd;

    protected NoActivateWindow()
    {
        ShowActivated = false;
        ShowInTaskbar = false;
        Topmost = true;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        SourceInitialized += OnSourceInitialized;
    }

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        _hwnd = new WindowInteropHelper(this).Handle;
        SetExStyle(add: NoActivateStyles, remove: 0);
        HwndSource.FromHwnd(_hwnd)?.AddHook(WndProc);
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == Native.WM_MOUSEACTIVATE && !_typing)
        {
            handled = true;
            return new IntPtr(Native.MA_NOACTIVATE);
        }
        return IntPtr.Zero;
    }

    private bool _typing;

    public void BeginTyping()
    {
        _typing = true;
        SetExStyle(add: 0, remove: Native.WS_EX_NOACTIVATE);
        Activate();
    }

    public void EndTyping()
    {
        _typing = false;
        SetExStyle(add: Native.WS_EX_NOACTIVATE, remove: 0);
    }

    private void SetExStyle(int add, int remove)
    {
        if (_hwnd == IntPtr.Zero) return;
        var cur = Native.GetWindowLongPtr(_hwnd, Native.GWL_EXSTYLE).ToInt64();
        var next = (cur | (uint)add) & ~(long)(uint)remove;
        Native.SetWindowLongPtr(_hwnd, Native.GWL_EXSTYLE, new IntPtr(next));
    }
}
