using System.IO.Compression;
using System.Net;
using Jarvis.Core.Http;
using Jarvis.Core.Update;
using Jarvis.Tests.Fakes;

namespace Jarvis.Tests.Update;

public class AppUpdaterTests
{
    private static (byte[] Zip, string Sha) MakeZip(long build)
    {
        var zip = Path.Combine(Tmp.Dir(), "JarvisWin.zip");
        ZipFile.CreateFromDirectory(UpdateTests.TmpZipRoot(build), zip);
        return (File.ReadAllBytes(zip), Sha256Check.Hash(zip));
    }

    private static HttpResponseMessage Bytes(byte[] b) => new(HttpStatusCode.OK) { Content = new ByteArrayContent(b) };

    private sealed record Launch(string Exe, string[] Args);

    private static (AppUpdater U, List<Launch> Launches, string Work, string App) Make(FakeHttp http, long current = 263100000)
    {
        var launches = new List<Launch>();
        var work = Tmp.Dir();
        var app = Path.Combine(Tmp.Dir(), "app");
        var u = new AppUpdater(new ApiClient(() => "http://o", http), new AppVersion("1.0.0", current), work, app,
            Path.Combine(work, "updater"), Path.Combine(work, "update.log"), 4242, (exe, args) => launches.Add(new Launch(exe, args)));
        return (u, launches, work, app);
    }

    [Fact]
    public async Task Check_AsksForOwnBuild_ReturnsNewerOffer()
    {
        var http = new FakeHttp(_ => FakeHttp.Json("{\"available\":true,\"platform\":\"windows\",\"build\":263200000,\"install_url\":\"https://v.example/JarvisWin.zip\",\"sha256\":\"" + new string('a', 64) + "\"}"));
        var (u, _, _, _) = Make(http);
        var offer = await u.CheckAsync();
        Assert.Equal(263200000, offer!.Build);
        Assert.Equal("/api/app-updates/latest?platform=windows&build=263100000", http.Requests[0].Path);
    }

    [Fact]
    public async Task Check_SameBuild_Null()
    {
        var http = new FakeHttp(_ => FakeHttp.Json("{\"available\":true,\"platform\":\"windows\",\"build\":263100000,\"install_url\":\"https://v.example/JarvisWin.zip\",\"sha256\":\"" + new string('a', 64) + "\"}"));
        Assert.Null(await Make(http).U.CheckAsync());
    }

    [Fact]
    public async Task Install_VerifiesStagesAndLaunchesUpdater()
    {
        var (zip, sha) = MakeZip(263200000);
        var http = new FakeHttp(_ => Bytes(zip));
        var (u, launches, work, app) = Make(http);
        var offer = new UpdateOffer(263200000, "1.0.1", "", zip.Length, new Uri("https://v.example/JarvisWin.zip"), sha);
        Assert.Null(await u.InstallAsync(offer));
        Assert.Equal("https://v.example/JarvisWin.zip", http.Requests[0].Uri);
        var l = Assert.Single(launches);
        Assert.Equal(Path.Combine(work, "updater", "JarvisUpdater.exe"), l.Exe);
        Assert.True(File.Exists(l.Exe));
        Assert.Equal(new[] { "--pid", "4242", "--app", app, "--new", Path.Combine(work, "staged", "Jarvis"), "--exe", "Jarvis.exe", "--log", Path.Combine(work, "update.log") }, l.Args);
    }

    [Fact]
    public async Task Install_ShaMismatch_NoLaunch()
    {
        var (zip, _) = MakeZip(263200000);
        var (u, launches, _, _) = Make(new FakeHttp(_ => Bytes(zip)));
        var offer = new UpdateOffer(263200000, "1.0.1", "", zip.Length, new Uri("https://v.example/JarvisWin.zip"), new string('0', 64));
        Assert.Equal("The download doesn't match the server's checksum.", await u.InstallAsync(offer));
        Assert.Empty(launches);
    }

    [Fact]
    public async Task Install_WrongBuildInside_NoLaunch()
    {
        var (zip, sha) = MakeZip(263100000);
        var (u, launches, _, _) = Make(new FakeHttp(_ => Bytes(zip)));
        var offer = new UpdateOffer(263200000, "1.0.1", "", zip.Length, new Uri("https://v.example/JarvisWin.zip"), sha);
        Assert.Equal("The download is build 263100000, not the offered 263200000.", await u.InstallAsync(offer));
        Assert.Empty(launches);
    }
}
