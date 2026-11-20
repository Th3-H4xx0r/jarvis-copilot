using System.Security.Cryptography;
using System.Text.Json.Nodes;
using Jarvis.Core.Unlock;

namespace Jarvis.Tests.Unlock;

/// His unlock permission (2026-11-20): one Face ID-signed permission unlocks this PC without asking each time,
/// until it ends (30 days at most) — checked here against the pinned key, never trusted from the server.
public class UnlockGrantTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
    private const string Device = "pc-1";

    private static (string Pub, Func<byte[], string> Sign) Phone()
    {
        var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var p = key.ExportParameters(false);
        var pub = Convert.ToBase64String(new byte[] { 0x04 }.Concat(p.Q.X!).Concat(p.Q.Y!).ToArray());
        return (pub, m => Convert.ToBase64String(key.SignData(m, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence)));
    }

    private static JsonObject Grant(Func<byte[], string> sign, string device = Device, long? until = null, long? ts = null,
                                    string id = "abababababababababababababababab", string signDevice = Device)
    {
        var t = ts ?? Now.ToUnixTimeSeconds();
        var u = until ?? t + 3600;
        var sig = sign(UnlockApproval.Message(UnlockGrant.Kind, id, t, UnlockGrant.Context(signDevice, u)));
        return new JsonObject { ["id"] = id, ["ts"] = t, ["until"] = u, ["device"] = device, ["signature"] = sig };
    }

    [Fact]
    public void A_Signed_Unexpired_Permission_For_This_PC_Unlocks()
    {
        var (pub, sign) = Phone();
        Assert.Null(UnlockGrant.Check(Grant(sign), Device, pub, Now));
    }

    [Fact]
    public void Ended_TooLong_OtherDevice_Tampered_Or_OtherKey_Is_Refused()
    {
        var (pub, sign) = Phone();
        var (_, otherSign) = Phone();
        Assert.NotNull(UnlockGrant.Check(Grant(sign), Device, pub, Now.AddHours(2)));                         // ended
        Assert.NotNull(UnlockGrant.Check(Grant(sign, until: Now.ToUnixTimeSeconds() + 31 * 86400), Device, pub, Now));
        Assert.NotNull(UnlockGrant.Check(Grant(sign, device: "mac-1", signDevice: "mac-1"), Device, pub, Now));
        var tampered = Grant(sign);
        tampered["until"] = Now.ToUnixTimeSeconds() + 7200;                                                   // longer than signed
        Assert.NotNull(UnlockGrant.Check(tampered, Device, pub, Now));
        Assert.NotNull(UnlockGrant.Check(Grant(otherSign), Device, pub, Now));                               // not his key
        Assert.NotNull(UnlockGrant.Check(Grant(sign, ts: Now.ToUnixTimeSeconds() + 3600), Device, pub, Now)); // from the future
        Assert.NotNull(UnlockGrant.Check(Grant(sign, id: "nope"), Device, pub, Now));
        Assert.NotNull(UnlockGrant.Check(Grant(sign), "", pub, Now));                                         // no device told
    }
}
