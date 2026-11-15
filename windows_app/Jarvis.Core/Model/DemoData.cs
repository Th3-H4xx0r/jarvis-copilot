using System.Text.Json.Nodes;

namespace Jarvis.Core.Model;

public enum Moment { NeedsYou, Finished, Failed, Started }

/// The `--demo` tour (port of the Mac's DemoEngine): made-up sessions working, an approval, a
/// question and a finish. Nothing is sent anywhere.
public static class DemoData
{
    public sealed record Step(double AtSeconds, IReadOnlyList<JsonObject> Sessions, IReadOnlyList<JsonObject> Pending);

    public static JsonObject Session(string key, string project, string state, string step, string? pending = null, double? now = null)
    {
        var t = now ?? DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
        var s = new JsonObject
        {
            ["key"] = key, ["agent"] = "claude", ["session_id"] = key, ["cwd"] = $@"C:\Users\demo\{project}",
            ["project"] = project, ["state"] = state, ["step"] = step,
            ["steps"] = new JsonArray(new JsonObject { ["t"] = "Read package.json" }, new JsonObject { ["t"] = step }),
            ["started_at"] = t - 120, ["last_event_at"] = t,
            ["terminal"] = new JsonObject { ["exe"] = "WindowsTerminal.exe" },
            ["turn"] = new JsonObject
            {
                ["prompt"] = "Make the tests pass",
                ["files"] = new JsonArray(new JsonObject
                {
                    ["path"] = $@"C:\Users\demo\{project}\src\app.ts", ["added"] = 4, ["removed"] = 1,
                    ["lines"] = new JsonArray(new JsonObject { ["k"] = "-", ["t"] = "const x = 1" }, new JsonObject { ["k"] = "+", ["t"] = "const x = 2" }),
                }),
            },
        };
        if (pending != null) s["pending"] = new JsonObject { ["kind"] = "approval", ["fingerprint"] = pending };
        return s;
    }

    public static IReadOnlyList<Step> Steps => new[]
    {
        new Step(0, new[] { Session("d1", "storefront", "working", "Bash: npm test") }, Array.Empty<JsonObject>()),
        new Step(3, new[] { Session("d1", "storefront", "working", "Edit app.ts"), Session("d2", "api", "thinking", "Thinking…") }, Array.Empty<JsonObject>()),
        new Step(6, new[] { Session("d1", "storefront", "approval", "Needs approval: Bash", "demo-fp"), Session("d2", "api", "working", "Grep TODO") },
            new[] { new JsonObject { ["fingerprint"] = "demo-fp", ["kind"] = "permission", ["agent"] = "claude", ["key"] = "d1",
                ["cwd"] = @"C:\Users\demo\storefront", ["tool"] = "Bash", ["summary"] = "Bash: rm -rf dist", ["command"] = "rm -rf dist", ["can_always"] = true } }),
        new Step(12, new[] { Session("d1", "storefront", "finished", "All 42 tests pass."), Session("d2", "api", "question", "Which database?") },
            new[] { new JsonObject { ["fingerprint"] = "demo-q", ["kind"] = "ask", ["agent"] = "claude", ["key"] = "d2", ["cwd"] = @"C:\Users\demo\api",
                ["questions"] = new JsonArray(new JsonObject { ["question"] = "Which database?", ["multiSelect"] = false,
                    ["options"] = new JsonArray(new JsonObject { ["label"] = "Postgres" }, new JsonObject { ["label"] = "SQLite" }) }) } }),
    };

    /// When the tour ends (the island returns to the real state).
    public const double EndsAtSeconds = 22;
}
