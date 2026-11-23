using System.Globalization;
using System.Text.Json.Nodes;
using Jarvis.Core.Link;

namespace Jarvis.Core.Pairing;

public enum PairStage { Loading, Waiting, Pairing, Paired, Failed }

/// The "Pair with your iPhone" screen's logic, over jc-client's app link (contract:
/// docs/superpowers/plans/2026-11-23-qr-pairing.md): `pair_status` (paired? which server?),
/// `pair_qr_start` (the QR payload and when it expires; a new key and listener each call),
/// `pair_state` broadcasts (waiting / pairing / paired / expired / error) and `pair_manual` (the
/// "Type a code instead" fallback). The code renews itself when it expires while the screen is
/// open; closing the screen stops that. Not thread-safe: the WPF Dispatcher is its only caller.
public sealed class PairFlow : IDisposable
{
    public const string OldClientError =
        "Jarvis on this PC is too old to show a pairing code. Update it (jc-client update), then try again.";

    /// An "expired" broadcast this soon after a new code is about the code it replaced.
    private static readonly TimeSpan FreshFor = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan ManualTimeout = TimeSpan.FromSeconds(45);

    private readonly IJcLink _link;
    private readonly TimeProvider _time;
    private ITimer? _tick;
    private bool _loading;
    private bool _disposed;
    private DateTimeOffset _codeAt;

    public PairFlow(IJcLink link, TimeProvider? time = null)
    {
        _link = link;
        _time = time ?? TimeProvider.System;
    }

    public PairStage Stage { get; private set; } = PairStage.Loading;
    public string? Payload { get; private set; }
    public DateTimeOffset? ExpiresAt { get; private set; }
    public string Host { get; private set; } = "";
    public int Port { get; private set; }
    public string? Error { get; private set; }
    /// What `pair_status` said: null until it answers.
    public bool? IsPaired { get; private set; }
    /// The server this PC is (or was last) paired with: the manual form's prefill. Empty when
    /// jc-client knows none; never a made-up LAN address.
    public string Server { get; private set; } = "";
    public string DeviceName { get; private set; } = "";
    public bool ManualBusy { get; private set; }
    public string? ManualError { get; private set; }

    public int SecondsLeft => ExpiresAt is { } at ? (int)Math.Max(0, Math.Ceiling((at - _time.GetUtcNow()).TotalSeconds)) : 0;

    /// "9:42", or "" when the code has no expiry.
    public string Countdown => ExpiresAt == null ? "" : FormatCountdown(SecondsLeft);

    public event Action? Changed;

    /// Settings' one line about it: "Paired with jarvis.example.com", "Not paired", or that
    /// jc-client didn't answer (null).
    public static string Summary(bool? paired, string server) => paired switch
    {
        null => "Jarvis isn't running on this PC",
        false => "Not paired",
        true => Uri.TryCreate(server.Trim(), UriKind.Absolute, out var u) && u.Host.Length > 0 ? $"Paired with {u.Host}"
            : server.Trim().Length > 0 ? $"Paired with {server.Trim()}" : "Paired",
    };

    public static string FormatCountdown(int seconds) =>
        string.Create(CultureInfo.InvariantCulture, $"{seconds / 60}:{seconds % 60:00}");

    /// True only when jc-client answers `pair_status` and says it isn't paired. An older jc-client
    /// or a link that's down never pops the screen on a guess.
    public static bool NeedsPairing(JsonObject statusReply) =>
        J.B(statusReply["ok"]) && statusReply["paired"] is JsonValue v && v.TryGetValue<bool>(out var paired) && !paired;

    public async Task<JsonObject> CheckAsync()
    {
        var reply = await _link.RequestAsync(new JsonObject { ["type"] = "pair_status" });
        if (_disposed || !J.B(reply["ok"])) return reply;
        if (reply["paired"] is JsonValue v && v.TryGetValue<bool>(out var paired)) IsPaired = paired;
        Server = J.S(reply["server"]).Trim();
        DeviceName = J.S(reply["device_name"]).Trim();
        Changed?.Invoke();
        return reply;
    }

    /// The screen opened: who we are (the manual form's server), then the first code.
    public async Task OpenAsync()
    {
        Stage = PairStage.Loading;
        Changed?.Invoke();
        await CheckAsync();
        if (_disposed) return;
        await NewCodeAsync();
    }

