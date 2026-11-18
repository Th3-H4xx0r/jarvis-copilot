using Jarvis.Core.Model;
using Jarvis.Core.Screen;
using Jarvis.Tests.Fakes;

namespace Jarvis.Tests.Screen;

public class ShareGameGraceTests
{
    private static DateTimeOffset At(double s) => TestClock.T0.AddSeconds(s);
    private static readonly GameMode Fullscreen = new(true, "fullscreen textinputhost.exe", false);

    [Fact]
    public void NotInAGame_Keeps()
    {
        Assert.IsType<ShareGameGrace.Keep>(new ShareGameGrace().Observe(GameMode.Off, At(0)));
    }

    [Fact]
    public void Fullscreen_WaitsOutTheGraceThenEnds()
    {
        var g = new ShareGameGrace();
        Assert.Equal(new ShareGameGrace.Wait(ShareGameGrace.Window), g.Observe(Fullscreen, At(0)));
        Assert.Equal(new ShareGameGrace.Wait(TimeSpan.FromSeconds(2)), g.Observe(Fullscreen, At(3)));
        var end = Assert.IsType<ShareGameGrace.End>(g.Observe(Fullscreen, At(5)));
        Assert.Contains("textinputhost.exe", end.Refusal);
    }

    [Fact]
    public void AFlickerOff_StartsTheGraceAgain()
    {
        var g = new ShareGameGrace();
        g.Observe(Fullscreen, At(0));
        Assert.IsType<ShareGameGrace.Keep>(g.Observe(GameMode.Off, At(2)));
        Assert.Equal(new ShareGameGrace.Wait(ShareGameGrace.Window), g.Observe(Fullscreen, At(3)));
        Assert.IsType<ShareGameGrace.Wait>(g.Observe(Fullscreen, At(7.9)));
        Assert.IsType<ShareGameGrace.End>(g.Observe(Fullscreen, At(8)));
    }

    [Fact]
    public void AnotherFullscreenAppWhileStillOn_KeepsCounting()
    {
        var g = new ShareGameGrace();
        g.Observe(Fullscreen, At(0));
        Assert.IsType<ShareGameGrace.End>(g.Observe(new GameMode(true, "fullscreen game.exe", false), At(5)));
    }

    [Fact]
    public void AntiCheatGame_EndsAtOnce()
    {
        var end = Assert.IsType<ShareGameGrace.End>(new ShareGameGrace().Observe(new GameMode(false, "VALORANT-Win64-Shipping.exe", true), At(0)));
        Assert.Contains("VALORANT", end.Refusal);
        Assert.IsType<ShareGameGrace.End>(new ShareGameGrace().Observe(new GameMode(true, "VALORANT-Win64-Shipping.exe", true), At(0)));
    }
}

public class ShareReadinessTests
{
    [Fact]
    public void OnTheConsole_Ready() => Assert.Null(ShareReadiness.Refusal(onConsole: true, remoteSession: false));

    [Fact]
    public void SessionOffTheConsoleAfterRemoteDesktop_SaysUnlockFirst()
    {
        Assert.Equal(ShareReadiness.SignInScreen, ShareReadiness.Refusal(onConsole: false, remoteSession: false));
        Assert.Contains("sign-in screen", ShareReadiness.SignInScreen);
    }

    [Fact]
    public void ShownOverRemoteDesktop_SaysSo() =>
        Assert.Equal(ShareReadiness.RemoteDesktop, ShareReadiness.Refusal(onConsole: false, remoteSession: true));

    [Fact]
    public void CaptureThatThrows_SaysWhy()
    {
        Assert.Equal(ShareReadiness.SignInScreen, ShareReadiness.CaptureFailure(onConsole: false, remoteSession: false));
        Assert.Equal(ShareReadiness.CaptureRefused, ShareReadiness.CaptureFailure(onConsole: true, remoteSession: false));
    }
}
