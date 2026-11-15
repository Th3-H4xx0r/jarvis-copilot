using Jarvis.Core.Chat;
using Jarvis.Core.Http;
using Jarvis.Core.Link;
using Jarvis.Core.Music;
using Jarvis.Tests.Fakes;
using static Jarvis.Tests.Fakes.TestClock;

namespace Jarvis.Tests.Chat;

public class ChatTests
{
    [Fact]
    public void Sse_ParsesTokenToolDone()
    {
        var p = new ChatSse();
        Assert.Null(p.Feed("event: token"));
        Assert.Null(p.Feed("data: {\"text\":\"Hi\"}"));
        var e = p.Feed("")!;
        Assert.Equal("Hi", e.Token);
        p.Feed("data: {\"event\":\"done\"}");
        Assert.True(p.Feed("")!.IsEnd);
        Assert.Null(p.Feed(": keep-alive"));
    }

    [Fact]
    public void Sse_NonJsonDataBecomesText() => Assert.Equal("plain", ChatSse.FromSse(new SseEvent("token", "plain")).Token);

    [Fact]
    public void StreamState_TokensToolsApprovalDone()
    {
        var s = new ChatStreamState();
        s.Apply(ChatSse.FromSse(new SseEvent("message", "{\"event\":\"chat_start\",\"stream_id\":\"st1\"}")));
        s.Apply(ChatSse.FromSse(new SseEvent("token", "{\"text\":\"Hel\"}")));
        s.Apply(ChatSse.FromSse(new SseEvent("token", "{\"text\":\"lo\"}")));
        s.Apply(ChatSse.FromSse(new SseEvent("tool", "{\"name\":\"device_ui_look\"}")));
        s.Apply(ChatSse.FromSse(new SseEvent("approval", "{\"pending\":{\"command\":\"rm x\",\"approval_id\":\"a1\"}}")));
        Assert.Equal("st1", s.StreamId);
        Assert.Equal("Hello", s.Text);
        Assert.Equal(new[] { "ui_look" }, s.Tools);
        Assert.Equal("a1", s.Approval!.Id);
        s.Apply(ChatSse.FromSse(new SseEvent("done", "{}")));
        Assert.True(s.Ended);
        Assert.Null(s.Approval);
    }

    [Fact]
    public void StreamState_AnswerOnlyInDone()
    {
        var s = new ChatStreamState();
        s.Apply(ChatSse.FromSse(new SseEvent("done", "{\"answer\":\"42\"}")));
        Assert.Equal("42", s.Text);
    }

    [Fact]
    public void StartBody_SingleModel() => Assert.Equal("{\"harness_id\":\"single\",\"message\":\"hi\",\"model\":\"m1\",\"model_provider\":\"p\",\"session_id\":\"s\"}",
        J.SortedJson(ChatRequest.StartBody("s", "hi", Array.Empty<JsonObject>(), new ChatRunChoice.Model("m1", "M1", "p"))));

    [Fact]
    public void StartBody_ChatDefaultSendsEmptyHarness()
    {
        var b = ChatRequest.StartBody("s", "hi", Array.Empty<JsonObject>(), new ChatRunChoice.ChatDefault());
        Assert.True(b.ContainsKey("harness_id"));
        Assert.Equal("", J.S(b["harness_id"]));
        Assert.False(b.ContainsKey("model"));
    }

    [Fact]
    public void WindowLine() => Assert.Equal("I'm looking at Google Chrome — \"Jarvis docs\" (https://jarvis.dev/docs).",
        new ChatContext.Window("Google Chrome", "Jarvis docs", "https://jarvis.dev/docs").Line);

    [Fact]
    public void Prompt_InlinesSmallTextFile()
    {
        var a = ChatContext.ForFile(@"C:\x\notes.txt", _ => 3, _ => "abc"u8.ToArray())!;
        Assert.Equal("hi\n\nFile notes.txt:\n```\nabc\n```", ChatContext.Prompt("hi", new[] { a }, null));
        var img = ChatContext.ForFile(@"C:\x\p.png", _ => 3, _ => new byte[] { 1, 2, 3 })!;
        Assert.True(img.IsImage);
        Assert.Equal("hi\n\n(Attached: p.png)", ChatContext.Prompt("hi", new[] { img }, null));
        Assert.False(ChatContext.CanUpload(ChatContext.MaxUploadBytes + 1));
    }

    [Fact]
    public void LocalModel_DeltaAndThinkHidden()
    {
        Assert.Equal("Hi", LocalModel.Delta("data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}"));
        Assert.Null(LocalModel.Delta("data: [DONE]"));
        Assert.True(LocalModel.IsDone("data: [DONE]"));
        Assert.Equal("ok", LocalModel.Visible("<think>x</think>ok"));
        Assert.Equal("before", LocalModel.Visible("before <think>still going"));
        Assert.Equal("http://127.0.0.1:11434/v1/chat/completions", LocalModel.ChatUrl("http://127.0.0.1:11434/v1/").ToString());
        Assert.Equal(new[] { "llama3" }, LocalModel.ChatModels(J.Parse("{\"data\":[{\"id\":\"llama3\"},{\"id\":\"nomic-embed-text\"}]}")));
    }

