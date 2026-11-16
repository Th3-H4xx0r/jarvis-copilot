using System.Security.Cryptography;
using Jarvis.Core.Crypto;
using Jarvis.Core.Remote;
using Jarvis.Core.Unlock;

namespace Jarvis.Tests.Remote;

public class RdpReleaseTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);

    private static (string Pub, Func<byte[], string> Sign) Phone()
    {
        var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var p = key.ExportParameters(false);
        var pub = Convert.ToBase64String(new byte[] { 4 }.Concat(p.Q.X!).Concat(p.Q.Y!).ToArray());
        return (pub, m => Convert.ToBase64String(key.SignData(m, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence)));
    }

    private static (ECDiffieHellman Key, string PubB64) EncKey()
    {
        var k = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);
        var p = k.ExportParameters(false);
        return (k, Convert.ToBase64String(new byte[] { 4 }.Concat(p.Q.X!).Concat(p.Q.Y!).ToArray()));
    }

    private static JsonObject Frame(string context, string kind, Func<byte[], string> sign, string? sigOverride = null)
    {
        var ts = Now.ToUnixTimeSeconds();
        const string nonce = "n0nce";
        return new JsonObject
        {
            ["type"] = "password_release", ["id"] = "r1", ["kind"] = kind, ["context"] = context, ["nonce"] = nonce,
            ["proof"] = new JsonObject { ["ts"] = ts, ["signature"] = sigOverride ?? sign(UnlockApproval.Message(kind, nonce, ts, context)) },
        };
    }

    private static string Ctx(string client, string? encPub) =>
        new JsonObject { ["session"] = "s1", ["client"] = client, ["enc_pub"] = encPub, ["device"] = "pranav-computer" }.ToJsonString();

    [Fact]
    public void Web_gets_the_password_for_its_session()
    {
        var (pub, sign) = Phone();
        var r = new RdpRelease().Handle(Frame(Ctx("web", null), "rdp", sign), pub, () => "pw!", Now);
        Assert.Equal("rdp_credential", (string)r["type"]!);
        Assert.Equal("s1", (string)r["session_id"]!);
        Assert.Equal("r1", (string)r["request_id"]!);   // the release's id, so jc-client can match it
        Assert.True((bool)r["ok"]!);
        Assert.Equal("pw!", (string)r["credential"]!["password"]!);
    }

    [Fact]
    public void Ios_gets_ciphertext_only_for_the_signed_key()
    {
        var (pub, sign) = Phone();
        var (enc, encPub) = EncKey();
        var r = new RdpRelease().Handle(Frame(Ctx("ios", encPub), "rdp", sign), pub, () => "pw!", Now);
        Assert.True((bool)r["ok"]!);
        var c = r["credential"]!.AsObject();
        Assert.Null(c["password"]);
        var pt = Ecies.Decrypt(Convert.FromBase64String((string)c["ciphertext"]!), Convert.FromBase64String((string)c["ephemeral_pub"]!),
            Convert.FromBase64String((string)c["nonce"]!), enc);
        Assert.Equal("pw!", System.Text.Encoding.UTF8.GetString(pt));
    }

    [Fact]
    public void Refuses_wrong_kind_bad_signature_and_replay()
    {
        var (pub, sign) = Phone();
        var release = new RdpRelease();
        Assert.False((bool)release.Handle(Frame(Ctx("web", null), "unlock", sign), pub, () => "pw", Now)["ok"]!);
        var (_, otherSign) = Phone();
        Assert.False((bool)release.Handle(Frame(Ctx("web", null), "rdp", otherSign), pub, () => "pw", Now)["ok"]!);
        var good = Frame(Ctx("web", null), "rdp", sign);
        Assert.True((bool)release.Handle(good, pub, () => "pw", Now)["ok"]!);
        Assert.False((bool)release.Handle(good, pub, () => "pw", Now)["ok"]!);   // a signed yes works once
    }

    [Fact]
    public void Ios_without_a_key_or_no_password_is_refused()
    {
        var (pub, sign) = Phone();
        Assert.False((bool)new RdpRelease().Handle(Frame(Ctx("ios", null), "rdp", sign), pub, () => "pw", Now)["ok"]!);
        var r = new RdpRelease().Handle(Frame(Ctx("web", null), "rdp", sign), pub, () => null, Now);
        Assert.False((bool)r["ok"]!);
        Assert.Equal("r1", (string)r["request_id"]!);
        Assert.Contains("Settings → PC power", (string)r["error"]!);
    }

    [Fact]
    public void A_frame_enc_pub_outside_the_signed_context_is_ignored()
    {
        var (pub, sign) = Phone();
        var (_, encPub) = EncKey();
        var f = Frame(Ctx("ios", null), "rdp", sign);
        f["enc_pub"] = encPub;   // not covered by his signature
        Assert.False((bool)new RdpRelease().Handle(f, pub, () => "pw", Now)["ok"]!);
    }
}
