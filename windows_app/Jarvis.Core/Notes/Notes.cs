using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.Json.Nodes;
using Jarvis.Core.Flow;
using Jarvis.Core.Http;
using Jarvis.Core.Link;

namespace Jarvis.Core.Notes;

public sealed record NoteSpeaker(string Id, string Name, bool IsMe = false);
public sealed record NoteLine(string Speaker, double Start, double End, string Text);
public sealed record NoteTodo(string Text, string? Owner, string? Due, bool Done = false);

public enum NoteStatus { Recording, Transcribing, Ready, Failed }
public enum SummaryStatus { None, Pending, Done, Failed }

/// One recorded call (port of NoteModels.swift). Text only: audio never reaches disk.
public sealed class Note
{
    public const string MeId = "me", ThemId = "them", MeName = "You", ThemName = "Them";

    public string Id { get; set; } = Guid.NewGuid().ToString().ToUpperInvariant();
    public string Title { get; set; } = "Call";
    public bool TitleEdited { get; set; }
    public DateTimeOffset Start { get; set; }
    public DateTimeOffset? End { get; set; }
    public string? App { get; set; }
    public NoteStatus Status { get; set; } = NoteStatus.Recording;
    public List<NoteSpeaker> Speakers { get; set; } = new();
    public List<NoteLine> Lines { get; set; } = new();
    public string? Summary { get; set; }
    public List<string> KeyPoints { get; set; } = new();
    public List<NoteTodo> Todos { get; set; } = new();
    public SummaryStatus SummaryStatus { get; set; } = SummaryStatus.None;
    public string? SummaryError { get; set; }
    public bool Uploaded { get; set; }

    public string NameOf(string speakerId) =>
        Speakers.FirstOrDefault(s => s.Id == speakerId)?.Name ?? (speakerId == MeId ? MeName : ThemName);

    public JsonObject ServerJson() => new()
    {
        ["id"] = Id,
        ["title"] = Title,
        ["title_edited"] = TitleEdited,
        ["start"] = Start.ToUnixTimeMilliseconds() / 1000.0,
        ["end"] = End is { } e ? e.ToUnixTimeMilliseconds() / 1000.0 : null,
        ["app"] = App,
        ["speakers"] = new JsonArray(Speakers.Select(s => (JsonNode?)new JsonObject { ["id"] = s.Id, ["name"] = s.Name, ["is_me"] = s.IsMe }).ToArray()),
        ["lines"] = new JsonArray(Lines.Select(l => (JsonNode?)new JsonObject { ["speaker"] = l.Speaker, ["start"] = l.Start, ["end"] = l.End, ["text"] = l.Text }).ToArray()),
        ["summary"] = Summary,
        ["key_points"] = new JsonArray(KeyPoints.Select(k => (JsonNode?)JsonValue.Create(k)).ToArray()),
        ["todos"] = new JsonArray(Todos.Select(t => (JsonNode?)new JsonObject { ["text"] = t.Text, ["owner"] = t.Owner, ["due"] = t.Due, ["done"] = t.Done }).ToArray()),
    };

    /// The server's summary. Only a finished one changes anything, an edited title is kept, and a
    /// failure never erases a summary already here.
    public void Absorb(JsonObject json)
    {
        SummaryStatus = J.S(json["summary_status"]) switch
        {
            "pending" => SummaryStatus.Pending,
            "done" => SummaryStatus.Done,
            "failed" => SummaryStatus.Failed,
            "none" => SummaryStatus.None,
            _ => SummaryStatus,
        };
        SummaryError = J.StrOrNull(json["summary_error"]) is { Length: > 0 } err ? err : null;
        if (SummaryStatus != SummaryStatus.Done) return;
        if (!TitleEdited && J.S(json["title"]).Trim() is { Length: > 0 } t) Title = t;
        if (J.S(json["summary"]).Trim() is { Length: > 0 } s) Summary = s;
        if (json["key_points"] is JsonArray pts) KeyPoints = pts.Select(p => J.S(p)).Where(p => p.Length > 0).ToList();
        if (json["todos"] is JsonArray todos)
            Todos = todos.OfType<JsonObject>().Where(o => J.S(o["text"]).Length > 0)
                .Select(o => new NoteTodo(J.S(o["text"]), J.StrOrNull(o["owner"]) is { Length: > 0 } ow ? ow : null,
                    J.StrOrNull(o["due"]) is { Length: > 0 } du ? du : null, J.B(o["done"]))).ToList();
    }
}

/// Lines from both channels: echo of the speakers in the mic dropped, sorted, speakers named.
public static class NoteBuilder
{
    public static IReadOnlyList<string> Tokens(string s) => FlowText.Tokens(s.ToLowerInvariant());

    private static bool Overlaps(NoteLine a, NoteLine b, double margin) => a.Start < b.End + margin && b.Start < a.End + margin;

