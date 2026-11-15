using System.Diagnostics;
using System.Runtime.InteropServices;
using Jarvis.Core.Screen;
using vpxmd;

namespace Jarvis.Screen;

/// VP8 for the screen share, on libvpx through SIPSorcery's bindings (vpxmd), set up for a
/// desktop: a real bitrate for the frame size, 8 threads, realtime speed, screen-content mode,
/// real timestamps, and a keyframe on demand and every 4 s. SIPSorcery's own VpxVideoEncoder
/// can't be used: it sets the bitrate and then resets the config to libvpx's defaults (so every
/// share went out at ~256 kbps: grainy), runs on one thread, and stamps every frame "1".
public sealed unsafe class Vp8Encoder : IDisposable
{
    private const int AbiVersion = 23;          // VPX_ENCODER_ABI_VERSION of the bundled vpxmd.dll
    private const uint Realtime = 1;            // VPX_DL_REALTIME
    private const int ForceKeyFlag = 1;         // VPX_EFLAG_FORCE_KF
    private const int ClockHz = 90_000;

    private readonly object _lock = new();
    private readonly Stopwatch _clock = Stopwatch.StartNew();
    private VpxCodecCtx? _ctx;
    private VpxImage? _img;
    private int _w, _h;
    private long _lastPts = -1;
    private bool _forceKey = true;

    public void ForceKeyFrame()
    {
        lock (_lock) _forceKey = true;
    }

    /// One I420 frame in, the encoded VP8 frame out (null when libvpx has nothing yet).
    public byte[]? Encode(byte[] i420, int width, int height)
    {
        lock (_lock)
        {
            if (_ctx == null || width != _w || height != _h) Open(width, height);
            var pts = _clock.ElapsedTicks * ClockHz / Stopwatch.Frequency;
            if (pts <= _lastPts) pts = _lastPts + 1;
            var duration = _lastPts < 0 ? (uint)(ClockHz / 30) : (uint)Math.Clamp(pts - _lastPts, 1, ClockHz);
            _lastPts = pts;
            var flags = _forceKey ? ForceKeyFlag : 0;
            _forceKey = false;
            byte[]? frame = null;
            fixed (byte* data = i420)
            {
                VpxImage.VpxImgWrap(_img!, VpxImgFmt.VPX_IMG_FMT_I420, (uint)width, (uint)height, 1, data);
                var err = vpx_encoder.VpxCodecEncode(_ctx!, _img!, pts, duration, flags, Realtime);
                if (err != VpxCodecErrT.VPX_CODEC_OK) throw new InvalidOperationException("VP8 encode failed: " + vpx_codec.VpxCodecErrToString(err));
                var iter = IntPtr.Zero;
                for (var pkt = vpx_encoder.VpxCodecGetCxData(_ctx!, (void**)&iter); pkt != null; pkt = vpx_encoder.VpxCodecGetCxData(_ctx!, (void**)&iter))
                {
                    if (pkt.Kind != VpxCodecCxPktKind.VPX_CODEC_CX_FRAME_PKT) continue;
                    // vpx_codec_cx_pkt_t (x64): kind @0, data.frame.buf @8, data.frame.sz @16. The
                    // bindings keep `data` internal, so it's read from the struct itself.
                    var buf = Marshal.ReadIntPtr(pkt.__Instance, 8);
                    var size = (int)Marshal.ReadInt64(pkt.__Instance, 16);
                    if (buf == IntPtr.Zero || size <= 0) continue;
                    frame = new byte[size];
                    Marshal.Copy(buf, frame, 0, size);
                }
            }
            return frame;
        }
    }

    private void Open(int width, int height)
    {
        Close();
        var cfg = new VpxCodecEncCfg();
        var err = vpx_encoder.VpxCodecEncConfigDefault(vp8cx.VpxCodecVp8Cx(), cfg, 0);
        if (err != VpxCodecErrT.VPX_CODEC_OK) throw new InvalidOperationException("VP8 defaults failed: " + vpx_codec.VpxCodecErrToString(err));
        var rc = Vp8Settings.For(width, height, Environment.ProcessorCount);
        cfg.GW = (uint)width;
        cfg.GH = (uint)height;
        cfg.GTimebase = new VpxRational { Num = 1, Den = ClockHz };
        cfg.GThreads = rc.Threads;
        cfg.GLagInFrames = 0;
        cfg.GErrorResilient = 1;
        cfg.RcEndUsage = VpxRcMode.VPX_CBR;
        cfg.RcTargetBitrate = rc.Kbps;
        cfg.RcMinQuantizer = 2;
        cfg.RcMaxQuantizer = 52;
        cfg.RcUndershootPct = 100;
        cfg.RcOvershootPct = 15;
        cfg.RcBufSz = 1000;
        cfg.RcBufInitialSz = 500;
        cfg.RcBufOptimalSz = 600;
        cfg.RcDropframeThresh = 0;
        cfg.RcResizeAllowed = 0;
        cfg.KfMode = VpxKfMode.VPX_KF_AUTO;
        cfg.KfMinDist = 0;
        cfg.KfMaxDist = rc.KeyEvery;
        var ctx = new VpxCodecCtx();
        err = vpx_encoder.VpxCodecEncInitVer(ctx, vp8cx.VpxCodecVp8Cx(), cfg, 0, AbiVersion);
        if (err != VpxCodecErrT.VPX_CODEC_OK) throw new InvalidOperationException("VP8 init failed: " + vpx_codec.VpxCodecErrToString(err));
        Control(ctx, Vp8eEncControlId.VP8E_SET_CPUUSED, rc.CpuUsed);
        Control(ctx, Vp8eEncControlId.VP8E_SET_SCREEN_CONTENT_MODE, 1);
        Control(ctx, Vp8eEncControlId.VP8E_SET_STATIC_THRESHOLD, 1);
        Control(ctx, Vp8eEncControlId.VP8E_SET_NOISE_SENSITIVITY, 0);
        Control(ctx, Vp8eEncControlId.VP8E_SET_TOKEN_PARTITIONS, 2);
        Control(ctx, Vp8eEncControlId.VP8E_SET_MAX_INTRA_BITRATE_PCT, 900);
        _ctx = ctx;
        _img = new VpxImage();
        _w = width;
        _h = height;
        _lastPts = -1;
        _forceKey = true;
    }

    /// libvpx's own vpx_codec_control_ (the bindings' per-control helpers aren't exported by the
    /// bundled vpxmd.dll). Variadic in C; on x64 an int argument travels the same way either way.
    [DllImport("vpxmd", EntryPoint = "vpx_codec_control_", CallingConvention = CallingConvention.Cdecl)]
    private static extern VpxCodecErrT CodecControl(IntPtr ctx, int id, int value);

    private static void Control(VpxCodecCtx ctx, Vp8eEncControlId id, int value)
    {
        var err = CodecControl(ctx.__Instance, (int)id, value);
        if (err != VpxCodecErrT.VPX_CODEC_OK) Debug.WriteLine($"VP8 control {id} failed: {err}");
    }

    private void Close()
    {
        if (_ctx != null) vpx_codec.VpxCodecDestroy(_ctx);
        _ctx = null;
        _img = null;
    }

    public void Dispose()
    {
        lock (_lock) Close();
    }
}
