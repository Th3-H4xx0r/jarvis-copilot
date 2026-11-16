using System.Security.Cryptography;

namespace Jarvis.Core.Crypto;

/// Encrypts a short secret to a P-256 public key so only the holder of the private key (his iPhone's
/// Secure Enclave) can read it: ECDH P-256 → HKDF-SHA256 (salt empty, info "jarvis-rdp-v1", 32 bytes)
/// → AES-256-GCM (12-byte nonce, 16-byte tag appended to the ciphertext). Matches iOS CryptoKit's
/// sharedSecretFromKeyAgreement + hkdfDerivedSymmetricKey + AES.GCM; vector: Jarvis.Tests/Crypto/ecies_vector.json.
public static class Ecies
{
    private static readonly byte[] Info = "jarvis-rdp-v1"u8.ToArray();

    /// `recipientX963` = 04 ‖ X ‖ Y (65 bytes). The ephemeral key and nonce are fresh unless given (tests).
    public static (byte[] Ciphertext, byte[] EphemeralPubX963, byte[] Nonce) Encrypt(byte[] plaintext, byte[] recipientX963,
        ECDiffieHellman? ephemeral = null, byte[]? nonce = null)
    {
        if (recipientX963.Length != 65 || recipientX963[0] != 4) throw new ArgumentException("recipient must be a 65-byte X9.63 P-256 point");
        using var recipient = Point(recipientX963);
        var eph = ephemeral ?? ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);
        try
        {
            var key = Derive(eph, recipient.PublicKey);
            nonce ??= RandomNumberGenerator.GetBytes(12);
            var ct = new byte[plaintext.Length];
            var tag = new byte[16];
            using (var gcm = new AesGcm(key, 16)) gcm.Encrypt(nonce, plaintext, ct, tag);
            CryptographicOperations.ZeroMemory(key);
            var p = eph.ExportParameters(false);
            return ([.. ct, .. tag], [4, .. p.Q.X!, .. p.Q.Y!], nonce);
        }
        finally
        {
            if (ephemeral == null) eph.Dispose();
        }
    }

    public static byte[] Decrypt(byte[] ciphertextWithTag, byte[] ephemeralX963, byte[] nonce, ECDiffieHellman recipient)
    {
        using var eph = Point(ephemeralX963);
        var key = Derive(recipient, eph.PublicKey);
        var ct = ciphertextWithTag[..^16];
        var pt = new byte[ct.Length];
        using (var gcm = new AesGcm(key, 16)) gcm.Decrypt(nonce, ct, ciphertextWithTag[^16..], pt);
        CryptographicOperations.ZeroMemory(key);
        return pt;
    }

    /// A public point as a key; a point that isn't on P-256 throws CryptographicException on every
    /// platform (Windows reports it as PlatformNotSupportedException).
    private static ECDiffieHellman Point(byte[] x963)
    {
        if (x963.Length != 65 || x963[0] != 4) throw new ArgumentException("expected a 65-byte X9.63 P-256 point");
        try
        {
            return ECDiffieHellman.Create(new ECParameters
            {
                Curve = ECCurve.NamedCurves.nistP256, Q = new ECPoint { X = x963[1..33], Y = x963[33..65] },
            });
        }
        catch (PlatformNotSupportedException e) { throw new CryptographicException("not a valid P-256 public key", e); }
    }

    private static byte[] Derive(ECDiffieHellman own, ECDiffieHellmanPublicKey other)
    {
        var shared = own.DeriveRawSecretAgreement(other);
        try { return HKDF.DeriveKey(HashAlgorithmName.SHA256, shared, 32, [], Info); }
        finally { CryptographicOperations.ZeroMemory(shared); }
    }
}
