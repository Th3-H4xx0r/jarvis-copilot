using System.Runtime.InteropServices;
using Jarvis.Core.Gaming;

namespace Jarvis.Platform;

/// Is the foreground window covering its whole monitor? Uses only the window and monitor
/// rectangles and the shell check: no process reads (C3), no hooks.
public sealed class Win32ForegroundProbe : IForegroundProbe
{
    public bool ForegroundIsFullscreen()
    {
        var hwnd = Native.GetForegroundWindow();
        if (hwnd == IntPtr.Zero) return false;
        if (IsShell(hwnd)) return false;
        if (!TryWindowRect(hwnd, out var w)) return false;
        var mon = Native.MonitorFromWindow(hwnd, Native.MONITOR_DEFAULTTONEAREST);
        var info = new Native.MONITORINFO { cbSize = Marshal.SizeOf<Native.MONITORINFO>() };
        if (mon == IntPtr.Zero || !Native.GetMonitorInfo(mon, ref info)) return false;
        var m = info.rcMonitor;
        return FullscreenRule.Covers(new RectI(w.Left, w.Top, w.Right, w.Bottom), new RectI(m.Left, m.Top, m.Right, m.Bottom), false);
    }

    private static bool TryWindowRect(IntPtr hwnd, out Native.RECT r)
    {
        if (Native.DwmGetWindowAttribute(hwnd, Native.DWMWA_EXTENDED_FRAME_BOUNDS, out r, Marshal.SizeOf<Native.RECT>()) == 0) return true;
        return Native.GetWindowRect(hwnd, out r);
    }

    private static bool IsShell(IntPtr hwnd)
    {
        if (hwnd == Native.GetShellWindow() || hwnd == Native.GetDesktopWindow()) return true;
        var buf = new char[64];
        var n = Native.GetClassName(hwnd, buf, buf.Length);
        var cls = n > 0 ? new string(buf, 0, n) : "";
        return cls is "Progman" or "WorkerW";
    }
}
