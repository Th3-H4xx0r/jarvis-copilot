namespace Jarvis.Core.Screen;

/// The captured frame on its way to the VP8 encoder: scaled (nearest neighbour) to the fitted
/// size, then BGRA → I420 (BT.601, studio range), which is what the encoder takes.
public static class FramePixels
{
    public static byte[] ScaleBgra(ReadOnlySpan<byte> src, int sw, int sh, int stride, int dw, int dh)
    {
        var dst = new byte[dw * dh * 4];
        for (var y = 0; y < dh; y++)
        {
            var sy = Math.Min(sh - 1, y * sh / dh);
            for (var x = 0; x < dw; x++)
            {
                var sx = Math.Min(sw - 1, x * sw / dw);
                var si = sy * stride + sx * 4;
                var di = (y * dw + x) * 4;
                dst[di] = src[si];
                dst[di + 1] = src[si + 1];
                dst[di + 2] = src[si + 2];
                dst[di + 3] = 255;
            }
        }
        return dst;
    }

    /// Width and height must be even (FrameSize.Fit guarantees it).
    public static byte[] BgraToI420(ReadOnlySpan<byte> bgra, int w, int h)
    {
        var ySize = w * h;
        var o = new byte[ySize + ySize / 2];
        var uOff = ySize;
        var vOff = ySize + ySize / 4;
        for (var y = 0; y < h; y++)
        {
            for (var x = 0; x < w; x++)
            {
                var i = (y * w + x) * 4;
                int b = bgra[i], g = bgra[i + 1], r = bgra[i + 2];
                o[y * w + x] = (byte)Math.Clamp(((66 * r + 129 * g + 25 * b + 128) >> 8) + 16, 0, 255);
                if ((y & 1) == 0 && (x & 1) == 0)
                {
                    var ci = (y / 2) * (w / 2) + x / 2;
                    o[uOff + ci] = (byte)Math.Clamp(((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128, 0, 255);
                    o[vOff + ci] = (byte)Math.Clamp(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128, 0, 255);
                }
            }
        }
        return o;
    }
}
