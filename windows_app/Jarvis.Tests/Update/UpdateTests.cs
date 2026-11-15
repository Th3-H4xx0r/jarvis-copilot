using System.IO.Compression;
using System.Security.Cryptography;
using Jarvis.Core.Link;
using Jarvis.Core.Update;
using Jarvis.Tests.Fakes;
using static Jarvis.Tests.Fakes.TestClock;

namespace Jarvis.Tests.Update;

public class UpdateTests
{
    private static readonly string Sha = new('a', 64);

    [Fact]
    public void Offer_RequiresHttpsShaAndWindows()
    {
        Assert.NotNull(UpdateOffer.FromJson(J.Parse("{\"available\":true,\"platform\":\"windows\",\"build\":263200000,\"version\":\"1.0.1\",\"install_url\":\"https://v.example/ota/d/t/JarvisWin.zip\",\"sha256\":\"" + Sha + "\"}")));
        Assert.Null(UpdateOffer.FromJson(J.Parse("{\"available\":true,\"platform\":\"windows\",\"build\":263200000,\"install_url\":\"http://x/JarvisWin.zip\",\"sha256\":\"" + Sha + "\"}")));
        Assert.Null(UpdateOffer.FromJson(J.Parse("{\"available\":true,\"platform\":\"mac\",\"build\":263200000,\"install_url\":\"https://x/Jarvis.zip\",\"sha256\":\"" + Sha + "\"}")));
        Assert.Null(UpdateOffer.FromJson(J.Parse("{\"available\":true,\"platform\":\"windows\",\"build\":263200000,\"install_url\":\"https://x/JarvisWin.zip\"}")));
    }

    [Fact]
    public void Offer_ReadsFields_AndRejectsUnavailable()
    {
        var o = UpdateOffer.FromJson(J.Parse("{\"available\":true,\"platform\":\"windows\",\"build\":263200000,\"version\":\"1.0.1\",\"notes\":\" • fixes \\n\",\"size\":1234,\"install_url\":\"https://v.example/JarvisWin.zip\",\"sha256\":\"" + new string('A', 64) + "\"}"))!;
        Assert.Equal(263200000, o.Build);
        Assert.Equal("1.0.1", o.Version);
        Assert.Equal("• fixes", o.Notes);
        Assert.Equal(1234, o.Size);
        Assert.Equal(new string('a', 64), o.Sha256);
        Assert.Null(UpdateOffer.FromJson(J.Parse("{\"available\":false,\"platform\":\"windows\",\"build\":2,\"install_url\":\"https://x/a.zip\",\"sha256\":\"" + Sha + "\"}")));
        Assert.Null(UpdateOffer.FromJson(J.Parse("{\"available\":true,\"platform\":\"windows\",\"build\":0,\"install_url\":\"https://x/a.zip\",\"sha256\":\"" + Sha + "\"}")));
    }

    [Fact]
    public void LatestPath() => Assert.Equal("/api/app-updates/latest?platform=windows&build=263190000", UpdateOffer.LatestPath(263190000));

    [Fact]
    public void Gate_LaterHidesSameBuild_NewerShows_ActivationAfter15Min()
    {
        var g = new UpdateGate();
        Assert.True(g.ShouldShow(5, UpdateGate.Trigger.Poll, T0));
        g.Later(5, T0);
        Assert.False(g.ShouldShow(5, UpdateGate.Trigger.Poll, T0.AddHours(1)));
        Assert.False(g.ShouldShow(5, UpdateGate.Trigger.Push, T0.AddHours(1)));
        Assert.False(g.ShouldShow(5, UpdateGate.Trigger.Activation, T0.AddMinutes(14)));
        Assert.True(g.ShouldShow(5, UpdateGate.Trigger.Activation, T0.AddMinutes(15)));
        Assert.True(g.ShouldShow(6, UpdateGate.Trigger.Poll, T0.AddMinutes(1)));
    }

    [Fact]
    public void Sha_Mismatch_False()
    {
        var p = Tmp.File("hello", "a.zip");
        var hex = Convert.ToHexString(SHA256.HashData("hello"u8)).ToLowerInvariant();
        Assert.True(Sha256Check.Matches(p, hex));
        Assert.True(Sha256Check.Matches(p, hex.ToUpperInvariant()));
        Assert.False(Sha256Check.Matches(p, new string('0', 64)));
        Assert.False(Sha256Check.Matches(Path.Combine(Tmp.Dir(), "missing.zip"), hex));
    }

    internal static string TmpZipRoot(long build, bool withUpdater = true)
    {
        var root = Tmp.Dir();
        var j = Directory.CreateDirectory(Path.Combine(root, "Jarvis")).FullName;
        File.WriteAllText(Path.Combine(j, "Jarvis.exe"), "x");
        if (withUpdater) File.WriteAllText(Path.Combine(j, "JarvisUpdater.exe"), "x");
        File.WriteAllText(Path.Combine(j, "version.json"), "{\"version\":\"1.0.1\",\"build\":" + build + "}");
        return root;
    }

    [Fact]
    public void ZipLayout_WrongBuild() => Assert.Equal("The download is build 263100000, not the offered 263200000.", ZipLayout.Problem(TmpZipRoot(263100000), 263200000));

    [Fact]
    public void ZipLayout_Good_AndMissingUpdater()
    {
        Assert.Null(ZipLayout.Problem(TmpZipRoot(263200000), 263200000));
        Assert.Equal("The download has no Jarvis/JarvisUpdater.exe.", ZipLayout.Problem(TmpZipRoot(263200000, withUpdater: false), 263200000));
    }

    [Fact]
    public void ZipLayout_ExtractsAZipWithJarvisRoot()
    {
        var src = TmpZipRoot(263200000);
        var zip = Path.Combine(Tmp.Dir(), "JarvisWin.zip");
        ZipFile.CreateFromDirectory(src, zip);
        var dest = Path.Combine(Tmp.Dir(), "staged");
        ZipLayout.Extract(zip, dest);
        Assert.Null(ZipLayout.Problem(dest, 263200000));
    }

    [Fact]
    public void Version_MissingFile_IsBuild1_NeverOffered()
    {
        var v = AppVersion.Read(Tmp.Dir());
        Assert.Equal(new AppVersion("0.0.0", 1), v);
        Assert.False(UpdateOffer.IsNewer(1, v.Build));
        Assert.True(UpdateOffer.IsNewer(263200000, v.Build));
    }

    [Fact]
    public void Version_ReadsFile()
    {
        var d = Tmp.Dir();
        File.WriteAllText(Path.Combine(d, "version.json"), "{\"version\":\"1.2.3\",\"build\":263200000}");
        Assert.Equal(new AppVersion("1.2.3", 263200000), AppVersion.Read(d));
    }

    [Fact]
    public void BuildStamp_IsYyDddHHmm() =>
        Assert.Equal(263191200, AppVersion.BuildStamp(new DateTimeOffset(2026, 11, 15, 12, 0, 0, TimeSpan.Zero)));
}
