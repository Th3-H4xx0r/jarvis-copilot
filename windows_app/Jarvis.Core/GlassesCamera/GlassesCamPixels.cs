using System.Buffers.Binary;
using System.IO.Compression;

namespace Jarvis.Core.GlassesCamera;

/// CPU pixel work for the Jarvis Glasses camera: fitting BGRA frames (the landscape format is the
/// portrait picture letterboxed), BGRA → NV12 for apps that take NV12, and I420 (the VP8
/// decoder's output) → BGRA. Sizes are small (720×1280), so plain loops are fast enough.
public static class GlassesCamPixels
{
    /// Opaque black, all of `w`×`h`.
    public static void FillBlack(Span<byte> dst, int w, int h, int stride)
    {
        for (var y = 0; y < h; y++)
        {
            var row = dst.Slice(y * stride, w * 4);
            row.Clear();
            for (var x = 3; x < row.Length; x += 4) row[x] = 255;
        }
    }

    /// `src` fitted and centred in `dst` (aspect kept), black around it; bilinear when the size changes.
    public static void FitBgra(ReadOnlySpan<byte> src, int sw, int sh, int sstride, Span<byte> dst, int dw, int dh, int dstride)
    {
        var (rx, ry, rw, rh) = GlassesCamGeometry.Fit((sw, sh), (dw, dh));
        if (rx != 0 || ry != 0 || rw != dw || rh != dh) FillBlack(dst, dw, dh, dstride);
        if (sw <= 0 || sh <= 0) return;
        if (rw == sw && rh == sh)
        {
            for (var y = 0; y < sh; y++) src.Slice(y * sstride, sw * 4).CopyTo(dst.Slice((ry + y) * dstride + rx * 4, sw * 4));
            return;
        }
        // Source position of each output column/row (16.16 fixed point, pixel centres lined up).
        Span<int> x0 = rw <= 4096 ? stackalloc int[rw] : new int[rw];
        Span<int> wx = rw <= 4096 ? stackalloc int[rw] : new int[rw];
        for (var x = 0; x < rw; x++) Sample(x, rw, sw, out x0[x], out wx[x]);
        for (var y = 0; y < rh; y++)
        {
            Sample(y, rh, sh, out var y0, out var wy);
            var y1 = Math.Min(y0 + 1, sh - 1);
            var top = src.Slice(y0 * sstride);
            var bot = src.Slice(y1 * sstride);
            var o = dst.Slice((ry + y) * dstride + rx * 4, rw * 4);
            for (var x = 0; x < rw; x++)
            {
                var a = x0[x] * 4;
                var b = Math.Min(x0[x] + 1, sw - 1) * 4;
                int fx = wx[x], fy = wy;
                for (var c = 0; c < 3; c++)
                {
                    var t = top[a + c] * (256 - fx) + top[b + c] * fx;
                    var u = bot[a + c] * (256 - fx) + bot[b + c] * fx;
                    o[x * 4 + c] = (byte)((t * (256 - fy) + u * fy + 32768) >> 16);
                }
                o[x * 4 + 3] = 255;
            }
        }
    }

    /// Output index `i` of `outN` → source index and an 8-bit weight toward the next one.
    private static void Sample(int i, int outN, int inN, out int i0, out int w)
    {
        var s = (long)(2 * i + 1) * inN * 65536 / (2L * outN) - 32768;
        s = Math.Clamp(s, 0, (long)(inN - 1) << 16);
        i0 = (int)(s >> 16);
        w = (int)((s & 0xFFFF) >> 8);
    }

