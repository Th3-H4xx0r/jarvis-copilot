using Jarvis.Core.Gaming;
using Jarvis.Core.Ui;

namespace Jarvis.Core.Island;

/// Where the island hangs: top-centre of the chosen monitor, flush with its top edge.
public static class IslandPlacement
{
    public static RectI Frame(RectI monitorBounds, double widthPx, double heightPx)
    {
        var w = (int)Math.Round(widthPx);
        var h = (int)Math.Round(heightPx);
        var left = monitorBounds.Left + (monitorBounds.Width - w) / 2;
        return new RectI(left, monitorBounds.Top, left + w, monitorBounds.Top + h);
    }

    /// `island.display`: "primary", "followMouse" or "display:\\.\DISPLAYn". Unknown → primary.
    public static RectI ChooseMonitor(string displayPref, IReadOnlyList<(string Name, RectI Bounds, bool Primary)> monitors, PointD cursor)
    {
        if (monitors.Count == 0) return new RectI(0, 0, 1920, 1080);
        var fallback = monitors.FirstOrDefault(m => m.Primary) is { Name: not null } p ? p.Bounds : monitors[0].Bounds;
        if (displayPref == "followMouse")
        {
            foreach (var m in monitors)
                if (cursor.X >= m.Bounds.Left && cursor.X < m.Bounds.Right && cursor.Y >= m.Bounds.Top && cursor.Y < m.Bounds.Bottom)
                    return m.Bounds;
            return fallback;
        }
        if (displayPref.StartsWith("display:", StringComparison.Ordinal))
        {
            var name = displayPref["display:".Length..];
            foreach (var m in monitors)
                if (string.Equals(m.Name, name, StringComparison.OrdinalIgnoreCase)) return m.Bounds;
        }
        return fallback;
    }
}
