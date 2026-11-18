using Jarvis.Core.Unlock;

namespace Jarvis.Tests.Unlock;

/// The service's answer after the typist ends: success only when Windows says his session is back.
public class UnlockOutcomeTests
{
    private const uint Typist = 3;   // the console session the typist was started in
    private static ConsoleSession His(uint id, ConsoleLock l = ConsoleLock.Unlocked, bool active = true) => new(id, true, active, l);
    private static ConsoleSession SignInScreen(uint id) => new(id, false, true, ConsoleLock.Unknown);

    [Fact]
    public void SameSession_TypistSawItUnlock_WindowsAgrees_Unlocked()
    {
        Assert.Null(UnlockOutcome.Error(TypistExit.Unlocked, Typist, His(Typist)));
        Assert.Null(UnlockOutcome.Error(TypistExit.Unlocked, Typist, His(Typist, ConsoleLock.Unknown)));
    }

    [Fact]
    public void SameSession_StillOnTheSignInScreen_NotTaken()
    {
        Assert.Equal(UnlockOutcome.NotTaken, UnlockOutcome.Error(TypistExit.NotTaken, Typist, His(Typist, ConsoleLock.Locked)));
        // Windows' word alone doesn't beat what the typist watched on this very screen
        Assert.Equal(UnlockOutcome.NotTaken, UnlockOutcome.Error(TypistExit.NotTaken, Typist, His(Typist)));
    }

    [Fact]
    public void SameSession_TypistSawUnlock_ButWindowsSaysLocked_NotTaken()
    {
        Assert.Equal(UnlockOutcome.NotTaken, UnlockOutcome.Error(TypistExit.Unlocked, Typist, His(Typist, ConsoleLock.Locked)));
        Assert.Equal(UnlockOutcome.NotTaken, UnlockOutcome.Error(TypistExit.Unlocked, Typist, SignInScreen(Typist)));
    }

    [Fact]
    public void AfterRemoteDesktop_ConsoleMovedToHisSession_Unlocked()
    {
        // The sign-in screen an RDP session leaves is its own session: the PIN reconnects his session to
        // the console and that sign-in session (with the typist in it) ends.
        Assert.Null(UnlockOutcome.Error(null, Typist, His(2)));
        Assert.Null(UnlockOutcome.Error(TypistExit.NotTaken, Typist, His(2)));
        Assert.Null(UnlockOutcome.Error(unchecked((int)0xC000013A), Typist, His(2, ConsoleLock.Unknown)));
    }

    [Fact]
    public void ConsoleMoved_ButNotToHimOrNotUnlocked_Fails()
    {
        Assert.Equal(UnlockOutcome.NotTaken, UnlockOutcome.Error(TypistExit.NotTaken, Typist, SignInScreen(4)));
        Assert.Equal(UnlockOutcome.NotTaken, UnlockOutcome.Error(TypistExit.Unlocked, Typist, His(2, ConsoleLock.Locked)));
        Assert.Equal(UnlockOutcome.NotTaken, UnlockOutcome.Error(TypistExit.NotTaken, Typist, His(2, active: false)));
        Assert.Equal(UnlockOutcome.NotTaken, UnlockOutcome.Error(TypistExit.NotTaken, Typist, new ConsoleSession(ConsoleSession.None, false, false, ConsoleLock.Unknown)));
    }

    [Fact]
    public void NothingTyped_SaysWhyAndIsFinal()
    {
        Assert.Equal("The PC isn't locked.", UnlockOutcome.Error(TypistExit.NotLocked, Typist, His(Typist)));
        Assert.Equal("The sign-in screen didn't come up.", UnlockOutcome.Error(TypistExit.NoSignIn, Typist, His(2)));
        Assert.Equal("No password was sent.", UnlockOutcome.Error(TypistExit.NoPassword, Typist, His(2)));
        Assert.True(UnlockOutcome.Final(TypistExit.NotLocked) && UnlockOutcome.Final(TypistExit.NoSignIn) && UnlockOutcome.Final(TypistExit.NoPassword));
        Assert.False(UnlockOutcome.Final(TypistExit.Unlocked) || UnlockOutcome.Final(TypistExit.NotTaken) || UnlockOutcome.Final(null));
    }

    [Fact]
    public void TypistTimedOutOrCrashed_StillLocked_SaysSo()
    {
        Assert.Equal("The lock screen didn't respond.", UnlockOutcome.Error(null, Typist, SignInScreen(Typist)));
        Assert.Equal("Typing on the lock screen failed (1).", UnlockOutcome.Error(1, Typist, SignInScreen(Typist)));
    }

    [Fact]
    public void NotTaken_TellsHimWindowsDidntTakeIt()
    {
        Assert.Contains("didn't take the PIN", UnlockOutcome.NotTaken);
        Assert.NotEqual(TypistExit.NotTaken, TypistExit.Unlocked);
        Assert.DoesNotContain(TypistExit.NotTaken, new[] { TypistExit.Unlocked, TypistExit.NotLocked, TypistExit.NoPassword, TypistExit.NoSignIn });
    }

    // ── the helper's pipe reply, as the app reads it ────────────────────

    [Fact]
    public void HelperReply_CheckedOk_IsUnlocked()
    {
        Assert.Null(UnlockReply.Error(J("{\"ok\":true,\"checked\":true}")));
    }

    [Fact]
    public void HelperReply_NotOk_CarriesItsError()
    {
        Assert.Equal(UnlockOutcome.NotTaken, UnlockReply.Error(J("{\"ok\":false,\"error\":\"" + UnlockOutcome.NotTaken + "\"}")));
        Assert.Equal("The unlock helper didn't type it.", UnlockReply.Error(J("{\"ok\":false}")));
        Assert.Equal("The unlock helper didn't type it.", UnlockReply.Error(J("{}")));
    }

    [Fact]
    public void HelperReply_OkWithoutACheck_FromAnOlderHelper_IsAFailure()
    {
        var e = UnlockReply.Error(J("{\"ok\":true}"));
        Assert.NotNull(e);
        Assert.Contains("Settings", e);
        Assert.NotNull(UnlockReply.Error(J("{\"ok\":\"true\",\"checked\":true}")));
    }

    private static JsonObject J(string s) => JsonNode.Parse(s)!.AsObject();
}
