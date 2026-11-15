using Jarvis.Core.Voice;
using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;

namespace Jarvis.Voice.Audio;

/// The Windows default speaker and mic (console role), and a change notice when either moves
/// (a headset plugged in). Event-driven through IMMNotificationClient: nothing polls.
public sealed class AudioEndpoints : IAudioEndpoints, IMMNotificationClient, IDisposable
{
    private readonly MMDeviceEnumerator _enumerator = new();

    public AudioEndpoints() => _enumerator.RegisterEndpointNotificationCallback(this);

    public event Action? DefaultsChanged;

    public (string RenderId, string CaptureId) Defaults()
    {
        string Id(DataFlow flow) => _enumerator.HasDefaultAudioEndpoint(flow, Role.Console)
            ? _enumerator.GetDefaultAudioEndpoint(flow, Role.Console).ID : "";
        return (Id(DataFlow.Render), Id(DataFlow.Capture));
    }

    /// The device's position among active endpoints of its kind: what the AEC DSP's
    /// DEVICE_INDEXES wants. -1 = let Windows pick its default.
    public static int IndexOf(string id, DataFlow flow)
    {
        if (id.Length == 0) return -1;
        using var e = new MMDeviceEnumerator();
        var i = 0;
        foreach (var d in e.EnumerateAudioEndPoints(flow, DeviceState.Active))
        {
            if (d.ID == id) return i;
            i++;
        }
        return -1;
    }

    public static string FriendlyName(string id)
    {
        try
        {
            using var e = new MMDeviceEnumerator();
            return e.GetDevice(id).FriendlyName;
        }
        catch (Exception ex) when (ex is System.Runtime.InteropServices.COMException or ArgumentException)
        {
            return "";
        }
    }

    public void OnDefaultDeviceChanged(DataFlow flow, Role role, string defaultDeviceId)
    {
        if (role == Role.Console) DefaultsChanged?.Invoke();
    }

    public void OnDeviceStateChanged(string deviceId, DeviceState newState) { }
    public void OnDeviceAdded(string pwstrDeviceId) { }
    public void OnDeviceRemoved(string deviceId) { }
    public void OnPropertyValueChanged(string pwstrDeviceId, PropertyKey key) { }

    public void Dispose()
    {
        _enumerator.UnregisterEndpointNotificationCallback(this);
        _enumerator.Dispose();
    }
}
