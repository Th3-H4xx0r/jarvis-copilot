using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Jarvis.Core.Voice;
using Jarvis.Ui;

namespace Jarvis.Voice;

/// The island's Voice view: the orb, what he said, the reply with karaoke, and Talk/Stop (the
/// one white button) plus Interrupt while Jarvis speaks. The 50 ms karaoke tick runs only while
/// this view is visible and a reply is playing.
public sealed class VoiceTab : Border
{
    private readonly VoiceController _voice;
    private readonly OrbView _orb = new() { Width = 96, Height = 96, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly TextBlock _state = Th.Text("", 12, "JcTextDim");
    private readonly TextBlock _user = Th.Text("", 13, "JcTextDim", wrap: true);
    private readonly KaraokeText _reply = new();
    private readonly Button _main;
    private readonly Button _interrupt;
    private readonly DispatcherTimer _tick = new(DispatcherPriority.Render) { Interval = TimeSpan.FromMilliseconds(50) };

    /// The Live segment (Task 12) opens the Live panel.
    public event Action? LiveRequested;

    public VoiceTab(VoiceController voice)
    {
        _voice = voice;
        _main = Th.Button("Talk", Toggle, primary: true);
        _interrupt = Th.Button("Interrupt", _voice.Interrupt);
        var live = Th.Button("Live", () => LiveRequested?.Invoke());
        var buttons = Th.Row(8, _main, _interrupt, live);
        buttons.HorizontalAlignment = HorizontalAlignment.Center;
        _state.HorizontalAlignment = HorizontalAlignment.Center;
        var scroll = new ScrollViewer { Content = Th.Column(6, _user, _reply), MaxHeight = 90, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Child = Th.Column(8, _orb, _state, scroll, buttons);
        Margin = new Thickness(0, 8, 0, 0);

        _tick.Tick += (_, _) => _voice.KaraokeTick();
        _voice.Changed += () => Dispatcher.BeginInvoke(Render);
        IsVisibleChanged += (_, _) => Render();
    }

    private void Toggle()
    {
        if (_voice.State.IsActive()) _ = _voice.StopAsync();
        else _ = _voice.StartConversationAsync("orb");
    }

    private void Render()
    {
        var s = _voice.State;
        _orb.Mood = _voice.Mood;
        _orb.Level = _voice.InputLevel;
        _state.Text = _voice.Error ?? s switch
        {
            VoiceState.Connecting => "Connecting…",
            VoiceState.Listening => _voice.PushToTalk ? "Listening while you hold the key" : "Listening",
            VoiceState.Thinking => "Thinking",
            VoiceState.Speaking => "Speaking",
            VoiceState.Error => "Something went wrong",
            _ => "Tap Talk, say \"Hey Jarvis\", or hold your talk key",
        };
        _user.Text = _voice.UserLine;
        _reply.Show(_voice.Reply.Text, _voice.Reply.SpokenWords);
        _main.Content = s.IsActive() ? "Stop" : "Talk";
        _interrupt.Visibility = s is VoiceState.Speaking or VoiceState.Thinking ? Visibility.Visible : Visibility.Collapsed;
        if (IsVisible && s == VoiceState.Speaking) _tick.Start(); else _tick.Stop();
    }
}
