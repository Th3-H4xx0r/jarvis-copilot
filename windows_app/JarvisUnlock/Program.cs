using System.ComponentModel;
using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Jarvis.Core.Admin;
using Jarvis.Core.Unlock;

namespace JarvisUnlock;

/// Unlock the PC from his iPhone. Windows lets nothing in his session type into the lock screen,
/// so this small helper runs as a Windows service (LocalSystem), installed once from Settings
/// with Face ID + UAC. The Jarvis app — after checking his iPhone's Face ID signature — sends it
/// the password over a pipe only his account can open; the service starts a copy of itself on
/// the sign-in desktop of the console session, which lifts the lock-screen picture if it's up and
/// types into the PIN / password box, never anywhere else; then it checks Windows really unlocked
/// (the typist watches the screen, the service asks Windows whose session is on the console) and
/// says so when it didn't. Nothing is stored here and nothing is typed anywhere else.
///
/// It also runs the IT agent's admin steps (admin_run, W4): ONE command per Face ID approval from his
/// iPhone, checked here against the approval key pinned in Program Files at install, run as him with
/// his elevated token (Elevated).
///
///   JarvisUnlock.exe --install &lt;user SID&gt; [&lt;approval key&gt;]   (elevated: copies itself and the
///                                                  key to Program Files, registers, starts)
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
                "--install" when args.Length > 1 => Installer.Install(args[1], args.Length > 2 ? args[2] : null),
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
        Console.Error.WriteLine("JarvisUnlock --install <sid> [<approval key>] | --uninstall | --service <sid> | --type");
        return 2;
    }
}

/// %ProgramData%\Jarvis\unlock.log (never the password).
internal static class Log
{
    private static readonly object Gate = new();   // requests run on their own tasks now

    public static void Write(string line)
    {
        lock (Gate) Append(line);
    }

    private static void Append(string line)
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
    public static string Dir => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Jarvis");
    public static string Exe => Path.Combine(Dir, "JarvisUnlock.exe");
    /// His iPhone's approval key for admin_run, copied here (admin-only) at install from the app's pinned
    /// key: the app's own copy is in his profile, which anything running as him could rewrite.
    public static string KeyPath => Path.Combine(Dir, AdminRun.KeyFileName);

    public static int Install(string sid, string? key = null)
    {
        _ = new SecurityIdentifier(sid);   // throws on anything that isn't a SID
        Sc("stop", Program.ServiceName);
        Thread.Sleep(1500);
        Directory.CreateDirectory(Dir);
        var self = Environment.ProcessPath ?? throw new InvalidOperationException("no exe path");
        if (!string.Equals(Path.GetFullPath(self), Path.GetFullPath(Exe), StringComparison.OrdinalIgnoreCase))
            File.Copy(self, Exe, overwrite: true);
        if (key != null)   // a refresh install without one keeps the key already here
        {
            if (AdminRun.ValidKey(key)) File.WriteAllText(KeyPath, key.Trim());
            else Log.Write("install: ignored an approval key that isn't a P-256 point");
        }
        var bin = $"\"{Exe}\" --service {sid}";
        if (Sc("query", Program.ServiceName) == 0)
            Sc("config", Program.ServiceName, "binPath=", bin, "start=", "auto");
        else
            Sc("create", Program.ServiceName, "binPath=", bin, "start=", "auto", "obj=", "LocalSystem", "DisplayName=", "Jarvis Unlock");
        Sc("description", Program.ServiceName, "Types your Windows password on the lock screen when you unlock the PC from your iPhone with Face ID, and runs the admin commands you approve there.");
        var started = Sc("start", Program.ServiceName);
        Log.Write($"installed for {sid} (start {started})");
        return 0;
    }

