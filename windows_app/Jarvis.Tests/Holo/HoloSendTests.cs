using System.Net;
using System.Net.Http;
using System.Text;
using Jarvis.Core.Holo;
using Jarvis.Core.Http;
using Jarvis.Core.Link;
using Jarvis.Core.Model;
using Jarvis.Core.Platform;
using Jarvis.Core.Ui;
using Jarvis.Tests.Fakes;

namespace Jarvis.Tests.Holo;

public sealed class FakeFrontProbe : IHoloFrontProbe
{
    public FrontWindow? Window { get; set; }
    public string? Url { get; set; }
    public List<string> Selection { get; set; } = new();
    public string? Document { get; set; }
    public string? Selected { get; set; }
    public List<string> Asked { get; } = new();

    public FrontWindow? Front() => Window;
    public string? BrowserUrl(FrontWindow w) { Asked.Add("url"); return Url; }
    public IReadOnlyList<string> ExplorerSelection(IntPtr hwnd) { Asked.Add("explorer"); return Selection; }
    public string? DocumentPath(FrontWindow w) { Asked.Add("doc"); return Document; }
    public string? SelectedText(FrontWindow w) { Asked.Add("text"); return Selected; }
}

public class HoloSendTests
{
    private static FrontWindow Win(string exe, string title = "") => new(exe, exe, 42, (IntPtr)7, title, null);

    [Fact]
    public void Grab_BrowserFirst()
    {
        var p = new FakeFrontProbe { Window = Win("chrome.exe", "x/y: the repo - Google Chrome"), Url = "github.com/x", Selected = "some text" };
        Assert.Equal(HoloItem.Link("https://github.com/x", "x/y: the repo"), HoloGrab.Grab(p, _ => true));
        var edge = new FakeFrontProbe { Window = Win("msedge.exe", "Docs"), Url = "http://intranet.local/page" };
        Assert.Equal(HoloItem.Link("http://intranet.local/page", "Docs"), HoloGrab.Grab(edge, _ => true));
    }

    [Fact]
    public void Grab_ExplorerSelectionWhenNoBrowser()
    {
        var p = new FakeFrontProbe
        {
            Window = Win("explorer.exe"),
            Selection = new() { @"C:\Users\p\a.png", @"C:\Users\p\gone.txt", "  " },
            Selected = "ignored",
        };
        Assert.Equal(HoloItem.Files(new[] { @"C:\Users\p\a.png" }), HoloGrab.Grab(p, path => path.EndsWith("a.png")));
        Assert.DoesNotContain("url", p.Asked);
    }

    [Fact]
    public void Grab_FrontDocument()
    {
        var p = new FakeFrontProbe { Window = Win("winword.exe"), Document = @"C:\Docs\plan.docx", Selected = "x" };
        Assert.Equal(HoloItem.Files(new[] { @"C:\Docs\plan.docx" }), HoloGrab.Grab(p, _ => true));
        var url = new FakeFrontProbe { Window = Win("notepad.exe"), Document = "file:///C:/Docs/a.txt" };
        Assert.Equal(HoloItem.Files(new[] { "C:/Docs/a.txt" }), HoloGrab.Grab(url, _ => true));
    }

    [Fact]
    public void Grab_SelectedTextLast()
    {
        var p = new FakeFrontProbe { Window = Win("notepad.exe"), Document = @"C:\missing.txt", Selected = "  hello world  " };
        Assert.Equal(HoloItem.Text("hello world"), HoloGrab.Grab(p, _ => false));
        var link = new FakeFrontProbe { Window = Win("notepad.exe"), Selected = "https://a.com/b" };
        Assert.Equal(HoloItem.Link("https://a.com/b"), HoloGrab.Grab(link, _ => false));
    }

    [Fact]
    public void Grab_NothingReturnsNull()
    {
        Assert.Null(HoloGrab.Grab(new FakeFrontProbe(), _ => true));
        Assert.Null(HoloGrab.Grab(new FakeFrontProbe { Window = Win("chrome.exe"), Url = "chrome://settings" }, _ => true));
        Assert.Null(HoloGrab.Grab(new FakeFrontProbe { Window = Win("notepad.exe"), Selected = "   " }, _ => true));
    }

