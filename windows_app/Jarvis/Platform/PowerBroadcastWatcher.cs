using Jarvis.Core.Power;

namespace Jarvis.Platform;

/// WM_POWERBROADCAST → the sleep/wake relay, as the Mac app does. Suspend blocks the message
/// loop for up to 4 s so jc-client can tell the server before the PC sleeps. Broadcasts don't
/// reach message-only windows, so this uses a hidden top-level one.
public sealed class PowerBroadcastWatcher : IDisposable
{
    private readonly MessageWindow _window = new("JarvisPower", topLevel: true);
    private readonly PowerRelay _relay;

    public PowerBroadcastWatcher(PowerRelay relay)
    {
        _relay = relay;
        _window.Add(OnMessage);
    }

    /// The PC woke (Holo Drop deliberately does nothing with this: spots stay).
    public event Action? Woke;

    private IntPtr? OnMessage(int msg, IntPtr wParam, IntPtr lParam)
    {
        if (msg != Native.WM_POWERBROADCAST) return null;
        switch (wParam.ToInt32())
        {
            case Native.PBT_APMSUSPEND:
                // Windows gives roughly 2 s before it suspends anyway; waiting longer is harmless.
                _relay.WillSleepAsync().Wait(PowerRelay.SleepWait);
                break;
            case Native.PBT_APMRESUMEAUTOMATIC:
                _relay.DidWake();
                Woke?.Invoke();
                break;
        }
        return new IntPtr(1);
    }

    public void Dispose() => _window.Dispose();
}
