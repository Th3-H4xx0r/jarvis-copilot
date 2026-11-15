using System.Text.Json;
using System.Text.Json.Nodes;
using Jarvis.Core.Http;
using Jarvis.Core.Link;
using Jarvis.Core.Platform;

namespace Jarvis.Core.Chat;

/// One server-sent event of a chat turn (port of the Mac's ChatSSE.Event).
public sealed record ChatEvent(string Name, IReadOnlyDictionary<string, string> Fields, JsonObject Json)
{
    public string? Token => Name is "token" or "delta" or "text"
        ? (Fields.GetValueOrDefault("text") ?? Fields.GetValueOrDefault("delta") ?? Fields.GetValueOrDefault("content")) is { Length: > 0 } t ? t : null
        : null;
    public bool IsEnd => Name is "done" or "stream_end" or "complete" or "error" or "apperror" or "cancel" or "cancelled";
    public string? Error => Name is "error" or "apperror" ? Fields.GetValueOrDefault("message") ?? Fields.GetValueOrDefault("error") ?? "The chat failed." : null;
    public string? StreamId => Fields.GetValueOrDefault("stream_id") is { Length: > 0 } s ? s : null;
}

/// The SSE line parser (event:, data:, blank line ends an event; a JSON frame's own "event"
/// names it).
public sealed class ChatSse
{
    private string _event = "message";
    private readonly List<string> _data = new();

    public ChatEvent? Feed(string line)
    {
        if (line.Length == 0)
        {
            var e = Flush();
            _event = "message";
            _data.Clear();
            return e;
        }
        if (line.StartsWith(':')) return null;
        if (line.StartsWith("event:", StringComparison.Ordinal)) _event = line[6..].Trim();
        else if (line.StartsWith("data:", StringComparison.Ordinal)) _data.Add(line[5..].StartsWith(' ') ? line[6..] : line[5..]);
        return null;
    }

    public ChatEvent? Finish()
    {
        var e = Flush();
        _data.Clear();
        return e;
    }

    public static ChatEvent FromSse(SseEvent e)
    {
        var p = new ChatSse();
        p._event = e.Event;
        p._data.Add(e.Data);
        return p.Flush()!;
    }

    private ChatEvent? Flush()
    {
        if (_data.Count == 0) return null;
        var raw = string.Join("\n", _data);
        var fields = new Dictionary<string, string>();
        var json = new JsonObject();
        try
        {
            if (JsonNode.Parse(raw) is JsonObject o)
            {
                json = o;
                foreach (var (k, v) in o)
                    if (v is JsonValue jv)
                        fields[k] = jv.TryGetValue<string>(out var s) ? s : jv.ToJsonString();
            }
            else fields["text"] = raw;
        }
        catch (JsonException) { fields["text"] = raw; }
        return new ChatEvent(fields.GetValueOrDefault("event") ?? _event, fields, json);
    }
}

public sealed record ChatApproval(string Command, string Description, string? Id)
{
    public enum Choice { once, session, always, deny }

    public static ChatApproval? FromJson(JsonObject json)
    {
        var p = json["pending"] as JsonObject ?? json;
        var a = new ChatApproval(J.S(p["command"]).Trim(), J.S(p["description"]).Trim(), J.StrOrNull(p["approval_id"]) is { Length: > 0 } id ? id : null);
        return a.Command.Length == 0 && a.Description.Length == 0 && J.S(p["kind"]) != "send" ? null : a;
    }

    public static JsonObject RespondBody(string session, Choice choice, string? approvalId)
    {
        var b = new JsonObject { ["session_id"] = session, ["choice"] = choice.ToString() };
        if (approvalId != null) b["approval_id"] = approvalId;
        return b;
    }
}

public sealed record ChatClarify(string Question, IReadOnlyList<string> Choices)
{
    public static ChatClarify? FromJson(JsonObject json)
    {
        var q = J.S(json["question"]).Trim();
        if (q.Length == 0) return null;
        var choices = (json["choices_offered"] as JsonArray ?? json["choices"] as JsonArray ?? new JsonArray()).Select(x => J.S(x)).ToList();
        return new ChatClarify(q, choices);
    }

    public static JsonObject RespondBody(string session, string answer) => new() { ["session_id"] = session, ["response"] = answer };
}

/// Who answers the island's Jarvis chat: the Chat default, a harness, or one model.
public abstract record ChatRunChoice
{
    public sealed record ChatDefault : ChatRunChoice;
    public sealed record Harness(string Id, string Name) : ChatRunChoice;
    public sealed record Model(string Id, string Label, string Provider) : ChatRunChoice;

    public string HarnessId => this switch { Harness h => h.Id, Model => "single", _ => "" };