    /// A "You" line mostly made of words "Them" said at the same moment is the speakers leaking into the mic.
    public static IReadOnlyList<NoteLine> RemovingEcho(IReadOnlyList<NoteLine> mine, IReadOnlyList<NoteLine> others) =>
        mine.Where(line =>
        {
            var words = Tokens(line.Text);
            if (words.Count < 2)
                return !others.Any(o => Overlaps(o, line, 0.8) && Tokens(o.Text).Contains(words.FirstOrDefault() ?? ""));
            var near = others.Where(o => Overlaps(o, line, 1.5)).SelectMany(o => Tokens(o.Text)).ToHashSet();
            if (near.Count == 0) return true;
            return (double)words.Count(near.Contains) / words.Count < 0.6;
        }).ToList();

    public static (List<NoteSpeaker> Speakers, List<NoteLine> Lines) Finalize(IReadOnlyList<NoteLine> all)
    {
        var mine = all.Where(l => l.Speaker == Note.MeId).ToList();
        var theirs = all.Where(l => l.Speaker != Note.MeId).ToList();
        var lines = RemovingEcho(mine, theirs).Concat(theirs).OrderBy(l => l.Start).ToList();
        var speakers = new List<NoteSpeaker>();
        if (mine.Count > 0 || theirs.Count == 0) speakers.Add(new NoteSpeaker(Note.MeId, Note.MeName, true));
        if (theirs.Count > 0) speakers.Add(new NoteSpeaker(Note.ThemId, Note.ThemName));
        return (speakers, lines);
    }
}

/// One channel's audio cut into stretches of at most 18 s, preferring a cut in a pause, so each
/// goes to the transcriber on its own and nothing waits for the call to end.
public sealed class NoteChunker
{
    public const double MaxSeconds = 18;
    public const int Rate = 16000;
    private const double MinCutSeconds = 6;
    private const double SilenceSeconds = 0.5;
    private const double SilenceAmp = 0.02;

    private readonly List<short> _buf = new();
    private double _bufStart;

    public IEnumerable<(double Start, double End, short[] Samples)> Push(ReadOnlySpan<short> s)
    {
        _buf.AddRange(s.ToArray());
        var o = new List<(double, double, short[])>();
        while (true)
        {
            var cut = CutPoint();
            if (cut == null) break;
            o.Add(Take(cut.Value));
        }
        return o;
    }

    public IEnumerable<(double Start, double End, short[] Samples)> Flush()
    {
        if (_buf.Count == 0) return Array.Empty<(double, double, short[])>();
        return new[] { Take(_buf.Count) };
    }

    private (double, double, short[]) Take(int n)
    {
        var chunk = _buf.GetRange(0, n).ToArray();
        _buf.RemoveRange(0, n);
        var start = _bufStart;
        _bufStart += (double)n / Rate;
        return (start, _bufStart, chunk);
    }

    /// The end of the first quiet half-second after 6 s, else the 18 s mark once there is that much.
    private int? CutPoint()
    {
        var max = (int)(MaxSeconds * Rate);
        var win = (int)(SilenceSeconds * Rate);
        var min = (int)(MinCutSeconds * Rate);
        var limit = Math.Min(_buf.Count, max);
        var quiet = 0;
        for (var i = 0; i < limit; i++)
        {
            quiet = Math.Abs(_buf[i] / 32768.0) < SilenceAmp ? quiet + 1 : 0;
            if (quiet >= win && i + 1 >= min) return i + 1;
        }
        return _buf.Count >= max ? max : null;
    }
}

/// Notes on disk: %APPDATA%\Jarvis\Notes\<id>\note.json, text only.
public sealed class NoteStore
{
    private static readonly JsonSerializerOptions Options = new() { WriteIndented = true };
    private readonly string _dir;

    public NoteStore(string? dir = null) =>
        _dir = dir ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Jarvis", "Notes");

    public void Save(Note n)
    {
        var d = Path.Combine(_dir, n.Id);
        Directory.CreateDirectory(d);
        var p = Path.Combine(d, "note.json");
        File.WriteAllText(p + ".tmp", JsonSerializer.Serialize(n, Options));
        File.Move(p + ".tmp", p, overwrite: true);
    }

    public IReadOnlyList<Note> All()
    {
        if (!Directory.Exists(_dir)) return Array.Empty<Note>();
        var o = new List<Note>();
        foreach (var d in Directory.EnumerateDirectories(_dir))
        {
            try
            {
                var p = Path.Combine(d, "note.json");
                if (File.Exists(p) && JsonSerializer.Deserialize<Note>(File.ReadAllText(p), Options) is { } n) o.Add(n);
            }
            catch (Exception e) when (e is IOException or JsonException) { }
        }
        return o.OrderByDescending(n => n.Start).ToList();
    }
}

/// The note-taker without audio devices: two channels (the mic is "You", what the PC plays is
/// "Them") cut into chunks, each transcribed on one worker (one in flight; a failure retried
/// once, then "[unheard]"), then on stop the note uploads once and its summary is polled.
public sealed class NoteSession
{
    public static readonly TimeSpan SummaryPoll = TimeSpan.FromSeconds(5);
    public static readonly TimeSpan SummaryFor = TimeSpan.FromMinutes(2);

