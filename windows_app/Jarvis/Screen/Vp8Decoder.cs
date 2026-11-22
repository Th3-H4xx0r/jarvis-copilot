using vpxmd;

namespace Jarvis.Screen;

/// VP8 decoding on libvpx through SIPSorcery's bindings (vpxmd), the mirror of Vp8Encoder: the
/// glasses' live video arriving from the iPhone for the Jarvis Glasses camera. Each picture comes
/// out as its I420 planes, straight from libvpx's buffers (no copy).
public sealed unsafe class Vp8Decoder : IDisposable
{
    private const int AbiVersion = 12;   // VPX_DECODER_ABI_VERSION of the bundled vpxmd.dll

    /// One decoded picture's planes (valid only during the call).
    public delegate void Picture(ReadOnlySpan<byte> y, int yStride, ReadOnlySpan<byte> u, int uStride,
        ReadOnlySpan<byte> v, int vStride, int width, int height);

    private readonly object _lock = new();
    private VpxCodecCtx? _ctx;
    private bool _disposed;

    /// Decodes one frame; `picture` gets each picture libvpx yields (normally one). False when
    /// libvpx refused it (a frame broken by a lost packet): ask the sender for a keyframe.
    public bool Decode(byte[] frame, Picture picture)
    {
        lock (_lock)
        {
            if (_disposed || frame.Length == 0) return false;
            _ctx ??= Open();
            fixed (byte* data = frame)
            {
                if (vpx_decoder.VpxCodecDecode(_ctx, data, (uint)frame.Length, IntPtr.Zero, 0) != VpxCodecErrT.VPX_CODEC_OK) return false;
            }
            var iter = IntPtr.Zero;
            for (var img = vpx_decoder.VpxCodecGetFrame(_ctx, (void**)&iter); img != null; img = vpx_decoder.VpxCodecGetFrame(_ctx, (void**)&iter))
            {
                int w = (int)img.DW, h = (int)img.DH;
                if (w <= 0 || h <= 0) continue;
                var stride = img.Stride;
                var ch = (h + 1) / 2;
                picture(new ReadOnlySpan<byte>((void*)img.PlaneY, stride[0] * h), stride[0],
                    new ReadOnlySpan<byte>((void*)img.PlaneU, stride[1] * ch), stride[1],
                    new ReadOnlySpan<byte>((void*)img.PlaneV, stride[2] * ch), stride[2], w, h);
            }
            return true;
        }
    }

    private static VpxCodecCtx Open()
    {
        var ctx = new VpxCodecCtx();
        var err = vpx_decoder.VpxCodecDecInitVer(ctx, vp8dx.VpxCodecVp8Dx(), null, 0, AbiVersion);
        if (err != VpxCodecErrT.VPX_CODEC_OK) throw new InvalidOperationException("VP8 decoder init failed: " + vpx_codec.VpxCodecErrToString(err));
        return ctx;
    }

    public void Dispose()
    {
        lock (_lock)
        {
            _disposed = true;
            if (_ctx != null) vpx_codec.VpxCodecDestroy(_ctx);
            _ctx = null;
        }
    }
}