    [Fact]
    public void BrowserUrl_AddsSchemeToBareHost()
    {
        Assert.Equal("https://github.com/x", BrowserUrl.Normalise("github.com/x"));
        Assert.Null(BrowserUrl.Normalise("search words here"));
        Assert.Equal("http://localhost:3000", BrowserUrl.Normalise("http://localhost:3000"));
        Assert.Null(BrowserUrl.Normalise("jarvis"));
    }

    [Fact] public void BrowserTitle_StripsSuffix() => Assert.Equal("Jarvis docs", BrowserUrl.StripBrowserSuffix("Jarvis docs - Google Chrome", "chrome.exe"));

    [Fact]
    public void NowPlaying_PositionRunsWhilePlaying()
    {
        Assert.Equal(15, new NowPlaying("Spotify", "S", "A", "", 200, 10, T0, true).PositionAt(T0.AddSeconds(5)), 6);
        Assert.Equal(10, new NowPlaying("Spotify", "S", "A", "", 200, 10, T0, false).PositionAt(T0.AddSeconds(5)), 6);
    }

    [Fact]
    public void Approval_RespondBody() => Assert.Equal("{\"approval_id\":\"a1\",\"choice\":\"once\",\"session_id\":\"s\"}",
        J.SortedJson(ChatApproval.RespondBody("s", ChatApproval.Choice.once, "a1")));

    [Fact]
    public async Task Store_JarvisTurn_StreamsAndKeepsTheReply()
    {
        var http = new FakeHttp(r => r.Path switch
        {
            "/api/session/new" => FakeHttp.Json("{\"session\":{\"session_id\":\"S1\"}}"),
            _ when r.Path.StartsWith("/api/chat/start") => FakeHttp.Text("event: token\ndata: {\"text\":\"Hi \"}\n\nevent: token\ndata: {\"text\":\"there\"}\n\ndata: {\"event\":\"done\"}\n\n"),
            _ => FakeHttp.Json("{\"ok\":true}"),
        });
        var store = new ChatStore(new ApiClient(() => "http://o", http)) { Origin = () => "http://o" };
        store.Attached = new Jarvis.Core.Platform.FrontWindow("Google Chrome", "chrome.exe", 1, IntPtr.Zero, "Docs", "https://d.example");
        await store.SendAsync("summarise this page");
        var start = http.To("/api/chat/start").Single();
        Assert.Equal("/api/chat/start?stream=1", start.Path);
        var body = J.Parse(start.Body!);
        Assert.Equal("S1", J.S(body["session_id"]));
        Assert.Contains("(https://d.example)", J.S(body["message"]));
        Assert.Equal(new[] { "summarise this page", "Hi there" }, store.Turns.Select(t => t.Text));
        Assert.Null(store.Attached);
        Assert.False(store.Busy);
    }

    [Fact]
    public async Task LocalModels_ListsChatModels_AndPicksTheFirst()
    {
        var local = new FakeHttp(r => r.Path == "/v1/models"
            ? FakeHttp.Json("{\"data\":[{\"id\":\"nomic-embed-text\"},{\"id\":\"llama3.2\"},{\"id\":\"qwen3\"}]}")
            : FakeHttp.Json("{}", System.Net.HttpStatusCode.NotFound));
        var store = new ChatStore(new ApiClient(() => "http://o", new FakeHttp(_ => FakeHttp.Json("{}"))), local) { Source = ChatStore.Backend.Ollama };
        Assert.Equal(new[] { "llama3.2", "qwen3" }, await store.LocalModelsAsync());
        Assert.Equal("llama3.2", store.LocalModelName);
        Assert.StartsWith("http://127.0.0.1:11434/", local.Requests.Single().Uri);
    }

    [Fact]
    public async Task LocalModels_JarvisOrDownIsEmpty()
    {
        var store = new ChatStore(new ApiClient(() => "http://o", new FakeHttp(_ => FakeHttp.Json("{}"))),
            new FakeHttp(_ => throw new HttpRequestException("refused")));
        Assert.Empty(await store.LocalModelsAsync());
        store.Source = ChatStore.Backend.LmStudio;
        Assert.Empty(await store.LocalModelsAsync());
    }

    [Fact]
    public async Task Approval_PostsRespond()
    {
        var gate = new TaskCompletionSource();
        var http = new FakeHttp(r => r.Path switch
        {
            "/api/session/new" => FakeHttp.Json("{\"session_id\":\"S1\"}"),
            _ when r.Path.StartsWith("/api/chat/start") => FakeHttp.Text("event: approval\ndata: {\"pending\":{\"command\":\"rm -rf x\",\"approval_id\":\"a9\"}}\n\n"),
            _ => FakeHttp.Json("{\"ok\":true}"),
        });
        var store = new ChatStore(new ApiClient(() => "http://o", http)) { Origin = () => "http://o" };
        ChatApproval? seen = null;
        store.Changed += () => { if (store.Approval is { } a) seen = a; };
        await store.SendAsync("clean up");
        Assert.Equal("a9", seen!.Id);
        // (the stream ended, so answer through a fresh state to check the body)
        Assert.Equal("{\"approval_id\":\"a9\",\"choice\":\"deny\",\"session_id\":\"S1\"}", J.SortedJson(ChatApproval.RespondBody(store.SessionId!, ChatApproval.Choice.deny, seen.Id)));
    }
}
