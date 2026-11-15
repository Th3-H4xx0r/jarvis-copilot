using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Jarvis.Core.Link;

public sealed record EndpointInfo(int Port, string Token, int Pid);

/// jc-client's endpoint file on Windows (C1): `{"v":1,"port":n,"token":"<64 lowercase hex>","pid":n}`
/// at the path the Mac uses for its socket.
public static partial class EndpointFile
{
    public static string DefaultPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".jarviscopilot-client", "ui.sock");

    [GeneratedRegex("^[0-9a-f]{64}$")]
    private static partial Regex TokenRx();

    public static EndpointInfo? Read(string path)
    {
        try
        {
            if (!File.Exists(path)) return null;
            var info = new FileInfo(path);
            if (info.Length > 4096) return null;
            if (JsonNode.Parse(File.ReadAllText(path)) is not JsonObject o) return null;
            if (!IsInt(o["v"], out var v) || v != 1) return null;
            if (!IsInt(o["port"], out var port) || port < 1 || port > 65535) return null;
            var token = J.StrOrNull(o["token"]);
            if (token == null || !TokenRx().IsMatch(token)) return null;
            if (!IsInt(o["pid"], out var pid) || pid < 0) return null;
            return new EndpointInfo(port, token, pid);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException)
        {
            return null;
        }
    }

    private static bool IsInt(JsonNode? n, out int value)
    {
        value = 0;
        return n is JsonValue jv && jv.GetValueKind() == JsonValueKind.Number && jv.TryGetValue(out value);
    }
}
