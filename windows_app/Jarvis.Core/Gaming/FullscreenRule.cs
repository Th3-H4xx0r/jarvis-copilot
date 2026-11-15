namespace Jarvis.Core.Gaming;

public readonly record struct RectI(int Left, int Top, int Right, int Bottom)
{
    public int Width => Right - Left;
    public int Height => Bottom - Top;
}

/// The foreground window counts as fullscreen when it covers its whole monitor and isn't the
/// desktop/shell (a maximised window stops at the taskbar, so it doesn't).
public static class FullscreenRule
{
    public static bool Covers(RectI window, RectI monitor, bool isShell) =>
        !isShell && window.Left <= monitor.Left && window.Top <= monitor.Top
        && window.Right >= monitor.Right && window.Bottom >= monitor.Bottom;
}

public interface IForegroundProbe
{
    bool ForegroundIsFullscreen();
}
