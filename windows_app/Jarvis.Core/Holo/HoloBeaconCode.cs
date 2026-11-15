using System.Globalization;

namespace Jarvis.Core.Holo;

/// The direction beacons' codes, so the phone can tell this PC's chirp or flash from any other
/// (port of `HoloBeaconCode`).
///
/// Chirp v1: FSK, 20 symbols × 15 ms = 300 ms; 18.5 kHz = 0, 19.5 kHz = 1; preamble 1 0 1 0,
/// then the 16 bits of `Code16(nonce)` MSB first; 2 ms raised-cosine edges.
/// Flash v1: 15 frames at 10 Hz (1.5 s) of a full-screen white veil, bright (alpha 0.10) = 1,
/// clear = 0; preamble 1 0 1 0, then the low 11 bits of `Code16(nonce)` MSB first.
public static class HoloBeaconCode
{
    public const double ChirpSymbol = 0.015;
    public const double ZeroHz = 18_500;
    public const double OneHz = 19_500;
    public const double FlashHz = 10;
    public const double FlashAlpha = 0.10;
    public static readonly IReadOnlyList<bool> Preamble = new[] { true, false, true, false };

    /// A nonce as 16 bits: a decimal or hex number's low bits, else FNV-1a of its UTF-8.
    public static ushort Code16(string nonce)
    {
        var t = nonce.Trim(' ', '\t', ' ');
        if (t.Length > 0 && t.All(char.IsAsciiDigit) && ulong.TryParse(t, NumberStyles.None, CultureInfo.InvariantCulture, out var n))
            return (ushort)n;
        if (t.Length <= 16)
        {
            var hex = t.StartsWith("0x", StringComparison.Ordinal) ? t[2..] : t;
            if (hex.Length > 0 && ulong.TryParse(hex, NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out var h))
                return (ushort)h;
        }
        return (ushort)HoloBle.Fnv1a(t);
    }

    public static IReadOnlyList<bool> ChirpBits(string nonce)
    {
        var c = Code16(nonce);
        return Preamble.Concat(Enumerable.Range(0, 16).Reverse().Select(i => ((c >> i) & 1) == 1)).ToList();
    }

    public static IReadOnlyList<bool> FlashFrames(string nonce)
    {
        var c = Code16(nonce);
        return Preamble.Concat(Enumerable.Range(0, 11).Reverse().Select(i => ((c >> i) & 1) == 1)).ToList();
    }

    /// The chirp's samples (mono, `rate` Hz): one tone per bit, soft edges so it doesn't click.
    public static float[] ChirpSamples(string nonce, double rate, float amplitude = 0.25f)
    {
        var bits = ChirpBits(nonce);
        var perSymbol = (int)(rate * ChirpSymbol);
        var ramp = Math.Max(1, (int)(rate * 0.002));
        var output = new float[perSymbol * bits.Count];
        var phase = 0.0;
        for (var i = 0; i < bits.Count; i++)
        {
            var step = 2 * Math.PI * (bits[i] ? OneHz : ZeroHz) / rate;
            for (var n = 0; n < perSymbol; n++)
            {
                var edge = Math.Min(n, perSymbol - 1 - n);
                var gain = edge >= ramp ? 1.0 : 0.5 - 0.5 * Math.Cos(Math.PI * edge / ramp);
                output[i * perSymbol + n] = amplitude * (float)(gain * Math.Sin(phase));
                phase += step;
            }
        }
        return output;
    }

    /// When each flash frame starts, as offsets from the first (fixed deadlines, so a late
    /// wake-up never pushes the frames after it).
    public static IReadOnlyList<TimeSpan> FlashFrameStarts(int count)
    {
        var step = (int)Math.Round(1000 / FlashHz);
        return Enumerable.Range(0, count).Select(i => TimeSpan.FromMilliseconds(step * i)).ToList();
    }
}