    /// BGRA → NV12, BT.709 studio range (what apps assume for 720p and up; the media type says so
    /// too). Each 2×2 block's colour is the mean of its pixels. `w` and `h` must be even.
    public static void BgraToNv12(ReadOnlySpan<byte> bgra, int w, int h, int stride, Span<byte> yPlane, int yPitch, Span<byte> uvPlane, int uvPitch)
    {
        for (var cy = 0; cy < h / 2; cy++)
        {
            for (var cx = 0; cx < w / 2; cx++)
            {
                int sb = 0, sg = 0, sr = 0;
                for (var dy = 0; dy < 2; dy++)
                {
                    var y = cy * 2 + dy;
                    for (var dx = 0; dx < 2; dx++)
                    {
                        var x = cx * 2 + dx;
                        var i = y * stride + x * 4;
                        int b = bgra[i], g = bgra[i + 1], r = bgra[i + 2];
                        yPlane[y * yPitch + x] = (byte)(((47 * r + 157 * g + 16 * b + 128) >> 8) + 16);
                        sb += b;
                        sg += g;
                        sr += r;
                    }
                }
                int mb = sb >> 2, mg = sg >> 2, mr = sr >> 2;
                var o = cy * uvPitch + cx * 2;
                uvPlane[o] = (byte)Math.Clamp(((-26 * mr - 86 * mg + 112 * mb + 128) >> 8) + 128, 16, 240);
                uvPlane[o + 1] = (byte)Math.Clamp(((112 * mr - 102 * mg - 10 * mb + 128) >> 8) + 128, 16, 240);
            }
        }
    }
}

/// Just enough PNG to read the camera's own card images (8-bit RGB or RGBA, not interlaced),
/// so the media source needs no imaging library inside Windows' camera service.
public static class GlassesCamPng
{
    private static readonly byte[] Signature = { 137, 80, 78, 71, 13, 10, 26, 10 };

    public static (byte[] Bgra, int W, int H) DecodeBgra(byte[] png)
    {
        if (png.Length < 8 || !png.AsSpan(0, 8).SequenceEqual(Signature)) throw new InvalidDataException("Not a PNG.");
        int w = 0, h = 0, colorType = -1;
        using var idat = new MemoryStream();
        var at = 8;
        while (at + 8 <= png.Length)
        {
            var len = BinaryPrimitives.ReadInt32BigEndian(png.AsSpan(at));
            var type = System.Text.Encoding.ASCII.GetString(png, at + 4, 4);
            if (len < 0 || at + 12 + (long)len > png.Length) throw new InvalidDataException("A truncated PNG.");
            var data = png.AsSpan(at + 8, len);
            if (type == "IHDR")
            {
                w = BinaryPrimitives.ReadInt32BigEndian(data);
                h = BinaryPrimitives.ReadInt32BigEndian(data[4..]);
                if (data[8] != 8 || (data[9] != 2 && data[9] != 6) || data[12] != 0)
                    throw new InvalidDataException("Only 8-bit RGB/RGBA, non-interlaced PNGs.");
                colorType = data[9];
            }
            else if (type == "IDAT") idat.Write(data);
            else if (type == "IEND") break;
            at += 12 + len;
        }
        if (w <= 0 || h <= 0 || colorType < 0 || w > 8192 || h > 8192) throw new InvalidDataException("No image in the PNG.");
        var bpp = colorType == 6 ? 4 : 3;
        var rowLen = w * bpp;
        var raw = new byte[(rowLen + 1) * h];
        idat.Position = 0;
        using (var z = new ZLibStream(idat, CompressionMode.Decompress)) z.ReadExactly(raw);
        var px = new byte[w * h * 4];
        var prev = new byte[rowLen];
        var cur = new byte[rowLen];
        for (var y = 0; y < h; y++)
        {
            var filter = raw[y * (rowLen + 1)];
            raw.AsSpan(y * (rowLen + 1) + 1, rowLen).CopyTo(cur);
            for (var i = 0; i < rowLen; i++)
            {
                int a = i >= bpp ? cur[i - bpp] : 0, b = prev[i], c = i >= bpp ? prev[i - bpp] : 0;
                cur[i] = (byte)(cur[i] + filter switch
                {
                    0 => 0,
                    1 => a,
                    2 => b,
                    3 => (a + b) / 2,
                    4 => Paeth(a, b, c),
                    _ => throw new InvalidDataException("A bad PNG filter."),
                });
            }
            for (var x = 0; x < w; x++)
            {
                var o = (y * w + x) * 4;
                px[o] = cur[x * bpp + 2];
                px[o + 1] = cur[x * bpp + 1];
                px[o + 2] = cur[x * bpp];
                px[o + 3] = bpp == 4 ? cur[x * bpp + 3] : (byte)255;
            }
            (prev, cur) = (cur, prev);
        }
        return (px, w, h);
    }

