using System.Text;
using Jarvis.Core.Flow;
using Jarvis.Core.Http;
using Jarvis.Core.Link;
using Jarvis.Core.Model;
using Jarvis.Tests.Fakes;
using A = Jarvis.Core.Flow.FlowKeyLogic.Action;
using P = Jarvis.Core.Flow.FlowKeyLogic.PhaseKind;

namespace Jarvis.Tests.Flow;

public class FlowLogicTests
{
    [Fact]
    public void HoldDictatesAndReleasePastes()
    {
        var k = new FlowKeyLogic();
        Assert.Equal(A.Start, k.KeyDown(0));
        Assert.Equal(A.None, k.KeyDown(0.1));
        Assert.Equal(A.Finish, k.KeyUp(1.0));
        Assert.Equal(P.Idle, k.Phase);
    }

    [Fact]
    public void DoubleTapIsHandsFreeUntilTheNextTap()
    {
        var k = new FlowKeyLogic();
        Assert.Equal(A.Start, k.KeyDown(0));
        Assert.Equal(A.None, k.KeyUp(0.1));
        Assert.Equal(P.TapWait, k.Phase);
        Assert.Equal(0.1 + FlowKeyLogic.DoubleTapWindow, k.PhaseTime, 9);
        Assert.Equal(A.Lock, k.KeyDown(0.3));
        Assert.Equal(A.None, k.KeyUp(0.35));
        Assert.Equal(P.Locked, k.Phase);
        Assert.Equal(A.Finish, k.KeyDown(9));
        Assert.Equal(P.Idle, k.Phase);
    }

    [Fact]
    public void ALoneShortTapIsDroppedWhenTheWindowRunsOut()
    {
        var k = new FlowKeyLogic();
        k.KeyDown(0);
        k.KeyUp(0.1);
        Assert.Equal(A.None, k.Tick(0.2));
        Assert.Equal(A.Cancel, k.Tick(0.6));
        Assert.Equal(P.Idle, k.Phase);
    }

    [Fact]
    public void ASecondPressAfterAMissedTimeoutStartsAfresh()
    {
        var k = new FlowKeyLogic();
        k.KeyDown(0);
        k.KeyUp(0.1);
        Assert.Equal(A.Restart, k.KeyDown(2));
        Assert.Equal(A.Finish, k.KeyUp(3));
    }

    [Fact]
    public void AnotherKeyMeansItWasAShortcut()
    {
        var k = new FlowKeyLogic();
        k.KeyDown(0);
        Assert.Equal(A.Cancel, k.OtherKey());
        Assert.Equal(P.Idle, k.Phase);
        var locked = new FlowKeyLogic();
        locked.Lock();
        Assert.Equal(A.None, locked.OtherKey());
    }

    [Fact]
    public void EscapeCancelsAnything()
    {
        var k = new FlowKeyLogic();
        Assert.Equal(A.None, k.Escape());
        k.Lock();
        Assert.Equal(A.Cancel, k.Escape());
        Assert.Equal(P.Idle, k.Phase);
    }

    private static readonly FlowReplacement[] NoReplacements = Array.Empty<FlowReplacement>();
    private static readonly FlowSnippet[] NoSnippets = Array.Empty<FlowSnippet>();

    [Fact]
    public void ReplacementsMatchWholeWordsAnyCaseAnySeparator()
    {
        Assert.Equal("open Claude Code now", FlowText.Apply("open Cloud-Code now", Array.Empty<string>(), new[] { new FlowReplacement("cloud code", "Claude Code") }, NoSnippets));
        Assert.Equal("depart ART", FlowText.Apply("depart art", Array.Empty<string>(), new[] { new FlowReplacement("art", "ART") }, NoSnippets));
    }

    [Fact] public void Replacing_WholeWordsAnySeparator() => Assert.Equal("I use Claude Code daily", FlowText.Replacing("cloud code", "Claude Code", "I use Cloud-Code daily"));
    [Fact] public void Replacing_NotInsideWords() => Assert.Equal("depart", FlowText.Replacing("art", "ART", "depart"));

    [Fact]
    public void TheDictionaryFixesSpelling()
    {
        Assert.Equal("deploy to Supabase", FlowText.Apply("deploy to supabase", new[] { "Supabase" }, NoReplacements, NoSnippets));
        Assert.Equal("learn c today", FlowText.Apply("learn c today", new[] { "C++" }, NoReplacements, NoSnippets));
    }

    [Fact]
    public void SnippetsAreSetAsideThenPutBack()
    {
        var s = new[] { new FlowSnippet("my signature", "Best,\nPranav") };
        var p = FlowText.Prepare("My signature.", Array.Empty<string>(), new[] { new FlowReplacement("best", "WORST") }, s);
        Assert.Equal("⟦1⟧", p.Text);
        Assert.Equal("Best,\nPranav", FlowText.Finish(p.Text, p.Snippets));
        Assert.True(FlowText.KeepsMarks("⟦1⟧", p.Snippets));
        Assert.False(FlowText.KeepsMarks("Thanks.", p.Snippets));
    }

