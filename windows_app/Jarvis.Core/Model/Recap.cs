using System.Text.Json.Nodes;
using Jarvis.Core.Link;

namespace Jarvis.Core.Model;

public sealed record RecapHighlight(string Icon, string Label, string Value);

/// The week's recap (`/api/coding/agents/recap`; port of MacRecap).
public sealed record Recap(
    int Minutes, int Sessions, int Files, int Added, int Removed, int Commands, int Approved, int Denied, int Answered,
    IReadOnlyList<RecapHighlight> Highlights)
{
    public bool IsEmpty => Minutes == 0;
    public string Time => Duration(Minutes);

    public static Recap FromJson(JsonObject json)
    {
        var h = new List<RecapHighlight>();
        var agent = J.Obj(json["top_agent"]);
        var project = J.Obj(json["top_project"]);
        var day = J.Obj(json["busiest_day"]);
        var longest = J.Obj(json["longest_session"]);
        if (J.StrOrNull(agent["agent"]) is { } a) h.Add(new("sparkles", "Top agent", AgentSession.DisplayName(a)));
        if (J.StrOrNull(project["project"]) is { } p) h.Add(new("folder", "Top project", p));
        if (J.StrOrNull(day["weekday"]) is { } d) h.Add(new("calendar", "Busiest day", $"{d} · {Duration(J.I(day["minutes"]))}"));
        if (J.StrOrNull(longest["project"]) is { } lp) h.Add(new("timer", "Longest session", $"{lp} · {Duration(J.I(longest["minutes"]))}"));
        return new Recap(J.I(json["minutes"]), J.I(json["sessions"]), J.I(json["files"]), J.I(json["added"]), J.I(json["removed"]),
            J.I(json["commands"]), J.I(json["approved"]), J.I(json["denied"]), J.I(json["answered"]), h);
    }

    public static string Duration(int minutes)
    {
        int h = minutes / 60, m = minutes % 60;
        if (h > 0 && m > 0) return $"{h}h {m}m";
        return h > 0 ? $"{h}h" : $"{m}m";
    }

    public static Uri? Url(string origin, int tzMinutes) =>
        Uri.TryCreate($"{origin}/api/coding/agents/recap?days=7&tz={tzMinutes}", UriKind.Absolute, out var u) ? u : null;
}
