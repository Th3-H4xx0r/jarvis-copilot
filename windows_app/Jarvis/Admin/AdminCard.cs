using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Jarvis.Core.Admin;
using Jarvis.Core.Gaming;
using Jarvis.Core.Island;
using Jarvis.Platform;
using Jarvis.Ui;

namespace Jarvis.Admin;

/// The C6 admin ask, shown under the island: amber while his iPhone is asked for Face ID, then
/// the outcome in white; hides 6 s after it settles. Goes through the presentation gate, never
/// takes focus, never mentions Windows Hello.
public sealed class AdminCard : NoActivateWindow
{
    private static readonly TimeSpan HideAfter = TimeSpan.FromSeconds(6);
    private readonly PresentationGate _gate;
    private readonly Border _shape;
    private readonly TextBlock _title = Th.Text("", 13, bold: true, wrap: true);
    private readonly TextBlock _line = Th.Text("", 12, "JcTextDim", wrap: true);
    private readonly JcLoader _loader = new() { Size = 16, Foreground = Th.B("JcAmber") };
    private readonly DispatcherTimer _hide = new() { Interval = HideAfter };

    public AdminCard(AdminRunner runner, PresentationGate gate)
    {
        _gate = gate;
        Title = "Jarvis admin";
        Background = Brushes.Transparent;
        Width = 380;
        SizeToContent = SizeToContent.Height;
        _shape = new Border
        {
            Background = Th.B("JcBackground"),
            CornerRadius = new CornerRadius(14),
            Padding = new Thickness(14),
            BorderThickness = new Thickness(1),
            Child = Th.Row(10, _loader, Th.Column(4, _title, _line)),
        };
        Content = _shape;
        _hide.Tick += (_, _) => { _hide.Stop(); Hide(); };

        runner.Asking += why => Dispatcher.BeginInvoke(() => Present(asking: true, why, AdminRunner.AskingLine));
        runner.Done += r => Dispatcher.BeginInvoke(() => Present(asking: false, r.Kind == AdminStatus.Approved ? "Approved" : "Not run", r.Message));
    }

    private void Present(bool asking, string title, string line)
    {
        _gate.Present("admin", () =>
        {
            _title.Text = title;
            _line.Text = line;
            _loader.Visibility = asking ? Visibility.Visible : Visibility.Collapsed;
            _shape.BorderBrush = Th.B(asking ? "JcAmber" : "JcHairline");
            _hide.Stop();
            if (!asking) _hide.Start();
            if (!IsVisible) Show();
            Place();
        });
    }

    private void Place()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        if (Monitors.Primary() is not { } mon || hwnd == IntPtr.Zero) return;
        var scale = Monitors.Scale(mon.Handle);
        var frame = IslandPlacement.Frame(mon.Bounds, Width * scale, Math.Max(ActualHeight, 72) * scale);
        var top = (int)(IslandLayout.CompactHeight * scale) + (int)(12 * scale);
        Monitors.Place(hwnd, new RectI(frame.Left, mon.Bounds.Top + top, frame.Right, mon.Bounds.Top + top + frame.Height));
    }
}