    [Fact]
    public void Fling_FastLongDragGivesAngle()
    {
        var f = new FlingDetector();
        f.Down(0, new(0, 0));
        f.Move(0.05, new(100, 0));
        Assert.Equal(0, f.Up(0.1, new(200, 0))!.Value, 1);
    }

    [Fact]
    public void Fling_SlowDragIsNotAFling()
    {
        var f = new FlingDetector();
        f.Down(0, new(0, 0));
        Assert.Null(f.Up(1.0, new(200, 0)));
    }

    [Fact]
    public void Fling_ShortDragIsNotAFling()
    {
        var f = new FlingDetector();
        f.Down(0, new(0, 0));
        Assert.Null(f.Up(0.01, new(100, 0)));
        Assert.Null(new FlingDetector().Up(1, new(500, 0)));   // no Down
    }

    [Fact]
    public void Fling_UpwardIs90()
    {
        var f = new FlingDetector();
        f.Down(0, new(0, 0));
        Assert.Equal(90, f.Up(0.1, new(0, -300))!.Value, 1);
        var g = new FlingDetector();
        g.Down(0, new(0, 0));
        Assert.Equal(225, g.Up(0.1, new(-300, 300))!.Value, 1);
    }

    [Fact]
    public void Fling_SlowStartFastFinishCounts()
    {
        var f = new FlingDetector();
        f.Down(0, new(0, 0));
        f.Move(1.0, new(10, 0));
        f.Move(1.05, new(100, 0));
        Assert.Equal(0, f.Up(1.1, new(200, 0))!.Value, 1);
    }

    [Fact]
    public void Orbit_PickNearestWithin35()
    {
        var a = new HoloDevice("a", "iPhone", "iphone");
        var b = new HoloDevice("b", "iPad", "ipad");
        var c = new HoloDevice("c", "Web", "web");
        var placed = HoloOrbitLayout.Place(new[] { a, b, c });
        // Spread evenly from the top, clockwise: 90 (up), 330, 210 in fling degrees.
        Assert.Equal(90, placed[0].AngleDeg, 6);
        Assert.Equal(330, placed[1].AngleDeg, 6);
        Assert.Equal(210, placed[2].AngleDeg, 6);
        Assert.Equal("a", HoloOrbitLayout.Pick(100, placed)!.Id);
        Assert.Equal("b", HoloOrbitLayout.Pick(-20, placed)!.Id);
        Assert.Null(HoloOrbitLayout.Pick(150, placed));
        Assert.Equal("c", HoloOrbitLayout.Pick(240, placed, maxOffDeg: 35)!.Id);
        Assert.Null(HoloOrbitLayout.Pick(250, placed));
    }

    [Fact]
    public void Orbit_BearingPlacesDevice()
    {
        var right = new HoloDevice("r", "Mac", "mac", Bearing: 90, BearingConfidence: 0.9);
        var other = new HoloDevice("o", "Pod", "pod", Distance: 2);
        var placed = HoloOrbitLayout.Place(new[] { right, other });
        Assert.Equal(0, placed[0].AngleDeg, 6);
        Assert.Equal(90, placed[1].AngleDeg, 6);
        Assert.Equal("o", HoloOrbitLayout.Nearest(new[] { right, other })!.Id);
        Assert.Equal("r", HoloOrbitLayout.Nearest(new[] { right })!.Id);
        var pos = HoloOrbitLayout.Positions(placed, new PointD(100, 100), 50);
        Assert.Equal(150, pos["r"].X, 6);
        Assert.Equal(100, pos["r"].Y, 6);
        Assert.Equal(50, pos["o"].Y, 6);
    }

    private const string Lan = "http://192.168.1.30:5000";

    private static HoloDevice Phone(bool lan = true) => new("iphone-1", "iPhone", "iphone", DefaultAction: HoloAction.Save,
        Lan: lan ? new HoloLan(Lan, "lan-token", 0) : null);

