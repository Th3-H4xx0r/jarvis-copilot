using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;

namespace Jarvis.Core.Holo;

/// The bits of HTTP the LAN receiver speaks (port of `HoloHTTP`; pure).
public static class HoloHttp
{
    public sealed record Head(string Method, string Path, IReadOnlyDictionary<string, string> Headers)
    {
        public long? ContentLength =>
            Headers.TryGetValue("content-length", out var v) && long.TryParse(v.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out var n)
                ? n : null;
    }

    public const int MaxHead = 64 * 1024;

    private static readonly byte[] Blank = "\r\n\r\n"u8.ToArray();

    /// Where the head ends (just past the blank line) within the first `count` bytes, or null while it hasn't.
    public static int? HeadEnd(byte[] data, int count)
    {
        var i = data.AsSpan(0, count).IndexOf(Blank);
        return i < 0 ? null : i + Blank.Length;
    }

    public static Head? Parse(ReadOnlySpan<byte> data)
    {
        string text;
        try { text = new UTF8Encoding(false, true).GetString(data); }
        catch (DecoderFallbackException) { text = Encoding.Latin1.GetString(data); }
        var lines = text.Split("\r\n");
        if (lines.Length == 0) return null;
        var first = lines[0].Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (first.Length < 2) return null;
        var headers = new Dictionary<string, string>();
        foreach (var line in lines.Skip(1))
        {
            if (line.Length == 0) continue;
            var colon = line.IndexOf(':');
            if (colon < 0) continue;
            headers[line[..colon].Trim().ToLowerInvariant()] = line[(colon + 1)..].Trim();
        }
        var path = first[1].Split('?', 2)[0];
        return new Head(first[0].ToUpperInvariant(), path, headers);
    }

    public static byte[] Response(int status, JsonObject json)
    {
        var body = Encoding.UTF8.GetBytes(json.ToJsonString());
        var reason = status switch
        {
            200 => "OK",
            400 => "Bad Request",
            401 => "Unauthorized",
            404 => "Not Found",
            405 => "Method Not Allowed",
            411 => "Length Required",
            413 => "Payload Too Large",
            500 => "Internal Server Error",
            503 => "Service Unavailable",
            _ => "Error",
        };
        var head = $"HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n";
        return Encoding.ASCII.GetBytes(head).Concat(body).ToArray();
    }

    /// Token check that takes the same time however much of it matches.
    public static bool SameToken(string a, string b)
    {
        var x = Encoding.UTF8.GetBytes(a);
        var y = Encoding.UTF8.GetBytes(b);
        if (x.Length != y.Length || x.Length == 0) return false;
        return System.Security.Cryptography.CryptographicOperations.FixedTimeEquals(x, y);
    }
}
