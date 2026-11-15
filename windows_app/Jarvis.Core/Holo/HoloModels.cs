using System.Globalization;
using System.Text.Json.Nodes;
using Jarvis.Core.Link;

namespace Jarvis.Core.Holo;

// Holo Drop's data (port of mac_app/.../HoloDrop/HoloDropModels.swift). Pure; field names and
// wire values follow the server's contract (webui/api/holo_drop_routes.py).

/// What a drop carries.
public enum HoloKind { Link, Text, Image, Video, File }

public static class HoloKinds
{
    private static readonly string[] Images = { "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "bmp", "tif", "tiff", "avif", "ico", "svg", "jfif" };
    private static readonly string[] Videos = { "mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "mpg", "mpeg", "3gp", "3g2", "mts", "m2ts", "ts", "flv" };

    private static readonly Dictionary<string, string> Mimes = new(StringComparer.OrdinalIgnoreCase)
    {
        ["jpg"] = "image/jpeg", ["jpeg"] = "image/jpeg", ["jfif"] = "image/jpeg", ["png"] = "image/png", ["gif"] = "image/gif",
        ["heic"] = "image/heic", ["heif"] = "image/heif", ["webp"] = "image/webp", ["bmp"] = "image/bmp",
        ["tif"] = "image/tiff", ["tiff"] = "image/tiff", ["avif"] = "image/avif", ["ico"] = "image/x-icon", ["svg"] = "image/svg+xml",
        ["mp4"] = "video/mp4", ["mov"] = "video/quicktime", ["m4v"] = "video/x-m4v", ["avi"] = "video/x-msvideo",
        ["mkv"] = "video/x-matroska", ["webm"] = "video/webm", ["wmv"] = "video/x-ms-wmv", ["mpg"] = "video/mpeg",
        ["mpeg"] = "video/mpeg", ["3gp"] = "video/3gpp", ["3g2"] = "video/3gpp2", ["mts"] = "video/mp2t", ["m2ts"] = "video/mp2t",
        ["ts"] = "video/mp2t", ["flv"] = "video/x-flv",
        ["txt"] = "text/plain", ["md"] = "text/markdown", ["csv"] = "text/csv", ["html"] = "text/html", ["htm"] = "text/html",
        ["json"] = "application/json", ["xml"] = "application/xml", ["pdf"] = "application/pdf", ["zip"] = "application/zip",
        ["rtf"] = "application/rtf", ["doc"] = "application/msword",
        ["docx"] = "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        ["xls"] = "application/vnd.ms-excel", ["xlsx"] = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        ["ppt"] = "application/vnd.ms-powerpoint", ["pptx"] = "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        ["key"] = "application/vnd.apple.keynote", ["pages"] = "application/vnd.apple.pages", ["numbers"] = "application/vnd.apple.numbers",
        ["mp3"] = "audio/mpeg", ["m4a"] = "audio/mp4", ["wav"] = "audio/wav", ["aac"] = "audio/aac", ["flac"] = "audio/flac",
        ["ogg"] = "audio/ogg", ["7z"] = "application/x-7z-compressed", ["gz"] = "application/gzip", ["tar"] = "application/x-tar",
    };

    public static string Wire(this HoloKind k) => k switch
    {
        HoloKind.Link => "link",
        HoloKind.Text => "text",
        HoloKind.Image => "image",
        HoloKind.Video => "video",
        _ => "file",
    };

    public static HoloKind? Parse(string? raw) => raw switch
    {
        "link" => HoloKind.Link,
        "text" => HoloKind.Text,
        "image" => HoloKind.Image,
        "video" => HoloKind.Video,
        "file" => HoloKind.File,
        _ => null,
    };

    /// Travels inside the JSON (no bytes to fetch).
    public static bool Inline(this HoloKind k) => k is HoloKind.Link or HoloKind.Text;

    /// A file's kind by its extension: photos and videos are told apart (Photos on the phone).
    public static HoloKind ForFile(string path)
    {
        var ext = Ext(path);
        if (Images.Contains(ext)) return HoloKind.Image;
        if (Videos.Contains(ext)) return HoloKind.Video;
        return HoloKind.File;
    }

    public static string Mime(string path) =>
        Mimes.TryGetValue(Ext(path), out var m) ? m : "application/octet-stream";

    private static string Ext(string path) => Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
}

/// What the receiver does on arrival. Each device has a default; the popup can change it for one drop.
public enum HoloAction { Save, Open, Copy, SaveOpen, SaveCopy }

public static class HoloActions
{
    public static string Wire(this HoloAction a) => a switch
    {
        HoloAction.Save => "save",
        HoloAction.Open => "open",
        HoloAction.Copy => "copy",
        HoloAction.SaveOpen => "save_open",
        _ => "save_copy",
    };

    public static string Title(this HoloAction a) => a switch
    {
        HoloAction.Save => "Save",
        HoloAction.Open => "Open",
        HoloAction.Copy => "Copy",
        HoloAction.SaveOpen => "Save + Open",
        _ => "Save + Copy",
    };

    public static bool Saves(this HoloAction a) => a is HoloAction.Save or HoloAction.SaveOpen or HoloAction.SaveCopy;
    public static bool Opens(this HoloAction a) => a is HoloAction.Open or HoloAction.SaveOpen;
    public static bool Copies(this HoloAction a) => a is HoloAction.Copy or HoloAction.SaveCopy;

    public static HoloAction? Parse(JsonNode? raw) => J.S(raw) switch
    {
        "save" => HoloAction.Save,
        "open" => HoloAction.Open,
        "copy" => HoloAction.Copy,
        "save_open" => HoloAction.SaveOpen,
        "save_copy" => HoloAction.SaveCopy,
        _ => null,
    };
}

/// How a drop ended on the receiver (`POST /drops/<id>/landed`).
public sealed record HoloOutcome
{
    public string Wire { get; }

    private HoloOutcome(string wire) => Wire = wire;

    public static readonly HoloOutcome Opened = new("opened");
    public static readonly HoloOutcome Saved = new("saved");
    public static readonly HoloOutcome Copied = new("copied");
    public static readonly HoloOutcome Shown = new("shown");
    public static readonly HoloOutcome Failed = new("failed");
    public static readonly HoloOutcome SavedOpened = new("saved_opened");
    public static readonly HoloOutcome SavedCopied = new("saved_copied");

    public static IReadOnlyList<HoloOutcome> All { get; } = new[] { Opened, Saved, Copied, Shown, Failed, SavedOpened, SavedCopied };

    public static HoloOutcome? Parse(string? raw) => All.FirstOrDefault(o => o.Wire == raw);

    /// What happened, from the steps that worked. Nothing worked: failed.
    public static HoloOutcome From(bool saved, bool opened, bool copied, bool shown) => (saved, opened, copied) switch
    {
        (true, true, _) => SavedOpened,
        (true, false, true) => SavedCopied,
        (true, false, false) => Saved,
        (false, true, _) => Opened,
        (false, false, true) => Copied,
        _ => shown ? Shown : Failed,
    };

    /// "Landed on iPhone · Saved".
    public string Label => Wire switch
    {
        "opened" => "Opened",
        "saved" => "Saved",
        "copied" => "Copied",
        "shown" => "Shown",
        "failed" => "Didn't land",
        "saved_opened" => "Saved and opened",
        _ => "Saved and copied",
    };

    public override string ToString() => Wire;
}

/// Where a drop lands: fractions (0–1) of the target screen, from its top-left corner.
public sealed record HoloPosition
{
    public double X { get; }
    public double Y { get; }

    public HoloPosition(double x, double y)
    {
        X = Math.Clamp(x, 0, 1);
        Y = Math.Clamp(y, 0, 1);
    }

    public static HoloPosition? FromJson(JsonNode? json)
    {
        var o = J.Obj(json);
        if (J.D(o["x"]) is not { } x || J.D(o["y"]) is not { } y || !double.IsFinite(x) || !double.IsFinite(y)) return null;
        return new HoloPosition(x, y);
    }

    public JsonObject Json() => new() { ["x"] = X, ["y"] = Y };
}

/// A receiver's direct endpoint on the local network.
public sealed record HoloLan(string Url, string Token, double Expires)
{
    public static HoloLan? FromJson(JsonNode? json)
    {
        var o = J.Obj(json);
        var url = J.S(o["url"]);
        var token = J.S(o["token"]);
        if (url.Length == 0 || token.Length == 0) return null;
        return new HoloLan(url, token, J.D(o["expires"]) ?? 0);
    }

    /// Unix seconds; 0 = no expiry given.
    public bool Usable(DateTimeOffset now) => Expires <= 0 || Expires > now.ToUnixTimeMilliseconds() / 1000.0;
}

/// One of his devices that can receive (`GET /devices`).
public sealed record HoloDevice(
    string Id,
    string Name,
    /// iphone, ipad, mac, pc, web, glasses, pod.
    string Kind,
    bool Online = true,
    IReadOnlyList<string>? Accepts = null,
    /// A computer: drops can be aimed at a spot on its screen.
    bool Aim = false,
    HoloAction DefaultAction = HoloAction.Open,
    HoloLan? Lan = null,
    /// Degrees from "straight ahead", clockwise, as the caller last saw it.
    double? Bearing = null,
    double BearingConfidence = 0,
    double? Distance = null)
{
    public static HoloDevice? FromJson(JsonObject o)
    {
        var id = J.S(o["id"]);
        if (id.Length == 0) return null;
        var kind = J.S(o["kind"], "mac");
        var name = J.S(o["name"]);
        if (name.Length == 0) name = kind.Length == 0 ? kind : char.ToUpperInvariant(kind[0]) + kind[1..].ToLowerInvariant();
        var accepts = o["accepts"] is JsonArray a ? a.Select(v => J.S(v)).ToList() : new List<string>();
        var b = J.Obj(o["bearing"]);
        return new HoloDevice(id, name, kind, J.B(o["online"]), accepts, J.B(o["aim"]),
            HoloActions.Parse(o["default_action"]) ?? HoloAction.Open, HoloLan.FromJson(o["lan"]),
            J.D(b["deg"]), J.D(b["confidence"]) ?? 0, J.D(o["distance_m"]));
    }

    public static IReadOnlyList<HoloDevice> List(JsonObject reply) =>
        J.Arr(reply["devices"]).Select(FromJson).OfType<HoloDevice>().ToList();

    /// No list means everything (an older server).
    public bool AcceptsKind(HoloKind k) => Accepts is not { Count: > 0 } || Accepts.Contains(k.Wire());

    public bool Equals(HoloDevice? other) =>
        other is not null && Id == other.Id && Name == other.Name && Kind == other.Kind && Online == other.Online
        && (Accepts ?? Array.Empty<string>()).SequenceEqual(other.Accepts ?? Array.Empty<string>()) && Aim == other.Aim
        && DefaultAction == other.DefaultAction && Lan == other.Lan && Bearing == other.Bearing
        && BearingConfidence == other.BearingConfidence && Distance == other.Distance;

    public override int GetHashCode() => HashCode.Combine(Id, Name, Kind);
}

/// A drop as the server keeps it (`GET /drops/<id>`, the bridge's `drop` frame, `/pending`).
public sealed record HoloDropRecord(
    string Id, HoloKind Kind, string From, string FromName, string Target, string Name, string Mime, long Size,
    string Text, string Url, string Title, HoloAction? Action, HoloPosition? Position, string State, string Outcome,
    DateTimeOffset? Created)
{
    public static HoloDropRecord? FromJson(JsonObject o)
    {
        if (HoloKinds.Parse(J.S(o["kind"])) is not { } kind) return null;
        DateTimeOffset? created = null;
        if (J.D(o["created"]) is { } t && t > 0)
            created = DateTimeOffset.FromUnixTimeMilliseconds((long)(t * 1000));
        else if (J.StrOrNull(o["created"]) is { } s
                 && DateTimeOffset.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var parsed))
            created = parsed;
        return new HoloDropRecord(J.S(o["id"]), kind, J.S(o["from"], J.S(o["sender"])), J.S(o["from_name"]), J.S(o["target"]),
            J.S(o["name"]), J.S(o["mime"]), J.L(o["size"]), J.S(o["text"]), J.S(o["url"]), J.S(o["title"]),
            HoloActions.Parse(o["action"]), HoloPosition.FromJson(o["position"]), J.S(o["state"]), J.S(o["outcome"]), created);
    }

    /// The link to open: a link drop's URL, or a text drop that is nothing but one.
    public Uri? WebUrl
    {
        get
        {
            var raw = (Kind == HoloKind.Link ? (Url.Length == 0 ? Text : Url) : Kind == HoloKind.Text ? Text : "").Trim();
            return HoloItem.WebUri(raw);
        }
    }

    /// The card's caption.
    public string DisplayName
    {
        get
        {
            switch (Kind)
            {
                case HoloKind.Link:
                    if (Title.Length > 0) return Title;
                    return WebUrl?.Host ?? (Url.Length == 0 ? "Link" : Url);
                case HoloKind.Text:
                    var line = Text.Split(new[] { '\n', '\r' }, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? Text;
                    return line.Length == 0 ? "Text" : line.Length > 80 ? line[..80] : line;
                default:
                    return Name.Length == 0 ? "File" : Name;
            }
        }
    }

    /// The landed frame's sentence: "Landed on iPhone · Saved".
    public static string LandedLine(string device, string outcome, string? error = null)
    {
        if (HoloOutcome.Parse(outcome) is not { } o) return $"Landed on {device}";
        if (o == HoloOutcome.Failed) return $"Didn't land on {device}" + (string.IsNullOrEmpty(error) ? "" : $" — {error}");
        return $"Landed on {device} · {o.Label}";
    }
}

/// What the PC is sending.
public abstract record HoloItem
{
    public static HoloItem Link(string url, string? title = null) => new HoloLinkItem(url, string.IsNullOrEmpty(title) ? null : title);
    public static HoloItem Text(string text) => new HoloTextItem(text);
    public static HoloItem Files(IEnumerable<string> paths) => new HoloFilesItem(paths.ToList());

    /// An http(s) address with a host, or null.
    public static Uri? WebUri(string raw)
    {
        if (raw.Length == 0 || raw.Any(char.IsWhiteSpace)) return null;
        if (!Uri.TryCreate(raw, UriKind.Absolute, out var u)) return null;
        if (u.Scheme != Uri.UriSchemeHttp && u.Scheme != Uri.UriSchemeHttps) return null;
        return string.IsNullOrEmpty(u.Host) ? null : u;
    }

    /// Pasted or dropped text that's just a web address goes as a link.
    public static HoloItem? FromText(string raw)
    {
        var t = raw.Trim();
        if (t.Length == 0) return null;
        return WebUri(t) != null ? Link(t) : Text(t);
    }

    public abstract IReadOnlyList<HoloKind> Kinds { get; }
    public abstract string Caption { get; }
}

public sealed record HoloLinkItem(string Url, string? Title) : HoloItem
{
    public override IReadOnlyList<HoloKind> Kinds => new[] { HoloKind.Link };
    public override string Caption => Title ?? WebUri(Url)?.Host ?? Url;
}

public sealed record HoloTextItem(string Value) : HoloItem
{
    public override IReadOnlyList<HoloKind> Kinds => new[] { HoloKind.Text };

    public override string Caption
    {
        get
        {
            var line = Value.Split(new[] { '\n', '\r' }, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? Value;
            return line.Length > 60 ? line[..60] : line;
        }
    }
}

public sealed record HoloFilesItem(IReadOnlyList<string> Paths) : HoloItem
{
    public override IReadOnlyList<HoloKind> Kinds => Paths.Select(HoloKinds.ForFile).ToList();
    public override string Caption => Paths.Count == 1 ? Path.GetFileName(Paths[0]) : $"{Paths.Count} files";

    public bool Equals(HoloFilesItem? other) => other is not null && Paths.SequenceEqual(other.Paths);

    public override int GetHashCode() => Paths.Aggregate(17, (h, p) => HashCode.Combine(h, p));
}
