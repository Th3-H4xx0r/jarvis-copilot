using System.Runtime.InteropServices;
using Jarvis.Core.Screen;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;
using Windows.Graphics.Imaging;
using WinRT;

namespace Jarvis.Screen;

/// One monitor through Windows.Graphics.Capture: a free-threaded frame pool (BGRA), no yellow
/// border, cursor included, at most 30 fps. Each frame is copied to a SoftwareBitmap, fitted to
/// 1920×1080 with even sides and converted to I420 for the encoder. Exists only while a share is
/// live; nothing captures otherwise.
public sealed class WgcCapture : IDisposable
{
    private static readonly Guid GraphicsCaptureItemIid = new("79C3F95B-31F7-4EC2-A464-632EF5D30760");
    private static readonly TimeSpan MinFrameGap = TimeSpan.FromMilliseconds(33);

    private IDirect3DDevice? _device;
    private Direct3D11CaptureFramePool? _pool;
    private GraphicsCaptureSession? _session;
    private DateTime _last;
    private int _busy;

    /// (I420 bytes, width, height) for each frame kept.
    public event Action<byte[], int, int>? Frame;
    public event Action<string>? Stopped;

    public void Start(IntPtr monitor)
    {
        Stop();
        _device = CreateDevice();
        var item = ForMonitor(monitor);
        item.Closed += (_, _) => Stopped?.Invoke("The shared display went away.");
        _pool = Direct3D11CaptureFramePool.CreateFreeThreaded(_device, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, item.Size);
        _session = _pool.CreateCaptureSession(item);
        try { _session.IsBorderRequired = false; } catch (Exception e) when (e is COMException or UnauthorizedAccessException) { }
        _session.IsCursorCaptureEnabled = true;
        _pool.FrameArrived += OnFrame;
        _session.StartCapture();
    }

    private void OnFrame(Direct3D11CaptureFramePool pool, object _)
    {
        using var frame = pool.TryGetNextFrame();
        if (frame == null) return;
        var now = DateTime.UtcNow;
        if (now - _last < MinFrameGap || Interlocked.Exchange(ref _busy, 1) == 1) return;
        _last = now;
        try
        {
            using var bmp = SoftwareBitmap.CreateCopyFromSurfaceAsync(frame.Surface, BitmapAlphaMode.Ignore).AsTask().GetAwaiter().GetResult();
            int w = bmp.PixelWidth, h = bmp.PixelHeight;
            var bgra = new byte[w * h * 4];
            bmp.CopyToBuffer(System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions.AsBuffer(bgra));
            var (fw, fh) = FrameSize.Fit(w, h);
            var scaled = fw == w && fh == h ? bgra : FramePixels.ScaleBgra(bgra, w, h, w * 4, fw, fh);
            Frame?.Invoke(FramePixels.BgraToI420(scaled, fw, fh), fw, fh);
        }
        catch (Exception e) when (e is COMException or InvalidOperationException or ObjectDisposedException) { }
        finally { Interlocked.Exchange(ref _busy, 0); }
    }

    public void Stop()
    {
        if (_pool != null) _pool.FrameArrived -= OnFrame;
        _session?.Dispose();
        _pool?.Dispose();
        (_device as IDisposable)?.Dispose();
        _session = null;
        _pool = null;
        _device = null;
    }

    public void Dispose() => Stop();

    // ── D3D11 + WinRT interop ──────────────────────────────────────────

    [DllImport("d3d11.dll", ExactSpelling = true)]
    private static extern int D3D11CreateDevice(IntPtr adapter, int driverType, IntPtr software, uint flags, IntPtr levels, uint count,
        uint sdk, out IntPtr device, out int level, out IntPtr context);

    [DllImport("d3d11.dll", ExactSpelling = true)]
    private static extern int CreateDirect3D11DeviceFromDXGIDevice(IntPtr dxgiDevice, out IntPtr graphicsDevice);

    [ComImport, Guid("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IGraphicsCaptureItemInterop
    {
        IntPtr CreateForWindow([In] IntPtr window, [In] ref Guid iid);
        IntPtr CreateForMonitor([In] IntPtr monitor, [In] ref Guid iid);
    }

    private static IDirect3DDevice CreateDevice()
    {
        const int Hardware = 1;
        const uint BgraSupport = 0x20, SdkVersion = 7;
        Marshal.ThrowExceptionForHR(D3D11CreateDevice(IntPtr.Zero, Hardware, IntPtr.Zero, BgraSupport, IntPtr.Zero, 0, SdkVersion,
            out var d3d, out _, out var ctx));
        try
        {
            var dxgiIid = new Guid("54ec77fa-1377-44e6-8c32-88fd5f44c84c");
            Marshal.ThrowExceptionForHR(Marshal.QueryInterface(d3d, ref dxgiIid, out var dxgi));
            try
            {
                Marshal.ThrowExceptionForHR(CreateDirect3D11DeviceFromDXGIDevice(dxgi, out var inspectable));
                try { return MarshalInterface<IDirect3DDevice>.FromAbi(inspectable); }
                finally { Marshal.Release(inspectable); }
            }
            finally { Marshal.Release(dxgi); }
        }
        finally
        {
            Marshal.Release(ctx);
            Marshal.Release(d3d);
        }
    }

    private static GraphicsCaptureItem ForMonitor(IntPtr monitor)
    {
        var factory = ActivationFactory.Get("Windows.Graphics.Capture.GraphicsCaptureItem");
        var interop = factory.AsInterface<IGraphicsCaptureItemInterop>();
        var iid = GraphicsCaptureItemIid;
        var ptr = interop.CreateForMonitor(monitor, ref iid);
        try { return GraphicsCaptureItem.FromAbi(ptr); }
        finally { Marshal.Release(ptr); }
    }
}