    public string Title => this switch { Harness h => h.Name, Model m => m.Label.Length > 0 ? m.Label : m.Id, _ => "Jarvis" };

    public void Apply(JsonObject body)
    {
        // Present-but-empty means "follow the Chat default".
        body["harness_id"] = HarnessId;
        if (this is Model m)
        {
            body["model"] = m.Id;
            if (m.Provider.Length > 0) body["model_provider"] = m.Provider;
        }
    }
}

public static class ChatRequest
{
    public static JsonObject StartBody(string session, string message, IReadOnlyList<JsonObject> attachments, ChatRunChoice choice)
    {
        var b = new JsonObject { ["session_id"] = session, ["message"] = message };
        if (attachments.Count > 0) b["attachments"] = new JsonArray(attachments.Select(a => (JsonNode?)a.DeepClone()).ToArray());
        choice.Apply(b);
        return b;
    }
}

/// What goes with a message: the window he was looking at (Ctrl+Alt+W) and small text files.
public static class ChatContext
{
    public const int MaxInlineBytes = 64 * 1024;
    public const long MaxUploadBytes = 50L * 1024 * 1024;

    public sealed record Window(string App, string Title, string? Url)
    {
        public string Line
        {
            get
            {
                var s = $"I'm looking at {App}";
                if (Title.Length > 0) s += $" — \"{Title}\"";
                if (!string.IsNullOrEmpty(Url)) s += $" ({Url})";
                return s + ".";
            }
        }
    }

    public sealed record Attachment(string Path, string Name, bool IsImage, string? InlineText, long? Size);

    public static readonly IReadOnlySet<string> ImageExtensions = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        { ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".heic" };

    public static Attachment? ForFile(string path, Func<string, long?> size, Func<string, byte[]?> read)
    {
        var name = Model.Paths.LastComponent(path);
        var isImage = ImageExtensions.Contains(System.IO.Path.GetExtension(path));
        var bytes = size(path);
        if (bytes == null) return null;
        string? text = null;
        if (!isImage && bytes <= MaxInlineBytes && read(path) is { } data && !data.Contains((byte)0))
        {
            try { text = new System.Text.UTF8Encoding(false, true).GetString(data); }
            catch (System.Text.DecoderFallbackException) { }
        }
        return new Attachment(path, name, isImage, text, bytes);
    }

    public static bool CanUpload(long? size) => size is { } s && s <= MaxUploadBytes;

    public static string Prompt(string text, IReadOnlyList<Attachment> attachments, Window? window)
    {
        var parts = new List<string> { text };
        if (window != null) parts.Add(window.Line);
        foreach (var a in attachments)
            parts.Add(a.InlineText is { } body ? $"File {a.Name}:\n```\n{body}\n```" : $"(Attached: {a.Name})");
        return string.Join("\n\n", parts);
    }

    public static Window? FromFront(FrontWindow? w) => w == null ? null : new Window(w.App, w.Title, w.Url);
}

/// Ollama (11434) and LM Studio (1234): OpenAI-compatible streaming on this PC.
public static class LocalModel
{
    public const string Ollama = "http://127.0.0.1:11434";
    public const string LmStudio = "http://127.0.0.1:1234";

    public static string Normalise(string raw)
    {
        var s = raw.Trim().TrimEnd('/');
        foreach (var suffix in new[] { "/api", "/v1" })
            if (s.EndsWith(suffix, StringComparison.Ordinal)) s = s[..^suffix.Length];
        return s;
    }

    public static Uri ChatUrl(string b) => new(Normalise(b) + "/v1/chat/completions");
    public static Uri ModelsUrl(string b) => new(Normalise(b) + "/v1/models");

    public static string? Delta(string line)
    {
        if (!line.StartsWith("data:", StringComparison.Ordinal)) return null;
        var payload = line[5..].Trim();
        if (payload == "[DONE]") return null;
        try
        {
            var o = JsonNode.Parse(payload) as JsonObject;
            var content = J.S(J.Obj(J.Obj(J.Arr(o?["choices"]).FirstOrDefault())["delta"])["content"]);
            return content.Length > 0 ? content : null;
        }
        catch (JsonException) { return null; }
    }

    public static bool IsDone(string line) => line.StartsWith("data:", StringComparison.Ordinal) && line[5..].Trim() == "[DONE]";

    /// Closed <think> blocks gone, an open one hidden until it closes.
    public static string Visible(string text)
    {
        var s = text;
        while (s.IndexOf("<think>", StringComparison.Ordinal) is var open and >= 0)
        {
            var close = s.IndexOf("</think>", open + 7, StringComparison.Ordinal);
            if (close < 0) { s = s[..open]; break; }
            s = s.Remove(open, close + 8 - open);
        }
        return s.Trim();
    }

