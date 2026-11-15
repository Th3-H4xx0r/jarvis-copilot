using System.Runtime.InteropServices;
using Jarvis.Core.Screen;
using Jarvis.Platform;

namespace Jarvis.Screen;

/// Core's InputEvents → SendInput, in chunks. Only reached through ScreenShareService's input
/// gate, so nothing is sent while a game is on. A short count means UIPI blocked it (an
/// elevated window in front): reported once.
public sealed class SendInputSink : IInputSink
{
    public const string ElevatedError = "That window is running as administrator; Jarvis can't click into it.";
    private const int Chunk = 40;
    private bool _warned;

    public event Action<string>? Problem;

    public void Send(IReadOnlyList<InputEvent> inputs)
    {
        for (var i = 0; i < inputs.Count; i += Chunk)
        {
            var batch = inputs.Skip(i).Take(Chunk).Select(ToNative).ToArray();
            var sent = Native.SendInput((uint)batch.Length, batch, Marshal.SizeOf<Native.INPUT>());
            if (sent < batch.Length && !_warned)
            {
                _warned = true;
                Problem?.Invoke(ElevatedError);
                return;
            }
        }
    }

    private static Native.INPUT ToNative(InputEvent e) => e.Kind == InputKind.Mouse
        ? new Native.INPUT
        {
            type = Native.INPUT_MOUSE,
            u = new Native.INPUTUNION { mi = new Native.MOUSEINPUT { dx = e.Dx, dy = e.Dy, mouseData = e.MouseData, dwFlags = e.Flags } },
        }
        : new Native.INPUT
        {
            type = Native.INPUT_KEYBOARD,
            u = new Native.INPUTUNION { ki = new Native.KEYBDINPUT { wVk = e.Vk, wScan = e.Scan, dwFlags = e.Flags } },
        };
}
