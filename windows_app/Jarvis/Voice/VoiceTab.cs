using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using Jarvis.Core.Island;
using Jarvis.Core.Ui;
using Jarvis.Core.Voice;
using Jarvis.Island;
using Jarvis.Orb;
using Jarvis.Ui;

namespace Jarvis.Voice;

/// Talking to Jarvis in the island: the Mac's voice stage (MacVoicePanel's island layout). A dark
/// rounded stage the island's width with a hairline rim; one quiet row of glyphs (Voice / Live,
/// the session chip; while talking End, and the gear); and the orb as the control — click it to
/// talk or to stop. Centred with its words under it, then, once there's a conversation, gliding
/// left while the words fill the stage. The orb redraws at the display's rate only while the
/// stage is on screen; the 50 ms karaoke tick runs only while a reply is playing.
public sealed class VoiceTab : Border
{
    private const double StageW = IslandLayout.Width - 2 * IslandLayout.PadX;
    private const double StageH = IslandLayout.VoicePanelHeight;
    private const double OrbBig = 72, OrbSmall = 54, TextLeft = 100;

    private readonly VoiceController _voice;
    private readonly Canvas _body = new() { ClipToBounds = false };
    private readonly Grid _orbHost = new() { Width = OrbBig, Height = OrbBig, Background = Brushes.Transparent };
    private readonly ScaleTransform _orbScale = new(1, 1);
    private readonly StackPanel _invite;
    private readonly TextBlock _headline;
    private readonly TextBlock _subline;
    private readonly Border _conversation = new() { ClipToBounds = true };
    private readonly ScrollViewer _convScroll;
    private readonly StackPanel _convText = new();
    private readonly KaraokeText _reply = new();
    private readonly TextBlock _lead;
    private readonly StackPanel _status;
    private readonly TextBlock _statusText;
    private readonly System.Windows.Shapes.Ellipse _statusDot = new() { Width = 5, Height = 5 };
    private readonly StackPanel _rowRight = new() { Orientation = Orientation.Horizontal };
    private readonly Spring _layout = new(0.6, 0.86);
    private readonly DispatcherTimer _tick = new(DispatcherPriority.Render) { Interval = TimeSpan.FromMilliseconds(50) };
    private bool _sticky;
    private bool _animating;
    private TimeSpan _last;
    private bool _wasActive;

    /// The stage's orb: where the island's orb lands when it opens on Voice.
    public JarvisOrb StageOrb { get; } = new(OrbBig, stage: true);

    /// The Live mode glyph opens the Live panel.
    public event Action? LiveRequested;
    /// The gear: Jarvis settings (Talk).
    public event Action? SettingsRequested;

    public VoiceTab(VoiceController voice)
    {
        _voice = voice;
        // ── the stage ──
        var stage = new Grid { Height = StageH };
        stage.Children.Add(new Border
        {
            CornerRadius = new CornerRadius(22),
            Background = K.A("JcSurface"),
            BorderBrush = K.W(0.07),
            BorderThickness = new Thickness(0.5),
            IsHitTestVisible = false,
        });

        // ── the row of glyphs ──
        var modes = K.H(4, ModeIcon(Sym.Waveform, true, "Voice", null), ModeIcon(Sym.RadioWaves, false, "Live — capture the room", () => LiveRequested?.Invoke()));
        var chip = K.H(4, new IconView(Sym.BubbleLeft, 12, K.A("JcAccent")), K.T("Voice", 11, FontWeights.Medium, K.A("JcStageText", 0.75)),
            new IconView(Sym.ChevronDown, 8, K.A("JcStageText", 0.5), 1.1));
        var chipTap = new Tap(chip, PressLook.Dim, "Voice settings") { Padding = new Thickness(8, 4, 8, 4), Margin = new Thickness(4, 0, 0, 0) };
        chipTap.Click += () => SettingsRequested?.Invoke();
        var left = K.H(4, modes, chipTap);
        var gear = Controls.IconButton(Sym.Gear, 17, K.A("JcAccent"), () => SettingsRequested?.Invoke(), 30, 30, "Jarvis Settings", 0.95);
        var right = K.H(4, _rowRight, gear);
        var row = K.Spread(left, right);
        row.Margin = new Thickness(10, 8, 10, 0);
        row.VerticalAlignment = VerticalAlignment.Top;
        stage.Children.Add(row);

        // ── the body: orb, invitation, conversation ──
        _headline = K.T("What's on your mind?", 17, FontWeights.Medium, K.A("JcStageText"));
        _headline.HorizontalAlignment = HorizontalAlignment.Center;
        _subline = K.T("Click the orb, or say “Hey Jarvis”", 11, null, K.A("JcMuted"));
        _subline.HorizontalAlignment = HorizontalAlignment.Center;
        _invite = K.V(3, _headline, _subline);
        _invite.Width = StageW - 40;
        _lead = K.T("", 12, null, K.A("JcMuted"), wrap: true);
        _lead.TextAlignment = TextAlignment.Center;
        _lead.Margin = new Thickness(0, 0, 0, 4);
        _convText.Children.Add(_lead);
        _convText.Children.Add(_reply);
        _convText.Margin = new Thickness(0, 16, 0, 16);
        _convScroll = new ScrollViewer { Content = _convText, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden, Focusable = false };
        _conversation.Child = _convScroll;
        _conversation.OpacityMask = new LinearGradientBrush
        {
            StartPoint = new Point(0, 0), EndPoint = new Point(0, 1),
            GradientStops = { new GradientStop(Colors.Transparent, 0), new GradientStop(Colors.Black, 0.08), new GradientStop(Colors.Black, 0.92), new GradientStop(Colors.Transparent, 1) },
        };
        _statusText = K.T("", 11, FontWeights.Medium, K.A("JcMuted"));
        _status = K.H(6, _statusDot, _statusText);

        _orbHost.Children.Add(StageOrb);
        _orbHost.RenderTransformOrigin = new Point(0.5, 0.5);
        _orbHost.RenderTransform = _orbScale;
        StageOrb.SetHalo(true, false);
        var orbTap = new Tap(_orbHost, PressLook.Shrink, "Talk to Jarvis");
        orbTap.Click += Primary;
        _body.Children.Add(_invite);
        _body.Children.Add(_conversation);
        _body.Children.Add(_status);
        _body.Children.Add(orbTap);
        _body.Margin = new Thickness(0, 8 + 26, 0, 10);
        stage.Children.Add(_body);
        _body.SizeChanged += (_, _) => Lay();

        Child = stage;
        _tick.Tick += (_, _) => _voice.KaraokeTick();
        _voice.Changed += () => Dispatcher.BeginInvoke(Render);
        IsVisibleChanged += (_, _) => Render();
    }

