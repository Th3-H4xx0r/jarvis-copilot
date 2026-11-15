using System.Globalization;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Jarvis.Core.Link;

/// JSON helpers for the loosely-typed objects that come over the link (the Swift `J`).
public static class J
{
    public static string S(JsonNode? v, string fallback = "")
    {
        if (v is JsonValue jv)
        {
            switch (jv.GetValueKind())
            {
                case JsonValueKind.String: return jv.GetValue<string>();
                case JsonValueKind.Number: return jv.ToJsonString();
            }
        }
        return fallback;
    }

    public static double? D(JsonNode? v)
    {
        if (v is not JsonValue jv) return null;
        switch (jv.GetValueKind())
        {
            case JsonValueKind.Number:
                return jv.TryGetValue<double>(out var d) ? d : double.Parse(jv.ToJsonString(), CultureInfo.InvariantCulture);
            case JsonValueKind.String:
                return double.TryParse(jv.GetValue<string>(), NumberStyles.Float, CultureInfo.InvariantCulture, out var p) ? p : null;
            default:
                return null;
        }
    }

    public static int I(JsonNode? v)
    {
        var d = D(v) ?? 0;
        if (double.IsNaN(d)) return 0;
        if (d >= int.MaxValue) return int.MaxValue;
        if (d <= int.MinValue) return int.MinValue;
        return (int)d;
    }

    public static long L(JsonNode? v)
    {
        var d = D(v) ?? 0;
        if (v is JsonValue jv && jv.GetValueKind() == JsonValueKind.Number && jv.TryGetValue<long>(out var l)) return l;
        if (double.IsNaN(d)) return 0;
        return (long)Math.Clamp(d, long.MinValue, long.MaxValue);
    }

    public static bool B(JsonNode? v)
    {
        if (v is not JsonValue jv) return false;
        return jv.GetValueKind() switch
        {
            JsonValueKind.True => true,
            JsonValueKind.Number => (D(v) ?? 0) != 0,
            _ => false,
        };
    }

    public static JsonObject Obj(JsonNode? v) => v as JsonObject ?? new JsonObject();

    public static IReadOnlyList<JsonObject> Arr(JsonNode? v) =>
        v is JsonArray a ? a.OfType<JsonObject>().ToList() : Array.Empty<JsonObject>();

    /// A string or null (the Swift `msg["x"] as? String`).
    public static string? StrOrNull(JsonNode? v) =>
        v is JsonValue jv && jv.GetValueKind() == JsonValueKind.String ? jv.GetValue<string>() : null;

    public static JsonObject Parse(string json) =>
        JsonNode.Parse(json) as JsonObject ?? throw new JsonException("not a JSON object");

    /// Text as-is (no \u escapes for quotes, apostrophes or non-ASCII), like the Swift side.
    public static readonly JsonSerializerOptions Plain = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    /// Compact JSON with object keys sorted ordinally at every level.
    public static string SortedJson(JsonNode n) => Sorted(n)?.ToJsonString(Plain) ?? "null";

    private static JsonNode? Sorted(JsonNode? n) => n switch
    {
        JsonObject o => new JsonObject(o.OrderBy(p => p.Key, StringComparer.Ordinal)
            .Select(p => KeyValuePair.Create(p.Key, Sorted(p.Value)))),
        JsonArray a => new JsonArray(a.Select(Sorted).ToArray()),
        null => null,
        _ => n.DeepClone(),
    };
}
