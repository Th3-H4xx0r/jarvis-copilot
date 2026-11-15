using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Jarvis.Core.Gaming;
using Jarvis.Core.Link;

namespace Jarvis.Core.Holo;

/// Request bodies and paths, exactly as the contract spells them (port of `HoloWire`).
public static class HoloWire
{
    public const string Base = "/api/holo-drop";

    /// `POST /drops` (JSON form) for a link or text; with `direct`, a drop of any kind that
    /// already went over the LAN (with the receiver's `outcome`), so history still records it.
    public static JsonObject InlineDrop(HoloKind kind, string target, string? text = null, string? url = null,
        HoloAction? action = null, HoloPosition? position = null, string? title = null, bool direct = false,
        string? name = null, string? mime = null, HoloOutcome? outcome = null)
    {
        var body = new JsonObject { ["kind"] = kind.Wire(), ["target"] = target };
        if (text != null) body["text"] = text;
        if (url != null) body["url"] = url;
        if (action is { } a) body["action"] = a.Wire();
        if (position != null) body["position"] = position.Json();
        if (!string.IsNullOrEmpty(title)) body["title"] = title;
        if (!string.IsNullOrEmpty(name)) body["name"] = name;
        if (!string.IsNullOrEmpty(mime)) body["mime"] = mime;
        if (direct) body["delivered_direct"] = true;
        // A direct drop's record carries the receiver's own answer, so it's recorded as landed.
        if (direct && outcome != null) body["outcome"] = outcome.Wire;
        return body;
    }

    /// `POST /drops/upload?kind=…&target=…&name=…&mime=…&action=…&x=…&y=…` (body = the bytes).
    /// Every value is fully percent-encoded ("+" as %2B, which a server would read as a space).
    public static string UploadPath(HoloKind kind, string target, string name, string mime, HoloAction? action,
        HoloPosition? position = null)
    {
        var items = new List<(string, string)> { ("kind", kind.Wire()), ("target", target), ("name", name), ("mime", mime) };
        if (action is { } a) items.Add(("action", a.Wire()));
        if (position != null)
        {
            items.Add(("x", Fraction(position.X)));
            items.Add(("y", Fraction(position.Y)));
        }
        return Base + "/drops/upload?" + string.Join("&", items.Select(i => i.Item1 + "=" + Uri.EscapeDataString(i.Item2)));
    }

    public static string Fraction(double v)
    {
        var t = v.ToString("F4", CultureInfo.InvariantCulture).TrimEnd('0').TrimEnd('.');
        return t.Length == 0 || t == "-0" ? "0" : t;
    }

    public static JsonObject Landed(HoloOutcome outcome, string? error = null)
    {
        var body = new JsonObject { ["outcome"] = outcome.Wire };
        if (!string.IsNullOrEmpty(error)) body["error"] = error;
        return body;
    }

    public static JsonObject LanAdvert(string url, string token, DateTimeOffset expires) =>
        new() { ["url"] = url, ["token"] = token, ["expires"] = (long)Math.Round(expires.ToUnixTimeMilliseconds() / 1000.0) };

    public static JsonObject ScreenReport(double width, double height, double scale, IEnumerable<HoloWindowOutline> windows) =>
        new()
        {
            ["width"] = width, ["height"] = height, ["scale"] = scale,
            ["windows"] = new JsonArray(windows.Select(w => (JsonNode)w.Json()).ToArray()),
        };

    /// The LAN receiver's `X-Holo-Meta`: the drop's fields as base64 JSON (keys sorted).
    public static string Meta(JsonObject fields) => Convert.ToBase64String(Encoding.UTF8.GetBytes(J.SortedJson(fields)));

    public static JsonObject? DecodeMeta(string? header)
    {
        if (header == null) return null;
        try
        {
            var bytes = Convert.FromBase64String(header.Trim());
            return JsonNode.Parse(bytes) as JsonObject;
        }
        catch (Exception e) when (e is FormatException or JsonException or ArgumentException)
        {
            return null;
        }
    }

