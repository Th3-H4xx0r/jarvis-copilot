using System.Text.Json;
using System.Text.Json.Nodes;
using Jarvis.Core.Link;

namespace Jarvis.Core.Live;

// The Live Jarvis wire protocol (v1), client side: a port of the phone's LiveProtocol.swift.
// Decoding is defensive throughout: a missing or oddly named field degrades to "understood less of
// that frame", never to a dropped capture.

public static class LiveHello
{
    public const string DeviceKind = "pc";
}

/// What this PC can do, sent once in `hello`. It streams PCM16 and lets the server transcribe.
public sealed record LiveCaps(string Stt = "none", string Codec = "pcm16", int Rate = 16000, bool Speak = true)
{
    public JsonObject Payload() => new()
    {
        ["audio"] = "stream", ["text"] = "stream", ["stt"] = Stt, ["embed"] = "none", ["embed_model"] = "",
        ["codec"] = Codec, ["rate"] = Rate, ["speak"] = Speak,
    };
}

public sealed record LiveResume(string LiveSessionId, int AfterSeq)
{
    public JsonObject Payload() => new() { ["live_session_id"] = LiveSessionId, ["after_seq"] = AfterSeq };
}

public abstract record LiveClientMessage
{
    public abstract JsonObject Payload();

    public string Encoded() => J.SortedJson(Payload());

    public static LiveClientMessage Hello(string deviceId, LiveCaps caps, LiveResume? resume) => new HelloMsg(deviceId, caps, resume);
    public static LiveClientMessage Seg(int startMs, int endMs, string text, string lang) => new SegMsg(startMs, endMs, text, lang);
    public static LiveClientMessage Source(string label) => new SourceMsg(label);
    public static LiveClientMessage Bye() => new ByeMsg();

    private sealed record HelloMsg(string DeviceId, LiveCaps Caps, LiveResume? Resume) : LiveClientMessage
    {
        public override JsonObject Payload()
        {
            var o = new JsonObject { ["t"] = "hello", ["device_id"] = DeviceId, ["device_kind"] = LiveHello.DeviceKind, ["caps"] = Caps.Payload() };
            if (Resume != null) o["resume"] = Resume.Payload();
            return o;
        }
    }

    private sealed record SegMsg(int StartMs, int EndMs, string Text, string Lang) : LiveClientMessage
    {
        public override JsonObject Payload() => new()
        {
            ["t"] = "seg", ["partial"] = false, ["ts_start_ms"] = StartMs, ["ts_end_ms"] = EndMs, ["text"] = Text,
            ["lang"] = Lang, ["local_label"] = "",
        };
    }

    private sealed record SourceMsg(string Label) : LiveClientMessage
    {
        public override JsonObject Payload() => new() { ["t"] = "source", ["source_label"] = Label };
    }

    private sealed record ByeMsg : LiveClientMessage
    {
        public override JsonObject Payload() => new() { ["t"] = "bye" };
    }
}

/// `[4B big-endian seq][8B big-endian ts_ms][payload]`.
public static class LiveAudioFrame
{
    public const int HeaderBytes = 12;

    public static byte[] Encode(int seq, long tsMs, ReadOnlySpan<byte> payload)
    {
        var o = new byte[HeaderBytes + payload.Length];
        var s = unchecked((uint)seq);
        var ts = (ulong)Math.Max(tsMs, 0);
        for (var i = 0; i < 4; i++) o[i] = (byte)(s >> (24 - 8 * i));
        for (var i = 0; i < 8; i++) o[4 + i] = (byte)(ts >> (56 - 8 * i));
        payload.CopyTo(o.AsSpan(HeaderBytes));
        return o;
    }

    public static (int Seq, long TsMs, byte[] Payload)? Decode(ReadOnlySpan<byte> data)
    {
        if (data.Length < HeaderBytes) return null;
        uint seq = 0;
        for (var i = 0; i < 4; i++) seq = (seq << 8) | data[i];
        ulong ts = 0;
        for (var i = 4; i < 12; i++) ts = (ts << 8) | data[i];
        return (unchecked((int)seq), (long)ts, data[HeaderBytes..].ToArray());
    }
}

public sealed record LiveSegment(int Seq, int StartMs, int EndMs, string? SpeakerId, string? SpeakerName, string Text, string Lang, string? Translation)
{
    /// Never a blank row: the server's name, else "Speaker N" from the id, else "Someone".
    public string Who => SpeakerName ?? (SpeakerId is { } id ? $"Speaker {id.Split('_', '-').Last()}" : "Someone");
}

public abstract record LiveServerFrame
{
    public sealed record Ready(string LiveSessionId, string ChatSessionId, int Seq, string Lane, string Engine) : LiveServerFrame;
    public sealed record Partial(string Text, int StartMs, string SpeakerLabel) : LiveServerFrame;
    public sealed record Seg(LiveSegment Segment) : LiveServerFrame;
    public sealed record Speaker(string Op, string SpeakerId, string? Name, IReadOnlyList<string> MergedFrom) : LiveServerFrame;
    public sealed record Insight(int Seq, string Kind, string Text, int? RefSeq) : LiveServerFrame;
    public sealed record Speak(string Text) : LiveServerFrame;
    public sealed record State(bool? Recording, bool? Paused, string? Message) : LiveServerFrame;
    public sealed record Error(string Message) : LiveServerFrame;
    public sealed record Other(string Type) : LiveServerFrame;

