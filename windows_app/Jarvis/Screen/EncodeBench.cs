using System.Diagnostics;
using Jarvis.Platform;

namespace Jarvis.Screen;

/// `--diag encode-bench <out.txt>`: one capture of the main display through the share's own
/// path (WGC → I420), then 150 frames of it scrolling 4 px a frame through Vp8Encoder (a page
/// being scrolled: the hard case), each decoded again. Reports encode time, the bitrate at 30
/// fps and PSNR against the source (desktop verification of the share's quality; nothing on his
/// screen changes).
internal static class EncodeBench
{
    public static void Run(string path)
    {
        var lines = new List<string>();
        try
        {
            byte[]? first = null;
            int w = 0, h = 0;
            using (var capture = new WgcCapture())
            {
                var got = new ManualResetEventSlim();
                capture.Frame += (i420, fw, fh) => { if (first == null) { first = i420; (w, h) = (fw, fh); got.Set(); } };
                capture.Start(Monitors.Primary()!.Handle);
                got.Wait(TimeSpan.FromSeconds(5));
                capture.Stop();
            }
            if (first == null) throw new InvalidOperationException("no frame captured");

            using var encoder = new Vp8Encoder();
            using var decoder = new SIPSorceryMedia.Encoders.Codecs.Vp8Codec();
            decoder.InitialiseDecoder();
            const int Frames = 150;
            long bytes = 0, keyBytes = 0;
            double encodeMs = 0, worstMs = 0, psnrSum = 0, psnrMin = 99;
            int psnrCount = 0;
            for (var n = 0; n < Frames; n++)
            {
                var frame = Scrolled(first, w, h, n * 4);
                var t = Stopwatch.StartNew();
                var vp8 = encoder.Encode(frame, w, h);
                var ms = t.Elapsed.TotalMilliseconds;
                encodeMs += ms;
                worstMs = Math.Max(worstMs, ms);
                if (vp8 == null) continue;
                bytes += vp8.Length;
                if ((vp8[0] & 1) == 0) keyBytes += vp8.Length;
                var decoded = decoder.Decode(vp8, vp8.Length, out _, out _);
                if (n % 10 == 0)
                    foreach (var img in decoded)
                    {
                        var p = Psnr(frame, img, w * h);
                        psnrSum += p;
                        psnrMin = Math.Min(psnrMin, p);
                        psnrCount++;
                    }
                Thread.Sleep(Math.Max(0, 33 - (int)ms));   // paced like the share (30 fps)
            }
            lines.Add($"frame {w}x{h}, {Frames} scrolling frames");
            lines.Add($"encode avg {encodeMs / Frames:F1} ms, worst {worstMs:F1} ms (budget 33 ms at 30 fps)");
            lines.Add($"bitrate {bytes * 8.0 / (Frames / 30.0) / 1000:F0} kbps at 30 fps (keyframes {keyBytes * 100 / Math.Max(1, bytes)}% of bytes)");
            lines.Add($"psnr (Y) avg {psnrSum / Math.Max(1, psnrCount):F1} dB, min {psnrMin:F1} dB over {psnrCount} frames");
        }
        catch (Exception e)
        {
            lines.Add("failed: " + e);
        }
        System.IO.File.WriteAllLines(path, lines);
    }

    /// The I420 frame moved up by `px` rows (even), wrapping: a page scrolling.
    private static byte[] Scrolled(byte[] src, int w, int h, int px)
    {
        px = (px % h) & ~1;
        var o = new byte[src.Length];
        Copy(src, o, 0, w, h, px);
        Copy(src, o, w * h, w / 2, h / 2, px / 2);
        Copy(src, o, w * h + w * h / 4, w / 2, h / 2, px / 2);
        return o;
    }

    private static void Copy(byte[] src, byte[] dst, int off, int w, int h, int shift)
    {
        for (var y = 0; y < h; y++)
            Buffer.BlockCopy(src, off + ((y + shift) % h) * w, dst, off + y * w, w);
    }

    /// PSNR of the Y plane (the first `pixels` bytes of each I420 buffer).
    private static double Psnr(byte[] a, byte[] b, int pixels)
    {
        if (b.Length < pixels) return 0;
        double se = 0;
        for (var i = 0; i < pixels; i++)
        {
            var d = a[i] - b[i];
            se += d * d;
        }
        var mse = se / pixels;
        return mse <= 0 ? 99 : 10 * Math.Log10(255.0 * 255.0 / mse);
    }
}
