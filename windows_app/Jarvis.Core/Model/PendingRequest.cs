using System.Text.Json.Nodes;
using Jarvis.Core.Link;

namespace Jarvis.Core.Model;

public sealed record Question(string Text, string Header, bool MultiSelect, IReadOnlyList<string> Options, IReadOnlyList<string> Details);

/// An approval or question waiting in jc-client's arbiter (port of MacPending).
public sealed record PendingRequest(
    string Fingerprint, bool IsQuestion, string Agent, string Key, string Project, string Tool, string Summary,
    string Command, bool CanAlways, IReadOnlyList<Question> Questions)
{
    public static PendingRequest? FromJson(JsonObject json)
    {
        var fp = J.S(json["fingerprint"]);
        if (fp.Length == 0) return null;
        var p = J.S(json["project"]);
        return new PendingRequest(
            Fingerprint: fp,
            IsQuestion: J.S(json["kind"]) == "ask",
            Agent: J.S(json["agent"], "claude"),
            Key: J.S(json["key"]),
            Project: p.Length > 0 ? p : Paths.LastComponent(J.S(json["cwd"])),
            Tool: J.S(json["tool"]),
            Summary: J.S(json["summary"]),
            Command: J.S(json["command"]),
            CanAlways: J.B(json["can_always"]),
            Questions: J.Arr(json["questions"]).Select(q =>
            {
                var opts = J.Arr(q["options"]);
                return new Question(J.S(q["question"]), J.S(q["header"]), J.B(q["multiSelect"]),
                    opts.Select(o => J.S(o["label"])).ToList(), opts.Select(o => J.S(o["description"])).ToList());
            }).ToList());
    }
}

/// The answers body for a question card's Send: one string per single-select question, a list
/// per multi-select; typed text joins a multi list or replaces a single pick; unanswered omitted.
public static class QuestionAnswers
{
    public static JsonObject Build(IReadOnlyList<Question> qs, IReadOnlyDictionary<string, IReadOnlyList<string>> picks,
        IReadOnlyDictionary<string, string> typed)
    {
        var answers = new JsonObject();
        foreach (var q in qs)
        {
            var chosen = picks.TryGetValue(q.Text, out var p) ? p.ToList() : new List<string>();
            var t = typed.TryGetValue(q.Text, out var raw) ? raw.Trim() : "";
            if (t.Length > 0) chosen = q.MultiSelect ? chosen.Append(t).ToList() : new List<string> { t };
            if (chosen.Count == 0) continue;
            answers[q.Text] = q.MultiSelect ? new JsonArray(chosen.Select(c => (JsonNode?)JsonValue.Create(c)).ToArray()) : chosen[0];
        }
        return answers;
    }
}
