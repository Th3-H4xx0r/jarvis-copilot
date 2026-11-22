using Jarvis.Core.GlassesCamera;
using Jarvis.Tests.Fakes;
using Jarvis.Tests.Ui;

namespace Jarvis.Tests.GlassesCamera;

/// What the camera's media source draws for each frame an app asks for (FrameProvider's pure
/// part): the newest glasses frame, fitted to the format the app picked, or the card.
public class GlassesCamPictureTests
{
    private static readonly DateTime Now = new(2026, 11, 22, 12, 0, 0, DateTimeKind.Utc);

    private static (GlassesCamPicture Picture, GlassesCamFrameFile File) Make(Func<(int W, int H), byte[]?>? card = null)
    {
        var file = GlassesCamFrameFile.Open(Path.Combine(Tmp.Dir(), "frames.bin"), create: true);
        var picture = new GlassesCamPicture(() => file, card ?? (s => Enumerable.Repeat((byte)77, s.W * s.H * 4).ToArray()), () => Now);
        return (picture, file);
    }

    private static byte[] Solid(int w, int h, byte b, byte g, byte r)
    {
        var px = new byte[w * h * 4];
        for (var i = 0; i < px.Length; i += 4) { px[i] = b; px[i + 1] = g; px[i + 2] = r; px[i + 3] = 255; }
        return px;
    }

    private static (byte B, byte G, byte R, byte A) At(byte[] px, int w, int x, int y)
    {
        var i = (y * w + x) * 4;
        return (px[i], px[i + 1], px[i + 2], px[i + 3]);
    }

    [Fact]
    public void StaleFramesGiveTheCard()
    {
        var (picture, file) = Make();
        using var _ = file;
        file.WriteFrame(Solid(720, 1280, 10, 20, 30), 720, 1280, 720 * 4, Now.AddSeconds(-2.5));
        var dst = new byte[720 * 1280 * 4];
        Assert.False(picture.Fill(dst, 720, 1280, 720 * 4));
        Assert.True(dst.All(v => v == 77));
    }

    [Fact]
    public void NoFrameYetOrNoFileGivesTheCard()
    {
        var (picture, file) = Make();
        using var _ = file;
        var dst = new byte[1280 * 720 * 4];
        Assert.False(picture.Fill(dst, 1280, 720, 1280 * 4));
        Assert.True(dst.All(v => v == 77));

        var noFile = new GlassesCamPicture(() => null, s => Enumerable.Repeat((byte)5, s.W * s.H * 4).ToArray(), () => Now);
        Assert.False(noFile.Fill(dst, 1280, 720, 1280 * 4));
        Assert.True(dst.All(v => v == 5));
    }

    [Fact]
    public void NoCardIsOpaqueBlack()
    {
        var (picture, file) = Make(card: _ => null);
        using var _ = file;
        var dst = Enumerable.Repeat((byte)9, 8 * 4 * 4).ToArray();
        Assert.False(picture.Fill(dst, 8, 4, 32));
        Assert.Equal((0, 0, 0, 255), At(dst, 8, 3, 2));
    }

    [Fact]
    public void FreshFrameIsCopiedForPortrait()
    {
        var (picture, file) = Make();
        using var _ = file;
        file.WriteFrame(Solid(720, 1280, 10, 20, 30), 720, 1280, 720 * 4, Now.AddSeconds(-0.1));
        var dst = new byte[720 * 1280 * 4];
        Assert.True(picture.Fill(dst, 720, 1280, 720 * 4));
        Assert.Equal((10, 20, 30, 255), At(dst, 720, 0, 0));
        Assert.Equal((10, 20, 30, 255), At(dst, 720, 719, 1279));
    }

