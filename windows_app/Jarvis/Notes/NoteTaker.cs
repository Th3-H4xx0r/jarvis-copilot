using System.Windows;
using System.Windows.Controls;
using Jarvis.Core.Http;
using Jarvis.Core.Notes;
using Jarvis.Ui;
using Jarvis.Voice.Audio;

namespace Jarvis.Notes;

/// Records a call: the mic is "You", what the PC plays (WASAPI loopback) is "Them". Audio lives
/// only in memory until its chunk is transcribed; the note itself is text. Starts and stops only
/// on his command (the RecordCall shortcut or the tray), never on its own.
public sealed class NoteTaker
{
    private readonly ApiClient _api;
    private readonly Func<string?> _origin;
    private readonly NoteStore _store = new();
    private readonly Mic16k _mic = new();
    private readonly Mic16k _system = new(loopback: true);
    private NoteSession? _session;

    public NoteTaker(ApiClient api, Func<string?> origin)
    {
        _api = api;
        _origin = origin;
        _mic.Samples += s => { _session?.Mic(s); MicLevel = Peak(s); };
        _system.Samples += s => { _session?.System(s); SystemLevel = Peak(s); };
    }

    public bool Recording => _session != null;
    public float MicLevel { get; private set; }
    public float SystemLevel { get; private set; }
    public IReadOnlyList<Note> Notes => _store.All();
    public Note? Current => _session?.Note;
    public event Action? Changed;

    private static float Peak(short[] s)
    {
        var p = 0;
        foreach (var v in s) p = Math.Max(p, Math.Abs((int)v));
        return p / 32768f;
    }

    public Task StartAsync()
    {
        if (_session != null) return Task.CompletedTask;
        _session = new NoteSession(_api, _origin);
        _session.Changed += () => Changed?.Invoke();
        _mic.Start();
        _system.Start();
        Changed?.Invoke();
        return Task.CompletedTask;
    }

    public async Task StopAsync()
    {
        if (_session is not { } s) return;
        _mic.Stop();
        _system.Stop();
        _session = null;
        Changed?.Invoke();
        await s.StopAsync();
        _store.Save(s.Note);
        Changed?.Invoke();
        await s.PollSummaryAsync();
        _store.Save(s.Note);
        Changed?.Invoke();
    }

    public Task ToggleAsync() => Recording ? StopAsync() : StartAsync();
}

/// The notes list: each call's title, summary, key points, to-dos and You/Them lines.
public sealed class NotesWindow : Window
{
    private readonly NoteTaker _notes;
    private readonly StackPanel _list = new();
    private readonly Button _record;

    public NotesWindow(NoteTaker notes)
    {
        _notes = notes;
        Title = "Call notes";
        Width = 560;
        Height = 680;
        Background = Th.B("JcBackground");
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        _record = Th.Button("Record a call", () => _ = _notes.ToggleAsync(), primary: true);
        var head = new DockPanel { Margin = new Thickness(0, 0, 0, 12) };
        DockPanel.SetDock(_record, Dock.Right);
        head.Children.Add(_record);
        head.Children.Add(Th.Text("Call notes", 18, bold: true));
        var dock = new DockPanel { Margin = new Thickness(18) };
        DockPanel.SetDock(head, Dock.Top);
        dock.Children.Add(head);
        dock.Children.Add(new ScrollViewer { Content = _list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        Content = dock;
        _notes.Changed += () => Dispatcher.BeginInvoke(Render);
        Render();
    }

    private void Render()
    {
        _record.Content = _notes.Recording ? "Stop recording" : "Record a call";
        _list.Children.Clear();
        if (_notes.Current is { } live)
        {
            _list.Children.Add(Th.Row(8, new JcLoader { Size = 14, Foreground = Th.B("JcGreen") }, Th.Text($"Recording · {live.Title}", 13)));
        }
        foreach (var n in _notes.Notes)
        {
            var col = new StackPanel();
            col.Children.Add(Th.Text(n.Title, 14, bold: true));
            var status = n.SummaryStatus switch
            {
                SummaryStatus.Pending => "Summarising…",
                SummaryStatus.Failed => $"No summary: {n.SummaryError}",
                _ => n.Summary ?? "",
            };
            if (status.Length > 0) col.Children.Add(Th.Text(status, 12, "JcTextDim", wrap: true));
            foreach (var k in n.KeyPoints) col.Children.Add(Th.Text("• " + k, 12, wrap: true));
            foreach (var t in n.Todos) col.Children.Add(Th.Text((t.Done ? "☑ " : "☐ ") + t.Text + (t.Owner != null ? $" ({t.Owner})" : ""), 12, wrap: true));
            foreach (var l in n.Lines.Take(40))
                col.Children.Add(Th.Text($"{n.NameOf(l.Speaker)}: {l.Text}", 12, l.Speaker == Note.MeId ? "JcText" : "JcTextDim", wrap: true));
            var card = Th.Card(col, pad: 12);
            card.Margin = new Thickness(0, 0, 0, 10);
            _list.Children.Add(card);
        }
    }
}
