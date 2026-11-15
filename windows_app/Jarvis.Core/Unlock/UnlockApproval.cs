using System.Security.Cryptography;
using System.Text;

namespace Jarvis.Core.Unlock;

/// His iPhone's Face ID yes for "Unlock PC", checked on the PC itself exactly as the Mac checks
/// it (MacPassword.swift / MacPasswordWire.swift): a P-256 signature by the approval key pinned
/// on this PC over `jarvis-mac-password|kind|nonce|ts|sha256(context)`, at most 5 minutes old,
/// each nonce once. The server only relays it: it can't forge or replay a yes.
public sealed class UnlockApproval
{
    public static readonly TimeSpan Freshness = TimeSpan.FromSeconds(300);
    private readonly Dictionary<string, DateTimeOffset> _used = new();
    private readonly object _lock = new();

    /// What his iPhone signs (MacPasswordWire.message).
    public static byte[] Message(string kind, string nonce, long ts, string context)
    {
        var digest = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(context))).ToLowerInvariant();
        return Encoding.UTF8.GetBytes($"jarvis-mac-password|{kind}|{nonce}|{ts}|{digest}");
    }

    /// The code both screens show: the first 8 hex of SHA-256 of the key (MacPasswordWire.fingerprint).
    public static string? Fingerprint(string publicKeyB64)
    {
        try { return Convert.ToHexString(SHA256.HashData(Convert.FromBase64String(publicKeyB64))[..4]).ToLowerInvariant(); }
        catch (FormatException) { return null; }
    }

    public bool Verify(string context, string kind, string nonce, long ts, string signatureB64, string publicKeyB64, DateTimeOffset now)
    {
        if (nonce.Length == 0 || Math.Abs(now.ToUnixTimeSeconds() - ts) > Freshness.TotalSeconds) return false;
        if (!SignatureValid(Message(kind, nonce, ts, context), signatureB64, publicKeyB64)) return false;
        lock (_lock)
        {
            foreach (var old in _used.Where(u => now - u.Value > Freshness * 2).Select(u => u.Key).ToList()) _used.Remove(old);
            if (_used.ContainsKey(nonce)) return false;
            _used[nonce] = now;
        }
        return true;
    }

    /// `publicKeyB64`: the x9.63 point (04 ‖ X ‖ Y, 65 bytes), as the iPhone registers it.
    /// `signatureB64`: DER (CryptoKit's derRepresentation).
    private static bool SignatureValid(byte[] message, string signatureB64, string publicKeyB64)
    {
        try
        {
            var point = Convert.FromBase64String(publicKeyB64);
            if (point.Length != 65 || point[0] != 0x04) return false;
            using var key = ECDsa.Create(new ECParameters
            {
                Curve = ECCurve.NamedCurves.nistP256,
                Q = new ECPoint { X = point[1..33], Y = point[33..65] },
            });
            return key.VerifyData(message, Convert.FromBase64String(signatureB64), HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence);
        }
        catch (Exception e) when (e is FormatException or CryptographicException)
        {
            return false;
        }
    }
}
