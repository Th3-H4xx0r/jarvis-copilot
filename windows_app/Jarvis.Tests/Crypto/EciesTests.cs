using System.Security.Cryptography;
using Jarvis.Core.Crypto;

namespace Jarvis.Tests.Crypto;

public class EciesTests
{
    private static JsonObject Vector() =>
        JsonNode.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Crypto", "ecies_vector.json")))!.AsObject();

    private static ECDiffieHellman Key(string dHex, string pubHex)
    {
        var pub = Convert.FromHexString(pubHex);
        return ECDiffieHellman.Create(new ECParameters
        {
            Curve = ECCurve.NamedCurves.nistP256, D = Convert.FromHexString(dHex),
            Q = new ECPoint { X = pub[1..33], Y = pub[33..65] },
        });
    }

    [Fact]
    public void Decrypts_the_shared_vector()
    {
        var v = Vector();
        using var recipient = Key((string)v["recipient_private_d"]!, (string)v["recipient_public_x963"]!);
        var pt = Ecies.Decrypt(Convert.FromHexString((string)v["ciphertext_with_tag"]!),
            Convert.FromHexString((string)v["ephemeral_public_x963"]!), Convert.FromHexString((string)v["nonce"]!), recipient);
        Assert.Equal((string)v["plaintext_utf8"]!, System.Text.Encoding.UTF8.GetString(pt));
    }

    [Fact]
    public void Encrypts_exactly_like_the_vector_with_its_ephemeral_key_and_nonce()
    {
        var v = Vector();
        using var eph = Key((string)v["ephemeral_private_d"]!, (string)v["ephemeral_public_x963"]!);
        var (ct, ephPub, nonce) = Ecies.Encrypt(System.Text.Encoding.UTF8.GetBytes((string)v["plaintext_utf8"]!),
            Convert.FromHexString((string)v["recipient_public_x963"]!), eph, Convert.FromHexString((string)v["nonce"]!));
        Assert.Equal((string)v["ciphertext_with_tag"]!, Convert.ToHexString(ct).ToLowerInvariant());
        Assert.Equal((string)v["ephemeral_public_x963"]!, Convert.ToHexString(ephPub).ToLowerInvariant());
        Assert.Equal(12, nonce.Length);
    }

    [Fact]
    public void Roundtrip_with_fresh_keys_and_tamper_fails()
    {
        using var recipient = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);
        var p = recipient.ExportParameters(false);
        var pub = new byte[] { 4 }.Concat(p.Q.X!).Concat(p.Q.Y!).ToArray();
        var (ct, eph, nonce) = Ecies.Encrypt("secret"u8.ToArray(), pub);
        Assert.Equal("secret", System.Text.Encoding.UTF8.GetString(Ecies.Decrypt(ct, eph, nonce, recipient)));
        ct[0] ^= 1;
        Assert.ThrowsAny<CryptographicException>(() => Ecies.Decrypt(ct, eph, nonce, recipient));
    }

    [Fact]
    public void Rejects_a_bad_public_key()
    {
        var offCurve = new byte[65];
        offCurve[0] = 4;   // well-formed, but (0, 0) isn't on P-256
        Assert.ThrowsAny<CryptographicException>(() => Ecies.Encrypt("x"u8.ToArray(), offCurve));
        Assert.ThrowsAny<ArgumentException>(() => Ecies.Encrypt("x"u8.ToArray(), new byte[10]));
    }
}