    public static int Uninstall()
    {
        Sc("stop", Program.ServiceName);
        Thread.Sleep(1500);
        Sc("delete", Program.ServiceName);
        try { File.Delete(KeyPath); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
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
    private const int MaxPipes = 4;
    private static readonly UnlockApproval Approval = new();
    private static readonly SemaphoreSlim AdminGate = new(1, 1);   // one admin command at a time
    private static readonly object Serial = new();                  // unlock + Remote Desktop: one at a time, as before
    /// Held while a child is started with inherited handles: no child inherits another request's pipe
    /// (the unlock's stdin carries his password).
    internal static readonly object SpawnLock = new();
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

    /// Up to 4 connections at once, each on its own task, so an admin command running for minutes never
    /// holds up an unlock. `{"password":"…"}`, `{"rdp":"on|off"}` or `{"admin_run":{…}}` →
    /// `{"ok":true,…}` or `{"ok":false,"error":"…"}`.
    private static void Serve(CancellationToken stop)
    {
        var security = new PipeSecurity();
        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(_sid), PipeAccessRights.ReadWrite, AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), PipeAccessRights.FullControl, AccessControlType.Allow));
        while (!stop.IsCancellationRequested)
        {
            NamedPipeServerStream pipe;
            try
            {
                pipe = NamedPipeServerStreamAcl.Create(Program.PipeName, PipeDirection.InOut, MaxPipes, PipeTransmissionMode.Byte,
                    PipeOptions.None, 4096, 4096, security);
            }
            catch (IOException)
            {
                Thread.Sleep(200);   // every instance is busy: one frees up soon
                continue;
            }
            try { pipe.WaitForConnection(); }
            catch (IOException) { pipe.Dispose(); continue; }
            if (stop.IsCancellationRequested) { pipe.Dispose(); return; }
            _ = Task.Run(() => Handle(pipe));
        }
    }

    private static void Handle(NamedPipeServerStream pipe)
    {
        using (pipe)
        {
            string reply;
            try
            {
                var node = JsonNode.Parse(ReadLine(pipe));
                if (node?["admin_run"] is { } admin)
                    reply = AdminRunReply(admin);
                else if (node?["rdp"]?.GetValue<string>() is { } rdp)
                {
                    lock (Serial) reply = rdp is "on" or "off" ? SwitchRemoteDesktop(rdp == "on") : Error("Bad request.");
                }
                else
                {
                    var password = node?["password"]?.GetValue<string>() ?? "";
                    if (password.Length == 0) reply = Error("No password was sent.");
                    else lock (Serial) reply = TypeOnLockScreen(password);
                }
            }
            catch (Exception e) when (e is JsonException or InvalidOperationException or IOException)
            {
                reply = Error("Bad request.");
            }
            catch (Exception e)
            {
                Log.Write("request failed: " + e.Message);
                reply = Error("The helper hit an error.");
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

    /// One admin command, only on his fresh Face ID signature over exactly this command (AdminRun).
    private static string AdminRunReply(JsonNode request)
    {
        var req = AdminRun.Parse(request, out var bad);
        if (req == null) return Error(bad);
        var key = File.Exists(Installer.KeyPath) ? File.ReadAllText(Installer.KeyPath).Trim() : null;
        var refusal = AdminRun.Refusal(req, key, Approval, DateTimeOffset.UtcNow);
        if (refusal != null)
        {
            Log.Write($"admin_run refused ({refusal}): {Short(req.Command)}");
            return Error(refusal);
        }
        if (!AdminGate.Wait(TimeSpan.FromSeconds(5))) return Error("Another admin command is running.");
        try
        {
            var r = Elevated.Run(AdminRun.EncodedCommand(req.Command), req.TimeoutS, _sid);
            if (r.Error != null)
            {
                Log.Write($"admin_run not run ({r.Error}): {Short(req.Command)}");
                return Error(r.Error);
            }
            var (output, truncated) = AdminRun.Cap(r.Stdout, AdminRun.PlainErrors(r.Stderr));
            Log.Write($"admin_run exit {(r.Exit is { } c ? c.ToString() : "timed out")} in {r.Ms} ms: {Short(req.Command)}");
            return AdminRun.Reply(r.Exit, output, truncated, r.TimedOut, r.Ms);
        }
        finally
        {
            AdminGate.Release();
        }
    }

    private static string Short(string command) => command.Length > 500 ? command[..500] + "…" : command;

    private static string ReadLine(Stream s)
    {
        var buf = new List<byte>();
        var one = new byte[1];
        while (buf.Count < 65536 && s.Read(one, 0, 1) == 1 && one[0] != (byte)'\n') buf.Add(one[0]);
        return Encoding.UTF8.GetString(buf.ToArray());
    }

    /// The remote-desktop integration switched on/off: re-applies Jarvis's Tailscale-only Remote Desktop
    /// setup, or switches RDP off and removes its rule (the only two things this command can do).
    private static string SwitchRemoteDesktop(bool on)
    {
        var script = on ? Jarvis.Core.Remote.RdpSetup.SetupScript() : Jarvis.Core.Remote.RdpSetup.OffScript();
        var psi = new System.Diagnostics.ProcessStartInfo("powershell.exe",
            "-NoProfile -NonInteractive -EncodedCommand " + Convert.ToBase64String(Encoding.Unicode.GetBytes(script)))
        { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true };
        using var p = System.Diagnostics.Process.Start(psi);
        if (p == null) return Error("Couldn't start PowerShell.");
        var err = p.StandardError.ReadToEnd();
        if (!p.WaitForExit(60_000)) { try { p.Kill(); } catch (InvalidOperationException) { } return Error("Timed out."); }
        Log.Write($"remote desktop {(on ? "on" : "off")}: exit {p.ExitCode}");
        return p.ExitCode == 0 ? new JsonObject { ["ok"] = true }.ToJsonString() : Error(err.Trim().Split('\n')[0]);
    }

    private static string Error(string why) => new JsonObject { ["ok"] = false, ["error"] = why }.ToJsonString();

    /// Starts `--type` as SYSTEM in the console session, on its sign-in desktop, hands it the
    /// password on stdin, then confirms with Windows: `{"ok":true,"checked":true}` only when his
    /// session is unlocked on the console (Jarvis.Core.Unlock.UnlockOutcome decides).
    private static string TypeOnLockScreen(string password)
    {
        var session = WTSGetActiveConsoleSessionId();
        if (session == ConsoleSession.None) return Error("No one is signed in at the PC.");
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ALL_ACCESS, out var own)) return Error("Couldn't read the service's token.");
        var token = IntPtr.Zero;
        int? exit;
        try
        {
            if (!DuplicateTokenEx(own, MAXIMUM_ALLOWED, IntPtr.Zero, 2 /* impersonation */, 1 /* primary */, out token))
                return Error("Couldn't prepare the sign-in desktop.");
            if (!SetTokenInformation(token, 12 /* TokenSessionId */, ref session, 4))
                return Error("Couldn't reach the signed-in session.");
            AnonymousPipeServerStream stdin;
            PROCESS_INFORMATION pi;
            lock (SpawnLock)   // the pipe carries his password: no other request's child may inherit it
            {
                stdin = new AnonymousPipeServerStream(PipeDirection.Out, HandleInheritability.Inheritable);
                var si = new STARTUPINFO
                {
                    cb = Marshal.SizeOf<STARTUPINFO>(),
                    lpDesktop = @"winsta0\winlogon",
                    dwFlags = STARTF_USESTDHANDLES,
                    hStdInput = stdin.ClientSafePipeHandle.DangerousGetHandle(),
                };
                var exe = Environment.ProcessPath!;
                var cmd = new StringBuilder($"\"{exe}\" --type");
                var started = CreateProcessAsUserW(token, exe, cmd, IntPtr.Zero, IntPtr.Zero, true, CREATE_NO_WINDOW, IntPtr.Zero, null, ref si, out pi);
                var startError = Marshal.GetLastWin32Error();
                stdin.DisposeLocalCopyOfClientHandle();
                if (!started)
                {
                    stdin.Dispose();
                    return Error($"Couldn't start on the sign-in desktop ({startError}).");
                }
            }
            try
            {
                var bytes = Encoding.UTF8.GetBytes(password + "\n");
                stdin.Write(bytes, 0, bytes.Length);
                stdin.Flush();
            }
            catch (IOException) { }
            stdin.Dispose();
            // Reach + settle + typing + watch is ~19 s at worst; past that it's stuck: end it.
            var waited = WaitForSingleObject(pi.hProcess, 22000);
            if (waited != 0) TerminateProcess(pi.hProcess, 1);
            GetExitCodeProcess(pi.hProcess, out var code);
            CloseHandle(pi.hThread);
            CloseHandle(pi.hProcess);
            exit = waited == 0 ? unchecked((int)code) : null;
        }
        finally
        {
            if (token != IntPtr.Zero) CloseHandle(token);
            CloseHandle(own);
        }
        // Windows' side: whose session is on the console now, and is it unlocked. A sign-in after
        // Remote Desktop reconnects his session a moment after Enter: look for up to 4 s.
        var error = UnlockOutcome.Error(exit, session, ReadConsole());
        for (var i = 0; error != null && !UnlockOutcome.Final(exit) && i < 16; i++)
        {
            Thread.Sleep(250);
            error = UnlockOutcome.Error(exit, session, ReadConsole());
        }
        var now = ReadConsole();
        Log.Write($"type finished: {(exit is { } c ? c.ToString() : "timed out")} in session {session}; console {now.Id} his={now.His} active={now.Active} {now.Lock} -> {error ?? "unlocked"}");
        return error == null ? new JsonObject { ["ok"] = true, ["checked"] = true }.ToJsonString() : Error(error);
    }

    /// The console session as Windows reports it: its id, whether it's his account's (its user token's
    /// SID), connected (WTSActive) and its lock flag (WTSSessionInfoEx).
    private static ConsoleSession ReadConsole()
    {
        var id = WTSGetActiveConsoleSessionId();
        if (id == ConsoleSession.None) return new ConsoleSession(id, false, false, ConsoleLock.Unknown);
        var his = false;
        if (WTSQueryUserToken(id, out var user))
        {
            try { his = string.Equals(new WindowsIdentity(user).User?.Value, _sid, StringComparison.OrdinalIgnoreCase); }
            catch (Exception e) when (e is ArgumentException or SecurityException or UnauthorizedAccessException) { }
            finally { CloseHandle(user); }
        }
        var active = false;
        var lockState = ConsoleLock.Unknown;
        if (WTSQuerySessionInformationW(IntPtr.Zero, id, 25 /* WTSSessionInfoEx */, out var buf, out var bytes))
        {
            try
            {
                // WTSINFOEXW: Level (DWORD), then the 8-byte-aligned WTSINFOEX_LEVEL1_W:
                // SessionId @8, SessionState @12 (0 = WTSActive), SessionFlags @16 (0 lock, 1 unlock).
                if (bytes >= 20 && Marshal.ReadInt32(buf, 0) == 1)
                {
                    active = Marshal.ReadInt32(buf, 12) == 0;
                    lockState = Marshal.ReadInt32(buf, 16) switch { 0 => ConsoleLock.Locked, 1 => ConsoleLock.Unlocked, _ => ConsoleLock.Unknown };
                }
            }
            finally { WTSFreeMemory(buf); }
        }
        return new ConsoleSession(id, his, active, lockState);
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
    private static extern bool TerminateProcess(IntPtr process, uint code);

    [DllImport("wtsapi32.dll", SetLastError = true)]
    private static extern bool WTSQueryUserToken(uint session, out IntPtr token);

    [DllImport("wtsapi32.dll", SetLastError = true)]
    private static extern bool WTSQuerySessionInformationW(IntPtr server, uint session, int infoClass, out IntPtr buffer, out int bytes);

    [DllImport("wtsapi32.dll")]
    private static extern void WTSFreeMemory(IntPtr memory);

    [DllImport("kernel32.dll")]
    private static extern bool GetExitCodeProcess(IntPtr process, out uint code);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);
}

