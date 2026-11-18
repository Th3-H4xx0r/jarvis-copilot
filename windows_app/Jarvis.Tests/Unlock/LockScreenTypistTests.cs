using Jarvis.Core.Unlock;
using Jarvis.Tests.Fakes;
using static Jarvis.Core.Unlock.TypistStep;

namespace Jarvis.Tests.Unlock;

public class LockScreenTypistTests
{
    private static DateTimeOffset At(double s) => TestClock.T0.AddSeconds(s);
    private static LockScreenTypist New(int passwordLength = 6) => new(passwordLength, At(0));

    /// Runs the typist to the point where it has typed and pressed Enter (first look: sign-in screen).
    private static LockScreenTypist Typed(double at = 1.2)
    {
        var t = New();
        t.Next(LockView.SignIn, At(0));
        Assert.Contains(t.Next(LockView.SignIn, At(at)), s => s is TypePassword);
        return t;
    }

    [Fact]
    public void FirstLookAtSignInScreen_LiftsWaitsClearsThenTypes()
    {
        var t = New(passwordLength: 6);
        // The fresh sign-in screen a Remote Desktop session leaves shows its picture with no LockApp:
        // a non-typing lift first, then a wait for the PIN box, never typing straight away.
        Assert.Equal(new TypistStep[] { new Press(LockScreenTypist.Space), new Wait(LockScreenTypist.Settle) }, t.Next(LockView.SignIn, At(0)));
        Assert.Equal(new TypistStep[]
        {
            new Clear(6 + LockScreenTypist.ExtraBackspaces), new TypePassword(), new Wait(LockScreenTypist.BeforeEnter), new Press(LockScreenTypist.Enter),
        }, t.Next(LockView.SignIn, At(1.1)));
    }

    [Fact]
    public void LeftoverPinDialog_IsDismissedBeforeTyping()
    {
        // A failed try leaves "Please enter your PIN" with its OK button focused (the screen still reads
        // as the sign-in screen). The first key presses OK (Space), and Enter never comes before the
        // password: an Enter on the empty box is what raises that dialog.
        var t = New();
        var steps = t.Next(LockView.SignIn, At(0)).Concat(t.Next(LockView.SignIn, At(1.1))).ToList();
        var dismiss = steps.FindIndex(s => s is Press p && p.Vk == LockScreenTypist.Space);
        var settle = steps.FindIndex(s => s is Wait w && w.For >= TimeSpan.FromSeconds(1));
        var clear = steps.FindIndex(s => s is Clear);
        var type = steps.FindIndex(s => s is TypePassword);
        var enter = steps.FindIndex(s => s is Press p && p.Vk == LockScreenTypist.Enter);
        Assert.True(dismiss == 0 && dismiss < settle && settle < clear && clear < type && type < enter,
            string.Join(", ", steps));
    }

    [Fact]
    public void EnterThenStillOnSignInScreen_FailsAsNotTaken()
    {
        var t = Typed(at: 1.2);
        Assert.Equal(new TypistStep[] { new Wait(LockScreenTypist.Poll) }, t.Next(LockView.SignIn, At(1.5)));
        Assert.Equal(new TypistStep[] { new Wait(LockScreenTypist.Poll) }, t.Next(LockView.SignIn, At(9.0)));
        Assert.Equal(new TypistStep[] { new Done(TypistExit.NotTaken) }, t.Next(LockView.SignIn, At(9.6)));
    }

    [Fact]
    public void EnterThenUnlocked_Succeeds()
    {
        var t = Typed();
        t.Next(LockView.SignIn, At(1.5));
        Assert.Equal(new TypistStep[] { new Wait(LockScreenTypist.Poll) }, t.Next(LockView.Unlocked, At(2.5)));
        Assert.Equal(new TypistStep[] { new Done(TypistExit.Unlocked) }, t.Next(LockView.Unlocked, At(2.8)));
    }

    [Fact]
    public void OneUnlockedFlashAfterEnter_IsNotASuccess()
    {
        var t = Typed();
        t.Next(LockView.SignIn, At(1.5));
        t.Next(LockView.Unlocked, At(2.0));
        t.Next(LockView.SignIn, At(2.3));
        t.Next(LockView.Unlocked, At(3.0));
        Assert.Equal(new TypistStep[] { new Done(TypistExit.NotTaken) }, t.Next(LockView.Picture, At(9.6)));
    }

    [Fact]
    public void UnknownScreenAfterEnter_IsNotASuccess()
    {
        var t = Typed();
        t.Next(LockView.Unknown, At(1.5));
        Assert.Equal(new TypistStep[] { new Done(TypistExit.NotTaken) }, t.Next(LockView.Unknown, At(9.6)));
    }

    [Fact]
    public void LockScreenPicture_SpacePacedThenSignInScreenFlow()
    {
        var t = New();
        Assert.Equal(new TypistStep[] { new Press(LockScreenTypist.Space), new Wait(LockScreenTypist.Poll) }, t.Next(LockView.Picture, At(0)));
        Assert.Equal(new TypistStep[] { new Wait(LockScreenTypist.Poll) }, t.Next(LockView.Picture, At(0.5)));
        Assert.Equal(new TypistStep[] { new Press(LockScreenTypist.Space), new Wait(LockScreenTypist.Poll) }, t.Next(LockView.Picture, At(1.6)));
        Assert.Equal(new TypistStep[] { new Press(LockScreenTypist.Space), new Wait(LockScreenTypist.Settle) }, t.Next(LockView.SignIn, At(1.9)));
        Assert.Contains(t.Next(LockView.SignIn, At(3.0)), s => s is TypePassword);
    }

    [Fact]
    public void NotLocked_PressesNothing()
    {
        Assert.Equal(new TypistStep[] { new Done(TypistExit.NotLocked) }, New().Next(LockView.Unlocked, At(0)));
    }

    [Fact]
    public void HeUnlocksItHimselfAfterTheLift_TypesNothing()
    {
        var t = New();
        t.Next(LockView.SignIn, At(0));
        Assert.Equal(new TypistStep[] { new Done(TypistExit.NotLocked) }, t.Next(LockView.Unlocked, At(1.1)));
    }

    [Fact]
    public void SignInScreenNeverComes_GivesUpWithoutTyping()
    {
        var t = New();
        var steps = new List<TypistStep>();
        for (var s = 0.0; s < 8; s += 0.5) steps.AddRange(t.Next(LockView.Unknown, At(s)));
        Assert.DoesNotContain(steps, x => x is Press or TypePassword);
        Assert.Equal(new TypistStep[] { new Done(TypistExit.NoSignIn) }, t.Next(LockView.Unknown, At(8.1)));
    }

    [Fact]
    public void ScreenFallsBackToThePictureAfterTheLift_StartsOver()
    {
        var t = New();
        t.Next(LockView.SignIn, At(0));
        Assert.Equal(new TypistStep[] { new Press(LockScreenTypist.Space), new Wait(LockScreenTypist.Poll) }, t.Next(LockView.Picture, At(1.1)));
        Assert.Equal(new TypistStep[] { new Press(LockScreenTypist.Space), new Wait(LockScreenTypist.Settle) }, t.Next(LockView.SignIn, At(1.4)));
        Assert.Contains(t.Next(LockView.SignIn, At(2.5)), s => s is TypePassword);
    }

    [Fact]
    public void AfterDone_KeepsSayingDone()
    {
        var t = New();
        t.Next(LockView.Unlocked, At(0));
        Assert.Equal(new TypistStep[] { new Done(TypistExit.NotLocked) }, t.Next(LockView.SignIn, At(0.5)));
    }
}
