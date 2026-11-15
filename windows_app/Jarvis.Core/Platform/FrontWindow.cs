namespace Jarvis.Core.Platform;

/// The window in front: its app, exe, process, handle, title and (for a browser) its page URL.
public sealed record FrontWindow(string App, string Exe, int Pid, IntPtr Hwnd, string Title, string? Url);

public interface IFrontWindowProbe
{
    FrontWindow? Capture(IntPtr hwnd);
}
