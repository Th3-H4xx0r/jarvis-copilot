using Jarvis.Core.Gaming;
using Jarvis.Core.Island;
using Jarvis.Core.Link;
using Jarvis.Core.Prefs;
using Jarvis.Core.State;
using Jarvis.Core.Voice;
using Jarvis.Tests.Fakes;
using Jarvis.Tests.Gaming;

namespace Jarvis.Tests.Voice;

internal sealed class FakeEndpoints : IAudioEndpoints
{
    public (string, string) Current = ("spk", "mic");
    public (string RenderId, string CaptureId) Defaults() => Current;
    public event Action? DefaultsChanged;
    public void Switch(string render, string capture) { Current = (render, capture); DefaultsChanged?.Invoke(); }
}

internal sealed class FakeCapture : IAecCapture
{
    public List<string> Calls { get; } = new();
    public event Action<ReadOnlyMemory<short>>? Frame;
    public void Start(string renderId, string captureId) => Calls.Add($"start {renderId} {captureId}");
    public void Stop() => Calls.Add("stop");
    public void Push(short level, int frames = 1)
    {
        for (var i = 0; i < frames; i++)
        {
            var f = new short[160];
            for (var j = 0; j < f.Length; j++) f[j] = j % 2 == 0 ? level : (short)-level;
            Frame?.Invoke(f);
        }
    }
}

internal sealed class FakePlayer : IReplyPlayer
{
    public List<string> Calls { get; } = new();
    public List<float> Volumes { get; } = new();
    public long PlayedMs { get; set; }
    public long QueuedMs { get; set; }
    public bool Draining { get; set; }
    public event Action? Drained;
    public void Start(string renderId) => Calls.Add($"start {renderId}");
    public void Stop() => Calls.Add("stop");
    public void Flush() => Calls.Add("flush");
    public void EndSegment() => Calls.Add("end");
    public void SetVolume(float v) => Volumes.Add(v);
    public void Enqueue(string format, int rate, ReadOnlyMemory<byte> data)
    {
        Calls.Add($"enqueue {format} {rate} {data.Length}");
        QueuedMs += format == "pcm_s16le" ? data.Length / 2 * 1000L / rate : 0;
        Draining = true;
    }
    public void Drain() { Draining = false; Drained?.Invoke(); }
}

internal sealed class FakeSocket : IVoiceSocket
{
    public Uri? Url;
    public List<string> TextsSent { get; } = new();
    public List<int> BinarySizes { get; } = new();
    public bool Closed;
    public event Action<string>? Text;
    public event Action<byte[]>? Binary;
    public event Action<string?>? ClosedEvent;
    event Action<string?>? IVoiceSocket.Closed { add => ClosedEvent += value; remove => ClosedEvent -= value; }
    public Task ConnectAsync(Uri url, CancellationToken ct) { Url = url; return Task.CompletedTask; }
    public Task SendTextAsync(string text) { lock (TextsSent) TextsSent.Add(text); return Task.CompletedTask; }
    public Task SendBinaryAsync(ReadOnlyMemory<byte> data) { lock (BinarySizes) BinarySizes.Add(data.Length); return Task.CompletedTask; }
    public Task CloseAsync() { Closed = true; return Task.CompletedTask; }
    public void Server(string json) => Text?.Invoke(json);
    public void ServerAudio(byte[] data) => Binary?.Invoke(data);
    public void Drop(string why) => ClosedEvent?.Invoke(why);
    public IEnumerable<JsonObject> Sent(string type) => TextsSent.Select(J.Parse).Where(o => J.S(o["type"]) == type);
}

internal sealed class FakeRecognizer : IWordsRecognizer
{
    public string? Next;
    public bool Running;
    public void Begin() => Running = true;
    public void Feed(ReadOnlyMemory<short> pcm) { }
    public string? TakeLatest() { var n = Next; Next = null; return n; }
    public void End() => Running = false;
}

public class VoiceControllerTests
{
    private readonly FakeEndpoints _endpoints = new();
    private readonly FakeCapture _capture = new();
    private readonly FakePlayer _player = new();
    private readonly FakeSocket _socket = new();
    private readonly FakeRecognizer _recognizer = new();
    private readonly ManualTime _time = new();
    private readonly VoiceController _voice;

    public VoiceControllerTests()
    {
        var routes = new DeviceRoutes(_endpoints, _capture, _player);
        _voice = new VoiceController(() => "http://127.0.0.1:8765", () => Task.FromResult<string?>("voice-sid"), () => _socket,
            routes, _capture, _player, _recognizer, _time);
    }

    private const short Loud = 3000;    // ~0.09 peak: speech
    private const short Quiet = 50;

