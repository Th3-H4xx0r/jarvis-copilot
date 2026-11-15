using System.Globalization;
using System.Text.Json.Nodes;
using Jarvis.Core.Link;

namespace Jarvis.Core.Model;

/// Where a session's terminal is. On Windows jc-client adds `exe`, `window_pid`, `wt_session`
/// (cross-plan (b)); `term_program` is shared with the Mac.
public sealed record TerminalInfo(string TermProgram, string Exe, int WindowPid, string WtSession)
{
    public static readonly TerminalInfo None = new("", "", 0, "");

    public static TerminalInfo FromJson(JsonObject t) =>
        new(J.S(t["term_program"]), J.S(t["exe"]), J.I(t["window_pid"]), J.S(t["wt_session"]));
}

public sealed record DiffLine(char Kind, string Text);

public sealed record ChangedFile(string Path, int Added, int Removed, IReadOnlyList<DiffLine> Lines)
{
    /// The last path component, for either separator.
    public string Name => Model.Paths.LastComponent(Path);
}

public static class Paths
{
    /// Last component of a Windows or POSIX path ("" for none).
    public static string LastComponent(string path)
    {
        var trimmed = path.TrimEnd('\\', '/');
        var i = trimmed.LastIndexOfAny(new[] { '\\', '/' });
        return i < 0 ? trimmed : trimmed[(i + 1)..];
    }
}

/// One coding-agent session, as jc-client's engine sees it (port of MacSession).
public sealed record AgentSession(
    string Key, string Agent, string SessionId, string Cwd, string Project, SessionState State, string Step,
    IReadOnlyList<string> Steps, DateTimeOffset StartedAt, DateTimeOffset LastEventAt, TerminalInfo Terminal,
    string PendingFingerprint, string Prompt, string Final, IReadOnlyList<ChangedFile> Files)
{
    public string AgentName => DisplayName(Agent);

    public static string DisplayName(string agent) => agent switch
    {
        "claude" => "Claude Code",
        "claude-desktop" => "Claude Desktop",
        "codex" => "Codex",
        "gemini" => "Gemini CLI",
        "cursor" => "Cursor",
        "copilot" => "Copilot CLI",
        "opencode" => "OpenCode",
        "amp" => "Amp",
        "antigravity" => "Antigravity",
        "muse" => "Muse Code",
        "" => "Agent",
        _ => Capitalized(agent),
    };

    /// Swift's `capitalized`: first letter of each word upper, the rest lower.
    internal static string Capitalized(string s) =>
        CultureInfo.InvariantCulture.TextInfo.ToTitleCase(s.ToLowerInvariant());

    internal static DateTimeOffset Epoch(JsonNode? v) =>
        DateTimeOffset.FromUnixTimeMilliseconds((long)Math.Round((J.D(v) ?? 0) * 1000));

    public static AgentSession FromJson(JsonObject json)
    {
        var cwd = J.S(json["cwd"]);
        var p = J.S(json["project"]);
        var last = Paths.LastComponent(cwd);
        var project = p.Length > 0 ? p : (last.Length > 0 ? last : "session");
        var turn = J.Obj(json["turn"]);
        var files = J.Arr(turn["files"]).Select(f => new ChangedFile(
            J.S(f["path"]), J.I(f["added"]), J.I(f["removed"]),
            J.Arr(f["lines"]).Select(l => new DiffLine(J.S(l["k"]) is { Length: > 0 } k ? k[0] : ' ', J.S(l["t"]))).ToList())).ToList();
        return new AgentSession(
            Key: J.S(json["key"]),
            Agent: J.S(json["agent"], "claude"),
            SessionId: J.S(json["session_id"]),
            Cwd: cwd,
            Project: project,
            State: SessionStates.Parse(J.S(json["state"])),
            Step: J.S(json["step"]),
            Steps: J.Arr(json["steps"]).Select(s => J.S(s["t"])).ToList(),
            StartedAt: Epoch(json["started_at"]),
            LastEventAt: Epoch(json["last_event_at"]),
            Terminal: TerminalInfo.FromJson(J.Obj(json["terminal"])),
            PendingFingerprint: J.S(J.Obj(json["pending"])["fingerprint"]),
            Prompt: J.S(turn["prompt"]),
            Final: J.S(turn["final"]),
            Files: files);
    }

    /// Most urgent first, then newest.
    public static IReadOnlyList<AgentSession> Sorted(IEnumerable<AgentSession> items) =>
        items.OrderBy(s => s.State.Urgency()).ThenByDescending(s => s.LastEventAt).ToList();
}
