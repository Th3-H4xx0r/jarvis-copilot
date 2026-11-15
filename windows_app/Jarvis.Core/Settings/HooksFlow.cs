using System.Text.Json.Nodes;
using Jarvis.Core.Link;
using Jarvis.Core.State;

namespace Jarvis.Core.Settings;

/// The Agents pane's install flow: preview shows the exact change (a diff and a token), Install
/// writes only that change (the token). A stale token (settings changed since) shows jc-client's
/// error and re-previews, so he always installs what he saw.
public sealed class HooksFlow
{
    public static readonly IReadOnlyList<string> Agents = new[] { "claude", "codex", "gemini", "copilot" };

    private readonly AppState _state;

    public HooksFlow(AppState state) => _state = state;

    public string Agent { get; set; } = "claude";
    public bool StatusLine { get; set; } = true;
    public string Diff { get; private set; } = "";
    public string? Token { get; private set; }
    public string? Error { get; private set; }
    public bool Busy { get; private set; }
    /// agent → a one-line status ("installed", "not installed", …).
    public IReadOnlyDictionary<string, string> Status { get; private set; } = new Dictionary<string, string>();

    public event Action? Changed;

    public async Task PreviewAsync()
    {
        Busy = true;
        Changed?.Invoke();
        var r = await _state.HooksAsync("preview", Agent, statusline: StatusLine);
        Busy = false;
        if (J.B(r["ok"]))
        {
            Diff = J.S(r["diff"]);
            Token = J.StrOrNull(r["token"]);
        }
        else
        {
            Error = J.S(r["error"], "Couldn't preview the change.");
        }
        Changed?.Invoke();
    }

    public async Task<bool> InstallAsync()
    {
        if (Token == null) { await PreviewAsync(); return false; }
        Busy = true;
        Error = null;
        Changed?.Invoke();
        var r = await _state.HooksAsync("install", Agent, Token, StatusLine);
        Busy = false;
        if (J.B(r["ok"]))
        {
            Token = null;
            Diff = "";
            await RefreshStatusAsync();
            return true;
        }
        Error = J.S(r["error"], "Couldn't install.");
        var keepError = Error;
        await PreviewAsync();
        Error = keepError;
        Changed?.Invoke();
        return false;
    }

    public async Task UninstallAsync()
    {
        var r = await _state.HooksAsync("uninstall", Agent, statusline: StatusLine);
        Error = J.B(r["ok"]) ? null : J.S(r["error"], "Couldn't uninstall.");
        await RefreshStatusAsync();
    }

    public async Task RefreshStatusAsync()
    {
        var r = await _state.HooksAsync("status", "all");
        var map = new Dictionary<string, string>();
        foreach (var (agent, node) in J.Obj(r["agents"])) map[agent] = Describe(node);
        Status = map;
        Changed?.Invoke();
    }

    /// jc-client's status is a string or an object with `installed`/`state`; show one line.
    public static string Describe(JsonNode? node) => node switch
    {
        JsonValue v when v.TryGetValue<string>(out var s) => s,
        JsonValue v when v.TryGetValue<bool>(out var b) => b ? "installed" : "not installed",
        JsonObject o when J.StrOrNull(o["state"]) is { } st => st,
        JsonObject o when o["installed"] is not null => J.B(o["installed"]) ? "installed" : "not installed",
        null => "unknown",
        _ => node.ToJsonString(),
    };

    /// Which lines of a unified diff are additions/removals (the pane colours them).
    public static IReadOnlyList<(char Kind, string Text)> DiffLines(string diff) =>
        diff.Split('\n').Select(l => (l.StartsWith("+++") || l.StartsWith("---") ? ' ' : l.Length > 0 && l[0] is '+' or '-' ? l[0] : ' ', l.TrimEnd('\r'))).ToList();
}
