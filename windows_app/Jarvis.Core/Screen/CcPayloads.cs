using System.Globalization;
using System.Text.Json.Nodes;

namespace Jarvis.Core.Screen;

/// An open app (visible top-level windows grouped by pid). `Bundle` = the lower-case exe name.
public sealed record PcApp(int Pid, string Name, string Bundle, bool Active, bool Hidden, string ExePath);

public sealed record PcWindow(long Id, string Title, bool Min, bool Front);

/// `cc_apps`, `cc_icon` and `cc_windows` (MacControls / MacWindows.payload shapes).
public static class CcPayloads
{
    public const int MaxWindows = 30;
    public const int MaxTitle = 120;

    public static JsonObject Apps(IReadOnlyList<PcApp> apps)
    {
        var arr = new JsonArray();
        foreach (var a in apps)
        {
            arr.Add(new JsonObject { ["pid"] = a.Pid, ["name"] = a.Name, ["bundle"] = a.Bundle, ["active"] = a.Active, ["hidden"] = a.Hidden });
        }
        return new JsonObject { ["t"] = "cc_apps", ["apps"] = arr };
    }

    public static JsonObject Icon(string bundle, byte[] png) =>
        new() { ["t"] = "cc_icon", ["bundle"] = bundle, ["png"] = Convert.ToBase64String(png) };

    /// On Windows there's no Accessibility grant to lack, so `ax` is always true.
    public static JsonObject Windows(int pid, IReadOnlyList<PcWindow> windows, bool canNewWindow)
    {
        var arr = new JsonArray();
        foreach (var w in windows.Take(MaxWindows))
        {
            arr.Add(new JsonObject { ["id"] = w.Id, ["title"] = Clip(w.Title), ["min"] = w.Min, ["front"] = w.Front });
        }
        return new JsonObject { ["t"] = "cc_windows", ["pid"] = pid, ["ax"] = true, ["new_window"] = canNewWindow, ["windows"] = arr };
    }

    /// Trimmed, at most MaxTitle text elements, ending in "…" when cut.
    public static string Clip(string title)
    {
        var t = title.Trim();
        var info = new StringInfo(t);
        return info.LengthInTextElements <= MaxTitle ? t : info.SubstringByTextElements(0, MaxTitle - 1) + "…";
    }
}