    [Fact]
    public void FreshFrameIsLetterboxedForLandscape()
    {
        var (picture, file) = Make();
        using var _ = file;
        file.WriteFrame(Solid(720, 1280, 10, 20, 30), 720, 1280, 720 * 4, Now.AddSeconds(-1));
        // A padded stride (a Media Foundation buffer's pitch) is honoured.
        const int stride = 1280 * 4 + 64;
        var dst = new byte[stride * 720];
        Assert.True(picture.Fill(dst, 1280, 720, stride));
        byte[] Row(int y) => dst.AsSpan(y * stride, 1280 * 4).ToArray();
        // Black pillars either side of a centred 404-wide picture (x 438..841), nothing stretched.
        Assert.Equal((0, 0, 0, 255), At(Row(0), 1280, 0, 0));
        Assert.Equal((0, 0, 0, 255), At(Row(360), 1280, 437, 0));
        Assert.Equal((10, 20, 30, 255), At(Row(360), 1280, 438, 0));
        Assert.Equal((10, 20, 30, 255), At(Row(0), 1280, 640, 0));
        Assert.Equal((10, 20, 30, 255), At(Row(719), 1280, 841, 0));
        Assert.Equal((0, 0, 0, 255), At(Row(719), 1280, 842, 0));
        Assert.Equal((0, 0, 0, 255), At(Row(719), 1280, 1279, 0));
    }

    [Fact]
    public void FitBgraScalesTheGradientInOrder()
    {
        // A horizontal ramp shrunk to half keeps its order left to right (no flips, no wrap).
        var src = new byte[16 * 2 * 4];
        for (var x = 0; x < 16; x++)
            for (var y = 0; y < 2; y++) { var i = (y * 16 + x) * 4; src[i] = src[i + 1] = src[i + 2] = (byte)(x * 16); src[i + 3] = 255; }
        var dst = new byte[8 * 1 * 4];
        GlassesCamPixels.FitBgra(src, 16, 2, 64, dst, 8, 1, 32);
        for (var x = 1; x < 8; x++) Assert.True(dst[x * 4] > dst[(x - 1) * 4]);
        Assert.All(Enumerable.Range(0, 8), x => Assert.Equal(255, dst[x * 4 + 3]));
    }

    [Fact]
    public void Nv12OfWhiteBlackAndRed()
    {
        // BT.709, studio range (what apps assume for 720p and up).
        static (byte[] Y, byte[] UV) Nv12(byte[] bgra, int w, int h)
        {
            var y = new byte[w * h];
            var uv = new byte[w * h / 2];
            GlassesCamPixels.BgraToNv12(bgra, w, h, w * 4, y, w, uv, w);
            return (y, uv);
        }
        var white = Nv12(Solid(4, 2, 255, 255, 255), 4, 2);
        Assert.All(white.Y, v => Assert.Equal(235, v));
        Assert.All(white.UV, v => Assert.Equal(128, v));
        var black = Nv12(Solid(4, 2, 0, 0, 0), 4, 2);
        Assert.All(black.Y, v => Assert.Equal(16, v));
        Assert.All(black.UV, v => Assert.Equal(128, v));
        var red = Nv12(Solid(2, 2, 0, 0, 255), 2, 2);
        Assert.Equal(63, red.Y[0]);     // 16 + 0.2126 × 219
        Assert.Equal(102, red.UV[0]);   // Cb
        Assert.Equal(240, red.UV[1]);   // Cr
    }

    [Fact]
    public void Nv12HonoursPitches()
    {
        var y = Enumerable.Repeat((byte)1, 8 * 2).ToArray();
        var uv = Enumerable.Repeat((byte)1, 8 * 1).ToArray();
        GlassesCamPixels.BgraToNv12(Solid(2, 2, 255, 255, 255), 2, 2, 8, y, 8, uv, 8);
        Assert.Equal(new byte[] { 235, 235, 1, 1, 1, 1, 1, 1, 235, 235, 1, 1, 1, 1, 1, 1 }, y);
        Assert.Equal(new byte[] { 128, 128, 1, 1, 1, 1, 1, 1 }, uv);
    }