    public static IReadOnlyList<string> ChatModels(JsonObject json)
    {
        var skip = new[] { "embed", "bge-", "all-minilm", "clip", "rerank" };
        return J.Arr(json["data"]).Select(m => J.S(m["id"])).Where(id => id.Length > 0 && !skip.Any(k => id.ToLowerInvariant().Contains(k))).ToList();
    }
}

/// Browser address-bar values and window titles.
public static class BrowserUrl
{
    public static readonly IReadOnlySet<string> BrowserExes = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        { "chrome.exe", "msedge.exe", "firefox.exe", "brave.exe", "vivaldi.exe", "opera.exe", "arc.exe" };

    /// An address bar's text → a URL. A bare host gets https://; words with spaces are a search, not a URL.
    public static string? Normalise(string addressBarValue)
    {
        var v = addressBarValue.Trim();
        if (v.Length == 0 || v.Contains(' ')) return null;
        if (v.StartsWith("http://", StringComparison.OrdinalIgnoreCase) || v.StartsWith("https://", StringComparison.OrdinalIgnoreCase)
            || v.StartsWith("file://", StringComparison.OrdinalIgnoreCase)) return v;
        var host = v.Split('/', 2)[0];
        if (!host.Contains('.') && !host.StartsWith("localhost", StringComparison.OrdinalIgnoreCase)) return null;
        return "https://" + v;
    }

    private static readonly Dictionary<string, string[]> Suffixes = new(StringComparer.OrdinalIgnoreCase)
    {
        ["chrome.exe"] = new[] { " - Google Chrome" },
        ["msedge.exe"] = new[] { " - Microsoft​ Edge", " - Microsoft Edge" },
        ["firefox.exe"] = new[] { " — Mozilla Firefox", " - Mozilla Firefox" },
        ["brave.exe"] = new[] { " - Brave" },
        ["vivaldi.exe"] = new[] { " - Vivaldi" },
        ["opera.exe"] = new[] { " - Opera" },
        ["arc.exe"] = new[] { " - Arc" },
    };

    public static string StripBrowserSuffix(string title, string exe)
    {
        if (!Suffixes.TryGetValue(exe, out var list)) return title;
        foreach (var s in list)
            if (title.EndsWith(s, StringComparison.Ordinal)) return title[..^s.Length];
        return title;
    }
}

public sealed record ChatTurn(bool Mine, string Text, string Reasoning = "", IReadOnlyList<string>? Tools = null, string? Error = null,
    bool Streaming = false, bool Stopped = false);

/// A turn being streamed (port of ChatStreamState, the parts the island shows).
public sealed class ChatStreamState
{
    public string Text { get; private set; } = "";
    public string Reasoning { get; private set; } = "";
    public List<string> Tools { get; } = new();
    public string? StreamId { get; private set; }
    public ChatApproval? Approval { get; private set; }
    public ChatClarify? Clarify { get; private set; }
    public string? Error { get; private set; }
    public bool Ended { get; private set; }
    public bool Stopped { get; private set; }

    public bool Apply(ChatEvent e)
    {
        if (e.StreamId is { } id) StreamId = id;
        switch (e.Name)
        {
            case "token" or "delta" or "text":
                if (e.Token is not { } t) return false;
                Text += t;
                return true;
            case "reasoning" or "thinking":
                var r = e.Fields.GetValueOrDefault("text") ?? e.Fields.GetValueOrDefault("delta") ?? "";
                if (r.Length == 0) return false;
                Reasoning += r;
                return true;
            case "interim_assistant":
                if (J.B(e.Json["already_streamed"]) || Text.Trim().Length > 0) return false;
                Text += e.Fields.GetValueOrDefault("text") ?? "";
                return true;
            case "tool" or "tool_start" or "tool_call":
                var name = e.Fields.GetValueOrDefault("name") ?? "tool";
                if (name == "clarify") return false;
                Tools.Add(name.StartsWith("device_", StringComparison.Ordinal) ? name[7..] : name);
                return true;
            case "approval":
                Approval = ChatApproval.FromJson(e.Json);
                return Approval != null;
            case "clarify":
                Clarify = ChatClarify.FromJson(e.Json);
                return Clarify != null;
            case "error" or "apperror":
                Error = e.Error;
                Close();
                return true;
            case "cancel" or "cancelled":
                Stopped = true;
                Close();
                return true;
            case "done" or "stream_end" or "complete":
                if (Text.Trim().Length == 0 && e.Fields.GetValueOrDefault("answer") is { Length: > 0 } ans) Text = ans;
                Close();
                return true;
            default:
                return false;
        }
    }

    private void Close()
    {
        Ended = true;
        Approval = null;
        Clarify = null;
    }

    public ChatTurn ToTurn() => new(false, Text, Reasoning, Tools.ToList(), Error, !Ended, Stopped);
}
