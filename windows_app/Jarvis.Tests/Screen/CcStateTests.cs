using Jarvis.Core.Link;
using Jarvis.Core.Music;
using Jarvis.Core.Screen;
using static Jarvis.Tests.Fakes.TestClock;

namespace Jarvis.Tests.Screen;

public class CcStateTests
{
    private static IEnumerable<string> Keys(JsonObject o) => o.Select(p => p.Key).OrderBy(k => k, StringComparer.Ordinal);

    [Fact]
    public void CcState_ExactKeys_Full()
    {
        var j = CcState.Build(new PcSnapshot(true, "Home", false, true, 40, false, 0.7, false, new NowPlaying("Spotify", "Song", "Artist", "", 200, 10, T0, true),
            new[] { new PcDisplay(1, "DELL U2720Q", true, 3840, 2160) }, 1, true));
        Assert.Equal(new[] { "bluetooth", "brightness", "dark", "display", "displays", "keep_awake", "locked", "muted", "now", "t", "volume", "wifi", "wifi_name" }, Keys(j));
        Assert.Equal("cc_state", (string)j["t"]!);
        Assert.Equal(new[] { "app", "artist", "playing", "title" }, Keys(j["now"]!.AsObject()));
        Assert.Equal(new[] { "h", "id", "main", "name", "w" }, Keys(j["displays"]![0]!.AsObject()));
        Assert.Equal("{\"app\":\"Spotify\",\"artist\":\"Artist\",\"playing\":true,\"title\":\"Song\"}", J.SortedJson(j["now"]!));
        Assert.Equal(0.7, J.D(j["brightness"]));
        Assert.Equal(1, J.I(j["display"]));
    }

    [Fact]
    public void CcState_OmitsUnknownTiles_NeverStage()
    {
        var j = CcState.Build(new PcSnapshot(null, null, null, false, 40, false, null, false, null, Array.Empty<PcDisplay>(), 0, null));
        foreach (var k in new[] { "wifi", "wifi_name", "bluetooth", "brightness", "now", "keep_awake", "stage" }) Assert.False(j.ContainsKey(k));
        Assert.Empty(j["displays"]!.AsArray());
    }

    [Fact]
    public void CcState_MainDisplayFirst()
    {
        var j = CcState.Build(new PcSnapshot(null, null, null, false, null, null, null, false, null,
            new[] { new PcDisplay(2, "Side", false, 1920, 1080), new PcDisplay(1, "Main", true, 2560, 1440) }, 1, null));
        Assert.Equal(1, J.I(j["displays"]![0]!["id"]));
    }

    [Fact]
    public void Payloads_AppsIconWindows()
    {
        var apps = CcPayloads.Apps(new[] { new PcApp(42, "Chrome", "chrome.exe", true, false, @"C:\chrome.exe") });
        Assert.Equal("{\"apps\":[{\"active\":true,\"bundle\":\"chrome.exe\",\"hidden\":false,\"name\":\"Chrome\",\"pid\":42}],\"t\":\"cc_apps\"}", J.SortedJson(apps));
        Assert.Equal("{\"bundle\":\"chrome.exe\",\"png\":\"AQI=\",\"t\":\"cc_icon\"}", J.SortedJson(CcPayloads.Icon("chrome.exe", new byte[] { 1, 2 })));
        var many = Enumerable.Range(0, 40).Select(i => new PcWindow(i, new string('x', 200), i == 3, i == 0)).ToList();
        var w = CcPayloads.Windows(42, many, true);
        Assert.Equal("cc_windows", J.S(w["t"]));
        Assert.True(J.B(w["ax"]));
        Assert.True(J.B(w["new_window"]));
        Assert.Equal(CcPayloads.MaxWindows, w["windows"]!.AsArray().Count);
        Assert.Equal(CcPayloads.MaxTitle, J.S(w["windows"]![0]!["title"]).Length);
        Assert.EndsWith("…", J.S(w["windows"]![0]!["title"]));
        Assert.Equal(new[] { "front", "id", "min", "title" }, Keys(w["windows"]![0]!.AsObject()));
    }
}