    /// A fresh code (the screen opening, the old one expiring, or "Try again").
    public async Task NewCodeAsync()
    {
        if (_disposed || _loading || Stage == PairStage.Paired) return;
        _loading = true;
        if (Stage == PairStage.Failed || Payload == null)
        {
            Stage = PairStage.Loading;
            Error = null;
            Changed?.Invoke();
        }
        JsonObject reply;
        try { reply = await _link.RequestAsync(new JsonObject { ["type"] = "pair_qr_start" }); }
        finally { _loading = false; }
        if (_disposed || Stage == PairStage.Paired) return;
        var payload = J.S(reply["payload"]);
        if (!J.B(reply["ok"]) || payload.Length == 0)
        {
            var error = J.S(reply["error"]);
            Stage = PairStage.Failed;
            Error = error.StartsWith("unknown request", StringComparison.Ordinal) ? OldClientError
                : error.Length > 0 ? error : "jc-client didn't make a code.";
            Payload = null;
            ExpiresAt = null;
            StopTick();
            Changed?.Invoke();
            return;
        }
        var now = _time.GetUtcNow();
        Payload = payload;
        Host = J.S(reply["host"]);
        Port = J.I(reply["port"]);
        var expires = J.L(reply["expires_at"]);
        // Already past (or missing): no countdown and no timer renewal, so a bad reply can't loop.
        ExpiresAt = expires > 0 && DateTimeOffset.FromUnixTimeSeconds(expires) > now ? DateTimeOffset.FromUnixTimeSeconds(expires) : null;
        _codeAt = now;
        Stage = PairStage.Waiting;
        Error = null;
        StartTick();
        Changed?.Invoke();
    }

    /// jc-client's `pair_state` broadcast.
    public void Handle(JsonObject msg)
    {
        if (_disposed || J.S(msg["type"]) != "pair_state" || Stage == PairStage.Paired) return;
        switch (J.S(msg["state"]))
        {
            case "waiting":
                if (Payload != null && Stage is PairStage.Pairing or PairStage.Waiting) Stage = PairStage.Waiting;
                break;
            case "pairing":
                Stage = PairStage.Pairing;
                break;
            case "paired":
                if (J.StrOrNull(msg["device_name"]) is { Length: > 0 } name) DeviceName = name;
                MarkPaired();
                return;
            case "expired":
                if (Stage == PairStage.Waiting && _time.GetUtcNow() - _codeAt >= FreshFor) _ = NewCodeAsync();
                return;
            case "error":
                Stage = PairStage.Failed;
                Error = J.StrOrNull(msg["error"]) is { Length: > 0 } e ? e : "Pairing didn't work.";
                break;
            default:
                return;
        }
        Changed?.Invoke();
    }

    /// "Type a code instead": the server's address and the code the iPhone shows (plus the
    /// Cloudflare Access service token when the server sits behind one).
    public async Task<bool> ManualAsync(string server, string code, string cfId = "", string cfSecret = "")
    {
        server = server.Trim();
        code = code.Trim();
        ManualError = server.Length == 0 ? "Type your Jarvis server's address."
            : !(server.StartsWith("https://", StringComparison.OrdinalIgnoreCase) || server.StartsWith("http://", StringComparison.OrdinalIgnoreCase))
                ? "The address starts with https:// (or http://)."
            : code.Length == 0 ? "Type the code your iPhone shows."
            : null;
        if (ManualError != null || ManualBusy || _disposed)
        {
            Changed?.Invoke();
            return false;
        }
        var body = new JsonObject { ["type"] = "pair_manual", ["server"] = server, ["code"] = code };
        if (cfId.Trim() is { Length: > 0 } id) body["cf_id"] = id;
        if (cfSecret.Trim() is { Length: > 0 } secret) body["cf_secret"] = secret;
        ManualBusy = true;
        Changed?.Invoke();
        JsonObject reply;
        try { reply = await _link.RequestAsync(body, ManualTimeout); }
        finally { ManualBusy = false; }
        if (_disposed) return false;
        if (!J.B(reply["ok"]))
        {
            var error = J.S(reply["error"]);
            ManualError = error.StartsWith("unknown request", StringComparison.Ordinal) ? OldClientError
                : error.Length > 0 ? error : "Pairing didn't work.";
            Changed?.Invoke();
            return false;
        }
        Server = server;
        MarkPaired();
        return true;
    }

    private void MarkPaired()
    {
        Stage = PairStage.Paired;
        IsPaired = true;
        Error = null;
        ManualError = null;
        StopTick();
        Changed?.Invoke();
    }

    /// Once a second: the countdown moves, and an expired code renews (only while it's waiting
    /// for the phone: never mid-claim, never over an error he hasn't seen).
    private void StartTick()
    {
        _tick ??= _time.CreateTimer(_ => OnTick(), null, TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(1));
    }

    private void OnTick()
    {
        if (_disposed) return;
        if (Stage == PairStage.Waiting && ExpiresAt != null && SecondsLeft <= 0)
        {
            _ = NewCodeAsync();
            return;
        }
        Changed?.Invoke();
    }

    private void StopTick()
    {
        _tick?.Dispose();
        _tick = null;
    }

    public void Dispose()
    {
        _disposed = true;
        StopTick();
    }
}
