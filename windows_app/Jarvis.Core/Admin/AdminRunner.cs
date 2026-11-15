using System.Text.Json.Nodes;
using Jarvis.Core.Link;

namespace Jarvis.Core.Admin;

public enum AdminStatus { Approved, Denied, Timeout, Failed }

/// What came of an admin ask. `Ok`/`Status` (the wire words) are kept for existing callers.
public sealed record AdminResult(bool Ok, string Status, string? Error)
{
    public AdminStatus Kind => Status switch
    {
        "approved" when Ok => AdminStatus.Approved,
        "denied" => AdminStatus.Denied,
        "timeout" => AdminStatus.Timeout,
        _ => AdminStatus.Failed,
    };

    /// The card's line once it's settled. Never mentions Windows Hello (it isn't used).
    public string Message => Kind switch
    {
        AdminStatus.Approved => "Approved on your iPhone. Click Yes on Windows' prompt to finish.",
        AdminStatus.Denied => "Denied on your iPhone. Nothing was run.",
        AdminStatus.Timeout => "No answer from your iPhone in 2 minutes. Nothing was run.",
        _ => $"Couldn't ask: {Error ?? "something went wrong"}",
    };
}

/// PC admin actions (C6): sends `admin_run`; jc-client asks his iPhone for Face ID and, only when
/// approved, launches the command elevated (Windows still shows UAC). No always-elevated helper.
public sealed class AdminRunner
{
    /// jc-client waits 120 s for the phone; the app waits a little longer.
    public static readonly TimeSpan ClientTimeout = TimeSpan.FromSeconds(125);

    /// The amber card's line while the phone is being asked.
    public const string AskingLine = "Approve on your iPhone with Face ID, then click Yes on Windows' prompt.";

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
