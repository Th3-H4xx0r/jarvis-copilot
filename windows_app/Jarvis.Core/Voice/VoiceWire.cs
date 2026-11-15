using System.Globalization;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using Jarvis.Core.Link;

namespace Jarvis.Core.Voice;

// The realtime transport's wire format (`/api/voice/s2s/ws`), as a pure codec.
// Port of ios_app/JarvisCopilot/Copilot/Voice/VoiceSession.swift (VoiceServerFrame / VoiceClientMessage).

/// Client → server.
public abstract record VoiceClientMessage
{
    private VoiceClientMessage() { }

    private static readonly JsonSerializerOptions Compact = new()
    {
        WriteIndented = false,
        // Like JSONSerialization: non-ASCII text goes out as itself, not \uXXXX.
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public abstract JsonObject Payload();

    /// Compact JSON with sorted keys, so a test can compare the exact string.
    public string Encoded()
    {
        var sorted = new JsonObject(Payload().OrderBy(p => p.Key, StringComparer.Ordinal)
            .Select(p => KeyValuePair.Create(p.Key, p.Value?.DeepClone())));
        return sorted.ToJsonString(Compact);
    }

    /// Opens (or resets) the server's per-turn audio buffer. With a harness other than "single" the
    /// server picks the model, so model/provider ride along only without one.
    public sealed record BeginTurn(int SampleRate, string? SessionId, string? Model, string? Provider,
        string? HarnessId = null, bool ClearStaleStream = false) : VoiceClientMessage
    {
        public override JsonObject Payload()
        {
            var o = new JsonObject { ["type"] = "begin_turn", ["sample_rate"] = SampleRate };
            if (ClearStaleStream) o["clear_stale_stream"] = true;
            if (!string.IsNullOrEmpty(SessionId)) o["session_id"] = SessionId;
            var harness = HarnessId ?? "";
            if (harness.Length > 0) o["harness_id"] = harness;
            if (harness.Length == 0 || harness == "single")
            {
                if (!string.IsNullOrEmpty(Model)) o["model"] = Model;
                if (!string.IsNullOrEmpty(Provider)) o["model_provider"] = Provider;
            }
            return o;
        }
    }

    /// Run the agent on this turn. `Text` is the on-device transcript when there is one (the server
    /// then skips its own STT); the timestamps line the server's spans up with the user's last word.
    public sealed record EndTurn(string? Text, long ClientTs, long? SpeechEndTs, string? TurnId) : VoiceClientMessage
    {
        public override JsonObject Payload()
        {
            var o = new JsonObject { ["type"] = "end_turn", ["client_ts"] = ClientTs };
            if (!string.IsNullOrEmpty(Text)) o["text"] = Text;
            if (SpeechEndTs is { } end) o["speech_end_ts"] = end;
            if (!string.IsNullOrEmpty(TurnId)) o["turn_id"] = TurnId;
            return o;
        }
    }

    /// Stop the reply. `Heard` is how much of it the user actually heard.
    public sealed record Interrupt(string? Heard) : VoiceClientMessage
    {
        public override JsonObject Payload()
        {
            var o = new JsonObject { ["type"] = "interrupt" };
            if (Heard != null) o["heard"] = Heard;
            return o;
        }
    }
}

/// Server → client.
public abstract record VoiceServerFrame
{
    private VoiceServerFrame() { }

    /// `ClearsStaleStream`: the server clears a stream left running for the session itself.
    public sealed record Ready(bool ClearsStaleStream) : VoiceServerFrame;
    /// The user's speech, as the server's STT hears it.
    public sealed record Transcript(string Text) : VoiceServerFrame;
    /// A chunk of the assistant's reply text.
    public sealed record AssistantText(string Text) : VoiceServerFrame;
    public sealed record Tool(string Name, string Status) : VoiceServerFrame;
    /// A reply segment is starting; `Format` is "pcm_s16le" or "mp3".
    public sealed record AudioMeta(string Format, int SampleRate) : VoiceServerFrame;
    public sealed record AudioEnd : VoiceServerFrame;
    /// Every turn outcome, failures included (see VoiceTurnMachine.FailureReasons). `Followup`: a
    /// hand-off's answer will still arrive (EscalationResult).
    public sealed record EndTurnFrame(string Reason, bool Followup) : VoiceServerFrame;
    /// The server's engine heard the end of the utterance.
    public sealed record EndOfSpeech : VoiceServerFrame;
    /// The server's end-of-turn timing summary, span name → ms.
    public sealed record Latency(string TurnId, IReadOnlyDictionary<string, double> Spans) : VoiceServerFrame
    {
        public bool Equals(Latency? other) =>
            other is not null && TurnId == other.TurnId && Spans.Count == other.Spans.Count
            && Spans.All(kv => other.Spans.TryGetValue(kv.Key, out var v) && v.Equals(kv.Value));

