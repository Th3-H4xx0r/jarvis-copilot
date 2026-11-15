using System.Text.Json.Nodes;
using Jarvis.Core.Link;

namespace Jarvis.Core.Power;

/// The PC's power state from jc-client's `mac_power_state` reply (cross-plan (a)). jc-client
/// reports wake as `{capable, adapter, reason}`; the plan's `{method, detail}` is read too.
public sealed record PcPowerState(bool KeepAwake, bool Held, string Reason, string WakeMethod, string WakeDetail)
{
    public static PcPowerState? FromReply(JsonObject reply)
    {
        if (!J.B(reply["ok"])) return null;
        var wake = J.Obj(reply["wake"]);
        var method = J.StrOrNull(wake["method"]) ?? (J.B(wake["capable"]) ? "wowlan" : "none");
        var detail = J.StrOrNull(wake["detail"]) ?? J.S(wake["reason"]);
        return new PcPowerState(J.B(reply["keep_awake"]), J.B(reply["held"]), J.S(reply["reason"]), method, detail);
    }

    public string WakeSentence => WakeMethod == "wowlan"
        ? "Wake from sleep works: the Mac or the Pod sends a wake-on-Wi-Fi packet."
        : "This Wi-Fi adapter can't wake the PC from sleep or off. Keep awake keeps it reachable with the screen off.";

    public string HeldLine => !Held ? "Nothing is holding the PC awake."
        : Reason switch
        {
            "manual" => "Kept awake by you.",
            "session" => "Kept awake while an agent session runs.",
            "" => "Kept awake.",
            _ => $"Kept awake ({Reason}).",
        };
}

/// Keep awake from the app: `mac_power_set {keep_awake}` then re-read `mac_power_state`.
public sealed class PcPowerClient
{
    private readonly IJcLink _link;

    public PcPowerClient(IJcLink link) => _link = link;

    public PcPowerState? Last { get; private set; }

    public event Action<PcPowerState>? Changed;

    public async Task<PcPowerState?> RefreshAsync()
    {
        var r = await _link.RequestAsync(new JsonObject { ["type"] = "mac_power_state" });
        if (PcPowerState.FromReply(r) is { } s)
        {
            Last = s;
            Changed?.Invoke(s);
        }
        return Last;
    }

    public async Task<PcPowerState?> SetKeepAwakeAsync(bool on)
    {
        await _link.RequestAsync(new JsonObject { ["type"] = "mac_power_set", ["keep_awake"] = on });
        return await RefreshAsync();
    }
}

/// The sleep/wake relay (the Mac's PowerRelay): will-sleep waits up to 4 s for jc-client to
/// flush and tell the server; did-wake is fire-and-forget.
public sealed class PowerRelay
{
    public static readonly TimeSpan SleepWait = TimeSpan.FromSeconds(4);

    private readonly IJcLink _link;
    private readonly TimeProvider _time;

    public PowerRelay(IJcLink link, TimeProvider? time = null)
    {
        _link = link;
        _time = time ?? TimeProvider.System;
    }

    public DateTimeOffset? LastEventAt { get; private set; }
    public string LastEvent { get; private set; } = "";

    public static JsonObject Message(string ev) => new() { ["type"] = "power", ["event"] = ev };

    public async Task WillSleepAsync()
    {
        Note("will_sleep");
        var request = _link.RequestAsync(Message("will_sleep"), SleepWait);
        // No context capture: the PC app blocks its UI thread on this while Windows suspends.
        await Task.WhenAny(request, Task.Delay(SleepWait, _time)).ConfigureAwait(false);
    }

    public void DidWake()
    {
        Note("did_wake");
        _ = _link.RequestAsync(Message("did_wake"));
    }

    private void Note(string ev)
    {
        LastEvent = ev;
        LastEventAt = _time.GetUtcNow();
    }
}
