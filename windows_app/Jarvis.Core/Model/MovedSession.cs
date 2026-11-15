using System.Text.Json.Nodes;
using Jarvis.Core.Link;

namespace Jarvis.Core.Model;

/// A session this PC handed to the server (it slept): listed as "On server" with Bring back.
public sealed record MovedSession(string Ckey, string Agent, string Title, string Project)
{
    public static MovedSession FromJson(JsonObject json)
    {
        var project = J.S(json["project"]);
        var t = J.S(json["title"]);
        return new MovedSession(J.S(json["ckey"]), J.S(json["agent"], "claude"), t.Length == 0 ? project : t, project);
    }
}
