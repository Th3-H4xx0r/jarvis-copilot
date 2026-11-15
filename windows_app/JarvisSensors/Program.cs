using System.ComponentModel;
using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json.Nodes;

namespace JarvisSensors;

/// PC Stats' sensor helper: a Windows service (LocalSystem) so it can read every sensor (through
/// the PawnIO driver) and the system's frame-timing events. It streams one JSON line a second to
/// the Jarvis app over a pipe only his account can open, and does nothing while no one is
/// connected. Installed from Settings with Face ID + UAC.
///
///   JarvisSensors.exe --install <user SID> [--driver]   (elevated: copies itself to Program Files, PawnIO if asked)
///   JarvisSensors.exe --uninstall
///   JarvisSensors.exe --service <user SID>              (what the service manager runs)
///   JarvisSensors.exe --dump                            (one reading to stdout, elevated)
internal static class Program
{
    public const string ServiceName = "JarvisSensors";
    public const string PipeName = "JarvisSensors";

    private static int Main(string[] args)
    {
        var mode = args.Length > 0 ? args[0] : "";
        try
        {
            return mode switch
            {
                "--install" when args.Length > 1 => Installer.Install(args[1], args.Contains("--driver")),
                "--uninstall" => Installer.Uninstall(),
                "--service" when args.Length > 1 => Service.Run(args[1]),
                "--dump" => Dump(),
                _ => Usage(),
            };
        }
        catch (Exception e)
        {
            Log.Write($"{mode} failed: {e}");
            return 1;
        }
    }

    private static int Usage()
    {
        Console.Error.WriteLine("JarvisSensors --install <sid> [--driver] | --uninstall | --service <sid> | --dump");
        return 2;
    }

    private static int Dump()
    {
        using var sensors = new Sensors();
        sensors.Read();
        Thread.Sleep(1000);
        foreach (var (k, v) in sensors.Read().OrderBy(x => x.Key)) Console.WriteLine($"{k} = {v}");
        return 0;
    }

    public static string Line(Dictionary<string, double> r, Dictionary<int, (double Fps, double Low1, double FrameTime)> frames)
    {
        var readings = new JsonObject();
        foreach (var (k, v) in r) readings[k] = v;
        var fps = new JsonObject();
        foreach (var (pid, f) in frames) fps[pid.ToString()] = new JsonObject { ["fps"] = f.Fps, ["low1"] = f.Low1, ["frametime"] = f.FrameTime };
        return new JsonObject { ["t"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0, ["r"] = readings, ["fps"] = fps }.ToJsonString();
    }
}

internal static class Log
{
    public static void Write(string line)
    {
        try
        {
            var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "Jarvis");
            Directory.CreateDirectory(dir);
            var path = Path.Combine(dir, "sensors.log");
            if (File.Exists(path) && new FileInfo(path).Length > 256 * 1024) File.Delete(path);
            File.AppendAllText(path, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {line}{Environment.NewLine}");
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}

/// Register / remove the service; runs elevated. The service runs from Program Files (admin-only).
internal static class Installer
{
    private static string Dir => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Jarvis", "Sensors");
    private static string Exe => Path.Combine(Dir, "JarvisSensors.exe");

    public static int Install(string sid, bool driver)
    {
        _ = new SecurityIdentifier(sid);
        if (driver && Sc("query", "PawnIO") != 0)
        {
            var winget = Run("winget", "install --id namazso.PawnIO --silent --accept-package-agreements --accept-source-agreements");
            Log.Write($"PawnIO install via winget: {winget}");
        }
        Sc("stop", Program.ServiceName);
        Thread.Sleep(1500);
        Directory.CreateDirectory(Dir);
        var self = Environment.ProcessPath ?? throw new InvalidOperationException("no exe path");
        if (!string.Equals(Path.GetFullPath(self), Path.GetFullPath(Exe), StringComparison.OrdinalIgnoreCase))
            File.Copy(self, Exe, overwrite: true);
        var bin = $"\"{Exe}\" --service {sid}";
        if (Sc("query", Program.ServiceName) == 0) Sc("config", Program.ServiceName, "binPath=", bin, "start=", "auto");
        else Sc("create", Program.ServiceName, "binPath=", bin, "start=", "auto", "obj=", "LocalSystem", "DisplayName=", "Jarvis Sensors");
        Sc("description", Program.ServiceName, "Reads your PC's sensors and frame rate for Jarvis PC Stats, only while Jarvis is showing them.");
        var started = Sc("start", Program.ServiceName);
        Log.Write($"installed for {sid} (start {started}, driver {(Sc("query", "PawnIO") == 0 ? "present" : "absent")})");
        return 0;
    }

    public static int Uninstall()
    {
        Sc("stop", Program.ServiceName);
        Thread.Sleep(1500);
        Sc("delete", Program.ServiceName);
        for (var i = 0; i < 20 && File.Exists(Exe); i++)
        {
            try { File.Delete(Exe); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { Thread.Sleep(500); }
        }
        Log.Write("uninstalled");
        return 0;
    }

    private static int Sc(params string[] args) => RunCode(Path.Combine(Environment.SystemDirectory, "sc.exe"), args);

    private static int RunCode(string exe, string[] args)
    {
        var psi = new ProcessStartInfo(exe) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true };
        foreach (var a in args) psi.ArgumentList.Add(a);
        using var p = Process.Start(psi)!;
        p.StandardOutput.ReadToEnd();
        p.WaitForExit(15000);
        return p.ExitCode;
    }

    private static int Run(string exe, string args)
    {
        var psi = new ProcessStartInfo(exe, args) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true };
        using var p = Process.Start(psi)!;
        p.StandardOutput.ReadToEnd();
        p.WaitForExit(300_000);
        return p.ExitCode;
    }
}

/// The service: one client at a time; while connected, a reading line every second.
internal static class Service
{
    private static string _sid = "";
    private static IntPtr _status;
    private static readonly ServiceMain MainDelegate = ServiceEntry;
    private static readonly HandlerEx HandlerDelegate = Control;
    private static readonly CancellationTokenSource Stop = new();

