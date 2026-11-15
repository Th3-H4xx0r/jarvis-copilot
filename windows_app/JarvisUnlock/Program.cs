using System.ComponentModel;
using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace JarvisUnlock;

/// Unlock the PC from his iPhone. Windows lets nothing in his session type into the lock screen,
/// so this small helper runs as a Windows service (LocalSystem), installed once from Settings
/// with Face ID + UAC. The Jarvis app — after checking his iPhone's Face ID signature — sends it
/// the password over a pipe only his account can open; the service starts a copy of itself on
/// the sign-in desktop of the console session, which types it, and only when that desktop is
/// the one showing (the PC really is locked). Nothing is stored here and nothing is typed
/// anywhere else.
///
///   JarvisUnlock.exe --install &lt;user SID&gt;   (elevated: copies itself to Program Files, registers, starts)
///   JarvisUnlock.exe --uninstall              (elevated)
///   JarvisUnlock.exe --service &lt;user SID&gt;   (what the service manager runs)
///   JarvisUnlock.exe --type                   (the copy on the sign-in desktop; reads stdin)
internal static class Program
{
    public const string ServiceName = "JarvisUnlock";
    public const string PipeName = "JarvisUnlock";

    private static int Main(string[] args)
    {
        var mode = args.Length > 0 ? args[0] : "";
        try
        {
            return mode switch
            {
                "--install" when args.Length > 1 => Installer.Install(args[1]),
                "--uninstall" => Installer.Uninstall(),
                "--service" when args.Length > 1 => Service.Run(args[1]),
                "--type" => Typist.Run(),
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
        Console.Error.WriteLine("JarvisUnlock --install <sid> | --uninstall | --service <sid> | --type");
        return 2;
    }
}

/// %ProgramData%\Jarvis\unlock.log (never the password).
internal static class Log
{
    public static void Write(string line)
    {
        try
        {
            var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "Jarvis");
            Directory.CreateDirectory(dir);
            var path = Path.Combine(dir, "unlock.log");
            if (File.Exists(path) && new FileInfo(path).Length > 256 * 1024) File.Delete(path);
            File.AppendAllText(path, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {line}{Environment.NewLine}");
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}

/// Register / remove the service. Runs elevated (UAC). The exe the service runs lives under
/// Program Files (admin-only), never in the app's per-user folder, which his account can write.
internal static class Installer
{
    private static string Dir => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Jarvis");
    public static string Exe => Path.Combine(Dir, "JarvisUnlock.exe");

    public static int Install(string sid)
    {
        _ = new SecurityIdentifier(sid);   // throws on anything that isn't a SID
        Sc("stop", Program.ServiceName);
        Thread.Sleep(1500);
        Directory.CreateDirectory(Dir);
        var self = Environment.ProcessPath ?? throw new InvalidOperationException("no exe path");
        if (!string.Equals(Path.GetFullPath(self), Path.GetFullPath(Exe), StringComparison.OrdinalIgnoreCase))
            File.Copy(self, Exe, overwrite: true);
        var bin = $"\"{Exe}\" --service {sid}";
        if (Sc("query", Program.ServiceName) == 0)
            Sc("config", Program.ServiceName, "binPath=", bin, "start=", "auto");
        else
            Sc("create", Program.ServiceName, "binPath=", bin, "start=", "auto", "obj=", "LocalSystem", "DisplayName=", "Jarvis Unlock");
        Sc("description", Program.ServiceName, "Types your Windows password on the lock screen when you unlock the PC from your iPhone with Face ID.");
        var started = Sc("start", Program.ServiceName);
        Log.Write($"installed for {sid} (start {started})");
        return 0;
    }

    public static int Uninstall()
    {
        Sc("stop", Program.ServiceName);
        Thread.Sleep(1500);
        Sc("delete", Program.ServiceName);
        // The service's process may still be exiting: try for up to 10 s.
        for (var i = 0; i < 20 && File.Exists(Exe); i++)
        {
            try { File.Delete(Exe); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { Thread.Sleep(500); }
        }
        Log.Write("uninstalled");
        return 0;
    }

    private static int Sc(params string[] args)
    {
        var psi = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "sc.exe")) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true };
        foreach (var a in args) psi.ArgumentList.Add(a);
        using var p = Process.Start(psi)!;
        p.StandardOutput.ReadToEnd();
        p.WaitForExit(15000);
        return p.ExitCode;
    }
}

/// The service: the pipe, and starting the typist on the sign-in desktop.
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
            // Unblock the pending WaitForConnection.
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

    /// One request at a time: `{"password":"…"}` → `{"ok":true}` or `{"ok":false,"error":"…"}`.
    private static void Serve(CancellationToken stop)
    {
        var security = new PipeSecurity();
        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(_sid), PipeAccessRights.ReadWrite, AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), PipeAccessRights.FullControl, AccessControlType.Allow));
        while (!stop.IsCancellationRequested)
        {
            using var pipe = NamedPipeServerStreamAcl.Create(Program.PipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
                PipeOptions.None, 4096, 4096, security);
            pipe.WaitForConnection();
            if (stop.IsCancellationRequested) return;
            string reply;
            try
            {
                var line = ReadLine(pipe);
                var password = JsonNode.Parse(line)?["password"]?.GetValue<string>() ?? "";
                reply = password.Length == 0 ? Error("No password was sent.") : TypeOnLockScreen(password);
            }
            catch (Exception e) when (e is JsonException or InvalidOperationException or IOException)
            {
                reply = Error("Bad request.");
            }
            try
            {
                var bytes = Encoding.UTF8.GetBytes(reply + "\n");
                pipe.Write(bytes, 0, bytes.Length);
                pipe.Flush();
                pipe.WaitForPipeDrain();
            }
            catch (IOException) { }
        }
    }

    private static string ReadLine(Stream s)
    {
        var buf = new List<byte>();
        var one = new byte[1];
        while (buf.Count < 8192 && s.Read(one, 0, 1) == 1 && one[0] != (byte)'\n') buf.Add(one[0]);
        return Encoding.UTF8.GetString(buf.ToArray());
    }

    private static string Error(string why) => new JsonObject { ["ok"] = false, ["error"] = why }.ToJsonString();

    /// Starts `--type` as SYSTEM in the console session, on its sign-in desktop, and hands it the
    /// password on stdin.
    private static string TypeOnLockScreen(string password)
    {
        var session = WTSGetActiveConsoleSessionId();
        if (session == 0xFFFFFFFF) return Error("No one is signed in at the PC.");
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ALL_ACCESS, out var own)) return Error("Couldn't read the service's token.");
        var token = IntPtr.Zero;
        try
        {
            if (!DuplicateTokenEx(own, MAXIMUM_ALLOWED, IntPtr.Zero, 2 /* impersonation */, 1 /* primary */, out token))
                return Error("Couldn't prepare the sign-in desktop.");
            if (!SetTokenInformation(token, 12 /* TokenSessionId */, ref session, 4))
                return Error("Couldn't reach the signed-in session.");
            using var stdin = new AnonymousPipeServerStream(PipeDirection.Out, HandleInheritability.Inheritable);
            var si = new STARTUPINFO
            {
                cb = Marshal.SizeOf<STARTUPINFO>(),
                lpDesktop = @"winsta0\winlogon",
                dwFlags = STARTF_USESTDHANDLES,
                hStdInput = stdin.ClientSafePipeHandle.DangerousGetHandle(),
            };
            var exe = Environment.ProcessPath!;
            var cmd = new StringBuilder($"\"{exe}\" --type");
            if (!CreateProcessAsUserW(token, exe, cmd, IntPtr.Zero, IntPtr.Zero, true, CREATE_NO_WINDOW, IntPtr.Zero, null, ref si, out var pi))
                return Error($"Couldn't start on the sign-in desktop ({Marshal.GetLastWin32Error()}).");
            stdin.DisposeLocalCopyOfClientHandle();
            try
            {
                var bytes = Encoding.UTF8.GetBytes(password + "\n");
                stdin.Write(bytes, 0, bytes.Length);
                stdin.Flush();
            }
            catch (IOException) { }
            stdin.Dispose();
            var waited = WaitForSingleObject(pi.hProcess, 20000);
            GetExitCodeProcess(pi.hProcess, out var code);
            CloseHandle(pi.hThread);
            CloseHandle(pi.hProcess);
            if (waited != 0) return Error("The lock screen didn't respond.");
            Log.Write($"type finished: {code}");
            return code switch
            {
                0 => new JsonObject { ["ok"] = true }.ToJsonString(),
                3 => Error("The PC isn't locked."),
                _ => Error($"Typing on the lock screen failed ({code})."),
            };
        }
        finally
        {
            if (token != IntPtr.Zero) CloseHandle(token);
            CloseHandle(own);
        }
    }

    // ── Win32 ───────────────────────────────────────────────────────────
    private delegate void ServiceMain(int argc, IntPtr argv);
    private delegate int HandlerEx(int control, int eventType, IntPtr eventData, IntPtr context);

    private const int SERVICE_WIN32_OWN_PROCESS = 0x10, SERVICE_STOPPED = 1, SERVICE_STOP_PENDING = 3, SERVICE_RUNNING = 4;
    private const int SERVICE_ACCEPT_STOP = 1, SERVICE_ACCEPT_SHUTDOWN = 4, SERVICE_CONTROL_STOP = 1, SERVICE_CONTROL_SHUTDOWN = 5;
    private const uint TOKEN_ALL_ACCESS = 0xF01FF, MAXIMUM_ALLOWED = 0x02000000, CREATE_NO_WINDOW = 0x08000000;
    private const int STARTF_USESTDHANDLES = 0x100;

    [StructLayout(LayoutKind.Sequential)]
    private struct SERVICE_TABLE_ENTRY { public IntPtr lpServiceName; public IntPtr lpServiceProc; }

    [StructLayout(LayoutKind.Sequential)]
    private struct SERVICE_STATUS
    {
        public int dwServiceType, dwCurrentState, dwControlsAccepted, dwWin32ExitCode, dwServiceSpecificExitCode, dwCheckPoint, dwWaitHint;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO
    {
        public int cb;
        public string? lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool StartServiceCtrlDispatcherW(SERVICE_TABLE_ENTRY[] table);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr RegisterServiceCtrlHandlerExW(string name, IntPtr handler, IntPtr context);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool SetServiceStatus(IntPtr handle, ref SERVICE_STATUS status);

    [DllImport("kernel32.dll")]
    private static extern uint WTSGetActiveConsoleSessionId();

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool DuplicateTokenEx(IntPtr token, uint access, IntPtr attributes, int level, int type, out IntPtr newToken);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool SetTokenInformation(IntPtr token, int infoClass, ref uint info, int length);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcessAsUserW(IntPtr token, string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit,
        uint flags, IntPtr env, string? dir, ref STARTUPINFO si, out PROCESS_INFORMATION pi);

    [DllImport("kernel32.dll")]
    private static extern uint WaitForSingleObject(IntPtr handle, uint ms);

    [DllImport("kernel32.dll")]
    private static extern bool GetExitCodeProcess(IntPtr process, out uint code);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);
}