    private static string? NonEmpty(JsonNode? n) => J.StrOrNull(n) is { Length: > 0 } s ? s : null;
    private static int? Int(JsonNode? n) => J.D(n) is { } d ? (int)d : null;
    private static bool? Bool(JsonNode? n) => n is JsonValue v && v.TryGetValue<bool>(out var b) ? b : null;

    public static LiveServerFrame Decode(string json)
    {
        JsonObject o;
        try { o = J.Parse(json); }
        catch (Exception e) when (e is JsonException or InvalidOperationException) { return new Other("unparsable"); }
        return Decode(o);
    }

    public static LiveServerFrame Decode(JsonObject d)
    {
        var t = (NonEmpty(d["t"]) ?? NonEmpty(d["type"]) ?? "").ToLowerInvariant();
        switch (t)
        {
            case "ready":
                return new Ready(J.S(d["live_session_id"]), J.S(d["chat_session_id"]), J.I(d["seq"]),
                    (NonEmpty(d["lane"]) ?? "server").ToLowerInvariant() == "edge" ? "edge" : "server", J.S(d["engine"]));
            case "partial":
                return new Partial(J.S(d["text"]), J.I(d["start_ms"]), J.S(d["speaker"]));
            case "seg" or "segment":
                return new Seg(new LiveSegment(J.I(d["seq"]), J.I(d["ts_start_ms"]), J.I(d["ts_end_ms"]), NonEmpty(d["speaker_id"]),
                    NonEmpty(d["speaker_name"]) ?? NonEmpty(d["name"]), J.S(d["text"]), J.S(d["lang"]), NonEmpty(d["translation"])));
            case "speaker":
            {
                var merged = d["merged_from"] is JsonArray arr
                    ? arr.Select(x => J.S(x)).Where(x => x.Length > 0).ToList()
                    : NonEmpty(d["from"]) is { } one ? new List<string> { one } : new List<string>();
                return new Speaker((NonEmpty(d["op"]) ?? "rename").ToLowerInvariant(), NonEmpty(d["speaker_id"]) ?? NonEmpty(d["into"]) ?? "",
                    NonEmpty(d["name"]), merged);
            }
            case "insight":
                return new Insight(J.I(d["seq"]), NonEmpty(d["kind"]) ?? "monitor", J.S(d["text"]), Int(d["ref_seq"]));
            case "speak":
                return new Speak(J.S(d["text"]));
            case "state":
                return new State(Bool(d["recording"]), Bool(d["paused"]), NonEmpty(d["message"]) ?? NonEmpty(d["warning"]));
            case "error":
                return new Error(NonEmpty(d["error"]) ?? NonEmpty(d["message"]) ?? "Live Jarvis reported an error");
            default:
                return new Other(t);
        }
    }
}

/// Reconnects and resume for a Live capture: the socket dropping is the normal path, so each new
/// hello carries the last session id and the last seq the server acknowledged (`ready.seq` and
/// every `seg` after it). Backoff 1, 2, 4, 8 s, capped at 8.
public sealed class LiveSession
{
    public static readonly TimeSpan[] Backoff = { TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(4), TimeSpan.FromSeconds(8) };

    private int _attempt;

    public string? LiveSessionId { get; private set; }
    public int LastSeq { get; private set; }
    public int AudioSeq { get; private set; }
    public List<LiveSegment> Segments { get; } = new();

    public LiveClientMessage Hello(string deviceId) =>
        LiveClientMessage.Hello(deviceId, new LiveCaps(), LiveSessionId is { } id ? new LiveResume(id, LastSeq) : null);

    public byte[] NextAudioFrame(long tsMs, ReadOnlySpan<byte> pcm) => LiveAudioFrame.Encode(AudioSeq++, tsMs, pcm);

    public TimeSpan NextDelay() => Backoff[Math.Min(_attempt++, Backoff.Length - 1)];

    /// Apply a server frame to the transcript; returns it for the UI.
    public LiveServerFrame Apply(LiveServerFrame f)
    {
        switch (f)
        {
            case LiveServerFrame.Ready r:
                LiveSessionId = r.LiveSessionId.Length > 0 ? r.LiveSessionId : LiveSessionId;
                LastSeq = Math.Max(LastSeq, r.Seq);
                _attempt = 0;
                break;
            case LiveServerFrame.Seg s:
                LastSeq = Math.Max(LastSeq, s.Segment.Seq);
                var i = Segments.FindIndex(x => x.Seq == s.Segment.Seq);
                if (i >= 0) Segments[i] = s.Segment; else Segments.Add(s.Segment);
                break;
            case LiveServerFrame.Speaker sp:
                for (var k = 0; k < Segments.Count; k++)
                {
                    var seg = Segments[k];
                    if (sp.Op == "merge" && seg.SpeakerId != null && sp.MergedFrom.Contains(seg.SpeakerId))
                        Segments[k] = seg with { SpeakerId = sp.SpeakerId, SpeakerName = sp.Name ?? seg.SpeakerName };
                    else if (seg.SpeakerId == sp.SpeakerId && sp.Name != null)
                        Segments[k] = seg with { SpeakerName = sp.Name };
                }
                break;
        }
        return f;
    }
}
