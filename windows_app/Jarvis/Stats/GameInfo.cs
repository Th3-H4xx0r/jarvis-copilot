using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Jarvis.Stats;

/// A game's friendly name ("Call of Duty") and its Windows icon, read once from the running exe.
/// Only the process's image path is queried (PROCESS_QUERY_LIMITED_INFORMATION, the access Task Manager
/// uses) — never its memory — so anti-cheat has nothing to object to.
public sealed record GameInfo(string Exe, string Name, ImageSource? Icon, byte[]? IconPng)
{
    private static readonly ConcurrentDictionary<string, GameInfo> Cache = new(StringComparer.OrdinalIgnoreCase);

    /// What's known so far ("cod.exe" → name/icon), or null before the first read.
    public static GameInfo? Cached(string? exe) => exe != null && Cache.TryGetValue(exe, out var g) ? g : null;

    /// "Call of Duty", else "cod" (the exe without .exe).
    public static string NameOf(string? exe) => Cached(exe)?.Name ?? System.IO.Path.GetFileNameWithoutExtension(exe ?? "");

    /// Reads (once per exe per run) the name and a 128 px icon from the running game.
    public static GameInfo? Read(string exe)
    {
        if (Cache.TryGetValue(exe, out var known)) return known;
        var path = ImagePath(exe);
        var name = path != null ? FriendlyName(path) : null;
        var png = path != null ? IconPngOf(path, 128) : null;
        ImageSource? icon = null;
        if (png != null)
        {
            var bmp = new BitmapImage();
            bmp.BeginInit();
            bmp.CacheOption = BitmapCacheOption.OnLoad;
            bmp.StreamSource = new System.IO.MemoryStream(png);
            bmp.EndInit();
            bmp.Freeze();
            icon = bmp;
        }
        var info = new GameInfo(exe, name ?? System.IO.Path.GetFileNameWithoutExtension(exe), icon, png);
        Cache[exe] = info;
        return info;
    }

    private static string? ImagePath(string exe)
    {
        foreach (var p in Process.GetProcessesByName(System.IO.Path.GetFileNameWithoutExtension(exe)))
        {
            using (p)
            {
                var h = OpenProcess(0x1000, false, p.Id);   // PROCESS_QUERY_LIMITED_INFORMATION
                if (h == IntPtr.Zero) continue;
                try
                {
                    var sb = new StringBuilder(1024);
                    var len = sb.Capacity;
                    if (QueryFullProcessImageNameW(h, 0, sb, ref len)) return sb.ToString(0, len);
                }
                finally { CloseHandle(h); }
            }
        }
        return null;
    }

    /// The exe's own description ("Call of Duty®" → "Call of Duty"), or its product name.
    private static string? FriendlyName(string path)
    {
        try
        {
            var v = FileVersionInfo.GetVersionInfo(path);
            foreach (var s in new[] { v.FileDescription, v.ProductName })
            {
                var clean = (s ?? "").Replace("®", "").Replace("™", "").Replace("©", "").Trim();
                if (clean.Length is > 1 and <= 80 && !clean.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) return clean;
            }
        }
        catch (System.IO.FileNotFoundException) { }
        return null;
    }

    private static byte[]? IconPngOf(string path, int size)
    {
        if (SHDefExtractIconW(path, 0, 0, out var large, out var small, (uint)(size | (16 << 16))) != 0 || large == IntPtr.Zero) return null;
        try
        {
            var src = Imaging.CreateBitmapSourceFromHIcon(large, Int32Rect.Empty, BitmapSizeOptions.FromWidthAndHeight(size, size));
            var enc = new PngBitmapEncoder();
            enc.Frames.Add(BitmapFrame.Create(src));
            using var ms = new System.IO.MemoryStream();
            enc.Save(ms);
            return ms.ToArray();
        }
        finally
        {
            DestroyIcon(large);
            if (small != IntPtr.Zero) DestroyIcon(small);
        }
    }

    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool QueryFullProcessImageNameW(IntPtr h, int flags, StringBuilder name, ref int size);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SHDefExtractIconW(string file, int index, uint flags, out IntPtr large, out IntPtr small, uint size);
    [DllImport("user32.dll")] private static extern bool DestroyIcon(IntPtr h);
}