/// The copy on the sign-in desktop: only if that desktop is the one showing, wake the lock
/// screen, type the password from stdin and press Enter. Exit 0 typed, 3 not locked.
internal static unsafe class Typist
{
    public static int Run()
    {
        var password = Console.In.ReadLine() ?? "";
        if (password.Length == 0) return 4;
        if (!OnSignInDesktop(out var desk)) return 3;
        SetThreadDesktop(desk);
        // A key with no character wakes the screen and lifts the lock-screen picture.
        Key(0x11 /* Ctrl */);
        Thread.Sleep(1500);
        if (!OnSignInDesktop(out _)) return 3;
        foreach (var ch in password) Unicode(ch);
        Thread.Sleep(80);
        Key(0x0D /* Enter */);
        return 0;
    }

    private static bool OnSignInDesktop(out IntPtr desk)
    {
        desk = OpenInputDesktop(0, false, 0x01FF /* DESKTOP_ALL */);
        if (desk == IntPtr.Zero) return false;
        var name = new char[64];
        fixed (char* p = name)
        {
            if (!GetUserObjectInformationW(desk, 2 /* UOI_NAME */, p, name.Length * 2, out _)) return false;
        }
        return new string(name).TrimEnd('\0').Equals("Winlogon", StringComparison.OrdinalIgnoreCase);
    }

    private static void Key(ushort vk)
    {
        var down = new INPUT { type = 1, ki = new KEYBDINPUT { wVk = vk } };
        var up = new INPUT { type = 1, ki = new KEYBDINPUT { wVk = vk, dwFlags = 2 /* KEYUP */ } };
        Send(down, up);
    }

    private static void Unicode(char c)
    {
        var down = new INPUT { type = 1, ki = new KEYBDINPUT { wScan = c, dwFlags = 4 /* UNICODE */ } };
        var up = new INPUT { type = 1, ki = new KEYBDINPUT { wScan = c, dwFlags = 4 | 2 } };
        Send(down, up);
        Thread.Sleep(15);
    }

    private static void Send(params INPUT[] inputs) => SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }

    // INPUT is a union; the mouse member is the largest, so pad to its size.
    [StructLayout(LayoutKind.Explicit, Size = 40)]
    private struct INPUT
    {
        [FieldOffset(0)] public uint type;
        [FieldOffset(8)] public KEYBDINPUT ki;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetThreadDesktop(IntPtr desk);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetUserObjectInformationW(IntPtr obj, int index, char* info, int length, out int needed);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, INPUT[] inputs, int size);
}