        public override int GetHashCode() => HashCode.Combine(TurnId, Spans.Count);
    }
    /// The slow lane finished after a turn was already answered.
    public sealed record EscalationResult(string Text) : VoiceServerFrame;
    /// A binary audio frame for the current segment (never produced by Decode).
    public sealed record Audio(byte[] Data) : VoiceServerFrame;
    /// A type we don't handle; carried so it can be logged, not dropped silently.
    public sealed record Other(string Type) : VoiceServerFrame;

    /// Null when the text is not a JSON object.
    public static VoiceServerFrame? Decode(string json)
    {
        JsonObject msg;
        try
        {
            if (JsonNode.Parse(json) is not JsonObject o) return null;
            msg = o;
        }
        catch (JsonException)
        {
            return null;
        }
        return Decode(msg);
    }

    public static VoiceServerFrame Decode(JsonObject msg)
    {
        var type = Str(msg["type"]) ?? "";
        switch (type)
        {
            case "ready":
                return new Ready(Bool(msg["clears_stale_stream"]) ?? false);
            case "transcript":
                return new Transcript(Str(msg["text"]) ?? "");
            case "assistant_text":
                return new AssistantText(Str(msg["text"]) ?? "");
            case "tool":
                return new Tool(Str(msg["name"]) ?? "tool", Str(msg["status"]) ?? "started");
            case "audio_meta":
                // The server sends "sample_rate": 0 with "format": "mp3" (the container carries its own
                // rate); zero must never reach the player.
                var rate = Int(msg["sample_rate"]) ?? 0;
                return new AudioMeta(Str(msg["format"]) ?? "pcm_s16le", rate > 0 ? rate : 24000);
            case "audio_end":
                return new AudioEnd();
            case "end_turn":
                return new EndTurnFrame(Str(msg["reason"]) ?? "", Bool(msg["followup"]) ?? false);
            case "end_of_speech":
                return new EndOfSpeech();
            case "latency":
                // Current servers send {"turn_id", "spans": {name: ms}}; older ones a flat span/ms pair.
                var spans = new Dictionary<string, double>();
                if (msg["spans"] is JsonObject so)
                {
                    foreach (var (name, value) in so)
                    {
                        if (value is JsonValue v && v.GetValueKind() == JsonValueKind.Number && J.D(v) is { } ms)
                            spans[name] = ms;
                    }
                }
                if (spans.Count == 0 && Str(msg["span"]) is { } span) spans[span] = Double(msg["ms"]) ?? 0;
                return new Latency(Str(msg["turn_id"]) ?? "", spans);
            case "escalation_result":
                return new EscalationResult(Str(msg["text"]) ?? "");
            default:
                return new Other(type);
        }
    }

    // The Swift `[String: Any]` helpers (JarvisAPI.swift): lenient about numbers vs strings.

    private static string? Str(JsonNode? v) => v is JsonValue jv
        ? jv.GetValueKind() switch
        {
            JsonValueKind.String => jv.GetValue<string>(),
            JsonValueKind.Number => jv.ToJsonString(),
            JsonValueKind.True => "1",
            JsonValueKind.False => "0",
            _ => null,
        }
        : null;

    private static int? Int(JsonNode? v)
    {
        if (v is not JsonValue jv) return null;
        switch (jv.GetValueKind())
        {
            case JsonValueKind.Number:
                return J.I(jv);
            case JsonValueKind.String:
                return int.TryParse(jv.GetValue<string>(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var i) ? i : null;
            default:
                return null;
        }
    }

    private static double? Double(JsonNode? v) => v is JsonValue jv && jv.GetValueKind() is JsonValueKind.Number or JsonValueKind.String
        ? J.D(jv)
        : null;

    private static bool? Bool(JsonNode? v)
    {
        if (v is not JsonValue jv) return null;
        return jv.GetValueKind() switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            JsonValueKind.Number => (J.D(jv) ?? 0) != 0,
            JsonValueKind.String => jv.GetValue<string>().ToLowerInvariant() is "1" or "true" or "yes",
            _ => null,
        };
    }
}
