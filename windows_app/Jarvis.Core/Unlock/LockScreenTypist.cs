namespace Jarvis.Core.Unlock;

// The lock-screen typing decisions, kept free of Win32 so they're tested on any OS. JarvisUnlock
// (the LocalSystem helper) compiles this file in and only does the looking and key pressing.
// Nothing here may depend on other Core code: the helper links this one file.

/// What's on the console's input desktop, as the typist reads it.
public enum LockView
{
    /// His desktop ("Default", LockApp not in front).
    Unlocked,
    /// The lock-screen picture (LockApp in front on the normal desktop).
    Picture,
    /// The secure sign-in desktop ("Winlogon"): the PIN / password box, its picture after Remote
    /// Desktop, or a "Please enter your PIN" dialog.
    SignIn,
    /// Couldn't read the screen (no input desktop yet, a desktop switch in progress).
    Unknown,
}

/// One thing for the typist to do, in order.
public abstract record TypistStep
{
    /// One key, down then up.
    public sealed record Press(ushort Vk) : TypistStep;
    public sealed record Wait(TimeSpan For) : TypistStep;
    /// End, then Backspace this many times: empties the PIN / password box.
    public sealed record Clear(int Backspaces) : TypistStep;
    public sealed record TypePassword : TypistStep;
    /// Stop; the process exits with this code (TypistExit).
    public sealed record Done(int Exit) : TypistStep;
}

/// The typist's exit codes (its process exit code, read by the service).
public static class TypistExit
{
    /// Typed, pressed Enter, and the sign-in screen gave way to his desktop.
    public const int Unlocked = 0;
    /// The PC wasn't locked: nothing pressed.
    public const int NotLocked = 3;
    public const int NoPassword = 4;
    /// The sign-in screen never came up: nothing typed.
    public const int NoSignIn = 5;
    /// Typed and pressed Enter, but Windows didn't take it: still at the sign-in screen after Watch.
    public const int NotTaken = 6;
}

/// The typist as a state machine: feed it what's on screen, do the steps it returns, look again.
///   1. Reach the sign-in screen: Space lifts the lock-screen picture (LockApp has no text box).
///   2. On the sign-in screen, before any typing: Space (lifts the picture the sign-in screen shows
///      after Remote Desktop, or presses OK on a leftover "Please enter your PIN" dialog; if the box
///      already had focus it types a space, cleared next), then wait for the box to settle.
///   3. Still the sign-in screen: clear the box, type, Enter.
///   4. Watch: success only once his desktop is back on two looks in a row; still the sign-in screen
///      (or anything else) after Watch is a failure. The service double-checks with Windows.
public sealed class LockScreenTypist
{
    public const ushort Space = 0x20, Enter = 0x0D;
    public const int ExtraBackspaces = 16;
    public static readonly TimeSpan Reach = TimeSpan.FromSeconds(8);
    public static readonly TimeSpan Settle = TimeSpan.FromSeconds(1);
    public static readonly TimeSpan Watch = TimeSpan.FromSeconds(8);
    public static readonly TimeSpan Poll = TimeSpan.FromMilliseconds(200);
    public static readonly TimeSpan BeforeEnter = TimeSpan.FromMilliseconds(80);
    private static readonly TimeSpan Nudge = TimeSpan.FromSeconds(1.5);

    private enum Phase { Reaching, Lifted, Watching, Finished }

    private readonly int _clear;
    private readonly DateTimeOffset _start;
    private Phase _phase = Phase.Reaching;
    private DateTimeOffset? _lastNudge;
    private DateTimeOffset? _watchFrom;
    private int _unlockedLooks;
    private int _exit;

    public LockScreenTypist(int passwordLength, DateTimeOffset start)
    {
        _clear = Math.Max(0, passwordLength) + ExtraBackspaces;
        _start = start;
    }