    [Fact]
    public void DeviceRouter_DefaultChanged_RestartsCaptureAndPlaybackOnNewIds()
    {
        var routes = new DeviceRoutes(_endpoints, _capture, _player);
        routes.Begin();
        Assert.Equal(new[] { "start spk mic" }, _capture.Calls);
        Assert.Equal(new[] { "start spk" }, _player.Calls);
        _endpoints.Switch("hs", "hsmic");
        Assert.Equal(new[] { "start spk mic", "stop", "start hs hsmic" }, _capture.Calls);
        Assert.Equal(new[] { "start spk", "stop", "start hs" }, _player.Calls);
    }

    [Fact]
    public void DeviceRouter_ChangeWhileIdle_DoesNothing()
    {
        var routes = new DeviceRoutes(_endpoints, _capture, _player);
        _endpoints.Switch("hs", "hsmic");
        Assert.Empty(_capture.Calls);
        routes.Begin();
        routes.End();
        _endpoints.Switch("spk", "mic");
        Assert.Equal(new[] { "start hs hsmic", "stop" }, _capture.Calls);
    }

    [Fact]
    public void SocketUrl_FromOrigin()
    {
        Assert.Equal("ws://127.0.0.1:8765/api/voice/s2s/ws", VoiceSessionApi.SocketUrl("http://127.0.0.1:8765")!.ToString());
        Assert.Equal("wss://j.example/api/voice/s2s/ws", VoiceSessionApi.SocketUrl("https://j.example")!.ToString());
        Assert.Null(VoiceSessionApi.SocketUrl(null));
    }

    [Fact]
    public async Task Conversation_SendsBeginTurnThenBinaryPcm()
    {
        await _voice.StartConversationAsync("orb");
        Assert.Equal(VoiceState.Listening, _voice.State);
        Assert.Equal("ws://127.0.0.1:8765/api/voice/s2s/ws", _socket.Url!.ToString());
        Assert.Equal(new VoiceClientMessage.BeginTurn(16000, "voice-sid", null, null, null, true).Encoded(), _socket.TextsSent[0]);
        _capture.Push(Quiet, 3);
        Assert.Equal(new[] { 320, 320, 320 }, _socket.BinarySizes);
    }

    [Fact]
    public async Task EndOfSpeech_SendsEndTurnWithClientTs()
    {
        await _voice.StartConversationAsync("orb");
        _capture.Push(Loud, 60);     // 600 ms of speech
        _capture.Push(Quiet, 150);   // then silence → endpoint
        Assert.Equal(VoiceState.Thinking, _voice.State);
        var end = Assert.Single(_socket.Sent("end_turn"));
        Assert.Equal(_time.GetUtcNow().ToUnixTimeMilliseconds(), (long)end["client_ts"]!);
        Assert.NotNull(end["turn_id"]);
    }

    private async Task SpeakingReply(string text = "The weather in Houston is sunny today and warm")
    {
        await _voice.StartConversationAsync("orb");
        _capture.Push(Loud, 60);
        _capture.Push(Quiet, 150);
        _socket.Server($"{{\"type\":\"assistant_text\",\"text\":\"{text}\"}}");
        _socket.Server("{\"type\":\"audio_meta\",\"format\":\"pcm_s16le\",\"sample_rate\":24000}");
        _socket.ServerAudio(new byte[48000]);    // 1 s
    }

    [Fact]
    public async Task ReplyAudio_DrivesKaraokeFromPlayedMs()
    {
        await SpeakingReply();
        Assert.Equal(VoiceState.Speaking, _voice.State);
        Assert.Contains("enqueue pcm_s16le 24000 48000", _player.Calls);
        _player.PlayedMs = 500;
        _voice.KaraokeTick();
        Assert.InRange(_voice.Reply.SpokenWords, 1, _voice.Reply.TotalWords - 1);
    }

    [Fact]
    public async Task BargeIn_DucksThenInterruptsOnForeignWords_SendsHeard()
    {
        await SpeakingReply();
        _player.PlayedMs = 600;   // past the settle window
        _capture.Push(Loud, 40);  // sustained sound over the reply
        Assert.Contains(BargeInTuning.DuckVolume, _player.Volumes);
        Assert.True(_voice.BargeCheckOpen);
        _recognizer.Next = "stop that";
        _capture.Push(Loud, 1);
        var interrupt = Assert.Single(_socket.Sent("interrupt"));
        Assert.Equal(_voice.Reply.HeardText(), J.S(interrupt["heard"]));
        Assert.Contains("flush", _player.Calls);
        Assert.Equal(VoiceState.Listening, _voice.State);
        // The cut-off reply's late audio is dropped.
        var before = _player.Calls.Count(c => c.StartsWith("enqueue"));
        _socket.ServerAudio(new byte[4800]);
        Assert.Equal(before, _player.Calls.Count(c => c.StartsWith("enqueue")));
    }

