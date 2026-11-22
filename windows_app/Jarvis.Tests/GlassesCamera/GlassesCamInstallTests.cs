using Jarvis.Core.GlassesCamera;

namespace Jarvis.Tests.GlassesCamera;

/// Settings → Glasses camera: what state the camera is in, and why an install failed, in his words.
public class GlassesCamInstallTests
{
    private static readonly DateTimeOffset At = new(2026, 11, 22, 12, 0, 0, TimeSpan.Zero);

    private static GlassesCamInstallFacts Facts(bool registered = true, bool frames = true, bool listed = true,
        GlassesCamInstallResult? last = null, string? working = null) => new(registered, frames, listed, last, working);

    [Fact]
    public void StateIsInstalledWhenTheCameraIsListed()
    {
        Assert.IsType<GlassesCamInstallState.Installed>(GlassesCamInstall.State(Facts()));
        // An old failure doesn't hide a camera that's there now.
        Assert.IsType<GlassesCamInstallState.Installed>(GlassesCamInstall.State(Facts(last: new(false, "install", "start", unchecked((int)0x80070005), null, At))));
    }

    [Fact]
    public void NothingThereIsNotInstalled()
    {
        Assert.IsType<GlassesCamInstallState.NotInstalled>(GlassesCamInstall.State(Facts(false, false, false)));
        Assert.IsType<GlassesCamInstallState.NotInstalled>(GlassesCamInstall.State(Facts(false, false, false, new(true, "remove", "", null, null, At))));
    }

    [Fact]
    public void WorkingWinsWhileTheAdminStepRuns() =>
        Assert.Equal(new GlassesCamInstallState.Working("Installing…"), GlassesCamInstall.State(Facts(false, false, false, working: "Installing…")));

    [Fact]
    public void AFailedInstallSaysWhy()
    {
        var s = Assert.IsType<GlassesCamInstallState.Failed>(GlassesCamInstall.State(
            Facts(true, true, false, new(false, "install", "start", unchecked((int)0x80070005), null, At))));
        Assert.Contains("camera service", s.Why);
    }

    [Fact]
    public void HalfInstalledSaysReinstall()
    {
        // Listed but its code is gone (files deleted), or registered but Windows doesn't list it.
        Assert.Contains("Reinstall", Assert.IsType<GlassesCamInstallState.Failed>(GlassesCamInstall.State(Facts(registered: false))).Why);
        Assert.Contains("Reinstall", Assert.IsType<GlassesCamInstallState.Failed>(GlassesCamInstall.State(Facts(listed: false))).Why);
        Assert.Contains("Reinstall", Assert.IsType<GlassesCamInstallState.Failed>(GlassesCamInstall.State(Facts(frames: false))).Why);
    }

    [Fact]
    public void AccessDeniedOnStartExplainsTheFolderPermission()
    {
        var why = GlassesCamInstall.Explain(new(false, "install", "start", unchecked((int)0x80070005), null, At));
        Assert.Contains("camera service", why);
        Assert.Contains("Reinstall", why);
        Assert.DoesNotContain("0x", why);
        Assert.DoesNotContain("80070005", why);
    }

    [Fact]
    public void ClassNotRegisteredSaysReinstall()
    {
        var why = GlassesCamInstall.Explain(new(false, "install", "start", unchecked((int)0x80040154), null, At));
        Assert.Contains("Reinstall", why);
        Assert.DoesNotContain("0x", why);
    }

    [Fact]
    public void EveryFailureIsInWords()
    {
        foreach (var hr in new uint[] { 0x80070002, 0x80008096, 0x800080A3, 0xC00D36B2, 0x80004005, 0x12345678 })
        {
            var why = GlassesCamInstall.Explain(new(false, "install", "start", unchecked((int)hr), null, At));
            Assert.False(string.IsNullOrWhiteSpace(why));
            Assert.DoesNotContain("0x", why);
            Assert.DoesNotContain(hr.ToString("X8"), why, StringComparison.OrdinalIgnoreCase);
        }
        Assert.Contains("Windows 11", GlassesCamInstall.Explain(new(false, "install", "create", null, "unsupported", At)));
        Assert.Contains(".NET 8", GlassesCamInstall.Explain(new(false, "install", "start", unchecked((int)0x80008096), null, At)));
        Assert.Contains("register", GlassesCamInstall.Explain(new(false, "install", "register", null, "regsvr32 exited 3", At)));
        Assert.Contains("copy", GlassesCamInstall.Explain(new(false, "install", "copy", null, "in use", At)));
    }

    [Fact]
    public void ResultFileParses()
    {
        var r = GlassesCamInstallResult.Parse("{\"ok\":false,\"action\":\"install\",\"step\":\"start\",\"hr\":-2147024891,\"error\":\"Access is denied.\",\"at\":\"2026-11-22T12:00:00Z\"}");
        Assert.Equal(new GlassesCamInstallResult(false, "install", "start", unchecked((int)0x80070005), "Access is denied.", At), r);
        Assert.True(GlassesCamInstallResult.Parse("{\"ok\":true,\"action\":\"remove\",\"at\":\"2026-11-22T12:00:00Z\"}")!.Ok);
        Assert.Null(GlassesCamInstallResult.Parse("not json"));
        Assert.Null(GlassesCamInstallResult.Parse("[]"));
    }

    [Fact]
    public void TheInstallCommandQuotesItsPaths()
    {
        var dir = @"C:\Users\krish\AppData\Local\Programs\Jarvis\app\GlassesCamera";
        Assert.Equal($"powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"{dir}\\glasses-camera.ps1\" -From \"{dir}\"",
            GlassesCamInstall.Command(dir, remove: false));
        Assert.EndsWith(" -Remove", GlassesCamInstall.Command(dir, remove: true));
    }
}