/// Runs one approved admin command (W4) as him, elevated: his linked full token in the console session
/// (his Face ID approval stands in for the UAC prompt), on his desktop, inside a job object so a timeout
/// ends the whole tree. Never for anyone else signed in, never as SYSTEM; only the command is logged.
internal static class Elevated
{
    public readonly record struct Result(int? Exit, string Stdout, string Stderr, bool TimedOut, long Ms, string? Error);

    private static Result Fail(string why) => new(null, "", "", false, 0, why);

    public static Result Run(string encoded, int timeoutS, string sid)
    {
        var clock = Stopwatch.StartNew();
        var session = WTSGetActiveConsoleSessionId();
        if (session == 0xFFFFFFFF || !WTSQueryUserToken(session, out var user)) return Fail("No one is signed in at the PC.");
        IntPtr linked = IntPtr.Zero, primary = IntPtr.Zero, env = IntPtr.Zero, job = IntPtr.Zero;
        var pi = default(PROCESS_INFORMATION);
        try
        {
            string? owner;
            try { owner = new WindowsIdentity(user).User?.Value; }
            catch (Exception e) when (e is ArgumentException or SecurityException or UnauthorizedAccessException) { owner = null; }
            if (!string.Equals(owner, sid, StringComparison.OrdinalIgnoreCase)) return Fail("Someone else is signed in at the PC.");
            if (!GetTokenInt(user, TokenElevationType, out var elevation, sizeof(int), out _)) return Fail("Couldn't read your account's token.");
            IntPtr source;
            if (elevation == 3)   // limited: a UAC-split admin's full token is the linked one
            {
                if (!GetTokenPtr(user, TokenLinkedToken, out linked, IntPtr.Size, out _)) return Fail("Couldn't get your account's admin token.");
                source = linked;
            }
            else if (elevation == 2) source = user;   // already full (UAC off)
            else return Fail("Your Windows account isn't an administrator.");
            if (!DuplicateTokenEx(source, MAXIMUM_ALLOWED, IntPtr.Zero, 2 /* impersonation */, 1 /* primary */, out primary))
                return Fail($"Couldn't prepare your admin token ({Marshal.GetLastWin32Error()}).");
            SetTokenInformation(primary, TokenSessionId, ref session, sizeof(uint));
            if (!CreateEnvironmentBlock(out env, primary, false)) env = IntPtr.Zero;
            var profile = Profile(primary);
            job = CreateJobObjectW(IntPtr.Zero, null);
            if (job == IntPtr.Zero || !KillOnClose(job, true)) return Fail("Couldn't set up a job for the command.");

            AnonymousPipeServerStream stdout, stderr;
            lock (Service.SpawnLock)   // no other request's child inherits these pipes, nor this child theirs
            {
                stdout = new AnonymousPipeServerStream(PipeDirection.In, HandleInheritability.Inheritable);
                stderr = new AnonymousPipeServerStream(PipeDirection.In, HandleInheritability.Inheritable);
                var stdin = new AnonymousPipeServerStream(PipeDirection.Out, HandleInheritability.Inheritable);
                var si = new STARTUPINFO
                {
                    cb = Marshal.SizeOf<STARTUPINFO>(),
                    lpDesktop = @"winsta0\default",
                    dwFlags = STARTF_USESTDHANDLES,
                    hStdInput = stdin.ClientSafePipeHandle.DangerousGetHandle(),
                    hStdOutput = stdout.ClientSafePipeHandle.DangerousGetHandle(),
                    hStdError = stderr.ClientSafePipeHandle.DangerousGetHandle(),
                };
                var exe = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
                var cmd = new StringBuilder($"\"{exe}\" -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand {encoded}");
                var started = CreateProcessAsUserW(primary, exe, cmd, IntPtr.Zero, IntPtr.Zero, true,
                    CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED, env, profile, ref si, out pi);
                var startError = Marshal.GetLastWin32Error();
                stdout.DisposeLocalCopyOfClientHandle();
                stderr.DisposeLocalCopyOfClientHandle();
                stdin.DisposeLocalCopyOfClientHandle();
                stdin.Dispose();   // no input: the command reads end of file
                if (!started)
                {
                    stdout.Dispose();
                    stderr.Dispose();
                    return Fail($"Couldn't start PowerShell as you ({startError}).");
                }
            }
            using (stdout)
            using (stderr)
            {
                if (!AssignProcessToJobObject(job, pi.hProcess))
                {
                    TerminateProcess(pi.hProcess, 1);
                    return Fail("Couldn't put the command in its job.");
                }
                ResumeThread(pi.hThread);
                var outText = new Tail();
                var errText = new Tail();
                var readers = new[] { Pump(stdout, outText), Pump(stderr, errText) };
                var exited = WaitForSingleObject(pi.hProcess, (uint)Math.Min(int.MaxValue, timeoutS * 1000L)) == 0;
                int? exit = null;
                if (exited)
                {
                    GetExitCodeProcess(pi.hProcess, out var code);
                    exit = unchecked((int)code);
                    KillOnClose(job, false);   // what it started on purpose (a service, an app) keeps running
                }
                else
                {
                    TerminateJobObject(job, 1);   // timed out: the whole tree
                }
                Task.WaitAll(readers, TimeSpan.FromSeconds(3));   // a child still holding the pipe: take what came
                return new Result(exit, outText.Text, errText.Text, !exited, clock.ElapsedMilliseconds, null);
            }
        }
        finally
        {
            if (pi.hThread != IntPtr.Zero) CloseHandle(pi.hThread);
            if (pi.hProcess != IntPtr.Zero) CloseHandle(pi.hProcess);
            if (job != IntPtr.Zero) CloseHandle(job);
            if (env != IntPtr.Zero) DestroyEnvironmentBlock(env);
            if (primary != IntPtr.Zero) CloseHandle(primary);
            if (linked != IntPtr.Zero) CloseHandle(linked);
            CloseHandle(user);
        }
    }