    [Theory]
    [InlineData("my email", "me@example.com")]
    [InlineData("My email.", "me@example.com")]
    [InlineData("  my, email!  ", "me@example.com")]
    [InlineData("Do you know what my email is?", "Do you know what my email is?")]
    [InlineData("send it to my email", "send it to my email")]
    [InlineData("my emails", "my emails")]
    public void ASnippetFiresOnlyWhenItIsAllYouSaid(string heard, string pasted) =>
        Assert.Equal(pasted, FlowText.Apply(heard, Array.Empty<string>(), NoReplacements, new[] { new FlowSnippet("my email", "me@example.com") }));

    [Fact]
    public void WordCount()
    {
        Assert.Equal(3, FlowText.WordCount("it's a test ?"));
        Assert.Equal(0, FlowText.WordCount(""));
    }

    [Fact]
    public void PerAppStyles()
    {
        var styles = new[] { new FlowAppStyle("OUTLOOK.EXE", FlowStyle.polished) };
        Assert.Equal(FlowStyle.polished, FlowAppStyle.Resolve("outlook.exe", styles, FlowStyle.natural));
        Assert.Equal(FlowStyle.natural, FlowAppStyle.Resolve("other.exe", styles, FlowStyle.natural));
        Assert.Equal(FlowStyle.verbatim, FlowAppStyle.Resolve(null, styles, FlowStyle.verbatim));
        Assert.Contains(FlowAppStyle.Defaults, a => a.Exe == "Code.exe" && a.Style == FlowStyle.natural);
    }

    [Fact] public void Cleanup_Body_Exact() => Assert.Equal("{\"app\":\"Code.exe\",\"style\":\"natural\",\"text\":\"so um yes\",\"words\":[\"Jarvis\"]}",
        J.SortedJson(FlowCleanup.Body("so um yes", FlowStyle.natural, "Code.exe", new[] { "Jarvis" }, null, null)));

    [Fact]
    public void Cleanup_CarriesPickedModel()
    {
        var b = FlowCleanup.Body("x y z", FlowStyle.polished, null, Array.Empty<string>(), "m1", "p1");
        Assert.Equal("m1", J.S(b["model"]));
        Assert.Equal("p1", J.S(b["provider"]));
    }

    [Fact]
    public void Cleanup_ImplausibleRejected()
    {
        Assert.True(FlowCleanup.Plausible("Meet at four.", "uh meet at three no at four"));
        Assert.False(FlowCleanup.Plausible("", "a b c"));
        Assert.False(FlowCleanup.Plausible(string.Concat(Enumerable.Repeat("word ", 40)), "one two three"));
        Assert.False(FlowCleanup.Plausible("one", "one two three four five six seven eight nine ten"));
    }

    [Fact]
    public void CleanUpRunsOnlyWhenItCanHelp()
    {
        Assert.True(FlowCleanup.WorthCleaning("send the report today", FlowStyle.natural, true));
        Assert.False(FlowCleanup.WorthCleaning("send the report today", FlowStyle.natural, false));
        Assert.False(FlowCleanup.WorthCleaning("git status now please", FlowStyle.verbatim, true));
        Assert.False(FlowCleanup.WorthCleaning("ok", FlowStyle.natural, true));
    }

    [Fact]
    public void Wav_Header()
    {
        var w = Wav.Pcm16Mono(new short[16000], 16000);
        Assert.Equal(44 + 32000, w.Length);
        Assert.Equal("RIFF", Encoding.ASCII.GetString(w, 0, 4));
        Assert.Equal(16000, BitConverter.ToInt32(w, 24));
        Assert.Equal(32000, BitConverter.ToInt32(w, 40));
    }

    [Fact]
    public void Store_RoundTripsSettings_CorruptFallsBack()
    {
        var dir = Path.Combine(Path.GetTempPath(), "jc-flow-" + Guid.NewGuid().ToString("N"));
        var store = new FlowStore(dir);
        Assert.Equal(FlowStyle.natural, store.LoadSettings().DefaultStyle);
        store.SaveSettings(FlowSettings.Default with { Words = new[] { "Jarvis" }, DefaultStyle = FlowStyle.polished, CleanupOn = true,
            Replacements = new[] { new FlowReplacement("a b", "AB") } });
        var back = store.LoadSettings();
        Assert.Equal(new[] { "Jarvis" }, back.Words);
        Assert.Equal(FlowStyle.polished, back.DefaultStyle);
        Assert.True(back.CleanupOn);
        Assert.Equal("AB", back.Replacements[0].To);
        File.WriteAllText(Path.Combine(dir, "settings.json"), "{nope");
        Assert.Equal(FlowSettings.Default.DefaultStyle, store.LoadSettings().DefaultStyle);
    }

    [Fact]
    public void Stats_CountWords_AndSpeed()
    {
        var stats = new FlowStats();
        stats.Add(12, 6, "slack.exe", "2026-11-15");
        stats.Add(3, 2, null, "2026-11-15");
        Assert.Equal(15, stats.Days["2026-11-15"].Words);
        Assert.Equal(2, stats.Days["2026-11-15"].Dictations);
        Assert.Equal(12, stats.Apps["slack.exe"]);
        Assert.Equal(150, FlowText.WordsPerMinute(150, 60));
        Assert.Equal(1.5, FlowText.MinutesSaved(90, 30), 3);
    }
}

