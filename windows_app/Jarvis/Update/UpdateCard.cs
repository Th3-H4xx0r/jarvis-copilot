using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using Jarvis.Core.Gaming;
using Jarvis.Core.Island;
using Jarvis.Core.Update;
using Jarvis.Platform;
using Jarvis.Ui;

namespace Jarvis.Update;

/// "Jarvis 1.0.1 is ready": what's new, Install now (the one white button) and Later. Install
/// downloads with a loader line, checks the SHA-256 and the zip, hands over to JarvisUpdater and
/// quits; a problem shows on the card. Under the island, through the gate, never activated.
public sealed class UpdateCard : NoActivateWindow
{
    private readonly AppUpdater _updater;
    private readonly UpdateCoordinator _coordinator;
    private readonly PresentationGate _gate;
    private readonly TextBlock _title = Th.Text("", 14, bold: true);
    private readonly TextBlock _notes = Th.Text("", 12, "JcTextDim", wrap: true);
    private readonly TextBlock _line = Th.Text("", 12, "JcTextDim", wrap: true);
    private readonly JcLoader _loader = new() { Size = 14, Visibility = Visibility.Collapsed };
    private readonly StackPanel _buttons;
    private UpdateOffer? _offer;

    public UpdateCard(AppUpdater updater, UpdateCoordinator coordinator, PresentationGate gate)
    {
        _updater = updater;
        _coordinator = coordinator;
        _gate = gate;
        Background = Brushes.Transparent;
        Width = 380;
        SizeToContent = SizeToContent.Height;
        _buttons = Th.Row(8, Th.Button("Install now", () => _ = InstallAsync(), primary: true), Th.Button("Later", () => { _coordinator.Later(); Hide(); }));
        Content = new Border
        {
            Background = Th.B("JcBackground"),
            CornerRadius = new CornerRadius(14),
            Padding = new Thickness(14),
            Child = Th.Column(6, _title, _notes, Th.Row(8, _loader, _line), _buttons),
        };
        coordinator.Show += o => Dispatcher.BeginInvoke(() => Offer(o));
    }

    private void Offer(UpdateOffer o)
    {
        _offer = o;
        _title.Text = $"Jarvis {o.Version} is ready";
        _notes.Text = o.Notes;
        _line.Text = "";
        _loader.Visibility = Visibility.Collapsed;
        _buttons.Visibility = Visibility.Visible;
        _gate.Present("update", () =>
        {
            Show();
            UpdateLayout();
            var hwnd = new WindowInteropHelper(this).Handle;
            if (Monitors.Primary() is not { } m || hwnd == IntPtr.Zero) return;
            var scale = Monitors.Scale(m.Handle);
            var frame = IslandPlacement.Frame(m.Bounds, Width * scale, ActualHeight * scale);
            var top = m.Bounds.Top + (int)((IslandLayout.CompactHeight + 12) * scale);
            Monitors.Place(hwnd, new RectI(frame.Left, top, frame.Right, top + frame.Height));
        });
    }

    private async Task InstallAsync()
    {
        if (_offer is not { } o) return;
        _buttons.Visibility = Visibility.Collapsed;
        _loader.Visibility = Visibility.Visible;
        _line.Text = "Downloading…";
        var progress = new Progress<double>(p => _line.Text = $"Downloading… {p:P0}");
        var problem = await _updater.InstallAsync(o, progress);
        if (problem == null)
        {
            _line.Text = "Restarting Jarvis…";
            Application.Current.Shutdown();
            return;
        }
        _loader.Visibility = Visibility.Collapsed;
        _line.Text = problem;
        _buttons.Visibility = Visibility.Visible;
    }

    /// Starts JarvisUpdater.exe with its arguments (no shell, so no Mark-of-the-Web prompt).
    public static void Launch(string exe, string[] args)
    {
        var psi = new ProcessStartInfo(exe) { UseShellExecute = false, CreateNoWindow = true };
        foreach (var a in args) psi.ArgumentList.Add(a);
        Process.Start(psi);
    }
}
