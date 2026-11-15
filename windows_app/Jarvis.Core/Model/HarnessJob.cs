using System.Text.Json.Nodes;
using Jarvis.Core.Link;

namespace Jarvis.Core.Model;

public sealed record JobStep(string Text, string Detail);

/// A job a harness handed to a bigger model (the server's `harness_jobs` feed; port of MacJob).
public sealed record HarnessJob(
    string Id, string SessionId, string Label, string Model, string Status, string Activity, int Steps,
    DateTimeOffset StartedAt, DateTimeOffset? CompletedAt, string Task, string Surface, string Device,
    IReadOnlyList<JobStep> Trail, string Result, string Error)
{
    /// An ended job stays listed this long, like the server keeps it.
    public static readonly TimeSpan ShownFor = TimeSpan.FromMinutes(15);

    public string Key => $"job:{Id}";
    public bool Running => Status == "running";

    public SessionState State => Status switch
    {
        "running" => SessionState.Working,
        "done" => SessionState.Finished,
        "failed" or "lost" => SessionState.Error,
        _ => SessionState.Idle,
    };

    public string AgentName => Label.Length == 0 ? "Hand-off"
        : Label == Label.ToLowerInvariant() ? AgentSession.Capitalized(Label) : Label;

    /// The model without its provider: "@anthropic:claude-sonnet-5-5" → "claude-sonnet-5-5".
    public string ModelName => Model.StartsWith('@') && Model.IndexOf(':') is var c and >= 0 ? Model[(c + 1)..] : Model;

    public string StateLabel => Status switch
    {
        "running" => "Working",
        "done" => "Done",
        "failed" => "Failed",
        "lost" => "Cut short",
        "stopped" => "Stopped",
        _ => AgentSession.Capitalized(Status),
    };

    public string Line
    {
        get
        {
            if (Running) return Activity.Length == 0 ? "Working on it" : Activity;
            if (Error.Length > 0 && Status == "failed") return Error;
            var first = Result.Split('\n', '\r').FirstOrDefault(l => l.Length > 0) ?? "";
            return first.Length == 0 ? StateLabel : first;
        }
    }

    public string Origin
    {
        get
        {
            var how = Surface == "voice" ? "By voice" : Surface == "chat" ? "In chat" : "";
            if (Device.Length == 0) return how;
            return how.Length == 0 ? $"From {Device}" : $"{how} on {Device}";
        }
    }

    public string Elapsed(DateTimeOffset now)
    {
        var s = Math.Max(0, (int)((CompletedAt ?? now) - StartedAt).TotalSeconds);
        return s < 60 ? $"{s}s" : $"{s / 60}m {s % 60}s";
    }

    public bool Expired(DateTimeOffset now) => CompletedAt is { } done && now - done > ShownFor;

    public static HarnessJob FromJson(JsonObject json)
    {
        var asked = J.S(json["task"]);
        return new HarnessJob(
            Id: J.S(json["id"]),
            SessionId: J.S(json["session_id"]),
            Label: J.S(json["label"]),
            Model: J.S(json["model"]),
            Status: J.S(json["status"], "running"),
            Activity: J.S(json["activity"]),
            Steps: J.I(json["steps"]),
            StartedAt: AgentSession.Epoch(json["started_at"]),
            CompletedAt: J.D(json["completed_at"]) is not null ? AgentSession.Epoch(json["completed_at"]) : null,
            Task: asked.Length > 0 ? asked : J.S(json["note"]),
            Surface: J.S(json["surface"]),
            Device: J.S(json["device"]),
            Trail: J.Arr(json["trail"]).Select(t => new JobStep(J.S(t["t"]), J.S(t["detail"]))).ToList(),
            Result: J.S(json["result"]),
            Error: J.S(json["error"]));
    }
}
