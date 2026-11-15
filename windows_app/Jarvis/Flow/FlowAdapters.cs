using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using Jarvis.Core.Flow;
using Jarvis.Platform;
using Jarvis.Voice.Audio;

namespace Jarvis.Flow;

/// Flow's mic: everything from the first press to the last, 16 kHz mono, in memory only.
public sealed class FlowCapture : IFlowCapture, IDisposable
{
    private readonly Mic16k _mic = new();
    private readonly List<short> _heard = new();

    public FlowCapture() => _mic.Samples += s =>
    {
        lock (_heard) _heard.AddRange(s);
        var peak = 0;
        foreach (var v in s) peak = Math.Max(peak, Math.Abs((int)v));
        Level = peak / 32768.0;
    };

    public double Level { get; private set; }

    public void Start()
    {
        lock (_heard) _heard.Clear();
        _mic.Start();
    }

    public short[] Stop()
    {
        _mic.Stop();
        Level = 0;
        lock (_heard) return _heard.ToArray();
    }

    public void Dispose() => _mic.Dispose();
}

/// Text on the Windows clipboard. The clipboard needs the STA UI thread, and a dictation
/// finishes on a pool thread, so every call is marshalled to the Dispatcher.
public sealed class WpfClipboard : IClipboardText
{
    private static T OnUi<T>(Func<T> f) =>
        Application.Current.Dispatcher.CheckAccess() ? f() : Application.Current.Dispatcher.Invoke(f);

    public string? GetText() => OnUi(() =>
    {
        try { return Clipboard.ContainsText() ? Clipboard.GetText() : null; }
        catch (COMException) { return (string?)null; }
    });

    public void SetText(string text) => OnUi(() => { SetNow(text); return true; });

    private static void SetNow(string text)
    {
        for (var i = 0; i < 3; i++)
        {
            try { Clipboard.SetDataObject(text, copy: true); return; }
            catch (COMException) { Thread.Sleep(30); }   // another app holds the clipboard open
        }
    }
}

/// Key presses through SendInput (only for Flow's Ctrl+V and jump-to-terminal's Alt tap).
public sealed class SendInputKeys : IKeySender
{
    public bool Send(IReadOnlyList<(ushort Vk, bool Down)> keys)
    {
        const uint KEYUP = 0x2;
        var inputs = keys.Select(k => new Native.INPUT
        {
            type = Native.INPUT_KEYBOARD,
            u = new Native.INPUTUNION { ki = new Native.KEYBDINPUT { wVk = k.Vk, dwFlags = k.Down ? 0 : KEYUP } },
        }).ToArray();
        return Native.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Native.INPUT>()) == inputs.Length;
    }
}

/// The foreground app's exe name, and whether it runs elevated while Jarvis doesn't (then
/// Windows drops Jarvis's synthetic keys: UIPI).
public static class Foreground
{
    private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    private const uint TOKEN_QUERY = 0x8;
    private const int TokenElevation = 20;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr h);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetTokenInformation(IntPtr token, int cls, out int info, int len, out int returned);

    public static int Pid()
    {
        Native.GetWindowThreadProcessId(Native.GetForegroundWindow(), out var pid);
        return (int)pid;
    }

    public static string? Exe()
    {
        try { return Process.GetProcessById(Pid()).ProcessName + ".exe"; }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException) { return null; }
    }

    public static bool ElevatedAboveUs() => IsElevated((uint)Pid()) && !IsElevated((uint)Environment.ProcessId);

    private static bool IsElevated(uint pid)
    {
        var p = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        // Can't even query it: treat as elevated (Windows would block our keys the same way).
        if (p == IntPtr.Zero) return pid != (uint)Environment.ProcessId;
        try
        {
            if (!OpenProcessToken(p, TOKEN_QUERY, out var token)) return true;
            try { return GetTokenInformation(token, TokenElevation, out var elevated, 4, out _) && elevated != 0; }
            finally { CloseHandle(token); }
        }
        finally { CloseHandle(p); }
    }
}
