using System.Runtime.InteropServices;

namespace Jarvis.Stats;

/// What the app can read itself when the sensor helper isn't there (not installed, or the
/// driver switched off): total CPU load (GetSystemTimes) and RAM (GlobalMemoryStatusEx). Every
/// other reading shows as unavailable.
internal static partial class PdhFallback
{
    private static ulong _idle, _kernel, _user;

    public static Dictionary<string, double> Read()
    {
        var r = new Dictionary<string, double>();
        if (GetSystemTimes(out var idle, out var kernel, out var user))
        {
            ulong di = idle - _idle, dk = kernel - _kernel, du = user - _user;
            if (_kernel != 0 && dk + du > 0) r["cpu.load"] = Math.Round(100.0 * (dk + du - di) / (dk + du), 1);
            (_idle, _kernel, _user) = (idle, kernel, user);
        }
        var m = new MEMORYSTATUSEX { dwLength = (uint)Marshal.SizeOf<MEMORYSTATUSEX>() };
        if (GlobalMemoryStatusEx(ref m))
        {
            const double Gb = 1024.0 * 1024 * 1024;
            r["ram.total"] = Math.Round(m.ullTotalPhys / Gb, 1);
            r["ram.used"] = Math.Round((m.ullTotalPhys - m.ullAvailPhys) / Gb, 2);
            r["ram.commit"] = Math.Round((m.ullTotalPageFile - m.ullAvailPageFile) / Gb, 2);
        }
        return r;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MEMORYSTATUSEX
    {
        public uint dwLength, dwMemoryLoad;
        public ulong ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile, ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual;
    }

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetSystemTimes(out ulong idle, out ulong kernel, out ulong user);

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX m);
}
