using System.Text;
using System.Text.Json.Nodes;
using Jarvis.Core.Crypto;
using Jarvis.Core.Link;
using Jarvis.Core.Unlock;

namespace Jarvis.Core.Remote;

/// After his Face ID yes for a Remote Desktop session, hands the saved password to that one session:
/// encrypted to the iPhone's key named INSIDE the signed request (so the server relays only ciphertext),
/// or as text for the web gateway (held in the server's memory for that connection only).
/// A signed yes works once (the approval's nonce check).
public sealed class RdpRelease
{
    public const string NoPassword = "Save your Microsoft account password in Jarvis on this PC first (Settings → PC power → Remote Desktop).";
    private readonly UnlockApproval _approval = new();

    public JsonObject Handle(JsonObject release, string pinnedKeyB64, Func<string?> readPassword, DateTimeOffset now)
    {
        var context = J.S(release["context"]);
        JsonObject? ctx;
        try { ctx = JsonNode.Parse(context) as JsonObject; }
        catch (System.Text.Json.JsonException) { ctx = null; }
        var session = J.S(ctx?["session"]);
        JsonObject Fail(string why) => new() { ["type"] = "rdp_credential", ["session_id"] = session, ["ok"] = false, ["error"] = why };

        if (J.S(release["kind"]) != "rdp" || ctx == null || session.Length == 0) return Fail("Not a Remote Desktop request.");
        var proof = release["proof"] as JsonObject;
        var ts = proof?["ts"] is JsonValue tv && tv.TryGetValue<long>(out var t) ? t : 0;
        if (!_approval.Verify(context, "rdp", J.S(release["nonce"]), ts, J.S(proof?["signature"]), pinnedKeyB64, now))
            return Fail("Your iPhone's Face ID approval didn't check out.");
        var client = J.S(ctx["client"]);
        if (client is not ("ios" or "web")) return Fail("Unknown Remote Desktop client.");
        byte[]? encPub = null;
        if (client == "ios")
        {
            try { encPub = Convert.FromBase64String(J.S(ctx["enc_pub"])); }
            catch (FormatException) { }
            if (encPub is not { Length: 65 }) return Fail("The iPhone didn't send its encryption key.");
        }
        var password = readPassword();
        if (string.IsNullOrEmpty(password)) return Fail(NoPassword);

        JsonObject credential;
        if (client == "web")
            credential = new JsonObject { ["password"] = password };
        else
        {
            (byte[] ct, byte[] eph, byte[] nonce) sealed_;
            try { sealed_ = Ecies.Encrypt(Encoding.UTF8.GetBytes(password), encPub!); }
            catch (System.Security.Cryptography.CryptographicException) { return Fail("The iPhone's encryption key isn't valid."); }
            var (ct, eph, nonce) = sealed_;
            credential = new JsonObject
            {
                ["ciphertext"] = Convert.ToBase64String(ct), ["ephemeral_pub"] = Convert.ToBase64String(eph), ["nonce"] = Convert.ToBase64String(nonce),
            };
        }
        return new JsonObject { ["type"] = "rdp_credential", ["session_id"] = session, ["ok"] = true, ["credential"] = credential };
    }
}
