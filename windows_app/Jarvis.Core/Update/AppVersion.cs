using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using Jarvis.Core.Link;

namespace Jarvis.Core.Update;

/// The running build, from `version.json` beside the exe (C5). A missing or unreadable file is
/// build 1: older than every published build.
public sealed record AppVersion(string Version, long Build)
{
    public static readonly AppVersion Unstamped = new("0.0.0", 1);

    public static AppVersion Read(string dir)
    {
        try
        {
            var p = Path.Combine(dir, "version.json");
            if (!File.Exists(p) || JsonNode.Parse(File.ReadAllText(p)) is not JsonObject o) return Unstamped;
            var build = J.L(o["build"]);
            return build > 0 ? new AppVersion(J.S(o["version"], "0.0.0"), build) : Unstamped;
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            return Unstamped;
        }
    }

    /// UTC `yyDDDHHmm`, the same as `date -u +%y%j%H%M`.
    public static long BuildStamp(DateTimeOffset utc)
    {
        var u = utc.ToUniversalTime();
        return long.Parse($"{u:yy}{u.DayOfYear:000}{u:HHmm}", CultureInfo.InvariantCulture);
    }
}
