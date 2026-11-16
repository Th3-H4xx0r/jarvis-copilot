using System.Text.Json.Nodes;
using Jarvis.Core.Link;

namespace Jarvis.Core.Stats;

/// A widget's look (the server's `style`): all optional.
public sealed record WidgetStyle(string? Chart = null, string? Color = null, double? Warn = null, double? Crit = null,
    int? Window = null, int? Decimals = null, IReadOnlyList<string>? Meta = null, string? Label = null, string? Unit = null);

/// One widget on the 12-column grid (webui/api/pc_stats_catalog.py validate_dashboard).
public sealed record Widget(string Id, string Kind, int X, int Y, int W, int H, IReadOnlyList<string> Readings, WidgetStyle Style);

/// A dashboard as the server stores it; `Rev` guards concurrent edits.
public sealed record Dashboard(string Id, string Name, string? Auto, IReadOnlyList<Widget> Widgets, int? Rev)
{
    public const int Columns = 12;
    public static readonly IReadOnlyList<string> Kinds = new[] { "hero", "number", "chart", "bars", "ring", "sparkline", "stats", "text", "session", "moments" };

    public static Dashboard Parse(JsonObject o)
    {
        var widgets = new List<Widget>();
        foreach (var n in o["widgets"] as JsonArray ?? new JsonArray())
        {
            if (n is not JsonObject w) continue;
            var st = w["style"] as JsonObject ?? new JsonObject();
            widgets.Add(new Widget(J.S(w["id"]), J.S(w["kind"]), J.I(w["x"]), J.I(w["y"]), Math.Max(1, J.I(w["w"])),
                Math.Max(1, J.I(w["h"])), Strings(w["readings"]),
                new WidgetStyle(J.StrOrNull(st["chart"]), J.StrOrNull(st["color"]), Num(st["warn"]), Num(st["crit"]),
                    Num(st["window"]) is { } win ? (int)win : null, Num(st["decimals"]) is { } dec ? (int)dec : null,
                    st["meta"] is JsonArray ? Strings(st["meta"]) : null, J.StrOrNull(st["label"]), J.StrOrNull(st["unit"]))));
        }
        return new Dashboard(J.S(o["id"]), J.S(o["name"]), J.StrOrNull(o["auto"]), widgets, Num(o["rev"]) is { } r ? (int)r : null);
    }

    public JsonObject ToJson()
    {
        var widgets = new JsonArray();
        foreach (var w in Widgets)
        {
            var st = new JsonObject();
            if (w.Style.Chart != null) st["chart"] = w.Style.Chart;
            if (w.Style.Color != null) st["color"] = w.Style.Color;
            if (w.Style.Warn != null) st["warn"] = w.Style.Warn;
            if (w.Style.Crit != null) st["crit"] = w.Style.Crit;
            if (w.Style.Window != null) st["window"] = w.Style.Window;
            if (w.Style.Decimals != null) st["decimals"] = w.Style.Decimals;
            if (w.Style.Meta != null) st["meta"] = new JsonArray(w.Style.Meta.Select(m => (JsonNode)m).ToArray());
            if (w.Style.Label != null) st["label"] = w.Style.Label;
            if (w.Style.Unit != null) st["unit"] = w.Style.Unit;
            widgets.Add(new JsonObject
            {
                ["id"] = w.Id, ["kind"] = w.Kind, ["x"] = w.X, ["y"] = w.Y, ["w"] = w.W, ["h"] = w.H,
                ["readings"] = new JsonArray(w.Readings.Select(r => (JsonNode)r).ToArray()), ["style"] = st,
            });
        }
        return new JsonObject { ["id"] = Id, ["name"] = Name, ["auto"] = Auto, ["widgets"] = widgets };
    }

    private static List<string> Strings(JsonNode? n) => (n as JsonArray ?? new JsonArray()).Select(x => J.S(x)).Where(x => x.Length > 0).ToList();

    private static double? Num(JsonNode? n) => n is JsonValue v && v.TryGetValue<double>(out var d) ? d : null;
}

/// Grid rules shared by the editor and Jarvis-style auto placement.
public static class DashboardLayout
{
    public static bool Fits(Widget w) => w.X >= 0 && w.Y >= 0 && w.W >= 1 && w.H >= 1 && w.X + w.W <= Dashboard.Columns;

    public static bool Overlaps(Widget a, Widget b) =>
        a.X < b.X + b.W && b.X < a.X + a.W && a.Y < b.Y + b.H && b.Y < a.Y + a.H;

    /// Whether `moved` can sit where it says among the dashboard's other widgets.
    public static bool CanPlace(Dashboard d, Widget moved) =>
        Fits(moved) && d.Widgets.Where(w => w.Id != moved.Id).All(w => !Overlaps(w, moved));

    /// The first free (x, y), row by row, for a w×h widget.
    public static (int X, int Y) AutoPlace(Dashboard d, int w, int h)
    {
        w = Math.Clamp(w, 1, Dashboard.Columns);
        for (var y = 0; y < 400; y++)
            for (var x = 0; x + w <= Dashboard.Columns; x++)
            {
                var probe = new Widget("_probe", "number", x, y, w, h, Array.Empty<string>(), new WidgetStyle());
                if (d.Widgets.All(o => !Overlaps(o, probe))) return (x, y);
            }
        return (0, 400);
    }

    /// Grid rows the dashboard uses.
    public static int Rows(Dashboard d) => d.Widgets.Count == 0 ? 0 : d.Widgets.Max(w => w.Y + w.H);
}

/// What a widget shows for a reading: the formatted value, or why it can't.
public static class WidgetText
{
    public static string Value(string key, IReadOnlyDictionary<string, double> r, int? decimals, bool driverOff = false)
    {
        if (!r.TryGetValue(key, out var v)) return driverOff && NeedsDriver(key) ? "needs the sensor driver" : "unavailable";
        var d = decimals ?? (Math.Abs(v) >= 100 ? 0 : key.EndsWith("used") || key.EndsWith("total") ? 1 : 0);
        return v.ToString("F" + Math.Clamp(d, 0, 3), System.Globalization.CultureInfo.InvariantCulture);
    }

    public static bool NeedsDriver(string key) => key is ReadingKeys.CpuTemp or ReadingKeys.CpuPower || key.StartsWith("fan.") || key.StartsWith("temp.");

    /// amber over warn, red over crit, else none.
    public static string Level(double? value, WidgetStyle s) =>
        value is not { } v ? "none" : s.Crit is { } c && v >= c ? "crit" : s.Warn is { } w && v >= w ? "warn" : "none";
}
