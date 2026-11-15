using Jarvis.Core.Model;

namespace Jarvis.Core.Terminal;

/// Which window "jump to terminal" raises: the session's own terminal exe when it is running,
/// else the first known terminal that is.
public static class TerminalTarget
{
    public static readonly string[] KnownExes =
    {
        "WindowsTerminal.exe", "Code.exe", "Cursor.exe", "wezterm-gui.exe", "alacritty.exe", "pwsh.exe", "powershell.exe", "cmd.exe",
    };

    public static string? PickExe(TerminalInfo t, IReadOnlySet<string> runningExes)
    {
        bool Running(string exe) => runningExes.Any(r => string.Equals(r, exe, StringComparison.OrdinalIgnoreCase));
        if (t.Exe.Length > 0 && Running(t.Exe)) return runningExes.First(r => string.Equals(r, t.Exe, StringComparison.OrdinalIgnoreCase));
        if (FromTermProgram(t.TermProgram) is { } fromProgram && Running(fromProgram)) return fromProgram;
        return KnownExes.FirstOrDefault(Running);
    }

    /// TERM_PROGRAM values agents report → the exe that owns them.
    public static string? FromTermProgram(string termProgram) => termProgram.ToLowerInvariant() switch
    {
        "vscode" => "Code.exe",
        "cursor" => "Cursor.exe",
        "wezterm" => "wezterm-gui.exe",
        "alacritty" => "alacritty.exe",
        "windows_terminal" or "windowsterminal" => "WindowsTerminal.exe",
        _ => null,
    };
}