    [Fact]
    public async Task Send_LanReachable_GoesDirect_ThenRecords()
    {
        var file = Path.Combine(Tmp.Dir(), "a.txt");
        File.WriteAllText(file, "hello");
        var http = new FakeHttp(s =>
        {
            if (s.Uri.StartsWith(Lan) && s.Method == "GET") return FakeHttp.Json("{\"ok\":false}", HttpStatusCode.MethodNotAllowed);
            if (s.Uri.StartsWith(Lan)) return FakeHttp.Json("{\"ok\":true,\"outcome\":\"saved\"}");
            if (s.Path == "/api/holo-drop/drops") return FakeHttp.Json("{\"drop\":{\"id\":\"rec1\",\"kind\":\"file\"}}");
            return FakeHttp.Json("{}");
        });
        var sender = new HoloSender(new HoloDropApi(new ApiClient(() => "http://127.0.0.1:8787", http)), new ApiClient(() => null, http));
        var sent = await sender.SendDetailedAsync(HoloItem.Files(new[] { file }), Phone(), HoloAction.Save);
        Assert.Equal(HoloOutcome.Saved, sent.Outcome);
        Assert.Equal(new[] { "rec1" }, sent.DirectIds);
        Assert.Empty(sent.Ids);

        var reqs = http.Requests;
        Assert.Equal("GET", reqs[0].Method);
        Assert.Equal(Lan + "/holo-drop", reqs[0].Uri);
        Assert.Equal("POST", reqs[1].Method);
        Assert.Equal(Lan + "/holo-drop", reqs[1].Uri);
        Assert.Equal("lan-token", reqs[1].Headers["X-Holo-Token"]);
        Assert.Equal("hello", reqs[1].Body);
        Assert.Equal("text/plain", reqs[1].ContentType);
        var meta = HoloWire.DecodeMeta(reqs[1].Headers["X-Holo-Meta"])!;
        Assert.Equal("{\"action\":\"save\",\"kind\":\"file\",\"mime\":\"text/plain\",\"name\":\"a.txt\"}", J.SortedJson(meta));
        var record = Assert.Single(http.To("/api/holo-drop/drops"));
        Assert.Equal("{\"action\":\"save\",\"delivered_direct\":true,\"kind\":\"file\",\"mime\":\"text/plain\",\"name\":\"a.txt\",\"outcome\":\"saved\",\"target\":\"iphone-1\"}",
            J.SortedJson(J.Parse(record.Body!)));

        Assert.Equal(HoloOutcome.Saved, await sender.SendAsync(HoloItem.Files(new[] { file }), Phone(), HoloAction.Save));
    }

    [Fact]
    public async Task Send_LanUnreachable_UploadsThroughJarvis()
    {
        var file = Path.Combine(Tmp.Dir(), "a b+c.txt");
        File.WriteAllText(file, "hello");
        var http = new FakeHttp(s =>
        {
            if (s.Uri.StartsWith(Lan)) throw new HttpRequestException("no route to host");
            if (s.Path.StartsWith("/api/holo-drop/drops/upload")) return FakeHttp.Json("{\"drop\":{\"id\":\"up1\",\"kind\":\"file\"}}");
            return FakeHttp.Json("{}");
        });
        var sender = new HoloSender(new HoloDropApi(new ApiClient(() => "http://127.0.0.1:8787", http)), new ApiClient(() => null, http));
        var sent = await sender.SendDetailedAsync(HoloItem.Files(new[] { file }), Phone(), HoloAction.Save, new HoloPosition(0.5, 0.25));
        Assert.Null(sent.Outcome);
        Assert.Equal(new[] { "up1" }, sent.Ids);
        var up = Assert.Single(http.To("/api/holo-drop/drops/upload"));
        Assert.Equal("/api/holo-drop/drops/upload?kind=file&target=iphone-1&name=a%20b%2Bc.txt&mime=text%2Fplain&action=save&x=0.5&y=0.25", up.Path);
        Assert.Equal("hello", up.Body);
        Assert.Equal("text/plain", up.ContentType);
        Assert.DoesNotContain(http.Requests, r => r.Uri.StartsWith(Lan) && r.Method == "POST");
    }

