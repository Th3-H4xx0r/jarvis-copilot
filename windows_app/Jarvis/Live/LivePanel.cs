using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using Jarvis.Core.Live;
using Jarvis.Core.Voice;
using Jarvis.Ui;
using Jarvis.Voice;
using Jarvis.Voice.Audio;

namespace Jarvis.Live;

/// Live Jarvis on the PC: streams the mic to `/api/live/ws` (the server transcribes and labels
/// speakers), shows the transcript and insights, and resumes after a drop. Capture runs only
/// between his Start and Stop; Live is never always-on.
public sealed class LiveController
{
    private readonly Func<string?> _origin;
    private readonly Func<string?> _deviceId;
    private readonly Mic16k _mic = new();
    private readonly Stopwatch _clock = new();
    private LiveSession _session = new();
    private VoiceSocket? _socket;
    private bool _running;

    public LiveController(Func<string?> origin, Func<string?> deviceId)
    {
        _origin = origin;
        _deviceId = deviceId;
        _mic.Samples += OnSamples;
    }

    public bool Running => _running;
    public IReadOnlyList<LiveSegment> Segments => _session.Segments;
    public string Partial { get; private set; } = "";
    public List<string> Insights { get; } = new();
    public string Status { get; private set; } = "";
    public event Action<LiveServerFrame>? Frame;
    public event Action? Changed;

    public async Task StartAsync()
    {
        if (_running) return;
        _running = true;
        _session = new LiveSession();
        Insights.Clear();
        _clock.Restart();
        _mic.Start();
        await ConnectAsync();
    }

    public async Task StopAsync()
    {
        _running = false;
        _mic.Stop();
        if (_socket is { } s)
        {
            await s.SendTextAsync(LiveClientMessage.Bye().Encoded());
            await s.CloseAsync();
        }
        _socket = null;
        Status = "Stopped.";
        Changed?.Invoke();
    }

    private async Task ConnectAsync()
    {
        while (_running)
        {
            var url = LiveUrl(_origin());
            if (url == null || _deviceId() is not { } device) { Status = "Jarvis isn't connected to the server yet."; Changed?.Invoke(); return; }
            var s = new VoiceSocket();
            s.Text += json => Apply(LiveServerFrame.Decode(json));
            s.Closed += why => { if (why != null && _running) _ = ReconnectAsync(); };
            try
            {
                await s.ConnectAsync(url, CancellationToken.None);
                await s.SendTextAsync(_session.Hello(device).Encoded());
                _socket = s;
                Status = "Listening.";
                Changed?.Invoke();
                return;
            }
            catch (Exception e) when (e is System.Net.WebSockets.WebSocketException or OperationCanceledException or System.IO.IOException)
            {
                Status = "Reconnecting…";
                Changed?.Invoke();
                await Task.Delay(_session.NextDelay());
            }
        }
    }

    private async Task ReconnectAsync()
    {
        _socket = null;
        Status = "Reconnecting…";
        Changed?.Invoke();
        await Task.Delay(_session.NextDelay());
        await ConnectAsync();
    }

    public static Uri? LiveUrl(string? origin) =>
        VoiceSessionApi.SocketUrl(origin) is { } voice ? new Uri(voice, "/api/live/ws") : null;

    private void OnSamples(short[] pcm)
    {
        if (_socket is not { } s || pcm.Length == 0) return;
        var bytes = new byte[pcm.Length * 2];
        Buffer.BlockCopy(pcm, 0, bytes, 0, bytes.Length);
        _ = s.SendBinaryAsync(_session.NextAudioFrame(_clock.ElapsedMilliseconds, bytes));
    }

    private void Apply(LiveServerFrame f)
    {
        _session.Apply(f);
        switch (f)
        {
            case LiveServerFrame.Partial p: Partial = p.Text; break;
            case LiveServerFrame.Seg: Partial = ""; break;
            case LiveServerFrame.Insight i when i.Text.Length > 0: Insights.Add(i.Text); break;
            case LiveServerFrame.Error e: Status = e.Message; break;
            case LiveServerFrame.State st when st.Message != null: Status = st.Message; break;
        }
        Frame?.Invoke(f);
        Changed?.Invoke();
    }
}

/// The Live panel: transcript with speakers, insights, Start/Stop.
public sealed class LivePanel : Window
{
    private readonly LiveController _live;
    private readonly StackPanel _rows = new();
    private readonly TextBlock _status = Th.Text("", 12, "JcTextDim");
    private readonly Button _toggle;

    public LivePanel(LiveController live)
    {
        _live = live;
        Title = "Live Jarvis";
        Width = 520;
        Height = 640;
        Background = Th.B("JcBackground");
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        _toggle = Th.Button("Start", () => _ = _live.Running ? _live.StopAsync() : _live.StartAsync(), primary: true);
        var head = new DockPanel { Margin = new Thickness(0, 0, 0, 10) };
        DockPanel.SetDock(_toggle, Dock.Right);
        head.Children.Add(_toggle);
        head.Children.Add(Th.Column(2, Th.Text("Live Jarvis", 18, bold: true), _status));
        var scroll = new ScrollViewer { Content = _rows, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var dock = new DockPanel { Margin = new Thickness(18) };
        DockPanel.SetDock(head, Dock.Top);
        dock.Children.Add(head);
        dock.Children.Add(scroll);
        Content = dock;
        _live.Changed += () => Dispatcher.BeginInvoke(() => { Render(); scroll.ScrollToEnd(); });
        Render();
    }

    private void Render()
    {
        _toggle.Content = _live.Running ? "Stop" : "Start";
        _status.Text = _live.Status.Length > 0 ? _live.Status : "Listens to the room and keeps a transcript with who said what.";
        _rows.Children.Clear();
        foreach (var s in _live.Segments)
            _rows.Children.Add(Th.Column(1, Th.Text(s.Who, 11, "JcTextFaint", bold: true), Th.Text(s.Text, 13, wrap: true)));
        if (_live.Partial.Length > 0) _rows.Children.Add(Th.Text(_live.Partial, 13, "JcTextDim", wrap: true));
        foreach (var i in _live.Insights.TakeLast(3))
        {
            var card = Th.Card(Th.Text(i, 12, "JcTextDim", wrap: true), pad: 10);
            card.Margin = new Thickness(0, 8, 0, 0);
            _rows.Children.Add(card);
        }
    }
}
