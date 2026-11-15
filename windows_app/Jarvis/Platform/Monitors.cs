using System.Runtime.InteropServices;
using Jarvis.Core.Gaming;
using Jarvis.Core.Ui;

namespace Jarvis.Platform;

/// The monitors in physical pixels (the app is PerMonitorV2), their device names
/// (\\.\DISPLAYn) and DPI scale, plus the cursor. Read on demand only, never polled.
public static class Monitors
{
    public sealed record Info(IntPtr Handle, string Name, RectI Bounds, RectI Work, bool Primary);

    [ThreadStatic] private static List<Info>? _collect;

    public static unsafe IReadOnlyList<Info> All()
    {
        _collect = new List<Info>();
        Native.EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, &Collect, IntPtr.Zero);
        var list = _collect;
        _collect = null;
        return list;
    }

    [UnmanagedCallersOnly]
    private static unsafe int Collect(IntPtr monitor, IntPtr hdc, Native.RECT* rect, IntPtr data)
    {
        var info = new Native.MONITORINFOEX { cbSize = Marshal.SizeOf<Native.MONITORINFOEX>() };
        if (Native.GetMonitorInfoEx(monitor, ref info))
        {
            var name = new string(info.szDevice);
            var nul = name.IndexOf('\0');
            if (nul >= 0) name = name[..nul];
            _collect?.Add(new Info(monitor, name,
                new RectI(info.rcMonitor.Left, info.rcMonitor.Top, info.rcMonitor.Right, info.rcMonitor.Bottom),
                new RectI(info.rcWork.Left, info.rcWork.Top, info.rcWork.Right, info.rcWork.Bottom),
                (info.dwFlags & Native.MONITORINFOF_PRIMARY) != 0));
        }
        return 1;
    }

    public static PointD Cursor() => Native.GetCursorPos(out var p) ? new PointD(p.X, p.Y) : new PointD(0, 0);

    public static Info? At(PointD p) => All().FirstOrDefault(m =>
        p.X >= m.Bounds.Left && p.X < m.Bounds.Right && p.Y >= m.Bounds.Top && p.Y < m.Bounds.Bottom);

    public static Info? Primary() => All().FirstOrDefault(m => m.Primary);

    /// DIP → pixel factor for a monitor (1.0 = 96 dpi).
    public static double Scale(IntPtr monitor) =>
        Native.GetDpiForMonitor(monitor, 0, out var dx, out _) == 0 && dx > 0 ? dx / 96.0 : 1.0;

    public static IReadOnlyList<(string Name, RectI Bounds, bool Primary)> ForPlacement() =>
        All().Select(m => (m.Name, m.Bounds, m.Primary)).ToList();

    /// Put a window at a pixel rectangle without activating it or changing z-order rules.
    public static void Place(IntPtr hwnd, RectI px) =>
        Native.SetWindowPos(hwnd, Native.HWND_TOPMOST, px.Left, px.Top, px.Width, px.Height, Native.SWP_NOACTIVATE);
}
