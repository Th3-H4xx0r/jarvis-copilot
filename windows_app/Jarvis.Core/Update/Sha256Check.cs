using System.Security.Cryptography;

namespace Jarvis.Core.Update;

public static class Sha256Check
{
    public static string Hash(string file)
    {
        using var s = File.OpenRead(file);
        return Convert.ToHexString(SHA256.HashData(s)).ToLowerInvariant();
    }

    public static bool Matches(string file, string hex)
    {
        try
        {
            var got = Convert.FromHexString(Hash(file));
            var want = Convert.FromHexString(hex);
            return CryptographicOperations.FixedTimeEquals(got, want);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or FormatException)
        {
            return false;
        }
    }
}