    private readonly ApiClient _api;
    private readonly Func<string?> _origin;
    private readonly TimeProvider _time;
    private readonly NoteChunker _me = new(), _them = new();
    private readonly SemaphoreSlim _worker = new(1, 1);
    private readonly List<Task> _jobs = new();
    private readonly List<NoteLine> _lines = new();

    public NoteSession(ApiClient api, Func<string?> origin, TimeProvider? time = null)
    {
        _api = api;
        _origin = origin;
        _time = time ?? TimeProvider.System;
        Note = new Note { Start = _time.GetUtcNow(), Title = $"Call {_time.GetLocalNow():ddd d MMM, HH:mm}" };
    }

    public Note Note { get; }
    public event Action? Changed;

    public void Mic(ReadOnlySpan<short> s) { foreach (var c in _me.Push(s)) Queue(Note.MeId, c); }
    public void System(ReadOnlySpan<short> s) { foreach (var c in _them.Push(s)) Queue(Note.ThemId, c); }

    private void Queue(string speaker, (double Start, double End, short[] Samples) c)
    {
        lock (_jobs) _jobs.Add(TranscribeAsync(speaker, c));
    }

    private async Task TranscribeAsync(string speaker, (double Start, double End, short[] Samples) c)
    {
        // Silence isn't worth a round trip.
        if (c.Samples.All(v => Math.Abs((int)v) < 600)) return;
        await _worker.WaitAsync().ConfigureAwait(false);
        try
        {
            string? text = null;
            for (var attempt = 0; attempt < 2 && text == null; attempt++)
            {
                try { text = await PostAsync(c.Samples).ConfigureAwait(false); }
                catch (Exception e) when (e is ApiException or HttpRequestException or TaskCanceledException) { }
            }
            var line = new NoteLine(speaker, c.Start, c.End, text ?? "[unheard]");
            if (line.Text.Trim().Length == 0) return;
            lock (_lines) _lines.Add(line);
            Changed?.Invoke();
        }
        finally { _worker.Release(); }
    }

    private async Task<string> PostAsync(short[] samples)
    {
        var origin = _origin() ?? throw new ApiException(0, ApiClient.NotConnected);
        var form = new MultipartFormDataContent();
        var file = new ByteArrayContent(Wav.Pcm16Mono(samples, NoteChunker.Rate));
        file.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
        form.Add(file, "file", "note.wav");
        var r = await _api.PostAbsoluteAsync(new Uri(origin.TrimEnd('/') + "/api/transcribe"), form, new Dictionary<string, string>(), TimeSpan.FromSeconds(60))
            .ConfigureAwait(false);
        return J.S(r["transcript"], J.S(r["text"]));
    }

    /// Stop: transcribe what's left, finish the note, upload it once, then fetch its summary.
    public async Task StopAsync()
    {
        foreach (var c in _me.Flush()) Queue(Note.MeId, c);
        foreach (var c in _them.Flush()) Queue(Note.ThemId, c);
        Note.End = _time.GetUtcNow();
        Note.Status = NoteStatus.Transcribing;
        Changed?.Invoke();
        Task[] jobs;
        lock (_jobs) jobs = _jobs.ToArray();
        await Task.WhenAll(jobs).ConfigureAwait(false);
        List<NoteLine> all;
        lock (_lines) all = _lines.ToList();
        var (speakers, lines) = NoteBuilder.Finalize(all);
        Note.Speakers = speakers;
        Note.Lines = lines;
        Note.Status = NoteStatus.Ready;
        await UploadAsync().ConfigureAwait(false);
    }

    public async Task UploadAsync()
    {
        if (Note.Uploaded) return;
        try
        {
            await _api.PostAsync("/api/agent-notes", Note.ServerJson(), TimeSpan.FromSeconds(30)).ConfigureAwait(false);
            Note.Uploaded = true;
            Note.SummaryStatus = SummaryStatus.Pending;
        }
        catch (ApiException e)
        {
            Note.SummaryStatus = SummaryStatus.Failed;
            Note.SummaryError = e.Error;
        }
        Changed?.Invoke();
    }

    /// Polls `/api/agent-notes/<id>` every 5 s for up to 2 minutes until the summary is done.
    public async Task PollSummaryAsync(CancellationToken ct = default)
    {
        var until = _time.GetUtcNow() + SummaryFor;
        while (Note.Uploaded && Note.SummaryStatus is SummaryStatus.Pending or SummaryStatus.None && _time.GetUtcNow() < until && !ct.IsCancellationRequested)
        {
            await Task.Delay(SummaryPoll, _time, ct).ConfigureAwait(false);
            try
            {
                var r = await _api.GetAsync("/api/agent-notes/" + Uri.EscapeDataString(Note.Id), TimeSpan.FromSeconds(15)).ConfigureAwait(false);
                Note.Absorb(r["note"] is JsonObject inner ? inner : r);
                Changed?.Invoke();
            }
            catch (ApiException) { }
        }
    }
}
