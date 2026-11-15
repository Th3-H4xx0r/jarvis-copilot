using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using Jarvis.Core.Gaming;
using Jarvis.Platform;
using Jarvis.Ui;

namespace Jarvis.Screen;

/// "Sharing your screen · Stop": a small pill at the top centre while the screen is captured, so
/// he always knows. Stop ends every share. Never activated.
public sealed class ShareBanner : NoActivateWindow
{
    private readonly System.Windows.Controls.TextBlock _text = Th.Text("Sharing your screen", 12);

    public ShareBanner(Action stop)
    {
        Background = Brushes.Transparent;
        SizeToContent = SizeToContent.WidthAndHeight;
        Content = new System.Windows.Controls.Border
        {
            Background = Th.B("JcBackground"),
            CornerRadius = new CornerRadius(14),
            Padding = new Thickness(12, 5, 6, 5),
            BorderBrush = Th.B("JcGreen"),
            BorderThickness = new Thickness(1),
            Child = Th.Row(10, Th.Dot("JcGreen"), _text, Th.Button("Stop", stop, size: 12)),
        };
    }

    public void Update(bool capturing, int viewers)
    {
        if (!capturing) { if (IsVisible) Hide(); return; }
        _text.Text = viewers > 1 ? $"Sharing your screen with {viewers} viewers" : "Sharing your screen";
        if (!IsVisible) Show();
        UpdateLayout();
        var hwnd = new WindowInteropHelper(this).Handle;
        if (Monitors.Primary() is not { } m || hwnd == IntPtr.Zero) return;
        var scale = Monitors.Scale(m.Handle);
        int w = (int)(ActualWidth * scale), h = (int)(ActualHeight * scale);
        var left = m.Bounds.Left + (m.Bounds.Width - w) / 2;
        var top = m.Bounds.Top + (int)(40 * scale);
        Monitors.Place(hwnd, new RectI(left, top, left + w, top + h));
    }
}
