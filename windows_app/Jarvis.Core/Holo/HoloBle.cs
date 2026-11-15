namespace Jarvis.Core.Holo;

/// Holo Drop's Bluetooth beacon (port of `HoloBLEAdvertiser`'s naming, cross-plan (e)): while
/// Holo Drop is on, the PC advertises a fixed service and manufacturer data derived from its
/// paired device id, so a phone's open popup can rank it by signal strength without connecting.
/// Windows forbids an advertised LocalName, so the iPhone matches the manufacturer data;
/// `LocalName` stays for parity with the Mac.
public static class HoloBle
{
    public static readonly Guid Service = new("6F1D5A3E-9C2B-4E7A-8D11-3B6A2C9E0F42");
    /// The Bluetooth SIG's "no company" id, for tests and prototypes.
    public const ushort CompanyId = 0xFFFF;

    /// FNV-1a 32-bit of the UTF-8 bytes.
    public static uint Fnv1a(string s)
    {
        var h = 2_166_136_261u;
        foreach (var b in System.Text.Encoding.UTF8.GetBytes(s)) h = unchecked((h ^ b) * 16_777_619u);
        return h;
    }

    /// "HD" + 8 lowercase hex digits.
    public static string LocalName(string deviceId) => "HD" + Fnv1a(deviceId).ToString("x8");

    /// 'H', 'D', then the FNV-1a hash big-endian (6 bytes).
    public static byte[] ManufacturerPayload(string deviceId)
    {
        var h = Fnv1a(deviceId);
        return new[] { (byte)'H', (byte)'D', (byte)(h >> 24), (byte)(h >> 16), (byte)(h >> 8), (byte)h };
    }
}
