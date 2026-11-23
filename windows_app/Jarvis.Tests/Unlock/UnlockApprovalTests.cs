using System.Security.Cryptography;
using Jarvis.Core.Unlock;

namespace Jarvis.Tests.Unlock;

public class UnlockApprovalTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);

    private static (string Pub, Func<byte[], string> Sign) Phone()
    {
        var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var p = key.ExportParameters(false);
        var pub = Convert.ToBase64String(new byte[] { 0x04 }.Concat(p.Q.X!).Concat(p.Q.Y!).ToArray());
        return (pub, m => Convert.ToBase64String(key.SignData(m, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence)));
    }

    [Fact]
    public void Message_MatchesThePhonesWire()
    {
        var m = System.Text.Encoding.UTF8.GetString(UnlockApproval.Message("unlock", "n1", 42, "Unlock PC"));
        var digest = Convert.ToHexString(SHA256.HashData("Unlock PC"u8.ToArray())).ToLowerInvariant();
        Assert.Equal($"jarvis-mac-password|unlock|n1|42|{digest}", m);
    }

    [Fact]
    public void Verify_AcceptsHisSignatureOnce()
    {
        var (pub, sign) = Phone();
        var ts = Now.ToUnixTimeSeconds();
        var sig = sign(UnlockApproval.Message("unlock", "n1", ts, "Unlock PC"));
        var a = new UnlockApproval();
        Assert.True(a.Verify("Unlock PC", "unlock", "n1", ts, sig, pub, Now));
        Assert.False(a.Verify("Unlock PC", "unlock", "n1", ts, sig, pub, Now));   // replay
    }

    [Fact]
    public void Verify_RefusesOtherText_OtherKey_OldOrEmpty()
    {
        var (pub, sign) = Phone();
        var (otherPub, _) = Phone();
        var ts = Now.ToUnixTimeSeconds();
        var sig = sign(UnlockApproval.Message("unlock", "n2", ts, "Unlock PC"));
        var a = new UnlockApproval();
        Assert.False(a.Verify("Something else", "unlock", "n2", ts, sig, pub, Now));
        Assert.False(a.Verify("Unlock PC", "admin", "n2", ts, sig, pub, Now));
        Assert.False(a.Verify("Unlock PC", "unlock", "n2", ts, sig, otherPub, Now));
        Assert.False(a.Verify("Unlock PC", "unlock", "n2", ts, sig, pub, Now.AddMinutes(6)));
        Assert.False(a.Verify("Unlock PC", "unlock", "", ts, sig, pub, Now));
        Assert.False(a.Verify("Unlock PC", "unlock", "n2", ts, "not base64!", pub, Now));
        Assert.True(a.Verify("Unlock PC", "unlock", "n2", ts, sig, pub, Now));
    }

    [Fact]
    public void Spend_AYesActedOnElsewhere_CantPassAgain()
    {
        var (pub, sign) = Phone();
        var ts = Now.ToUnixTimeSeconds();
        var sig = sign(UnlockApproval.Message("unlock", "n3", ts, "Unlock PC"));
        var a = new UnlockApproval();
        a.Spend("n3", Now);
        Assert.False(a.Verify("Unlock PC", "unlock", "n3", ts, sig, pub, Now));
        a.Spend("", Now);   // nothing to spend
        Assert.True(a.Verify("Unlock PC", "unlock", "n4", ts, sign(UnlockApproval.Message("unlock", "n4", ts, "Unlock PC")), pub, Now));
    }

    [Fact]
    public void Fingerprint_IsFirst8HexOfSha256()
    {
        var (pub, _) = Phone();
        var want = Convert.ToHexString(SHA256.HashData(Convert.FromBase64String(pub))[..4]).ToLowerInvariant();
        Assert.Equal(want, UnlockApproval.Fingerprint(pub));
        Assert.Null(UnlockApproval.Fingerprint("%%%"));
    }
}
