using System.Runtime.InteropServices;

namespace Jarvis.Voice.Audio;

/// A voice turn must never turn the game down. The echo-cancelling capture opens a
/// "communications" stream, which by default makes Windows duck every other app by 80%;
/// IAudioSessionControl2.SetDuckingPreference(TRUE) on this process's sessions opts out. Called
/// before each capture starts (the docs require it before the communications stream opens).
public static class DuckingOptOut
{
    private const int ERender = 0, ECapture = 1;
    private const int EConsole = 0, ECommunications = 2;
    private const int ClsCtxAll = 0x17;

    public static void Apply(Action<string>? log = null)
    {
        try
        {
            var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorCom();
            foreach (var (flow, role) in new[] { (ECapture, ECommunications), (ECapture, EConsole), (ERender, ECommunications), (ERender, EConsole) })
            {
                if (enumerator.GetDefaultAudioEndpoint(flow, role, out var device) != 0 || device == null) continue;
                var iid = typeof(IAudioSessionManager).GUID;
                if (device.Activate(ref iid, ClsCtxAll, IntPtr.Zero, out var mgrObj) != 0 || mgrObj is not IAudioSessionManager mgr) continue;
                if (mgr.GetAudioSessionControl(IntPtr.Zero, 0, out var control) != 0 || control is not IAudioSessionControl2 control2) continue;
                control2.SetDuckingPreference(true);
            }
        }
        catch (Exception e) when (e is COMException or InvalidCastException)
        {
            log?.Invoke($"ducking opt-out failed: {e.Message}");
        }
    }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    private class MMDeviceEnumeratorCom { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice? device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object? iface);
    }

    [ComImport, Guid("BFA971F1-4D5E-40BB-935E-967039BFBEE4"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioSessionManager
    {
        [PreserveSig] int GetAudioSessionControl(IntPtr sessionGuid, int streamFlags, [MarshalAs(UnmanagedType.IUnknown)] out object? control);
    }

    [ComImport, Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioSessionControl2
    {
        // IAudioSessionControl
        [PreserveSig] int GetState(out int state);
        [PreserveSig] int GetDisplayName(out IntPtr name);
        [PreserveSig] int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string name, ref Guid context);
        [PreserveSig] int GetIconPath(out IntPtr path);
        [PreserveSig] int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string path, ref Guid context);
        [PreserveSig] int GetGroupingParam(out Guid param);
        [PreserveSig] int SetGroupingParam(ref Guid param, ref Guid context);
        [PreserveSig] int RegisterAudioSessionNotification(IntPtr client);
        [PreserveSig] int UnregisterAudioSessionNotification(IntPtr client);
        // IAudioSessionControl2
        [PreserveSig] int GetSessionIdentifier(out IntPtr id);
        [PreserveSig] int GetSessionInstanceIdentifier(out IntPtr id);
        [PreserveSig] int GetProcessId(out uint pid);
        [PreserveSig] int IsSystemSoundsSession();
        [PreserveSig] int SetDuckingPreference([MarshalAs(UnmanagedType.Bool)] bool optOut);
    }
}