    private Tap ModeIcon(Sym icon, bool on, string tip, Action? click)
    {
        var host = new Grid { Width = 32, Height = 26 };
        host.Children.Add(new Border { CornerRadius = new CornerRadius(13), Background = on ? K.W(0.10) : Brushes.Transparent });
        host.Children.Add(new IconView(icon, 14, on ? K.A("JcStageText") : K.A("JcMuted"), 1.05));
        var t = new Tap(host, PressLook.Dim, tip);
        if (click != null) t.Click += click;
        return t;
    }

    private void Primary()
    {
        if (_voice.State.IsActive()) _ = _voice.StopAsync();
        else _ = _voice.StartConversationAsync("orb");
    }

    /// `--diag voice-preview`: a made-up turn (his words, a reply half spoken) to check the layout.
    private (VoiceState State, string User, string Reply, int Spoken)? _preview;

    public void Preview(bool on)
    {
        _preview = on ? (VoiceState.Speaking, "What's on my calendar this afternoon?",
            "You have a design review at two, then a call with Sam at four. The rest of the afternoon is free.", 9) : null;
        Render();
    }

    private VoiceState State => _preview?.State ?? _voice.State;
    private string UserLine => _preview?.User ?? _voice.UserLine;
    private string ReplyText => _preview?.Reply ?? _voice.Reply.Text;
    private int Spoken => _preview?.Spoken ?? _voice.Reply.SpokenWords;

    private bool HasContent => !string.IsNullOrEmpty(_voice.Error) || UserLine.Length > 0 || ReplyText.Length > 0;

    private void Render()
    {
        var s = State;
        var active = s.IsActive();
        if (active != _wasActive) _sticky = active ? false : HasContent;
        _wasActive = active;
        if (HasContent) _sticky = true;
        var conversation = HasContent || _sticky;

        _headline.Text = s switch
        {
            VoiceState.Idle or VoiceState.Error => "What's on your mind?",
            VoiceState.Listening => "Go ahead, I'm here.",
            VoiceState.Connecting => "One moment…",
            _ => "Thinking it through…",
        };
        _subline.Text = s == VoiceState.Idle ? "Click the orb, or say “Hey Jarvis”" : StatusText(s);
        _statusText.Text = StatusText(s);
        _statusDot.Fill = K.A(s switch
        {
            VoiceState.Listening => "JcAccent",
            VoiceState.Thinking or VoiceState.Connecting => "JcAmber",
            VoiceState.Speaking => "JcGreen",
            VoiceState.Error => "JcDanger",
            _ => "JcMuted",
        });
        _status.Opacity = s == VoiceState.Idle ? 0 : 1;

        if (!string.IsNullOrEmpty(_voice.Error))
        {
            _lead.Text = "";
            _reply.Show(_voice.Error!, int.MaxValue);
        }
        else
        {
            _lead.Text = UserLine;
            _lead.Visibility = UserLine.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
            _reply.Show(ReplyText, Spoken);
        }

        _rowRight.Children.Clear();
        if (active)
        {
            if (s == VoiceState.Speaking)
                _rowRight.Children.Add(Controls.IconButton(Sym.Pause, 13, K.A("JcMuted"), _voice.Interrupt, 28, 26, "Interrupt"));
            _rowRight.Children.Add(Controls.IconButton(Sym.Stop, 14, K.A("JcMuted"), () => _ = _voice.StopAsync(), 28, 26, "End"));
        }

        StageOrb.Level = s == VoiceState.Listening ? _voice.InputLevel : s == VoiceState.Speaking ? 0.12 : 0;
        StageOrb.SetHalo(true, active);
        if (IsVisible && s == VoiceState.Speaking) _tick.Start(); else _tick.Stop();

        var target = conversation ? 1 : 0;
        if (Math.Abs(_layout.Target - target) > 0.001)
        {
            _layout.Target = target;
            if (!IsVisible || !SystemParameters.ClientAreaAnimation) _layout.Snap(target);
            StartLayoutAnimation();
        }
        Lay();
    }

