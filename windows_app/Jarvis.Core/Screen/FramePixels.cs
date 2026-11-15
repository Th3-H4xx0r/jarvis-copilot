namespace Jarvis.Core.Screen;

/// The captured frame on its way to the VP8 encoder: scaled (area average) to the fitted size
/// when the display is bigger than that, then BGRA → I420 (BT.601, studio range), which is what
/// the encoder takes.
public static class FramePixels
{
    /// Downscale by area average: each output pixel is the mean of the source pixels it covers,
    /// so text and edges stay smooth instead of the jagged look of picking one pixel.
    public static byte[] ScaleBgra(ReadOnlySpan<byte> src, int sw, int sh, int stride, int dw, int dh)
    {
        var dst = new byte[dw * dh * 4];
        for (var y = 0; y < dh; y++)
        {
            var y0 = y * sh / dh;
            var y1 = Math.Max(y0 + 1, Math.Min(sh, (y + 1) * sh / dh));
            for (var x = 0; x < dw; x++)
            {
                var x0 = x * sw / dw;
                var x1 = Math.Max(x0 + 1, Math.Min(sw, (x + 1) * sw / dw));
                int b = 0, g = 0, r = 0;
                for (var sy = y0; sy < y1; sy++)
                {
                    var row = sy * stride;
                    for (var sx = x0; sx < x1; sx++)
                    {
                        var si = row + sx * 4;
                        b += src[si];
                        g += src[si + 1];
                        r += src[si + 2];
                    }
                }
                var n = (y1 - y0) * (x1 - x0);
                var di = (y * dw + x) * 4;
                dst[di] = (byte)(b / n);
                dst[di + 1] = (byte)(g / n);
                dst[di + 2] = (byte)(r / n);
                dst[di + 3] = 255;
            }
        }
        return dst;
    }

    /// BT.601 limited range, what WebRTC's decoders expect. Each 2×2 block's colour is the mean of
    /// its four pixels (not just the top-left one: no colour fringes on text). Row pairs run in
    /// parallel: a 1440p frame is 3.7 M pixels, 30 times a second. Width and height must be even
    /// (FrameSize.Fit guarantees it).
    public static byte[] BgraToI420(byte[] bgra, int w, int h)
    {
        var ySize = w * h;
        var o = new byte[ySize + ySize / 2];
        var uOff = ySize;
        var vOff = ySize + ySize / 4;
        var cw = w / 2;
        Parallel.For(0, h / 2, cy =>
        {
            var y0 = cy * 2;
            for (var cx = 0; cx < cw; cx++)
            {
                int sb = 0, sg = 0, sr = 0;
                for (var dy = 0; dy < 2; dy++)
                {
                    var row = (y0 + dy) * w;
                    for (var dx = 0; dx < 2; dx++)
                    {
                        var p = row + cx * 2 + dx;
                        var i = p * 4;
                        int b = bgra[i], g = bgra[i + 1], r = bgra[i + 2];
                        o[p] = (byte)Math.Clamp(((66 * r + 129 * g + 25 * b + 128) >> 8) + 16, 0, 255);
                        sb += b;
                        sg += g;
                        sr += r;
                    }
                }
                int mb = sb >> 2, mg = sg >> 2, mr = sr >> 2;
                var ci = cy * cw + cx;
                o[uOff + ci] = (byte)Math.Clamp(((-38 * mr - 74 * mg + 112 * mb + 128) >> 8) + 128, 0, 255);
                o[vOff + ci] = (byte)Math.Clamp(((112 * mr - 94 * mg - 18 * mb + 128) >> 8) + 128, 0, 255);
            }
        });
        return o;
    }
}
