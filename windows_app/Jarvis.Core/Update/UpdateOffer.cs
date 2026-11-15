using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Jarvis.Core.Link;

namespace Jarvis.Core.Update;

/// A Windows build the server offers (`GET /api/app-updates/latest?platform=windows`). Only an
/// HTTPS download with a SHA-256 (cross-plan (c)) is usable: the app is unsigned, so the hash is
/// what makes the download trustworthy.
public sealed partial record UpdateOffer(long Build, string Version, string Notes, long Size, Uri InstallUrl, string Sha256)
{
    [GeneratedRegex("^[0-9a-fA-F]{64}$")]
    private static partial Regex ShaRx();

    public static UpdateOffer? FromJson(JsonObject j)
    {
        if (!J.B(j["available"]) || J.S(j["platform"], "windows") != "windows") return null;
        if (!Uri.TryCreate(J.S(j["install_url"]), UriKind.Absolute, out var url) || url.Scheme != Uri.UriSchemeHttps) return null;
        var sha = J.S(j["sha256"]);
        if (!ShaRx().IsMatch(sha)) return null;
        var build = J.L(j["build"]);
        if (build <= 0) return null;
        return new UpdateOffer(build, J.S(j["version"]), J.S(j["notes"]).Trim(), J.L(j["size"]), url, sha.ToLowerInvariant());
    }

    public static string LatestPath(long build) => $"/api/app-updates/latest?platform=windows&build={build}";

    /// Offer only what's newer than what runs, never the same or an older build.
    public static bool IsNewer(long offered, long installed) => offered > installed;
}

/// When the update card may show (port of AppUpdateGate). Later puts one build off: hidden on
/// polls and pushes, back on the next launch or an activation 15 minutes on; a newer build shows.
public struct UpdateGate
{
    public static readonly TimeSpan Snooze = TimeSpan.FromMinutes(15);

    public enum Trigger { Launch, Activation, Poll, Push }

    private long? _laterBuild;
    private DateTimeOffset? _laterAt;

    public void Later(long build, DateTimeOffset at)
    {
        _laterBuild = build;
        _laterAt = at;
    }

    public readonly bool ShouldShow(long build, Trigger t, DateTimeOffset now)
    {
        if (_laterBuild is not { } lb || _laterAt is not { } at || build > lb) return true;
        return t == Trigger.Activation && now - at >= Snooze;
    }
}