    private static Task Pump(Stream s, Tail into) => Task.Run(() =>
    {
        try
        {
            using var reader = new StreamReader(s, new UTF8Encoding(false), false, 4096, leaveOpen: true);
            var buf = new char[4096];
            int n;
            while ((n = reader.Read(buf, 0, buf.Length)) > 0) into.Add(buf, n);
        }
        catch (Exception e) when (e is IOException or ObjectDisposedException) { }
    });

    /// The last stretch of a stream (the reply keeps 16000 characters; a chatty installer can print far more).
    private sealed class Tail
    {
        private readonly StringBuilder _sb = new();

        public void Add(char[] buf, int n)
        {
            lock (_sb)
            {
                _sb.Append(buf, 0, n);
                if (_sb.Length > 64_000) _sb.Remove(0, _sb.Length - 32_000);
            }
        }

        public string Text
        {
            get { lock (_sb) return _sb.ToString().Replace("\r\n", "\n"); }
        }
    }

    private static string? Profile(IntPtr token)
    {
        var size = 520u;
        var dir = new StringBuilder((int)size);
        return GetUserProfileDirectoryW(token, dir, ref size) ? dir.ToString() : null;
    }

    private static bool KillOnClose(IntPtr job, bool on)
    {
        var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        info.BasicLimitInformation.LimitFlags = on ? JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE : 0;
        return SetInformationJobObject(job, 9 /* JobObjectExtendedLimitInformation */, ref info,
            (uint)Marshal.SizeOf<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>());
    }

