using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Jarvis.Core.Link;

namespace Jarvis.Core.Unlock;

/// His unlock permission (2026-11-20): one Face ID-signed permission lets Jarvis unlock this PC without asking each
/// time, until it ends (30 days at most, his pick). Signed with the same iPhone key as an approval — kind
/// "unlock-grant", nonce = the permission's id, ts = when he gave it, context = the device and the end time — so a
/// server can't make one, stretch one or move one from the Mac to the PC. Stopping it needs no signature.
public static class UnlockGrant
{
    public const string Kind = "unlock-grant";
    public static readonly TimeSpan MaxLength = TimeSpan.FromDays(30);
    private static readonly Regex Id = new("^[0-9a-f]{32}$", RegexOptions.CultureInvariant);

    /// What the signature covers besides the id and time (MacPasswordWire.grantContext on the iPhone and Mac).
    public static string Context(string device, long until) => $"unlock-grant device={device} until={until}";

    /// Null when this permission lets this PC unlock now; otherwise why not, in his words.
    public static string? Check(JsonObject? grant, string device, string publicKeyB64, DateTimeOffset now)
    {
        if (grant is null) return "There's no unlock permission.";
        var id = J.S(grant["id"]);
        long ts = Seconds(grant["ts"]), until = Seconds(grant["until"]);
        if (!Id.IsMatch(id) || ts <= 0 || until <= 0) return "The unlock permission doesn't look right.";
        if (device.Length == 0 || J.S(grant["device"]) != device) return "The unlock permission is for another computer.";
        var nowS = now.ToUnixTimeSeconds();
        if (until <= nowS) return "Your unlock permission has ended.";
        if (ts > nowS + 120 || until - ts > MaxLength.TotalSeconds + 60) return "The unlock permission's dates aren't allowed.";
        var message = UnlockApproval.Message(Kind, id, ts, Context(device, until));
        if (!UnlockApproval.SignatureValid(message, J.S(grant["signature"]), publicKeyB64))
            return "Your unlock permission didn't check out on the PC.";
        return null;
    }

    private static long Seconds(JsonNode? n) =>
        n is not JsonValue v ? 0 : v.TryGetValue<long>(out var l) ? l : v.TryGetValue<double>(out var d) ? (long)d : 0;
}
