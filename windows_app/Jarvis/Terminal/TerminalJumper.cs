using System.Diagnostics;
using System.Runtime.InteropServices;
using Jarvis.Core.Gaming;
using Jarvis.Core.Model;
using Jarvis.Core.Terminal;
using Jarvis.Platform;

namespace Jarvis.Terminal;

/// Raises a session's terminal. Only ever on his hotkey or click (never on attention), and
/// refused while a game is on. Activation is the documented focus-permission trick: restore if
/// minimised, a lone Alt tap, then SetForegroundWindow.
public sealed class TerminalJumper
{
    private readonly Func<GameMode> _gameMode;

    public TerminalJumper(Func<GameMode> gameMode) => _gameMode = gameMode;

    /// Returns null on success, else the reason (shown in the island).
    public string? Jump(AgentSession s)
    {
        if (ComputerControlGuard.Refusal(_gameMode()) is { } refusal) return refusal;
        var hwnd = IntPtr.Zero;
        if (s.Terminal.WindowPid > 0 && Alive(s.Terminal.WindowPid)) hwnd = TopWindowOf(s.Terminal.WindowPid);
        if (hwnd == IntPtr.Zero)
        {
            var running = Process.GetProcesses().Select(p => { try { return p.ProcessName + ".exe"; } catch (InvalidOperationException) { return ""; } })
                .Where(n => n.Length > 4).ToHashSet(StringComparer.OrdinalIgnoreCase);
            if (TerminalTarget.PickExe(s.Terminal, running) is { } exe)
                foreach (var p in Process.GetProcessesByName(System.IO.Path.GetFileNameWithoutExtension(exe)))
                {
                    hwnd = TopWindowOf(p.Id);
                    if (hwnd != IntPtr.Zero) break;
                }
        }
        if (hwnd == IntPtr.Zero) return "Couldn't find that session's terminal.";
        Activate(hwnd);
        return null;
    }

    private static bool Alive(int pid)
    {
        try { return !Process.GetProcessById(pid).HasExited; }
        catch (ArgumentException) { return false; }
        catch (InvalidOperationException) { return false; }
    }

    [ThreadStatic] private static (uint Pid, IntPtr Found) _search;

    private static unsafe IntPtr TopWindowOf(int pid)
    {
        _search = ((uint)pid, IntPtr.Zero);
        Native.EnumWindows(&Visit, IntPtr.Zero);
        return _search.Found;
    }

    [UnmanagedCallersOnly]
    private static int Visit(IntPtr hwnd, IntPtr data)
    {
        Native.GetWindowThreadProcessId(hwnd, out var pid);
        if (pid != _search.Pid || !Native.IsWindowVisible(hwnd) || Native.GetWindow(hwnd, Native.GW_OWNER) != IntPtr.Zero) return 1;
        _search.Found = hwnd;
        return 0;
    }

    public static void Activate(IntPtr hwnd)
    {
        if (Native.IsIconic(hwnd)) Native.ShowWindow(hwnd, Native.SW_RESTORE);
        const ushort VK_MENU = 0x12;
        const uint KEYUP = 0x2;
        var alt = new[]
        {
            new Native.INPUT { type = Native.INPUT_KEYBOARD, u = new Native.INPUTUNION { ki = new Native.KEYBDINPUT { wVk = VK_MENU } } },
            new Native.INPUT { type = Native.INPUT_KEYBOARD, u = new Native.INPUTUNION { ki = new Native.KEYBDINPUT { wVk = VK_MENU, dwFlags = KEYUP } } },
        };
        Native.SendInput(2, alt, Marshal.SizeOf<Native.INPUT>());
        Native.SetForegroundWindow(hwnd);
    }
}