    // ── Win32 ───────────────────────────────────────────────────────────
    private const int TokenSessionId = 12, TokenElevationType = 18, TokenLinkedToken = 19, STARTF_USESTDHANDLES = 0x100;
    private const uint MAXIMUM_ALLOWED = 0x02000000, CREATE_NO_WINDOW = 0x08000000, CREATE_UNICODE_ENVIRONMENT = 0x400,
        CREATE_SUSPENDED = 0x4, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;

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

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS
    {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll")]
    private static extern uint WTSGetActiveConsoleSessionId();

    [DllImport("wtsapi32.dll", SetLastError = true)]
    private static extern bool WTSQueryUserToken(uint session, out IntPtr token);

    [DllImport("advapi32.dll", SetLastError = true, EntryPoint = "GetTokenInformation")]
    private static extern bool GetTokenInt(IntPtr token, int infoClass, out int info, int length, out int returned);

    [DllImport("advapi32.dll", SetLastError = true, EntryPoint = "GetTokenInformation")]
    private static extern bool GetTokenPtr(IntPtr token, int infoClass, out IntPtr info, int length, out int returned);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool DuplicateTokenEx(IntPtr token, uint access, IntPtr attributes, int level, int type, out IntPtr newToken);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool SetTokenInformation(IntPtr token, int infoClass, ref uint info, int length);

    [DllImport("userenv.dll", SetLastError = true)]
    private static extern bool CreateEnvironmentBlock(out IntPtr env, IntPtr token, bool inherit);

    [DllImport("userenv.dll", SetLastError = true)]
    private static extern bool DestroyEnvironmentBlock(IntPtr env);

    [DllImport("userenv.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool GetUserProfileDirectoryW(IntPtr token, StringBuilder dir, ref uint size);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcessAsUserW(IntPtr token, string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit,
        uint flags, IntPtr env, string? dir, ref STARTUPINFO si, out PROCESS_INFORMATION pi);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateJobObjectW(IntPtr attributes, string? name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info, uint length);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateJobObject(IntPtr job, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint ResumeThread(IntPtr thread);

    [DllImport("kernel32.dll")]
    private static extern uint WaitForSingleObject(IntPtr handle, uint ms);

    [DllImport("kernel32.dll")]
    private static extern bool GetExitCodeProcess(IntPtr process, out uint code);

    [DllImport("kernel32.dll")]
    private static extern bool TerminateProcess(IntPtr process, uint code);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);
}

/// The copy started in the console session (as SYSTEM). It types only into the sign-in screen,
/// judged from what's on screen, and follows Jarvis.Core.Unlock.LockScreenTypist: lift the picture
/// (or a leftover "enter your PIN" dialog) with Space, wait for the box, clear it, type, Enter, then
/// watch up to 8 s for his desktop to come back. Exit codes: TypistExit.
internal static unsafe class Typist
{
    private static IntPtr _desk;

    public static int Run()
    {
        var password = Console.In.ReadLine() ?? "";
        if (password.Length == 0) return TypistExit.NoPassword;
        var typist = new LockScreenTypist(password.Length, DateTimeOffset.UtcNow);
        while (true)
        {
            foreach (var step in typist.Next(Look(), DateTimeOffset.UtcNow))
            {
                switch (step)
                {
                    case TypistStep.Done done:
                        return done.Exit;
                    case TypistStep.Press press:
                        Key(press.Vk);
                        break;
                    case TypistStep.Wait wait:
                        Thread.Sleep(wait.For);
                        break;
                    case TypistStep.Clear clear:
                        Key(0x23 /* End */);
                        for (var i = 0; i < clear.Backspaces; i++) { Key(0x08 /* Backspace */); Thread.Sleep(10); }
                        break;
                    case TypistStep.TypePassword:
                        foreach (var ch in password) Unicode(ch);
                        break;
                }
            }
        }
    }

    /// What's on screen, read from the screen itself (Windows' session-lock flag isn't reliable for
    /// this): the secure Winlogon desktop is the sign-in screen; LockApp in front on the normal desktop
    /// is the lock-screen picture; the normal desktop otherwise is unlocked; anything unreadable is
    /// Unknown (never "unlocked"). Attaches this thread to the input desktop, so keys go there.
    private static LockView Look()
    {
        var desk = OpenInputDesktop(0, false, 0x01FF /* DESKTOP_ALL */);
        if (desk == IntPtr.Zero) return LockView.Unknown;
        if (!SetThreadDesktop(desk))
        {
            CloseDesktop(desk);
            return LockView.Unknown;
        }
        if (_desk != IntPtr.Zero) CloseDesktop(_desk);
        _desk = desk;
        var name = DesktopName(desk);
        // A UAC prompt (consent.exe) also sits on the secure desktop, over an unlocked PC: never a
        // sign-in screen, so nothing is pressed or typed into it.
        if (name.Equals("Winlogon", StringComparison.OrdinalIgnoreCase))
            return ForegroundExe().Equals("consent.exe", StringComparison.OrdinalIgnoreCase) ? LockView.Unlocked : LockView.SignIn;
        if (!name.Equals("Default", StringComparison.OrdinalIgnoreCase)) return LockView.Unknown;
        return ForegroundExe().Equals("LockApp.exe", StringComparison.OrdinalIgnoreCase) ? LockView.Picture : LockView.Unlocked;
    }

    private static string DesktopName(IntPtr desk)
    {
        if (desk == IntPtr.Zero) return "";
        var name = new char[64];
        fixed (char* p = name)
        {
            if (!GetUserObjectInformationW(desk, 2 /* UOI_NAME */, p, name.Length * 2, out _)) return "";
        }
        return new string(name).TrimEnd('\0');
    }

    /// The exe behind the foreground window of this thread's (input) desktop.
    private static string ForegroundExe()
    {
        var hwnd = GetForegroundWindow();
        if (hwnd == IntPtr.Zero) return "";
        GetWindowThreadProcessId(hwnd, out var pid);
        var proc = OpenProcess(0x1000 /* QUERY_LIMITED_INFORMATION */, false, pid);
        if (proc == IntPtr.Zero) return "";
        try
        {
            var buf = new char[520];
            var len = buf.Length;
            fixed (char* p = buf)
            {
                if (!QueryFullProcessImageNameW(proc, 0, p, ref len)) return "";
            }
            return Path.GetFileName(new string(buf, 0, len));
        }
        finally
        {
            CloseHandle(proc);
        }
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

    [DllImport("user32.dll")]
    private static extern bool CloseDesktop(IntPtr desk);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetUserObjectInformationW(IntPtr obj, int index, char* info, int length, out int needed);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, INPUT[] inputs, int size);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool QueryFullProcessImageNameW(IntPtr process, int flags, char* name, ref int size);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

}
