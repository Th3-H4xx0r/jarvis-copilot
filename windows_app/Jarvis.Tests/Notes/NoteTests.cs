using Jarvis.Core.Http;
using Jarvis.Core.Link;
using Jarvis.Core.Notes;
using Jarvis.Tests.Fakes;

namespace Jarvis.Tests.Notes;

public class NoteTests
{
    private static short[] Tone(double seconds, short level = 8000) =>
        Enumerable.Range(0, (int)(seconds * 16000)).Select(i => i % 2 == 0 ? level : (short)-level).ToArray();

    [Fact]
    public void Chunker_SplitsAt18s()
    {
        var c = new NoteChunker();
        var chunks = c.Push(Tone(40)).Concat(c.Flush()).ToList();
        Assert.All(chunks, x => Assert.True(x.End - x.Start <= 18.0 + 1e-9));
        Assert.Equal(40, chunks.Sum(x => x.End - x.Start), 6);
        for (var i = 1; i < chunks.Count; i++) Assert.Equal(chunks[i - 1].End, chunks[i].Start, 9);
    }

    [Fact]
    public void Chunker_PrefersSilenceCut()
    {
        var c = new NoteChunker();
        var audio = Tone(10).Concat(new short[(int)(0.6 * 16000)]).Concat(Tone(10)).ToArray();
        var first = c.Push(audio).First();
        Assert.InRange(first.End, 10.0, 10.7);
    }

    [Fact]
    public void ServerJson_Shape()
    {
        var n = new Note { Start = TestClock.T0, Speakers = { new NoteSpeaker("me", "You", true) }, Lines = { new NoteLine("me", 0, 1, "hi") },
            Todos = { new NoteTodo("x", null, null) } };
        var j = n.ServerJson();
        Assert.Equal(new[] { "app", "end", "id", "key_points", "lines", "speakers", "start", "summary", "title", "title_edited", "todos" },
            j.Select(p => p.Key).OrderBy(k => k, StringComparer.Ordinal));
        Assert.Equal(new[] { "id", "is_me", "name" }, j["speakers"]![0]!.AsObject().Select(p => p.Key).OrderBy(k => k, StringComparer.Ordinal));
        Assert.Equal(new[] { "end", "speaker", "start", "text" }, j["lines"]![0]!.AsObject().Select(p => p.Key).OrderBy(k => k, StringComparer.Ordinal));
    }

    [Fact]
    public void Absorb_KeepsEditedTitle_NeverErasesSummaryOnFailure()
    {
        var n = new Note { Title = "Mine", TitleEdited = true, Summary = "kept" };
        n.Absorb(J.Parse("{\"summary_status\":\"failed\",\"summary_error\":\"boom\",\"summary\":\"\"}"));
        Assert.Equal("kept", n.Summary);
        Assert.Equal("boom", n.SummaryError);
        n.Absorb(J.Parse("{\"summary_status\":\"done\",\"title\":\"Server title\",\"summary\":\"new\",\"key_points\":[\"a\",\"\"],\"todos\":[{\"text\":\"t\",\"owner\":\"\"},{\"text\":\"\"}]}"));
        Assert.Equal("Mine", n.Title);
        Assert.Equal("new", n.Summary);
        Assert.Equal(new[] { "a" }, n.KeyPoints);
        Assert.Single(n.Todos);
        Assert.Null(n.Todos[0].Owner);
    }

    [Fact]
    public void Lines_MicIsYou_LoopbackIsThem_EchoDropped()
    {
        var all = new[]
        {
            new NoteLine("them", 0, 3, "the quarterly numbers look strong"),
            new NoteLine("me", 0.2, 3, "quarterly numbers look strong"),   // the speakers in the mic
            new NoteLine("me", 4, 6, "great let's ship it"),
        };
        var (speakers, lines) = NoteBuilder.Finalize(all);
        Assert.Equal(new[] { "You", "Them" }, speakers.Select(s => s.Name));
        Assert.Equal(new[] { "them", "me" }, lines.Select(l => l.Speaker));
        Assert.Equal("great let's ship it", lines[1].Text);
    }

    [Fact]
    public async Task Stop_UploadsOnceAndMarksUploaded()
    {
        var said = new Queue<string>(new[] { "hello there", "general kenobi" });
        var http = new FakeHttp(r => r.Path.StartsWith("/api/transcribe") ? FakeHttp.Json($"{{\"ok\":true,\"transcript\":\"{said.Dequeue()}\"}}") : FakeHttp.Json("{\"ok\":true}"));
        var s = new NoteSession(new ApiClient(() => "http://o", http), () => "http://o", new ManualTime());
        s.Mic(Tone(3));
        s.System(Tone(2));
        await s.StopAsync();
        await s.UploadAsync();
        Assert.True(s.Note.Uploaded);
        Assert.Single(http.To("/api/agent-notes"));
        Assert.Equal(2, http.To("/api/transcribe").Count);
        Assert.Equal(NoteStatus.Ready, s.Note.Status);
        Assert.Contains(s.Note.Lines, l => l.Speaker == "me");
        Assert.Contains(s.Note.Lines, l => l.Speaker == "them");
    }

    [Fact]
    public async Task FailedChunk_RetriedOnceThenUnheard()
    {
        var calls = 0;
        var http = new FakeHttp(r => r.Path.StartsWith("/api/transcribe")
            ? (++calls > 0 ? FakeHttp.Json("{\"error\":\"down\"}", System.Net.HttpStatusCode.BadGateway) : FakeHttp.Json("{}"))
            : FakeHttp.Json("{\"ok\":true}"));
        var s = new NoteSession(new ApiClient(() => "http://o", http), () => "http://o", new ManualTime());
        s.Mic(Tone(2));
        await s.StopAsync();
        Assert.Equal(2, calls);
        Assert.Equal("[unheard]", Assert.Single(s.Note.Lines).Text);
    }

    [Fact]
    public void Store_RoundTrip()
    {
        var store = new NoteStore(Path.Combine(Path.GetTempPath(), "jc-notes-" + Guid.NewGuid().ToString("N")));
        var n = new Note { Start = TestClock.T0, Title = "T", Lines = { new NoteLine("me", 0, 1, "x") } };
        store.Save(n);
        var back = Assert.Single(store.All());
        Assert.Equal("T", back.Title);
        Assert.Equal("x", back.Lines[0].Text);
    }
}
