using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text.Json.Nodes;
using DirectN;
using Jarvis.Core.GlassesCamera;

namespace JarvisGlassesCamTool;

/// The Jarvis Glasses camera's setup tool (Program Files\Jarvis\GlassesCamera). Prints one JSON
/// line; exit 0 = it worked.
///   create   makes the "Jarvis Glasses" virtual camera for good (system lifetime: it survives
///            reboots and this tool exiting); admin, run by glasses-camera.ps1
///   remove   removes it (admin)
///   list     the cameras Windows lists
///   probe <out.png> [seconds] [format]
///            reads "Jarvis Glasses" through Windows' camera service like an app does and saves
///            the last frame (format: 0 = 720×1280 NV12, 1 = RGB32, 2 = 1280×720 NV12, 3 = RGB32)
///   selftest <dir>
///            drives the media source in this process (no install, no admin): every format, first
///            with no frames (the card), then with a test picture as the newest frame; PNGs in <dir>
internal static unsafe class Program
{
    private static int Main(string[] args)
    {
        var verb = args.Length > 0 ? args[0] : "";
        JsonObject result;
        try
        {
            MFFunctions.MFStartup();
            result = verb switch
            {
                "create" => Create(),
                "remove" => Remove(),
                "list" => List(),
                "probe" when args.Length > 1 => Probe(args[1], args.Length > 2 && double.TryParse(args[2], System.Globalization.CultureInfo.InvariantCulture, out var s) ? s : 3,
                    args.Length > 3 && uint.TryParse(args[3], out var f) ? f : 1),
                "selftest" when args.Length > 1 => SelfTest(args[1]),
                _ => Fail("usage", null, "usage: JarvisGlassesCamTool create|remove|list|probe <out.png> [seconds] [format]|selftest <dir>"),
            };
        }
        catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException)
        {
            result = Fail(verb, null, "unsupported");
        }
        catch (COMException e)
        {
            result = Fail(verb, e.HResult, e.Message);
        }
        Console.WriteLine(result.ToJsonString());
        return result["ok"]?.GetValue<bool>() == true ? 0 : 1;
    }

    private static JsonObject Fail(string step, int? hr, string? error)
    {
        var o = new JsonObject { ["ok"] = false, ["step"] = step };
        if (hr is { } h) o["hr"] = h;
        if (error != null) o["error"] = error;
        return o;
    }

    private static bool Elevated()
    {
        using var id = WindowsIdentity.GetCurrent();
        return new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator);
    }

    /// The camera object for "Jarvis Glasses" (a new one, or the existing camera with the same name
    /// and source): system lifetime, every user's apps see it when made as admin.
    private static HRESULT Open(out IMFVirtualCamera camera)
    {
        camera = null!;
        Functions.MFIsVirtualCameraTypeSupported(__MIDL___MIDL_itf_mfvirtualcamera_0000_0000_0001.MFVirtualCameraType_SoftwareCameraSource, out var supported);
        if (!supported) return HRESULTS.E_NOTIMPL;
        return Functions.MFCreateVirtualCamera(
            __MIDL___MIDL_itf_mfvirtualcamera_0000_0000_0001.MFVirtualCameraType_SoftwareCameraSource,
            __MIDL___MIDL_itf_mfvirtualcamera_0000_0000_0002.MFVirtualCameraLifetime_System,
            Elevated() ? __MIDL___MIDL_itf_mfvirtualcamera_0000_0000_0003.MFVirtualCameraAccess_AllUsers
                       : __MIDL___MIDL_itf_mfvirtualcamera_0000_0000_0003.MFVirtualCameraAccess_CurrentUser,
            GlassesCamSpec.Name,
            "{" + GlassesCamSpec.SourceClsid + "}",
            null!,
            0,
            out camera);
    }

    private static JsonObject Create()
    {
        var hr = Open(out var camera);
        if (hr == HRESULTS.E_NOTIMPL) return Fail("create", null, "unsupported");
        if (hr.IsError) return Fail("create", hr.Value, null);
        try
        {
            hr = camera.Start(null!);
            return hr.IsError ? Fail("start", hr.Value, null) : new JsonObject { ["ok"] = true, ["elevated"] = Elevated() };
        }
        finally
        {
            Marshal.ReleaseComObject(camera);
        }
    }

    private static JsonObject Remove()
    {
        var hr = Open(out var camera);
        if (hr == HRESULTS.E_NOTIMPL) return Fail("remove", null, "unsupported");
        if (hr.IsError) return Fail("remove", hr.Value, null);
        try
        {
            hr = camera.Remove();
            return hr.IsError ? Fail("remove", hr.Value, null) : new JsonObject { ["ok"] = true };
        }
        finally
        {
            Marshal.ReleaseComObject(camera);
        }
    }

    private static JsonObject List()
    {
        var names = new JsonArray();
        foreach (var (name, activate) in Cameras())
        {
            names.Add(name);
            Marshal.ReleaseComObject(activate);
        }
        return new JsonObject { ["ok"] = true, ["cameras"] = names };
    }

    /// "Jarvis Glasses" as an app sees it (through Windows' camera service): reads for `seconds`
    /// and saves the last frame.
    private static JsonObject Probe(string png, double seconds, uint format)
    {
        IMFActivate? camera = null;
        foreach (var (name, activate) in Cameras())
        {
            if (camera == null && name == GlassesCamSpec.Name) camera = activate;
            else Marshal.ReleaseComObject(activate);
        }
        if (camera == null) return Fail("probe", null, "Windows lists no \"Jarvis Glasses\" camera");
        camera.ActivateObject(typeof(IMFMediaSource).GUID, out var activated).ThrowOnError();
        var source = (IMFMediaSource)activated;
        try { return Read(source, format, seconds, png); }
        finally
        {
            source.Shutdown();
            Marshal.ReleaseComObject(source);
            Marshal.ReleaseComObject(camera);
        }
    }

    /// The media source in this process, as Windows' camera service would drive it (it hands the
    /// source a sample allocator first): a PNG per format, of the card and of a test picture.
    private static JsonObject SelfTest(string dir)
    {
        Directory.CreateDirectory(dir);
        var frames = Path.Combine(dir, "selftest-frames.bin");
        Environment.SetEnvironmentVariable(GlassesCamSpec.FrameFileOverride, frames);
        File.Delete(frames);
        GlassesCamFrameFile.Open(frames, create: true).Dispose();
        var shots = new JsonArray();
        using var writer = GlassesCamFrameFile.Open(frames, create: false);
        var picture = TestPicture();
        Timer? feed = null;
        foreach (var label in new[] { "card", "live" })
        {
            if (label == "live")
            {
                // Like the Jarvis app while the phone streams: a fresh frame several times a second.
                writer.WriteFrame(picture, 720, 1280, 720 * 4, DateTime.UtcNow);
                feed = new Timer(_ => writer.WriteFrame(picture, 720, 1280, 720 * 4, DateTime.UtcNow), null, 100, 100);
            }
            for (uint format = 0; format < 4; format++)
            {
                var activator = new JarvisGlassesCam.Activator();
                var hr = activator.ActivateObject(typeof(IMFMediaSource).GUID, out var ptr);
                if (hr.IsError) return Fail("selftest: activate", hr.Value, null);
                var source = (IMFMediaSource)Marshal.GetObjectForIUnknown(ptr);
                Marshal.Release(ptr);
                try
                {
                    hr = Functions.MFCreateVideoSampleAllocatorEx(typeof(IMFVideoSampleAllocatorEx).GUID, out var allocatorPtr);
                    if (hr.IsError) return Fail("selftest: allocator", hr.Value, null);
                    var allocator = Marshal.GetObjectForIUnknown(allocatorPtr);
                    Marshal.Release(allocatorPtr);
                    hr = ((IMFSampleAllocatorControl)source).SetDefaultAllocator(0, allocator);
                    if (hr.IsError) return Fail("selftest: set allocator", hr.Value, null);
                    var shot = Read(source, format, 0.5, Path.Combine(dir, $"selftest-{label}-{format}.png"));
                    shot["label"] = label;
                    shots.Add(shot);
                    if (shot["ok"]?.GetValue<bool>() != true) return new JsonObject { ["ok"] = false, ["shots"] = shots };
                }
                finally
                {
                    source.Shutdown();
                    if (source is IDisposable managed) managed.Dispose();   // in-process it's the managed source itself, not a COM wrapper
                }
            }
        }
        feed?.Dispose();
        return new JsonObject { ["ok"] = true, ["shots"] = shots };
    }

    /// Colour bars with a white frame: easy to tell from the card and to check for letterboxing.
    private static byte[] TestPicture()
    {
        var px = new byte[720 * 1280 * 4];
        (byte B, byte G, byte R)[] bars = { (255, 255, 255), (0, 255, 255), (255, 255, 0), (0, 255, 0), (255, 0, 255), (0, 0, 255), (255, 0, 0), (0, 0, 0) };
        for (var y = 0; y < 1280; y++)
            for (var x = 0; x < 720; x++)
            {
                var edge = x < 8 || y < 8 || x >= 712 || y >= 1272;
                var (b, g, r) = edge ? ((byte)255, (byte)255, (byte)255) : bars[x * bars.Length / 720];
                var i = (y * 720 + x) * 4;
                px[i] = b; px[i + 1] = g; px[i + 2] = r; px[i + 3] = 255;
            }
        return px;
    }

    /// Reads one native format from `source` for `seconds` (at least 3 frames) and saves the last frame as a PNG.
    private static JsonObject Read(IMFMediaSource source, uint format, double seconds, string png)
    {
        Functions.MFCreateSourceReaderFromMediaSource(source, null!, out var reader).ThrowOnError();
        try
        {
            reader.GetNativeMediaType(0, format, out var type).ThrowOnError();
            type.GetGUID(MFConstants.MF_MT_SUBTYPE, out var subtype).ThrowOnError();
            type.GetUINT64(MFConstants.MF_MT_FRAME_SIZE, out var size).ThrowOnError();
            int w = (int)(size >> 32), h = (int)(size & 0xFFFFFFFF);
            reader.SetCurrentMediaType(0, IntPtr.Zero, type).ThrowOnError();
            reader.SetStreamSelection(0, true).ThrowOnError();   // the source's stream starts deselected (the camera service selects it)
            var nv12 = subtype == MFConstants.MFVideoFormat_NV12;
            byte[]? last = null;
            var frames = 0;
            var until = DateTime.UtcNow.AddSeconds(seconds);
            while (frames < 3 || DateTime.UtcNow < until)
            {
                uint actual, flags;
                long stamp;
                var hr = reader.ReadSample(0, 0, (IntPtr)(&actual), (IntPtr)(&flags), (IntPtr)(&stamp), out var sample);
                if (hr.IsError) return Fail("read", hr.Value, $"after {frames} frames");
                if ((flags & 3) != 0) return Fail("read", null, $"the stream {((flags & 1) != 0 ? "failed" : "ended")} after {frames} frames");
                if (sample == null) continue;
                try
                {
                    sample.ConvertToContiguousBuffer(out var buffer).ThrowOnError();
                    try
                    {
                        buffer.Lock(out var data, IntPtr.Zero, IntPtr.Zero).ThrowOnError();
                        try { last = nv12 ? Nv12ToBgra((byte*)data, w, h) : new ReadOnlySpan<byte>((void*)data, w * h * 4).ToArray(); }
                        finally { buffer.Unlock(); }
                    }
                    finally { Marshal.ReleaseComObject(buffer); }
                }
                finally { Marshal.ReleaseComObject(sample); }
                frames++;
            }
            File.WriteAllBytes(png, GlassesCamPng.EncodeBgra(last!, w, h));
            return new JsonObject { ["ok"] = true, ["format"] = format, ["subtype"] = nv12 ? "NV12" : "RGB32", ["width"] = w, ["height"] = h, ["frames"] = frames, ["png"] = png };
        }
        finally
        {
            Marshal.ReleaseComObject(reader);
        }
    }

    /// NV12 (BT.709 studio range, what the camera says it sends) → BGRA, for the snapshots.
    private static byte[] Nv12ToBgra(byte* data, int w, int h)
    {
        var o = new byte[w * h * 4];
        var uv = data + w * h;
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
            {
                var c = 298 * (data[y * w + x] - 16);
                var d = uv[y / 2 * w + (x & ~1)] - 128;
                var e = uv[y / 2 * w + (x & ~1) + 1] - 128;
                var i = (y * w + x) * 4;
                o[i] = (byte)Math.Clamp((c + 541 * d + 128) >> 8, 0, 255);
                o[i + 1] = (byte)Math.Clamp((c - 55 * d - 136 * e + 128) >> 8, 0, 255);
                o[i + 2] = (byte)Math.Clamp((c + 459 * e + 128) >> 8, 0, 255);
                o[i + 3] = 255;
            }
        return o;
    }

    /// Every video capture device Media Foundation sees, with its friendly name.
    internal static List<(string Name, IMFActivate Activate)> Cameras()
    {
        Functions.MFCreateAttributes(out var attrs, 1).ThrowOnError();
        attrs.SetGUID(MFConstants.MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, MFConstants.MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID).ThrowOnError();
        Functions.MFEnumDeviceSources(attrs, out IntPtr array, out var count).ThrowOnError();
        var found = new List<(string, IMFActivate)>();
        try
        {
            for (var i = 0; i < count; i++)
            {
                var p = Marshal.ReadIntPtr(array, i * IntPtr.Size);
                var activate = (IMFActivate)Marshal.GetObjectForIUnknown(p);
                Marshal.Release(p);
                IntPtr text = IntPtr.Zero;
                activate.GetAllocatedString(MFConstants.MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME, (IntPtr)(&text), out _);
                var name = Marshal.PtrToStringUni(text) ?? "";
                Marshal.FreeCoTaskMem(text);
                found.Add((name, activate));
            }
        }
        finally
        {
            Marshal.FreeCoTaskMem(array);
            Marshal.ReleaseComObject(attrs);
        }
        return found;
    }
}
