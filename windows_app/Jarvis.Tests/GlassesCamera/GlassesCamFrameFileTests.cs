using Jarvis.Core.GlassesCamera;
using Jarvis.Tests.Fakes;

namespace Jarvis.Tests.GlassesCamera;

/// The memory-mapped file between the Jarvis app (writes the glasses' frames) and the camera's
/// media source inside Windows' camera service (reads them; writes how many apps use it).
public class GlassesCamFrameFileTests
{
    private const int W = 720, H = 1280;

    private static GlassesCamFrameFile Fresh() => GlassesCamFrameFile.Open(Path.Combine(Tmp.Dir(), "frames.bin"), create: true);

    private static byte[] Solid(byte v, int w = W, int h = H) => Enumerable.Repeat(v, w * h * 4).ToArray();

    [Fact]
    public void FrameFileStartsEmpty()
    {
        using var f = Fresh();
        Assert.False(f.TryReadLatest(new byte[W * H * 4], out _, out _, out _));
        Assert.Null(f.LastFrameUtc);
        Assert.Equal(0, f.Clients);
    }

    [Fact]
    public void FrameFileRoundTripsAFrame()
    {
        var path = Path.Combine(Tmp.Dir(), "frames.bin");
        using var writer = GlassesCamFrameFile.Open(path, create: true);
        var px = new byte[W * H * 4];
        for (var i = 0; i < px.Length; i++) px[i] = (byte)(i * 7);
        var at = new DateTime(2026, 11, 22, 12, 0, 0, DateTimeKind.Utc);
        writer.WriteFrame(px, W, H, W * 4, at);

        // Another opener (the camera's process) sees it.
        using var reader = GlassesCamFrameFile.Open(path, create: false);
        var dst = new byte[W * H * 4];
        Assert.True(reader.TryReadLatest(dst, out var w, out var h, out var utc));
        Assert.Equal((W, H), (w, h));
        Assert.Equal(at, utc);
        Assert.Equal(DateTimeKind.Utc, utc.Kind);
        Assert.Equal(px, dst);
        Assert.Equal(at, reader.LastFrameUtc);
    }

    [Fact]
    public void FrameFileTakesAPaddedStrideAndSmallerFrames()
    {
        using var f = Fresh();
        // 4×2 frame with 4 bytes of padding per row: the file keeps it packed.
        var src = new byte[] { 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 9, 9, 9, 9,
                               5, 5, 5, 5, 6, 6, 6, 6, 7, 7, 7, 7, 8, 8, 8, 8, 9, 9, 9, 9 };
        f.WriteFrame(src, 4, 2, 20, DateTime.UtcNow);
        var dst = new byte[32];
        Assert.True(f.TryReadLatest(dst, out var w, out var h, out _));
        Assert.Equal((4, 2), (w, h));
        Assert.Equal(new byte[] { 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 6, 6, 7, 7, 7, 7, 8, 8, 8, 8 }, dst);
        Assert.False(f.TryReadLatest(new byte[31], out _, out _, out _));   // too small for it
        Assert.Throws<ArgumentException>(() => f.WriteFrame(new byte[8], 1281, 1280, 1281 * 4, DateTime.UtcNow));
    }

    [Fact]
    public void FrameFileReaderNeverReturnsATornFrame()
    {
        var path = Path.Combine(Tmp.Dir(), "frames.bin");
        using var writer = GlassesCamFrameFile.Open(path, create: true);
        using var reader = GlassesCamFrameFile.Open(path, create: false);
        var frames = Enumerable.Range(0, 8).Select(i => Solid((byte)(i * 30 + 1))).ToArray();
        var done = false;
        var t = new Thread(() =>
        {
            for (var i = 0; i < 500; i++) writer.WriteFrame(frames[i % frames.Length], W, H, W * 4, DateTime.UtcNow);
            Volatile.Write(ref done, true);
        });
        t.Start();
        var dst = new byte[W * H * 4];
        var reads = 0;
        while (!Volatile.Read(ref done) || reads == 0)
        {
            if (!reader.TryReadLatest(dst, out _, out _, out _)) continue;
            reads++;
            var first = dst[0];
            Assert.NotEqual(0, first);
            Assert.True(dst.AsSpan().IndexOfAnyExcept(first) < 0, "a torn frame (two frames mixed)");
        }
        t.Join();
        Assert.True(reads > 0);
    }

    [Fact]
    public void ClientsAndBeatRoundTrip()
    {
        var path = Path.Combine(Tmp.Dir(), "frames.bin");
        using var source = GlassesCamFrameFile.Open(path, create: true);
        using var app = GlassesCamFrameFile.Open(path, create: false);
        var beat = new DateTime(2026, 11, 22, 12, 0, 1, DateTimeKind.Utc);
        source.Clients = 1;
        source.SourceBeat = beat;
        Assert.Equal(1, app.Clients);
        Assert.Equal(beat, app.SourceBeat);
        Assert.Equal(2, source.AddClients(1));
        Assert.Equal(1, source.AddClients(-1));
        Assert.Equal(0, source.AddClients(-5));   // never below zero
    }

    [Fact]
    public void InUseOnlyWhileTheSourceBeats()
    {
        using var f = Fresh();
        var now = new DateTime(2026, 11, 22, 12, 0, 0, DateTimeKind.Utc);
        f.Clients = 1;
        f.SourceBeat = now;
        Assert.Equal(1, f.ClientsAt(now.AddSeconds(4)));
        // The camera service died with the count up: after the beat goes stale nobody is using it.
        Assert.Equal(0, f.ClientsAt(now.AddSeconds(6)));
    }

    [Fact]
    public void OpeningAMissingFileWithoutCreateThrows() =>
        Assert.Throws<FileNotFoundException>(() => GlassesCamFrameFile.Open(Path.Combine(Tmp.Dir(), "nope.bin"), create: false));

    [Fact]
    public void AnotherFormatIsRefused()
    {
        var path = Path.Combine(Tmp.Dir(), "frames.bin");
        GlassesCamFrameFile.Open(path, create: true).Dispose();
        using (var fs = new FileStream(path, FileMode.Open, FileAccess.Write, FileShare.ReadWrite)) { fs.Position = 4; fs.WriteByte(99); }   // version 99
        Assert.Throws<InvalidDataException>(() => GlassesCamFrameFile.Open(path, create: false));
    }

    [Fact]
    public void AZeroFilledFileFromTheInstallerIsUsable()
    {
        var path = Path.Combine(Tmp.Dir(), "frames.bin");
        File.WriteAllBytes(path, new byte[GlassesCamFrameFile.FileSize]);
        using var f = GlassesCamFrameFile.Open(path, create: false);
        Assert.False(f.TryReadLatest(new byte[W * H * 4], out _, out _, out _));
        f.WriteFrame(Solid(5), W, H, W * 4, DateTime.UtcNow);
        Assert.True(f.TryReadLatest(new byte[W * H * 4], out _, out _, out _));
    }
}
