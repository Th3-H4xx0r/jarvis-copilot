using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Jarvis.Core.Flow;
using Jarvis.Core.Gaming;
using Jarvis.Platform;
using Jarvis.Ui;

namespace Jarvis.Flow;

/// The small pill above the taskbar centre while Flow listens: dancing bars from the mic level,
/// the loader while it transcribes, "Copied, press Ctrl+V" when the window in front is elevated.
/// No-activate; its 50 ms redraw runs only while it is shown.
public sealed class FlowPill : NoActivateWindow
{
    private const int Bars = 9;
    private readonly FlowController _flow;
    private readonly FlowCapture _capture;
    private readonly StackPanel _bars = new() { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
    private readonly JcLoader _loader = new() { Size = 16 };
    private readonly TextBlock _text = Th.Text("", 12, "JcTextDim");
    private readonly DispatcherTimer _tick = new(DispatcherPriority.Render) { Interval = TimeSpan.FromMilliseconds(50) };
    private readonly DispatcherTimer _hide = new() { Interval = TimeSpan.FromSeconds(2.5) };
    private readonly Random _rng = new();

    public FlowPill(FlowController flow, FlowCapture capture)
    {
        _flow = flow;
        _capture = capture;
        Title = "Jarvis Flow";
        Background = Brushes.Transparent;
        SizeToContent = SizeToContent.WidthAndHeight;
        for (var i = 0; i < Bars; i++) _bars.Children.Add(new Border { Width = 3, Height = 4, Margin = new Thickness(1.5, 0, 1.5, 0), CornerRadius = new CornerRadius(1.5), Background = Th.B("JcText") });
        Content = new Border
        {
            Background = Th.B("JcBackground"),
            CornerRadius = new CornerRadius(14),
            Padding = new Thickness(12, 6, 12, 6),
            Child = Th.Row(8, _bars, _loader, _text),
        };
        _tick.Tick += (_, _) => Animate();
        _hide.Tick += (_, _) => { _hide.Stop(); Hide(); };
        flow.Changed += () => Dispatcher.BeginInvoke(Render);
        flow.Pasted += _ => Dispatcher.BeginInvoke(Render);
    }

    private void Render()
    {
        switch (_flow.State)
        {
            case FlowController.Phase.Listening:
                _bars.Visibility = Visibility.Visible;
                _loader.Visibility = Visibility.Collapsed;
                _text.Text = _flow.Locked ? "Hands-free · tap to finish" : "";
                ShowPill();
                _tick.Start();
                break;
            case FlowController.Phase.Working:
                _bars.Visibility = Visibility.Collapsed;
                _loader.Visibility = Visibility.Visible;
                _text.Text = "Writing…";
                _tick.Stop();
                ShowPill();
                break;
            default:
                _tick.Stop();
                _bars.Visibility = Visibility.Collapsed;
                _loader.Visibility = Visibility.Collapsed;
                if (_flow.LastError is { } err) { _text.Text = err; ShowPill(); _hide.Start(); }
                else if (_flow.LastPaste == PasteResult.CopiedOnly) { _text.Text = "Copied, press Ctrl+V"; ShowPill(); _hide.Start(); }
                else Hide();
                break;
        }
    }

    private void Animate()
    {
        var level = Math.Clamp(_capture.Level * 5, 0, 1);
        foreach (Border b in _bars.Children) b.Height = 4 + 16 * level * (0.4 + 0.6 * _rng.NextDouble());
    }

    private void ShowPill()
    {
        if (!IsVisible) Show();
        UpdateLayout();
        var hwnd = new WindowInteropHelper(this).Handle;
        if (Monitors.Primary() is not { } m || hwnd == IntPtr.Zero) return;
        var scale = Monitors.Scale(m.Handle);
        int w = (int)(ActualWidth * scale), h = (int)(ActualHeight * scale);
        var left = m.Work.Left + (m.Work.Width - w) / 2;
        var top = m.Work.Bottom - h - (int)(16 * scale);
        Monitors.Place(hwnd, new RectI(left, top, left + w, top + h));
    }
}
