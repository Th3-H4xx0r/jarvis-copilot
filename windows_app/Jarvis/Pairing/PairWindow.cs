using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Jarvis.Core.Pairing;
using Jarvis.Ui;

namespace Jarvis.Pairing;

/// "Pair with your iPhone": the QR jc-client made (`pair_qr_start`), drawn black on a white card,
/// with a countdown (the code renews itself), live state from jc-client's `pair_state`, and
/// "Type a code instead" (server prefilled from `pair_status`, never a LAN guess). Replaces
/// jc-client's old Python pairing window. Closing it stops the code renewing.
public sealed class PairWindow : Window
{
    private const double QrSide = 232;

    private readonly PairFlow _flow;
    private readonly Image _qr = new() { Width = QrSide, Height = QrSide, Stretch = Stretch.Uniform };
    private readonly ContentControl _overlay = new() { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private readonly Border _card;
    private readonly TextBlock _status = Th.Text("", 13, "JcTextDim", wrap: true);
    private readonly Button _typeInstead;
    private readonly Button _retry;
    private readonly Button _done;
    private readonly StackPanel _manual;
    private readonly TextBox _server = Th.Input("https://…");
    private readonly TextBox _code = Th.Input("ABC-123");
    private readonly TextBox _cfId = Th.Input("Client ID");
    private readonly PasswordBox _cfSecret = new();
    private readonly StackPanel _cf;
    private readonly Button _cfToggle;
    private readonly Button _pair;
    private readonly TextBlock _manualError = Th.Text("", 12, "JcAmber", wrap: true);
    private string? _shownPayload;
    private bool _serverFilled;

    public PairWindow(PairFlow flow)
    {
        _flow = flow;
        Title = "Pair with your iPhone";
        Width = 420;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = Th.B("JcBackground");
        Foreground = Th.B("JcText");
        FontFamily = (FontFamily)FindResource("JcFont");
        UseLayoutRounding = true;

        // Crisp module edges: no anti-aliased seams between the rows of the code.
        RenderOptions.SetEdgeMode(_qr, EdgeMode.Aliased);
        var qrArea = new Grid { Width = QrSide, Height = QrSide };
        qrArea.Children.Add(_qr);
        qrArea.Children.Add(_overlay);
        // The white card is the code's quiet zone.
        _card = new Border
        {
            Background = Th.B("JcQrLight"),
            CornerRadius = new CornerRadius(16),
            Padding = new Thickness(20),
            HorizontalAlignment = HorizontalAlignment.Center,
            Child = qrArea,
        };

        _typeInstead = Th.Button("Type a code instead", ShowManual);
        _retry = Th.Button("Show a new code", () => _ = _flow.NewCodeAsync(), primary: true);
        _done = Th.Button("Done", Close, primary: true);

        _cfSecret.Background = Th.B("JcButton");
        _cfSecret.Foreground = Th.B("JcText");
        _cfSecret.CaretBrush = Th.B("JcText");
        _cfSecret.BorderThickness = new Thickness(0);
        _cfSecret.Padding = new Thickness(8, 6, 8, 6);
        _cfSecret.FontSize = 13;
        _cf = Th.Column(6, Field("Cloudflare Access client ID", _cfId), Field("Client secret", _cfSecret));
        _cf.Visibility = Visibility.Collapsed;
        _cfToggle = Th.Button("Cloudflare Access token…", () =>
        {
            _cf.Visibility = Visibility.Visible;
            _cfToggle!.Visibility = Visibility.Collapsed;
        }, size: 12);
        _cfToggle.HorizontalAlignment = HorizontalAlignment.Left;
        _pair = Th.Button("Pair", () => _ = PairManualAsync(), primary: true);
        _pair.HorizontalAlignment = HorizontalAlignment.Left;
        _manual = Th.Column(10,
            Th.Text("On your iPhone: Jarvis → Devices → Add computer → Show a code.", 12, "JcTextDim", wrap: true),
            Field("Server", _server),
            Field("Code", _code),
            _cfToggle,
            _cf,
            _manualError,
            _pair);
        _manual.Visibility = Visibility.Collapsed;
        _manual.Margin = new Thickness(0, 18, 0, 0);
        _code.KeyDown += (_, e) => { if (e.Key == System.Windows.Input.Key.Enter) _ = PairManualAsync(); };

        var buttons = Th.Row(8, _typeInstead, _retry, _done);
        buttons.HorizontalAlignment = HorizontalAlignment.Center;
        _status.TextAlignment = TextAlignment.Center;
        _status.HorizontalAlignment = HorizontalAlignment.Center;
        var lead = Th.Text("Open Jarvis on your iPhone → Devices → Add computer, then scan this code.", 13, "JcTextDim", wrap: true);
        var root = Th.Column(14,
            Th.Text("Pair with your iPhone", 20, bold: true),
            lead,
            _card,
            _status,
            buttons,
            _manual);
        Content = new Border { Padding = new Thickness(24, 20, 24, 24), Child = root };

        _flow.Changed += () => Dispatcher.BeginInvoke(Render);
        Loaded += async (_, _) => await _flow.OpenAsync();
        Closed += (_, _) => _flow.Dispose();
        Render();
    }

    public PairFlow Flow => _flow;

    private static StackPanel Field(string label, Control box)
    {
        box.MinWidth = 300;
        return Th.Column(4, Th.Text(label, 12, "JcTextDim"), box);
    }

    private void ShowManual()
    {
        _manual.Visibility = Visibility.Visible;
        _typeInstead.Visibility = Visibility.Collapsed;
        FillServer();
        (_server.Text.Length == 0 ? _server : _code).Focus();
    }

    /// The server jc-client knows, once, and never over what he typed.
    private void FillServer()
    {
        if (_serverFilled || _flow.Server.Length == 0 || _server.Text.Length > 0) return;
        _server.Text = _flow.Server;
        _serverFilled = true;
    }

    private async Task PairManualAsync()
    {
        if (_flow.ManualBusy) return;
        await _flow.ManualAsync(_server.Text, _code.Text, _cfId.Text, _cfSecret.Password);
    }

    private void Render()
    {
        var stage = _flow.Stage;
        if (_flow.Payload is { } payload && payload != _shownPayload)
        {
            _shownPayload = payload;
            _qr.Source = QrImage(PairQr.Encode(payload));
        }
        var showQr = stage is PairStage.Waiting or PairStage.Pairing && _flow.Payload != null;
        _qr.Visibility = showQr ? Visibility.Visible : Visibility.Hidden;
        _qr.Opacity = stage == PairStage.Pairing ? 0.12 : 1;
        _overlay.Content = stage switch
        {
            PairStage.Loading or PairStage.Pairing => new JcLoader { Size = 28, Foreground = Th.B("JcQrDark") },
            PairStage.Paired => Glyph("\uE73E"),
            PairStage.Failed => Glyph("\uE783"),
            _ => null,
        };
        _status.Text = stage switch
        {
            PairStage.Loading => "Making a code…",
            PairStage.Waiting => _flow.Countdown.Length > 0 ? $"A new code in {_flow.Countdown}" : "",
            PairStage.Pairing => "Your iPhone is pairing this PC…",
            PairStage.Paired => _flow.DeviceName.Length > 0 ? $"Paired. This PC is \"{_flow.DeviceName}\" in Jarvis." : "Paired.",
            PairStage.Failed => _flow.Error ?? "Pairing didn't work.",
            _ => "",
        };
        _status.Foreground = Th.B(stage == PairStage.Failed ? "JcAmber" : "JcTextDim");
        _status.Visibility = _status.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        _retry.Visibility = stage == PairStage.Failed ? Visibility.Visible : Visibility.Collapsed;
        _done.Visibility = stage == PairStage.Paired ? Visibility.Visible : Visibility.Collapsed;
        if (stage == PairStage.Paired)
        {
            _manual.Visibility = Visibility.Collapsed;
            _typeInstead.Visibility = Visibility.Collapsed;
        }
        else if (_manual.Visibility != Visibility.Visible) _typeInstead.Visibility = Visibility.Visible;
        if (_manual.Visibility == Visibility.Visible) FillServer();
        _pair.IsEnabled = !_flow.ManualBusy;
        _pair.Content = _flow.ManualBusy ? "Pairing…" : "Pair";
        _manualError.Text = _flow.ManualError ?? "";
        _manualError.Visibility = _manualError.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    /// A big Segoe Fluent glyph (check, warning) in the card's place, drawn on the white card.
    private static TextBlock Glyph(string glyph) => new()
    {
        Text = glyph,
        FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"),
        FontSize = 64,
        Foreground = Th.B("JcQrDark"),
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
    };

    /// The modules as one drawing: a light square the symbol's size (so its bounds are exact),
    /// then the dark runs. The card's white padding is the quiet zone.
    private static ImageSource QrImage(QrMatrix qr)
    {
        var dark = new GeometryGroup { FillRule = FillRule.Nonzero };
        foreach (var (x, y, w) in qr.Runs()) dark.Children.Add(new RectangleGeometry(new Rect(x, y, w, 1)));
        var drawing = new DrawingGroup();
        drawing.Children.Add(new GeometryDrawing(Th.B("JcQrLight"), null, new RectangleGeometry(new Rect(0, 0, qr.Size, qr.Size))));
        drawing.Children.Add(new GeometryDrawing(Th.B("JcQrDark"), null, dark));
        var image = new DrawingImage(drawing);
        image.Freeze();
        return image;
    }
}