    [Fact]
    public async Task Send_Link_NoLan_PostsInline()
    {
        var http = new FakeHttp(s => s.Path == "/api/holo-drop/drops" ? FakeHttp.Json("{\"drop\":{\"id\":\"i1\",\"kind\":\"link\"}}") : FakeHttp.Json("{}"));
        var sender = new HoloSender(new HoloDropApi(new ApiClient(() => "http://o", http)), new ApiClient(() => null, http));
        var sent = await sender.SendDetailedAsync(HoloItem.Link("https://github.com/x", "Repo"), Phone(lan: false), HoloAction.Open);
        Assert.Equal(new[] { "i1" }, sent.Ids);
        Assert.Equal("{\"action\":\"open\",\"kind\":\"link\",\"target\":\"iphone-1\",\"title\":\"Repo\",\"url\":\"https://github.com/x\"}",
            J.SortedJson(J.Parse(Assert.Single(http.Requests).Body!)));
    }

    [Fact]
    public async Task Send_LanRefuses_ReportsFailedNeverResends()
    {
        var http = new FakeHttp(s =>
        {
            if (s.Uri.StartsWith(Lan) && s.Method == "GET") return FakeHttp.Json("{}", HttpStatusCode.MethodNotAllowed);
            if (s.Uri.StartsWith(Lan)) return FakeHttp.Json("{\"ok\":false,\"error\":\"disk full\"}", HttpStatusCode.InternalServerError);
            return FakeHttp.Json("{\"drop\":{\"id\":\"r\",\"kind\":\"text\"}}");
        });
        var sender = new HoloSender(new HoloDropApi(new ApiClient(() => "http://o", http)), new ApiClient(() => null, http));
        var sent = await sender.SendDetailedAsync(HoloItem.Text("hi"), Phone(), HoloAction.Copy);
        Assert.Equal(HoloOutcome.Failed, sent.Outcome);
        Assert.Equal("disk full", sent.Error);
        var rec = J.Parse(Assert.Single(http.To("/api/holo-drop/drops")).Body!);
        Assert.True(J.B(rec["delivered_direct"]));
        Assert.Equal("failed", J.S(rec["outcome"]));
    }

    [Fact]
    public void Worse_PicksLeastComplete()
    {
        Assert.Equal(HoloOutcome.Saved, HoloSender.Worse(null, HoloOutcome.Saved));
        Assert.Equal(HoloOutcome.Failed, HoloSender.Worse(HoloOutcome.Saved, HoloOutcome.Failed));
        Assert.Equal(HoloOutcome.Copied, HoloSender.Worse(HoloOutcome.Saved, HoloOutcome.Copied));
    }

    [Fact]
    public void Uploadable_ZipsAFolder()
    {
        var dir = Directory.CreateDirectory(Path.Combine(Tmp.Dir(), "Folder")).FullName;
        File.WriteAllText(Path.Combine(dir, "x.txt"), "x");
        var zip = HoloSender.Uploadable(dir, Tmp.Dir());
        Assert.Equal("Folder.zip", Path.GetFileName(zip));
        Assert.True(File.Exists(zip));
        var plain = Path.Combine(dir, "x.txt");
        Assert.Equal(plain, HoloSender.Uploadable(plain, Tmp.Dir()));
    }

    [Fact]
    public void FlingWatcher_NotRegisteredInGameMode()
    {
        Assert.True(FlingWatchRule.ShouldRegister(flingOn: true, ctrlAltDown: true, GameMode.Off));
        Assert.False(FlingWatchRule.ShouldRegister(flingOn: true, ctrlAltDown: true, new GameMode(true, "fullscreen", false)));
        Assert.False(FlingWatchRule.ShouldRegister(flingOn: false, ctrlAltDown: true, GameMode.Off));
        Assert.False(FlingWatchRule.ShouldRegister(flingOn: true, ctrlAltDown: false, GameMode.Off));
        // An anti-cheat game in the background doesn't hold the watcher back (it only reads the mouse).
        Assert.True(FlingWatchRule.ShouldRegister(flingOn: true, ctrlAltDown: true, new GameMode(false, "x.exe", true)));
    }

    [Fact]
    public void KindAndMime_ByExtension()
    {
        Assert.Equal(HoloKind.Image, HoloKinds.ForFile("a.JPG"));
        Assert.Equal(HoloKind.Video, HoloKinds.ForFile("a.mov"));
        Assert.Equal(HoloKind.File, HoloKinds.ForFile("a.pdf"));
        Assert.Equal("application/pdf", HoloKinds.Mime("a.pdf"));
        Assert.Equal("application/octet-stream", HoloKinds.Mime("a.weird"));
    }
}