    public IReadOnlyList<TypistStep> Next(LockView view, DateTimeOffset now)
    {
        switch (_phase)
        {
            case Phase.Reaching:
                if (view == LockView.Unlocked) return Finish(TypistExit.NotLocked);
                if (now - _start >= Reach) return Finish(TypistExit.NoSignIn);
                if (view == LockView.SignIn)
                {
                    _phase = Phase.Lifted;
                    return new TypistStep[] { new TypistStep.Press(Space), new TypistStep.Wait(Settle) };
                }
                if (view == LockView.Picture && (_lastNudge is not { } last || now - last >= Nudge))
                {
                    _lastNudge = now;
                    return new TypistStep[] { new TypistStep.Press(Space), new TypistStep.Wait(Poll) };
                }
                return new TypistStep[] { new TypistStep.Wait(Poll) };

            case Phase.Lifted:
                if (view != LockView.SignIn)
                {
                    // The screen changed under us (back to the picture, or he unlocked it himself): start over.
                    _phase = Phase.Reaching;
                    _lastNudge = null;
                    return Next(view, now);
                }
                _phase = Phase.Watching;
                return new TypistStep[]
                {
                    new TypistStep.Clear(_clear), new TypistStep.TypePassword(), new TypistStep.Wait(BeforeEnter), new TypistStep.Press(Enter),
                };

            case Phase.Watching:
                _watchFrom ??= now;
                if (view == LockView.Unlocked)
                {
                    if (++_unlockedLooks >= 2) return Finish(TypistExit.Unlocked);
                }
                else _unlockedLooks = 0;
                if (now - _watchFrom.Value >= Watch) return Finish(TypistExit.NotTaken);
                return new TypistStep[] { new TypistStep.Wait(Poll) };

            default:
                return new TypistStep[] { new TypistStep.Done(_exit) };
        }
    }

    private TypistStep[] Finish(int exit)
    {
        _phase = Phase.Finished;
        _exit = exit;
        return new TypistStep[] { new TypistStep.Done(exit) };
    }
}

public enum ConsoleLock { Locked, Unlocked, Unknown }

/// The console session as the service reads it from Windows (WTS): which session, whether it's his
/// account's, connected (WTSActive), and its lock flag.
public sealed record ConsoleSession(uint Id, bool His, bool Active, ConsoleLock Lock)
{
    /// WTSGetActiveConsoleSessionId's "no session on the console" (during a session switch).
    public const uint None = 0xFFFFFFFF;
}

/// What the service answers once the typist has ended.
public static class UnlockOutcome
{
    public const string NotTaken = "Windows didn't take the PIN: the PC is still at the sign-in screen.";

    /// Nothing was typed: no point watching Windows for a change.
    public static bool Final(int? typistExit) =>
        typistExit is TypistExit.NotLocked or TypistExit.NoPassword or TypistExit.NoSignIn;

    /// Null when Windows unlocked; otherwise the error for `{"ok":false}`. `typistExit` is null when
    /// the typist didn't finish in time; `typistSession` is the console session it was started in.
    /// `signedOutBefore`: the console wasn't his before typing (the sign-in screen after a restart, or the one
    /// Remote Desktop leaves): then his session on the console, connected and flagged unlocked (not just "not
    /// locked": an unreadable flag proves nothing), is enough — it only gets there once Windows took the password,
    /// however long his profile takes to load past the typist's watch.
    public static string? Error(int? typistExit, uint typistSession, ConsoleSession console, bool signedOutBefore = false)
    {
        switch (typistExit)
        {
            case TypistExit.NotLocked: return "The PC isn't locked.";
            case TypistExit.NoPassword: return "No password was sent.";
            case TypistExit.NoSignIn: return "The sign-in screen didn't come up.";
        }
        if (signedOutBefore && console.Id != ConsoleSession.None && console.His && console.Active && console.Lock == ConsoleLock.Unlocked)
            return null;
        if (console.Id != typistSession)
        {
            // The console moved to another session: a PIN on the sign-in screen Remote Desktop leaves
            // reconnects his own session, and the sign-in session (the typist with it) ends. His session
            // connected on the console only happens after Windows took the PIN.
            if (console.Id != ConsoleSession.None && console.His && console.Active && console.Lock != ConsoleLock.Locked) return null;
        }
        else if (typistExit == TypistExit.Unlocked && console.His && console.Lock != ConsoleLock.Locked)
        {
            // The typist watched this very screen give way to his desktop, and Windows agrees.
            return null;
        }
        return typistExit switch
        {
            TypistExit.Unlocked or TypistExit.NotTaken => NotTaken,
            null => console.Id != typistSession ? NotTaken : "The lock screen didn't respond.",
            _ => console.Id != typistSession ? NotTaken : $"Typing on the lock screen failed ({typistExit}).",
        };
    }
}
