using System.Text.Json.Nodes;
using Jarvis.Core.Link;

namespace Jarvis.Core.Admin;

public sealed record AdminResult(bool Ok, string Status, string? Error);

/// PC admin actions (C6): sends `admin_run`; jc-client asks his iPhone for Face ID and, only when
/// approved, launches the command elevated (Windows still shows UAC). No always-elevated helper.
public sealed class AdminRunner
{
    /// jc-client waits 120 s for the phone; the app waits a little longer.
    public static readonly TimeSpan ClientTimeout = TimeSpan.FromSeconds(125);

    private readonly IJcLink _link;

    public AdminRunner(IJcLink link) => _link = link;

    /// The phone is being asked (the UI shows an amber "Waiting on your iPhone").
    public event Action<string>? Asking;
    public event Action<AdminResult>? Done;

    public async Task<AdminResult> RunAsync(string command, string why)
    {
        Asking?.Invoke(why);
        var reply = await _link.RequestAsync(new JsonObject { ["type"] = "admin_run", ["command"] = command, ["why"] = why }, ClientTimeout);
        var ok = J.B(reply["ok"]);
        var status = J.S(reply["status"]);
        var error = J.StrOrNull(reply["error"]);
        if (status.Length == 0) status = ok ? "approved" : error == JcLink.TimedOutError ? "timeout" : "error";
        var result = new AdminResult(ok, status, error);
        Done?.Invoke(result);
        return result;
    }
}
