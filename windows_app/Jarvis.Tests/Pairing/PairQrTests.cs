using Jarvis.Core.Pairing;

namespace Jarvis.Tests.Pairing;

/// The QR on the pair screen: the module grid the window draws (black on white, quiet zone
/// added by the window).
public class PairQrTests
{
    private const string Payload =
        "jarvis://pair-computer?v=1&host=192.168.1.23&port=50001&key=q3Jp0x1lV9kz8Qm2Ue4Rt6Yh0Wn5Bc7Da9Fg1Hj3Kl5&name=Pranav%27s%20Gaming%20PC&os=windows";

    [Fact]
    public void Encode_MakesAValidQrSymbol()
    {
        var qr = PairQr.Encode(Payload);
        Assert.True(qr.Size >= 21 && (qr.Size - 17) % 4 == 0, $"size {qr.Size} isn't a QR version");
        Assert.True(qr.Size <= 57, "a pairing payload stays a small, easy-to-scan code (version 10 or less)");
        Assert.Equal(qr.Size * qr.Size, qr.Modules.Length);
        // The three finder patterns: a dark 7x7 ring with a dark 3x3 centre and a light ring between.
        foreach (var (ox, oy) in new[] { (0, 0), (qr.Size - 7, 0), (0, qr.Size - 7) })
        {
            Assert.True(qr.Dark(ox, oy) && qr.Dark(ox + 6, oy + 6) && qr.Dark(ox + 3, oy + 3));
            Assert.False(qr.Dark(ox + 1, oy + 1));
            Assert.False(qr.Dark(ox + 5, oy + 5));
        }
    }

    [Fact]
    public void Encode_DifferentPayloads_DifferentCodes()
    {
        var a = PairQr.Encode(Payload);
        var b = PairQr.Encode(Payload.Replace("50001", "50002"));
        Assert.NotEqual(a.Modules, b.Modules);
    }

    [Fact]
    public void Runs_CoverExactlyTheDarkModules()
    {
        var qr = PairQr.Encode(Payload);
        var drawn = new bool[qr.Size * qr.Size];
        foreach (var (x, y, w) in qr.Runs())
        {
            Assert.True(w >= 1);
            for (var i = 0; i < w; i++)
            {
                Assert.False(drawn[y * qr.Size + x + i], "runs overlap");
                drawn[y * qr.Size + x + i] = true;
            }
        }
        Assert.Equal(qr.Modules, drawn);
        Assert.True(qr.Runs().Count() < qr.Modules.Count(d => d), "runs merge neighbours (fewer shapes to draw)");
    }

    [Fact]
    public void Encode_Empty_Throws() => Assert.Throws<ArgumentException>(() => PairQr.Encode(""));
}
