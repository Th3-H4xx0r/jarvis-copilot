using System.Text.Json.Nodes;
using Jarvis.Core.Music;

namespace Jarvis.Core.Screen;

/// A display: Id is N of `\\.\DISPLAYN`; size in pixels.
public sealed record PcDisplay(int Id, string Name, bool Main, int W, int H);

/// What the Command Center shows. Null = the PC can't tell, and the phone hides that tile.
public sealed record PcSnapshot(bool? Wifi, string? WifiName, bool? Bluetooth, bool Dark, int? Volume, bool? Muted,
    double? Brightness, bool Locked, NowPlaying? Now, IReadOnlyList<PcDisplay> Displays, int Display, bool? KeepAwake);

/// `cc_state` with the Mac's exact keys (MacControls.state): never `stage`; `brightness` only
/// when the monitor reports it; plus `keep_awake`.
public static class CcState
{
    public static JsonObject Build(PcSnapshot s)
    {
        var j = new JsonObject { ["t"] = "cc_state" };
        if (s.Wifi is { } wifi) j["wifi"] = wifi;
        if (s.WifiName is { } name) j["wifi_name"] = name;
        if (s.Bluetooth is { } bt) j["bluetooth"] = bt;
        j["dark"] = s.Dark;
        if (s.Volume is { } v) j["volume"] = v;
        if (s.Muted is { } m) j["muted"] = m;
        if (s.Brightness is { } b) j["brightness"] = b;
        j["locked"] = s.Locked;
        if (s.Now is { } now)
        {
            j["now"] = new JsonObject { ["title"] = now.Title, ["artist"] = now.Artist, ["playing"] = now.IsPlaying, ["app"] = now.App };
        }
        var displays = new JsonArray();
        foreach (var d in s.Displays.OrderBy(d => d.Main ? 0 : 1))
        {
            displays.Add(new JsonObject { ["id"] = d.Id, ["name"] = d.Name, ["main"] = d.Main, ["w"] = d.W, ["h"] = d.H });
        }
        j["displays"] = displays;
        j["display"] = s.Display;
        if (s.KeepAwake is { } k) j["keep_awake"] = k;
        return j;
    }
}
