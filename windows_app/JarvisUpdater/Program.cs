using System.Diagnostics;
using Jarvis.Core.Update;

namespace JarvisUpdater;

/// `JarvisUpdater.exe --pid <n> --app <dir> --new <dir> --exe Jarvis.exe --log <file>`:
/// swaps %LOCALAPPDATA%\Programs\Jarvis\app for the staged build after Jarvis exits (C5).
internal static class Program
{
    private static int Main(string[] args)
    {
        var a = ParseArgs(args);
        if (a == null)
        {
            Console.Error.WriteLine("usage: JarvisUpdater --pid <n> --app <dir> --new <dir> --exe Jarvis.exe --log <file>");
            return 2;
        }
        var logPath = a.Value.Log;
        void Log(string line)
        {
            var text = $"{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss} {line}{Environment.NewLine}";
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(logPath)!);
                File.AppendAllText(logPath, text);
            }
            catch (IOException) { }
        }
        try
        {
            return new Swapper(new RealSwapFs(), new RealProcessOps(), Log).Run(a.Value.Pid, a.Value.App, a.Value.New, a.Value.Exe);
        }
        catch (Exception e)
        {
            Log($"updater crashed: {e}");
            return 1;
        }
    }

    internal static (int Pid, string App, string New, string Exe, string Log)? ParseArgs(string[] args)
    {
        var map = new Dictionary<string, string>();
        for (var i = 0; i + 1 < args.Length; i += 2) map[args[i]] = args[i + 1];
        if (!map.TryGetValue("--pid", out var pidS) || !int.TryParse(pidS, out var pid)) return null;
        if (!map.TryGetValue("--app", out var app) || !map.TryGetValue("--new", out var staged)) return null;
        var exe = map.GetValueOrDefault("--exe", "Jarvis.exe");
        if (exe.Contains('\\') || exe.Contains('/')) return null;
        var log = map.GetValueOrDefault("--log",
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Jarvis", "logs", "update.log"));
        return (pid, app, staged, exe, log);
    }
}

internal sealed class RealSwapFs : ISwapFs
{
    public void Move(string from, string to) => Directory.Move(from, to);
    public void DeleteTree(string path) { if (Directory.Exists(path)) Directory.Delete(path, recursive: true); }
    public bool Exists(string path) => Directory.Exists(path);
}

internal sealed class RealProcessOps : IProcessOps
{
    public bool WaitExit(int pid, TimeSpan timeout)
    {
        try
        {
            using var p = Process.GetProcessById(pid);
            return p.WaitForExit((int)timeout.TotalMilliseconds);
        }
        catch (ArgumentException) { return true; }   // already gone
    }

    public void Kill(int pid)
    {
        try
        {
            using var p = Process.GetProcessById(pid);
            p.Kill(entireProcessTree: true);
            p.WaitForExit(5000);
        }
        catch (ArgumentException) { }   // already gone
        catch (Exception) { Taskkill($"/F /T /PID {pid}"); }   // never a silent no-op (live 2026-11-18)
    }

    private static void Taskkill(string args)
    {
        try
        {
            using var t = Process.Start(new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "taskkill.exe"), args)
                { UseShellExecute = false, CreateNoWindow = true });
            t?.WaitForExit(10000);
        }
        catch (Exception) { }
    }

    public int Start(string exe)
    {
        var psi = new ProcessStartInfo(exe) { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(exe)! };
        using var p = Process.Start(psi) ?? throw new InvalidOperationException($"couldn't start {exe}");
        return p.Id;
    }

    public bool AliveAfter(int pid, TimeSpan wait)
    {
        Thread.Sleep(wait);
        try
        {
            using var p = Process.GetProcessById(pid);
            return !p.HasExited;
        }
        catch (ArgumentException) { return false; }
    }

    public void KillByPath(string exe)
    {
        var name = Path.GetFileNameWithoutExtension(exe);
        foreach (var p in Process.GetProcessesByName(name))
        {
            using (p)
            {
                try
                {
                    if (string.Equals(p.MainModule?.FileName, exe, StringComparison.OrdinalIgnoreCase))
                    {
                        p.Kill(entireProcessTree: true);
                        p.WaitForExit(5000);
                    }
                }
                catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception)
                {
                    try { Taskkill($"/F /T /PID {p.Id}"); } catch (InvalidOperationException) { }
                }
            }
        }
    }
}