    public static int Run(string sid)
    {
        _sid = new SecurityIdentifier(sid).Value;
        var table = new[]
        {
            new SERVICE_TABLE_ENTRY { lpServiceName = Marshal.StringToHGlobalUni(Program.ServiceName), lpServiceProc = Marshal.GetFunctionPointerForDelegate(MainDelegate) },
            new SERVICE_TABLE_ENTRY(),
        };
        if (!StartServiceCtrlDispatcherW(table)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return 0;
    }

    private static void ServiceEntry(int argc, IntPtr argv)
    {
        _status = RegisterServiceCtrlHandlerExW(Program.ServiceName, Marshal.GetFunctionPointerForDelegate(HandlerDelegate), IntPtr.Zero);
        SetState(SERVICE_RUNNING);
        Log.Write("service running");
        try { Serve(Stop.Token); }
        catch (Exception e) { Log.Write("service loop ended: " + e.Message); }
        SetState(SERVICE_STOPPED);
    }

    private static int Control(int control, int eventType, IntPtr eventData, IntPtr context)
    {
        if (control is SERVICE_CONTROL_STOP or SERVICE_CONTROL_SHUTDOWN)
        {
            SetState(SERVICE_STOP_PENDING);
            Stop.Cancel();
            try
            {
                using var c = new NamedPipeClientStream(".", Program.PipeName, PipeDirection.InOut);
                c.Connect(500);
            }
            catch (Exception e) when (e is TimeoutException or IOException or UnauthorizedAccessException) { }
        }
        return 0;
    }

    private static void SetState(int state)
    {
        var s = new SERVICE_STATUS
        {
            dwServiceType = SERVICE_WIN32_OWN_PROCESS,
            dwCurrentState = state,
            dwControlsAccepted = state == SERVICE_RUNNING ? SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN : 0,
            dwWaitHint = 3000,
        };
        SetServiceStatus(_status, ref s);
    }

    private static void Serve(CancellationToken stop)
    {
        var security = new PipeSecurity();
        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(_sid), PipeAccessRights.ReadWrite, AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), PipeAccessRights.FullControl, AccessControlType.Allow));
        using var sensors = new Sensors();
        using var frames = new Frames();
        while (!stop.IsCancellationRequested)
        {
            using var pipe = NamedPipeServerStreamAcl.Create(Program.PipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
                PipeOptions.None, 4096, 65536, security);
            pipe.WaitForConnection();
            if (stop.IsCancellationRequested) return;
            frames.Start();
            Log.Write("client connected");
            try
            {
                var next = DateTime.UtcNow;
                while (!stop.IsCancellationRequested && pipe.IsConnected)
                {
                    var line = Encoding.UTF8.GetBytes(Program.Line(sensors.Read(), frames.Snapshot()) + "\n");
                    pipe.Write(line, 0, line.Length);
                    pipe.Flush();
                    next = next.AddSeconds(1);
                    var wait = next - DateTime.UtcNow;
                    if (wait > TimeSpan.Zero) Thread.Sleep(wait); else next = DateTime.UtcNow;
                }
            }
            catch (IOException) { }
            finally
            {
                frames.Stop();
                sensors.Close();
                Log.Write("client gone");
            }
        }
    }

    private delegate void ServiceMain(int argc, IntPtr argv);
    private delegate int HandlerEx(int control, int eventType, IntPtr eventData, IntPtr context);

    private const int SERVICE_WIN32_OWN_PROCESS = 0x10, SERVICE_STOPPED = 1, SERVICE_STOP_PENDING = 3, SERVICE_RUNNING = 4;
    private const int SERVICE_ACCEPT_STOP = 1, SERVICE_ACCEPT_SHUTDOWN = 4, SERVICE_CONTROL_STOP = 1, SERVICE_CONTROL_SHUTDOWN = 5;

    [StructLayout(LayoutKind.Sequential)]
    private struct SERVICE_TABLE_ENTRY { public IntPtr lpServiceName; public IntPtr lpServiceProc; }

    [StructLayout(LayoutKind.Sequential)]
    private struct SERVICE_STATUS
    {
        public int dwServiceType, dwCurrentState, dwControlsAccepted, dwWin32ExitCode, dwServiceSpecificExitCode, dwCheckPoint, dwWaitHint;
    }

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool StartServiceCtrlDispatcherW(SERVICE_TABLE_ENTRY[] table);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr RegisterServiceCtrlHandlerExW(string name, IntPtr handler, IntPtr context);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool SetServiceStatus(IntPtr handle, ref SERVICE_STATUS status);
}
