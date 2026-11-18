namespace Jarvis.Core.Remote;

/// The session switches Windows reports (Microsoft.Win32.SessionSwitchReason, which Core can't see).
public enum SessionChange { Lock, Unlock, Logon, ConsoleConnect, ConsoleDisconnect, RemoteConnect, RemoteDisconnect, Other }

/// Whether the PC reads as locked for /api/rdp/status. Lock/unlock events alone miss the case that
/// matters after Remote Desktop: the RDP session ends with his session unlocked but no longer on the
/// physical console, which shows the sign-in screen, and Windows sends no lock for that.
public static class LockState
{
    /// The lock flag after one session switch. Signing back in at the console (ConsoleConnect) means
    /// Windows took his PIN, so it's unlocked even when no SessionUnlock follows.
    public static bool After(bool locked, SessionChange change) => change switch
    {
        SessionChange.Lock => true,
        SessionChange.Unlock or SessionChange.Logon or SessionChange.ConsoleConnect => false,
        _ => locked,
    };

    /// Worth posting a fresh status for.
    public static bool Reports(SessionChange change) => change != SessionChange.Other;

    /// Locked for the server: the events say so, or his session is neither on the console nor shown
    /// over RDP (left at the sign-in screen when an RDP session ended).
    public static bool Locked(bool lockedByEvents, bool onConsole, bool remoteSession) =>
        lockedByEvents || (!onConsole && !remoteSession);
}
