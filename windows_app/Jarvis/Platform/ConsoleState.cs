using System.Runtime.InteropServices;

namespace Jarvis.Platform;

/// Where this Windows session is shown. On the physical console normally; over Remote Desktop while
/// an RDP session is connected; nowhere once that RDP session ends (the session is left
/// disconnected and the console shows the sign-in screen until he signs back in). Windows won't
/// capture a session that isn't on the console, and it sends no lock event for that last case.
internal static partial class ConsoleState
{
    private const uint NoSession = 0xFFFFFFFF;

    /// This session is the one on the physical console.
    public static bool OnConsole
    {
        get
        {
            var console = WTSGetActiveConsoleSessionId();
            return console != NoSession && ProcessIdToSessionId((uint)Environment.ProcessId, out var own) && own == console;
        }
    }

    /// Connected over Remote Desktop right now (connected, but not on the console).
    public static bool ShownOverRemoteDesktop => !OnConsole && Connected;

    /// WTSConnectState of this session is WTSActive (a disconnected session isn't shown anywhere).
    private static bool Connected
    {
        get
        {
            if (!WTSQuerySessionInformationW(IntPtr.Zero, NoSession /* WTS_CURRENT_SESSION */, 8 /* WTSConnectState */, out var buf, out var bytes))
                return false;
            try { return bytes >= 4 && Marshal.ReadInt32(buf) == 0 /* WTSActive */; }
            finally { WTSFreeMemory(buf); }
        }
    }

    [LibraryImport("kernel32.dll")]
    private static partial uint WTSGetActiveConsoleSessionId();

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool ProcessIdToSessionId(uint pid, out uint session);

    [LibraryImport("wtsapi32.dll", EntryPoint = "WTSQuerySessionInformationW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool WTSQuerySessionInformationW(IntPtr server, uint session, int infoClass, out IntPtr buffer, out int bytes);

    [LibraryImport("wtsapi32.dll")]
    private static partial void WTSFreeMemory(IntPtr memory);
}
