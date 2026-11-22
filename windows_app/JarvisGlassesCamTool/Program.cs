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
                _ => Fail("usage", null, "usage: JarvisGlassesCamTool create|remove|list"),
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