    private static string StatusText(VoiceState s) => s switch
    {
        VoiceState.Connecting => "Connecting",
        VoiceState.Listening => "Listening",
        VoiceState.Thinking => "Thinking",
        VoiceState.Speaking => "Speaking",
        VoiceState.Error => "Let's try again",
        _ => "",
    };

    private void StartLayoutAnimation()
    {
        if (_animating) return;
        _animating = true;
        _last = TimeSpan.Zero;
        CompositionTarget.Rendering += OnFrame;
    }

    private void OnFrame(object? sender, EventArgs e)
    {
        var now = ((RenderingEventArgs)e).RenderingTime;
        if (now == _last) return;
        var dt = _last == TimeSpan.Zero ? 1.0 / 60 : Math.Min((now - _last).TotalSeconds, 0.05);
        _last = now;
        _layout.Step(dt);
        if (_layout.IsSettled(0.002))
        {
            _layout.Snap(_layout.Target);
            _animating = false;
            CompositionTarget.Rendering -= OnFrame;
        }
        Lay();
    }

    /// Positions everything for the layout spring's value (0 invitation, 1 conversation).
    private void Lay()
    {
        var w = StageW;
        var h = Math.Max(1, _body.ActualHeight > 0 ? _body.ActualHeight : StageH - 34 - 10);
        var p = _layout.Value;
        var side = OrbBig + (OrbSmall - OrbBig) * p;
        var cx = w / 2 + (52 - w / 2) * p;
        var cy = (OrbBig / 2 + 4) + ((h / 2 - 8) - (OrbBig / 2 + 4)) * p;
        _orbScale.ScaleX = _orbScale.ScaleY = side / OrbBig;
        Place(_orbHost.Parent as FrameworkElement ?? _orbHost, cx - OrbBig / 2, cy - OrbBig / 2);

        var inviteH = _invite.DesiredSize.Height > 0 ? _invite.DesiredSize.Height : 40;
        Place(_invite, 20, cy + side / 2 + 30 - inviteH / 2);
        _invite.Opacity = Math.Clamp(1 - p * 1.6, 0, 1);

        var tw = Math.Max(0, w - TextLeft - 18);
        _conversation.Width = tw;
        _conversation.Height = Math.Max(0, h - 6);
        Place(_conversation, TextLeft, 3);
        _conversation.Opacity = Math.Clamp((p - 0.25) / 0.75, 0, 1);
        _reply.Width = tw;
        _lead.Width = tw;

        _status.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        Place(_status, cx - _status.DesiredSize.Width / 2, cy + side / 2 + 13 - _status.DesiredSize.Height / 2);
        _status.Visibility = p > 0.5 ? Visibility.Visible : Visibility.Hidden;
    }

    private static void Place(UIElement e, double x, double y)
    {
        Canvas.SetLeft(e, x);
        Canvas.SetTop(e, y);
    }
}

/// The reply with karaoke: spoken words full white, the rest muted (VoiceKaraokeReply: 15 medium,
/// centred, 4 pt between lines).
public sealed class KaraokeText : TextBlock
{
    public KaraokeText()
    {
        TextWrapping = TextWrapping.Wrap;
        TextAlignment = TextAlignment.Center;
        FontFamily = K.Font;
        FontSize = 15;
        FontWeight = FontWeights.Medium;
        LineHeight = 20;
    }

    public void Show(string text, int spokenWords)
    {
        Inlines.Clear();
        var words = text.Split(' ', StringSplitOptions.None);
        var spoken = string.Join(' ', words.Take(spokenWords));
        var rest = string.Join(' ', words.Skip(spokenWords));
        Inlines.Add(new System.Windows.Documents.Run(spoken) { Foreground = K.A("JcStageText") });
        if (rest.Length > 0) Inlines.Add(new System.Windows.Documents.Run((spoken.Length > 0 ? " " : "") + rest) { Foreground = K.A("JcMuted") });
    }
}