internal sealed class FakeCapture : IFlowCapture
{
    public int Starts;
    public short[] Heard = new short[16000];
    public double Level => 0;
    public void Start() => Starts++;
    public short[] Stop() => Heard;
}

internal sealed class FakePaster : IPaster
{
    public List<string> Pasted { get; } = new();
    public PasteResult Paste(string text) { Pasted.Add(text); return PasteResult.Pasted; }
}

internal sealed class FakeClipboard : IClipboardText
{
    public string? Text;
    public string? GetText() => Text;
    public void SetText(string text) => Text = text;
}

internal sealed class FakeKeys : IKeySender
{
    public List<(ushort, bool)> Sent { get; } = new();
    public bool Send(IReadOnlyList<(ushort Vk, bool Down)> keys) { Sent.AddRange(keys); return true; }
}

public class FlowControllerTests
{
    private static (FlowController, FakeHttp, FakePaster, FakeCapture) Make(GameMode? mode = null, string transcript = "cloud code is great")
    {
        var http = new FakeHttp(r => r.Path.StartsWith("/api/transcribe")
            ? FakeHttp.Json($"{{\"ok\":true,\"transcript\":\"{transcript}\"}}")
            : FakeHttp.Json("{\"cleaned\":true,\"text\":\"Claude Code is great!\"}"));
        var api = new ApiClient(() => "http://o", http);
        var paster = new FakePaster();
        var capture = new FakeCapture();
        var settings = FlowSettings.Default with { Replacements = new[] { new FlowReplacement("cloud code", "Claude Code") } };
        var c = new FlowController(api, () => "http://o", paster, capture, () => mode ?? GameMode.Off, () => settings, () => "notepad.exe", new ManualTime());
        return (c, http, paster, capture);
    }

    [Fact]
    public async Task Finish_PostsWavAsFileField_ThenPastesProcessedText()
    {
        var (c, http, paster, capture) = Make();
        c.OnKey(true, 0);
        Assert.Equal(1, capture.Starts);
        c.OnKey(false, 1);
        await c.Pending;
        var req = http.To("/api/transcribe").Single();
        Assert.Equal("multipart/form-data", req.ContentType);
        Assert.Contains("name=file", req.Body);
        Assert.Contains("filename=flow.wav", req.Body);
        Assert.Equal(new[] { "Claude Code is great" }, paster.Pasted);
        Assert.Empty(http.To("/api/flow/cleanup"));   // clean-up is off by default
        Assert.Equal(FlowController.Phase.Idle, c.State);
    }

    [Fact]
    public async Task Flow_KeyDuringGameMode_DoesNothing()
    {
        var (c, http, paster, capture) = Make(new GameMode(true, "fullscreen", false));
        c.OnKey(true, 0);
        c.OnKey(false, 1);
        await c.Pending;
        Assert.Equal(0, capture.Starts);
        Assert.Empty(http.Requests);
        Assert.Empty(paster.Pasted);
    }

    [Fact]
    public async Task ShortTapThenTimeout_PastesNothing()
    {
        var (c, http, paster, _) = Make();
        c.OnKey(true, 0);
        c.OnKey(false, 0.1);
        Assert.True(c.TickNeeded);
        c.Tick(0.6);
        await c.Pending;
        Assert.Empty(http.Requests);
        Assert.Empty(paster.Pasted);
    }

    [Fact]
    public void Paster_ElevatedForeground_CopiesOnly()
    {
        var clip = new FakeClipboard { Text = "before" };
        var keys = new FakeKeys();
        var r = new FlowPaster(clip, keys, () => true, new ManualTime()).Paste("words");
        Assert.Equal(PasteResult.CopiedOnly, r);
        Assert.Empty(keys.Sent);
        Assert.Equal("words", clip.Text);
    }

    [Fact]
    public void Paster_Normal_SendsCtrlVAndRestoresClipboard()
    {
        var clip = new FakeClipboard { Text = "before" };
        var keys = new FakeKeys();
        var time = new ManualTime();
        Assert.Equal(PasteResult.Pasted, new FlowPaster(clip, keys, () => false, time).Paste("words"));
        Assert.Equal(new (ushort, bool)[] { (0x11, true), (0x56, true), (0x56, false), (0x11, false) }, keys.Sent);
        Assert.Equal("words", clip.Text);
        time.Advance(TimeSpan.FromMilliseconds(400));
        Assert.Equal("before", clip.Text);
    }

    [Fact]
    public void Paster_SomethingElseCopiedMeanwhile_NotOverwritten()
    {
        var clip = new FakeClipboard { Text = "before" };
        var time = new ManualTime();
        new FlowPaster(clip, new FakeKeys(), () => false, time).Paste("words");
        clip.Text = "newer copy";
        time.Advance(TimeSpan.FromMilliseconds(500));
        Assert.Equal("newer copy", clip.Text);
    }
}
