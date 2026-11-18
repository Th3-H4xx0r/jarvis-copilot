using Jarvis.Core.Remote;

namespace Jarvis.Tests.Remote;

public class LockStateTests
{
    [Fact]
    public void RemoteDesktopEnded_SessionLeftOffTheConsole_ReportsLocked()
    {
        // RDP unlocked the session (SessionUnlock/Logon), then ended: Windows sends no lock, but the
        // physical PC now shows the sign-in screen.
        var locked = LockState.After(false, SessionChange.Unlock);
        locked = LockState.After(locked, SessionChange.RemoteDisconnect);
        Assert.True(LockState.Locked(locked, onConsole: false, remoteSession: false));
    }

    [Fact]
    public void OnTheConsole_FollowsLockAndUnlock()
    {
        Assert.True(LockState.Locked(LockState.After(false, SessionChange.Lock), onConsole: true, remoteSession: false));
        Assert.False(LockState.Locked(LockState.After(true, SessionChange.Unlock), onConsole: true, remoteSession: false));
        Assert.False(LockState.Locked(LockState.After(true, SessionChange.Logon), onConsole: true, remoteSession: false));
    }

    [Fact]
    public void SigningBackInAtTheConsole_IsUnlocked()
    {
        // Locked over RDP, disconnected, then he signs in at the PC: Windows may send only ConsoleConnect.
        var locked = LockState.After(false, SessionChange.Lock);
        locked = LockState.After(locked, SessionChange.RemoteDisconnect);
        locked = LockState.After(locked, SessionChange.ConsoleConnect);
        Assert.False(LockState.Locked(locked, onConsole: true, remoteSession: false));
    }

    [Fact]
    public void ShownOverRemoteDesktop_FollowsTheEvents()
    {
        Assert.False(LockState.Locked(false, onConsole: false, remoteSession: true));
        Assert.True(LockState.Locked(true, onConsole: false, remoteSession: true));
    }

    [Fact]
    public void WhichChangesAreWorthReporting()
    {
        Assert.True(LockState.Reports(SessionChange.Lock));
        Assert.True(LockState.Reports(SessionChange.RemoteDisconnect));
        Assert.True(LockState.Reports(SessionChange.ConsoleConnect));
        Assert.False(LockState.Reports(SessionChange.Other));
        Assert.True(LockState.After(true, SessionChange.Other));
        Assert.False(LockState.After(false, SessionChange.RemoteConnect));
    }
}
