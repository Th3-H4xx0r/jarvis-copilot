using System.Text.Json.Nodes;
using Jarvis.Core.Link;

namespace Jarvis.Core.Unlock;

/// "Unlock PC" checked on the PC: the one rule for both places that act on it — the Jarvis app in his session
/// (PcUnlock's fill) and the JarvisUnlock service at the sign-in screen before he has signed in (HelperSignIn; no app
/// runs yet). The request is what jc-client relays, `{kind, context, nonce, proof:{ts, signature}, grant?, device}`,
/// and only his iPhone's key makes it pass: his unlock permission (UnlockGrant: signed, unexpired, for this computer)
/// or a fresh Face ID yes over exactly this request (UnlockApproval: at most 5 minutes old, each nonce once).
/// Nothing here may depend on other Core code but Link/Json.cs, UnlockApproval and UnlockGrant: the helper links it.
public static class UnlockCheck
{
    public const string Kind = "unlock";
    public const string NotUnlock = "This PC only fills its lock screen.";
    public const string NoKey = "Trust your iPhone in Jarvis Settings → PC power on the PC first.";
    public const string BadApproval = "Your iPhone's approval didn't check out on the PC.";

    /// Null when this request may unlock the PC now; otherwise why not, in his words. A Face ID yes is spent here
    /// (its nonce can't pass this `approval` again); his unlock permission stands until it ends.
    public static string? Refusal(JsonObject m, string? pinnedKey, UnlockApproval approval, DateTimeOffset now, string noKey = NoKey)
    {
        if (J.S(m["kind"]) != Kind) return NotUnlock;
        if (string.IsNullOrWhiteSpace(pinnedKey)) return noKey;
        if (m["grant"] is JsonObject grant)
            return UnlockGrant.Check(grant, J.S(m["device"]), pinnedKey, now);
        var proof = m["proof"] as JsonObject;
        return approval.Verify(J.S(m["context"]), Kind, J.S(m["nonce"]), Seconds(proof?["ts"]), J.S(proof?["signature"]), pinnedKey, now)
            ? null
            : BadApproval;
    }

    private static long Seconds(JsonNode? n) =>
        n is not JsonValue v ? 0 : v.TryGetValue<long>(out var l) ? l : v.TryGetValue<double>(out var d) ? (long)d : 0;
}