    private static int Paeth(int a, int b, int c)
    {
        var p = a + b - c;
        int pa = Math.Abs(p - a), pb = Math.Abs(p - b), pc = Math.Abs(p - c);
        return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
    }
}

/// The "Glasses not streaming" card at any size the camera is asked for: the shipped portrait or
/// landscape image (rendered by the Mac camera's own drawing code), fitted when the size differs.
public sealed class GlassesCamCards
{
    private readonly byte[]? _portraitPng, _landscapePng;
    private readonly Dictionary<(int W, int H), byte[]?> _made = new();
    private readonly object _lock = new();

    public GlassesCamCards(byte[]? portraitPng, byte[]? landscapePng)
    {
        _portraitPng = portraitPng;
        _landscapePng = landscapePng;
    }

    /// Packed BGRA of `size`, or null when no card image could be read.
    public byte[]? For((int W, int H) size)
    {
        lock (_lock)
        {
            if (_made.TryGetValue(size, out var done)) return done;
            var png = size.H >= size.W ? _portraitPng ?? _landscapePng : _landscapePng ?? _portraitPng;
            byte[]? made = null;
            if (png != null && size.W > 0 && size.H > 0)
            {
                try
                {
                    var (px, w, h) = GlassesCamPng.DecodeBgra(png);
                    if ((w, h) == size) made = px;
                    else
                    {
                        made = new byte[size.W * size.H * 4];
                        GlassesCamPixels.FitBgra(px, w, h, w * 4, made, size.W, size.H, size.W * 4);
                    }
                }
                catch (InvalidDataException) { made = null; }
            }
            _made[size] = made;
            return made;
        }
    }
}

/// What the camera shows for each frame an app asks for: the newest glasses frame (no older than
/// GlassesCamSpec.StaleAfter) fitted to the format the app picked, else the card. Never waits on
/// the Jarvis app: with it closed (no frame file, no frames) the card shows and the call goes on.
public sealed class GlassesCamPicture
{
    private readonly Func<GlassesCamFrameFile?> _frames;
    private readonly Func<(int W, int H), byte[]?> _card;
    private readonly Func<DateTime> _utcNow;
    private readonly byte[] _scratch = new byte[GlassesCamFrameFile.MaxPixelBytes];

    public GlassesCamPicture(Func<GlassesCamFrameFile?> frames, Func<(int W, int H), byte[]?> card, Func<DateTime>? utcNow = null)
    {
        _frames = frames;
        _card = card;
        _utcNow = utcNow ?? (() => DateTime.UtcNow);
    }

    /// Draws into `dst` (BGRA, `w`×`h`, `stride` bytes a row). True when it's live video.
    public bool Fill(Span<byte> dst, int w, int h, int stride)
    {
        var file = _frames();
        if (file != null && file.LastFrameUtc is { } at && Fresh(at)
            && file.TryReadLatest(_scratch, out var fw, out var fh, out var utc) && Fresh(utc))
        {
            GlassesCamPixels.FitBgra(_scratch, fw, fh, fw * 4, dst, w, h, stride);
            return true;
        }
        var card = _card((w, h));
        if (card == null || card.Length < w * h * 4) GlassesCamPixels.FillBlack(dst, w, h, stride);
        else
            for (var y = 0; y < h; y++) card.AsSpan(y * w * 4, w * 4).CopyTo(dst.Slice(y * stride, w * 4));
        return false;
    }

    private bool Fresh(DateTime at)
    {
        var age = _utcNow() - at;
        return age < GlassesCamSpec.StaleAfter && age > -GlassesCamSpec.StaleAfter;
    }
}