    /// A drop's fields for the LAN path (same names as the server's record).
    public static JsonObject DirectFields(HoloKind kind, string name = "", string mime = "", string? text = null,
        string? url = null, string? title = null, HoloAction? action = null, HoloPosition? position = null,
        string from = "", string fromName = "")
    {
        var f = new JsonObject { ["kind"] = kind.Wire() };
        if (name.Length > 0) f["name"] = name;
        if (mime.Length > 0) f["mime"] = mime;
        if (text != null) f["text"] = text;
        if (url != null) f["url"] = url;
        if (!string.IsNullOrEmpty(title)) f["title"] = title;
        if (action is { } a) f["action"] = a.Wire();
        if (position != null) f["position"] = position.Json();
        if (from.Length > 0) f["from"] = from;
        if (fromName.Length > 0) f["from_name"] = fromName;
        return f;
    }
}

/// One window on the PC's screen map, as fractions of the display (top-left origin).
public sealed record HoloWindowOutline(double X, double Y, double W, double H, string App)
{
    public JsonObject Json() => new()
    {
        ["x"] = HoloGeometry.Round4(X), ["y"] = HoloGeometry.Round4(Y),
        ["w"] = HoloGeometry.Round4(W), ["h"] = HoloGeometry.Round4(H), ["app"] = App,
    };
}

/// The screen map the sender aims with (`POST /screen/<request>`). Window titles are never read.
public sealed record HoloScreen(double Width, double Height, double Scale, IReadOnlyList<HoloWindowOutline> Windows);

public static class HoloGeometry
{
    public static double Round4(double v) => Math.Round(v * 10_000, MidpointRounding.AwayFromZero) / 10_000;

    /// Windows (screen pixels, front to back) as fractions of `display`, clipped to it.
    /// Off-display, tiny and nameless ones are left out.
    public static IReadOnlyList<HoloWindowOutline> Outlines(IEnumerable<(RectI Bounds, string App)> windows, RectI display,
        int minSide = 40, int limit = 30)
    {
        var outlines = new List<HoloWindowOutline>();
        if (display.Width <= 0 || display.Height <= 0) return outlines;
        foreach (var (b, app) in windows)
        {
            var l = Math.Max(b.Left, display.Left);
            var t = Math.Max(b.Top, display.Top);
            var r = Math.Min(b.Right, display.Right);
            var btm = Math.Min(b.Bottom, display.Bottom);
            if (r - l < minSide || btm - t < minSide || app.Length == 0) continue;
            outlines.Add(new HoloWindowOutline((double)(l - display.Left) / display.Width, (double)(t - display.Top) / display.Height,
                (double)(r - l) / display.Width, (double)(btm - t) / display.Height, app));
            if (outlines.Count >= limit) break;
        }
        return outlines;
    }
}

/// Where the arrival card goes: centred on `drop.position` within the primary monitor's work
/// area (kept 8 px inside it), else its bottom-right corner. A picture card is the picture: the
/// same area whatever its shape, 240–420 px wide.
public static class HoloCardLayout
{
    public const int Margin = 8;
    public const double HeroArea = 320 * 240;
    public const double MinWidth = 240, MaxWidth = 420, MinHeight = 150, MaxHeight = 420;
    /// Link, text and file cards (no picture): this wide, as tall as their content.
    public const double CompactWidth = 360;

    public static RectI Frame(HoloPosition? position, RectI work, int width, int height)
    {
        int x, y;
        if (position == null)
        {
            x = work.Right - width - Margin * 2;
            y = work.Bottom - height - Margin * 2;
        }
        else
        {
            x = (int)Math.Round(work.Left + position.X * work.Width - width / 2.0);
            y = (int)Math.Round(work.Top + position.Y * work.Height - height / 2.0);
        }
        x = Math.Max(work.Left + Margin, Math.Min(x, work.Right - width - Margin));
        y = Math.Max(work.Top + Margin, Math.Min(y, work.Bottom - height - Margin));
        return new RectI(x, y, x + width, y + height);
    }

    /// The card's size for a picture of `aspect` (width ÷ height): cropped a little at the clamp
    /// (UniformToFill), never letterboxed.
    public static (double Width, double Height) HeroSize(double aspect)
    {
        if (!double.IsFinite(aspect) || aspect <= 0) return (320, 240);
        var w = Math.Sqrt(HeroArea * aspect);
        var h = w / aspect;
        var down = Math.Min(1, Math.Min(MaxWidth / w, MaxHeight / h));
        w = Math.Clamp(w * down, MinWidth, MaxWidth);
        h = Math.Clamp(h * down, MinHeight, MaxHeight);
        return (Math.Round(w), Math.Round(h));
    }
}