    [Fact]
    public async Task BargeIn_NoiseOnly_Unducks()
    {
        await SpeakingReply();
        _player.PlayedMs = 600;
        _capture.Push(Loud, 40);
        Assert.True(_voice.BargeCheckOpen);
        _recognizer.Next = "";
        _capture.Push(Loud, 90);   // 1.2 s heard in all
        _capture.Push(Quiet, 60);  // then quiet
        Assert.False(_voice.BargeCheckOpen);
        Assert.Equal(1f, _player.Volumes[^1]);
        Assert.Empty(_socket.Sent("interrupt"));
        Assert.Equal(VoiceState.Speaking, _voice.State);
    }

    [Fact]
    public async Task EchoUnderTheReply_NeverInterrupts()
    {
        await SpeakingReply();
        _capture.Push(Loud, 40);   // inside the 500 ms settle window: learned as echo
        Assert.False(_voice.BargeCheckOpen);
        Assert.Empty(_socket.Sent("interrupt"));
    }

    [Fact]
    public async Task TurnEnd_AfterDrain_ListensAgain()
    {
        await SpeakingReply();
        _socket.Server("{\"type\":\"audio_end\"}");
        _socket.Server("{\"type\":\"end_turn\",\"reason\":\"done\"}");
        _player.Drain();
        Assert.Equal(VoiceState.Listening, _voice.State);
    }

    [Fact]
    public async Task PushToTalk_KeyHeld_EndpointerOff_KeyUpSendsTurn_OneAnswerThenCloses()
    {
        await _voice.PushToTalkDownAsync();
        Assert.True(_voice.PushToTalk);
        Assert.Equal(VoiceState.Listening, _voice.State);
        _capture.Push(Loud, 60);
        _capture.Push(Quiet, 200);   // a pause while the key is held never ends the turn
        Assert.Empty(_socket.Sent("end_turn"));
        await _voice.PushToTalkUpAsync();
        Assert.Single(_socket.Sent("end_turn"));
        Assert.Equal(VoiceState.Thinking, _voice.State);
        _socket.Server("{\"type\":\"assistant_text\",\"text\":\"It's three.\"}");
        _socket.Server("{\"type\":\"audio_meta\",\"format\":\"pcm_s16le\",\"sample_rate\":24000}");
        _socket.ServerAudio(new byte[4800]);
        _socket.Server("{\"type\":\"end_turn\",\"reason\":\"done\"}");
        _player.Drain();
        Assert.Equal(VoiceState.Idle, _voice.State);
        Assert.True(_socket.Closed);
    }

    [Fact]
    public async Task PushToTalk_OverAReply_Interrupts()
    {
        await SpeakingReply();
        await _voice.PushToTalkDownAsync();
        Assert.Single(_socket.Sent("interrupt"));
        Assert.Equal(VoiceState.Listening, _voice.State);
    }

    [Fact]
    public async Task GameMode_VoiceStillAnswers_ButNoIslandShow()
    {
        var dir = Path.Combine(Path.GetTempPath(), "jc-voice-" + Guid.NewGuid().ToString("N"));
        var link = new FakeLink();
        var state = new AppState(link, _time);
        var gate = new PresentationGate(new FakeProbe(), _time);
        state.GameModeChanged += gate.SetGameMode;
        var island = new IslandPresenter(state, gate, new PrefsStore(Path.Combine(dir, "p.json")), _time);
        state.Handle(new JsonObject { ["type"] = "game_mode", ["on"] = true, ["reason"] = "fullscreen", ["anticheat"] = false });
        await _voice.StartConversationAsync("wake");
        Assert.NotNull(_socket.Url);
        Assert.Equal(VoiceState.Listening, _voice.State);
        Assert.False(island.Visible);
    }

    [Fact]
    public async Task SocketDrop_ShowsErrorAndTearsDown()
    {
        await _voice.StartConversationAsync("orb");
        _socket.Drop("reset");
        Assert.Equal(VoiceState.Error, _voice.State);
        Assert.Equal("The voice connection dropped.", _voice.Error);
        Assert.Contains("stop", _capture.Calls);
    }

    [Fact]
    public async Task AudioWhileConnecting_IsHeldThenFlushed()
    {
        var gate = new TaskCompletionSource<string?>();
        var routes = new DeviceRoutes(_endpoints, _capture, _player);
        var voice = new VoiceController(() => "http://o:1", () => gate.Task, () => _socket, routes, _capture, _player, null, _time);
        var start = voice.StartConversationAsync("orb");
        _capture.Push(Quiet, 4);
        Assert.Empty(_socket.BinarySizes);
        gate.SetResult("sid");
        await start;
        Assert.Equal(4, _socket.BinarySizes.Count);
        Assert.StartsWith("{\"clear_stale_stream\"", _socket.TextsSent[0]);
    }

    [Fact]
    public async Task Stop_TearsDown()
    {
        await _voice.StartConversationAsync("orb");
        await _voice.StopAsync();
        Assert.Equal(VoiceState.Idle, _voice.State);
        Assert.True(_socket.Closed);
        Assert.Contains("stop", _capture.Calls);
    }
}
