using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using Jarvis.Core.Gaming;
using Jarvis.Core.Wake;
using Jarvis.Platform;
using Jarvis.Ui;

namespace Jarvis.Voice;

/// The screen glow while Jarvis listens: a soft white line around the edges of the monitor the
/// conversation is on, drawn as two halves from the top centre. Click-through (WS_EX_TRANSPARENT)
/// and never activated. Never shown while the presentation gate is closed.
public sealed class ScreenGlow : NoActivateWindow
{
    private readonly PresentationGate _gate;
    private readonly Canvas _canvas = new();

    public ScreenGlow(PresentationGate gate)
    {
        _gate = gate;
        Title = "Jarvis glow";
        Background = Brushes.Transparent;
        IsHitTestVisible = false;
        Content = _canvas;
        SourceInitialized += (_, _) =>
        {
            var hwnd = new WindowInteropHelper(this).Handle;
            var ex = Native.GetWindowLongPtr(hwnd, Native.GWL_EXSTYLE).ToInt64();
            Native.SetWindowLongPtr(hwnd, Native.GWL_EXSTYLE, new IntPtr(ex | Native.WS_EX_TRANSPARENT | Native.WS_EX_LAYERED));
        };
    }

    public void ShowOn(Monitors.Info? monitor)
    {
        if (!_gate.CanPresent || (monitor ?? Monitors.Primary()) is not { } m) { HideGlow(); return; }
        var scale = Monitors.Scale(m.Handle);
        Width = m.Bounds.Width / scale;
        Height = m.Bounds.Height / scale;
        _canvas.Children.Clear();
        var dip = new RectI(0, 0, (int)Width, (int)Height);
        foreach (var right in new[] { false, true })
        {
            var pts = EdgeGlowPath.Half(dip, 12, right);
            var line = new Polyline
            {
                Points = new PointCollection(pts.Select(p => new Point(p.X, p.Y))),
                Stroke = Th.B("JcAccent"),
                StrokeThickness = 3,
                Opacity = 0.55,
                Effect = new System.Windows.Media.Effects.BlurEffect { Radius = 8 },
            };
            _canvas.Children.Add(line);
        }
        if (!IsVisible) Show();
        Monitors.Place(new WindowInteropHelper(this).Handle, m.Bounds);
    }

    public void HideGlow()
    {
        if (IsVisible) Hide();
    }
}