    [Fact]
    public void PngDecodesTheShippedCards()
    {
        var dir = Path.Combine(ThemeInvariantTests.RepoRoot(), "JarvisGlassesCam", "Cards");
        foreach (var (name, size) in new[] { ("card-portrait.png", GlassesCamSpec.Portrait), ("card-landscape.png", GlassesCamSpec.Landscape) })
        {
            var (px, w, h) = GlassesCamPng.DecodeBgra(File.ReadAllBytes(Path.Combine(dir, name)));
            Assert.Equal(size, (w, h));
            Assert.Equal(w * h * 4, px.Length);
            Assert.Equal((0, 0, 0, 255), At(px, w, 0, 0));                         // black around
            Assert.Contains(px.Where((_, i) => i % 4 == 2), r => r > 200);         // and white words on it
        }
    }

    [Fact]
    public void CardsComeAtTheAskedSize()
    {
        var dir = Path.Combine(ThemeInvariantTests.RepoRoot(), "JarvisGlassesCam", "Cards");
        var cards = new GlassesCamCards(File.ReadAllBytes(Path.Combine(dir, "card-portrait.png")), File.ReadAllBytes(Path.Combine(dir, "card-landscape.png")));
        Assert.Equal(1280 * 720 * 4, cards.For((1280, 720))!.Length);
        // An odd size (an app asked for something else): the nearest card, fitted.
        var small = cards.For((640, 480))!;
        Assert.Equal(640 * 480 * 4, small.Length);
        Assert.Same(small, cards.For((640, 480)));   // made once
        Assert.Null(new GlassesCamCards(null, null).For((1280, 720)));
        Assert.Null(new GlassesCamCards(new byte[] { 1, 2 }, null).For((720, 1280)));   // a bad image: no card, not a crash
    }

    [Fact]
    public void PngDecodesEachFilterAndRgba()
    {
        // 3×2 RGBA with filter types 1 (Sub) and 4 (Paeth), made with .NET's zlib.
        var raw = new byte[]
        {
            1, 10, 20, 30, 255, 5, 5, 5, 0, 1, 1, 1, 0,          // Sub: deltas from the pixel to the left
            4, 1, 2, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0,               // Paeth
        };
        var png = GlassesCamPngTestData.Build(3, 2, colorType: 6, raw);
        var (px, w, h) = GlassesCamPng.DecodeBgra(png);
        Assert.Equal((3, 2), (w, h));
        Assert.Equal((30, 20, 10, 255), At(px, 3, 0, 0));   // BGRA of RGBA(10,20,30,255)
        Assert.Equal((35, 25, 15, 255), At(px, 3, 1, 0));
        Assert.Equal((36, 26, 16, 255), At(px, 3, 2, 0));
        Assert.Equal((33, 22, 11, 255), At(px, 3, 0, 1));   // Paeth's predictor is the pixel above
        Assert.Throws<InvalidDataException>(() => GlassesCamPng.DecodeBgra(new byte[] { 1, 2, 3 }));
    }
}

internal static class GlassesCamPngTestData
{
    public static byte[] Build(int w, int h, byte colorType, byte[] filteredRows)
    {
        using var ms = new MemoryStream();
        ms.Write(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 });
        void Chunk(string type, byte[] data)
        {
            var len = new byte[4];
            System.Buffers.Binary.BinaryPrimitives.WriteInt32BigEndian(len, data.Length);
            ms.Write(len);
            var t = System.Text.Encoding.ASCII.GetBytes(type);
            ms.Write(t);
            ms.Write(data);
            ms.Write(new byte[4]);   // CRC isn't checked
        }
        var ihdr = new byte[13];
        System.Buffers.Binary.BinaryPrimitives.WriteInt32BigEndian(ihdr, w);
        System.Buffers.Binary.BinaryPrimitives.WriteInt32BigEndian(ihdr.AsSpan(4), h);
        ihdr[8] = 8;
        ihdr[9] = colorType;
        Chunk("IHDR", ihdr);
        using var z = new MemoryStream();
        using (var zs = new System.IO.Compression.ZLibStream(z, System.IO.Compression.CompressionLevel.Optimal, leaveOpen: true)) zs.Write(filteredRows);
        Chunk("IDAT", z.ToArray());
        Chunk("IEND", Array.Empty<byte>());
        return ms.ToArray();
    }
}
