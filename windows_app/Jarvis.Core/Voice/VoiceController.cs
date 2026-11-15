using System.Runtime.InteropServices;
using Jarvis.Core.Model;

namespace Jarvis.Core.Voice;

/// One voice conversation at a time, on the server's realtime protocol (the Mac dylib's
/// VoiceStoreTransport, in Core so it is tested here). It owns the turn machine, the endpointer,
/// the words-only barge-in and the karaoke reply, and drives the ports: the AEC mic, the reply
/// player and the socket. Push to talk is the same socket: the key held = the endpointer off,
/// let go = the turn goes. Voice works in game mode too (audio only; the island stays hidden).
/// Thread-safe: mic frames, socket frames and timers all enter through one lock.
public sealed class VoiceController
{
    public const int SampleRate = 16000;
    public static readonly TimeSpan ResumeGrace = TimeSpan.FromMilliseconds(700);
    public static readonly TimeSpan ThinkingWatchdog = TimeSpan.FromSeconds(45);
    /// Audio said while the socket opens is held, up to this much.
    public const int MaxHeldMs = 5000;

    private readonly object _sync = new();
    private readonly Func<string?> _origin;
    private readonly Func<Task<string?>> _sessionId;
    private readonly Func<IVoiceSocket> _newSocket;
    private readonly DeviceRoutes _routes;
    private readonly IReplyPlayer _player;
    private readonly IWordsRecognizer? _recognizer;
    private readonly TimeProvider _time;
    private readonly VoiceTurnMachine _machine = new();
    private readonly Endpointer _endpointer = new();
    private readonly BargeInDetector _barge = new();
    private readonly PostInterruptFilter _postInterrupt = new();
    private readonly List<byte[]> _held = new();
    private IVoiceSocket? _socket;
    private Task _opening = Task.CompletedTask;
    private ITimer? _resume, _watchdog;
    private WordsCheck? _check;
    private QuietCooldown? _cooldown;
    private int _heldMs;
    private bool _connected;
    private string _format = "pcm_s16le";
    private int _rate = 24000;
    private int? _segment;
    private long _segmentQueuedAt, _segmentPlayedAt;
    private bool _clipStarted;
    private bool _turnHadAudio;
    private long _speechEndMs;
    private string _turnId = "";
    private int _epoch;
    private long _playbackStartedPlayed;
    private int _conn;

    public VoiceController(Func<string?> origin, Func<Task<string?>> sessionId, Func<IVoiceSocket> newSocket,
        DeviceRoutes routes, IAecCapture capture, IReplyPlayer player, IWordsRecognizer? recognizer = null, TimeProvider? time = null)
    {
        _origin = origin;
        _sessionId = sessionId;
        _newSocket = newSocket;
        _routes = routes;
        _player = player;
        _recognizer = recognizer;
        _time = time ?? TimeProvider.System;
        capture.Frame += OnMicFrame;
        player.Drained += () => Raise(VoiceEvent.PlaybackDrained);
    }

    public VoiceState State { get { lock (_sync) return _machine.State; } }
    public bool PushToTalk { get { lock (_sync) return _machine.PushToTalk; } }
    public string UserLine { get; private set; } = "";
    public VoiceReply Reply { get; } = new();
    public string? Error { get; private set; }
    /// How loud the mic is (0..1, peak), for the orb.
    public double InputLevel { get; private set; }
    /// Where this conversation started: "orb", "wake" or "ptt".
    public string Origin { get; private set; } = "";
    public bool BargeCheckOpen { get { lock (_sync) return _check != null; } }

    public OrbMood Mood => State switch
    {
        VoiceState.Listening => OrbMood.Waiting,
        VoiceState.Thinking or VoiceState.Connecting => OrbMood.Working,
        VoiceState.Speaking => OrbMood.Finished,
        VoiceState.Error => OrbMood.Error,
        _ => OrbMood.Idle,
    };

    public event Action? Changed;
    public event Action<string>? Log;

    // ── entry points ───────────────────────────────────────────────────

    public Task StartConversationAsync(string origin)
    {
        lock (_sync)
        {
            Origin = origin;
            Error = null;
            Run(_machine.Handle(origin == "ptt" ? VoiceEvent.TalkKeyDown : VoiceEvent.StartRequested));
            return _opening;
        }
    }

    public Task StopAsync()
    {
        Raise(VoiceEvent.StopRequested);
        return Task.CompletedTask;
    }

    public Task PushToTalkDownAsync()
    {
        lock (_sync)
        {
            if (!_machine.State.IsActive()) Origin = "ptt";
            Run(_machine.Handle(VoiceEvent.TalkKeyDown));
            return _opening;
        }
    }

    public Task PushToTalkUpAsync()
    {
        Raise(VoiceEvent.TalkKeyUp);
        return Task.CompletedTask;
    }

    /// The Voice tab's Interrupt button.
    public void Interrupt() => Raise(VoiceEvent.InterruptRequested);

    private void Raise(VoiceEvent e)
    {
        lock (_sync) Run(_machine.Handle(e));
    }

    // ── effects ────────────────────────────────────────────────────────

    private void Run(IReadOnlyList<VoiceEffect> effects)
    {
        foreach (var fx in effects) Apply(fx);
        Changed?.Invoke();
    }

    private void Apply(VoiceEffect fx)
    {
        switch (fx.Kind)
        {
            case VoiceEffectKind.OpenTransport:
                _opening = OpenAsync(++_conn);
                break;
            case VoiceEffectKind.StartMic:
                _routes.Begin();
                break;
            case VoiceEffectKind.SendEndTurn:
                Send(new VoiceClientMessage.EndTurn(null, NowMs(), _speechEndMs > 0 ? _speechEndMs : null, _turnId).Encoded());
                break;
            case VoiceEffectKind.SendInterrupt:
                Send(new VoiceClientMessage.Interrupt(Reply.HeardText()).Encoded());
                _postInterrupt.Interrupted(_time.GetUtcNow());
                Log?.Invoke($"interrupt heard={Reply.HeardText()}");
                break;
            case VoiceEffectKind.StopPlayback:
                _player.Flush();
                _player.SetVolume(1f);
                _check = null;
                _clipStarted = false;
                _segment = null;
                break;
            case VoiceEffectKind.ClearReply:
                Reply.Reset();
                _turnHadAudio = false;
                break;
            case VoiceEffectKind.FinalizeSpoken:
                Reply.FinalizeSpoken();
                break;
            case VoiceEffectKind.ResetEndpointer:
                _endpointer.Reset();
                break;
            case VoiceEffectKind.NewTurnEpoch:
                _epoch++;
                _turnId = Guid.NewGuid().ToString("N")[..12];
                break;
            case VoiceEffectKind.MarkSpeechEnd:
                _speechEndMs = NowMs();
                break;
            case VoiceEffectKind.ScheduleResume:
                _resume?.Dispose();
                _resume = _time.CreateTimer(_ => { lock (_sync) { _resume?.Dispose(); _resume = null; Run(_machine.Handle(VoiceEvent.ResumeGraceElapsed)); } },
                    null, ResumeGrace, Timeout.InfiniteTimeSpan);
                break;
            case VoiceEffectKind.CancelResume:
                _resume?.Dispose();
                _resume = null;
                break;
            case VoiceEffectKind.ResumeWhenQuiet:
                if (!_player.Draining) Run(_machine.Handle(VoiceEvent.PlaybackDrained));
                break;
            case VoiceEffectKind.ArmThinkingWatchdog:
                _watchdog?.Dispose();
                _watchdog = _time.CreateTimer(_ => { lock (_sync) { _watchdog?.Dispose(); _watchdog = null; Run(_machine.Handle(VoiceEvent.Failed("Jarvis didn't answer. Try again."))); } },
                    null, ThinkingWatchdog, Timeout.InfiniteTimeSpan);
                break;
            case VoiceEffectKind.CancelThinkingWatchdog:
                _watchdog?.Dispose();
                _watchdog = null;
                break;
            case VoiceEffectKind.Teardown:
                Teardown();
                break;
            case VoiceEffectKind.ShowError:
                Error = fx.Message;
                break;
            case VoiceEffectKind.RestartRecognizer:
            case VoiceEffectKind.AbortRecognizer:
            case VoiceEffectKind.OneShotFinished:
                // The server transcribes each turn; the on-device recogniser runs only in a words check.
                break;
        }
    }

    private async Task OpenAsync(int conn)
    {
        var url = VoiceSessionApi.SocketUrl(_origin());
        if (url == null) { Raise(VoiceEvent.Failed("Jarvis isn't connected to the server yet.")); return; }
        var sid = await _sessionId().ConfigureAwait(false);
        var socket = _newSocket();
        socket.Text += OnText;
        socket.Binary += OnBinary;
        socket.Closed += why => { lock (_sync) { if (_socket == socket && why != null) Run(_machine.Handle(VoiceEvent.Failed("The voice connection dropped."))); } };
        try
        {
            await socket.ConnectAsync(url, CancellationToken.None).ConfigureAwait(false);
        }
        catch (Exception e) when (e is IOException or OperationCanceledException or System.Net.WebSockets.WebSocketException or InvalidOperationException)
        {
            Raise(VoiceEvent.Failed("Couldn't reach Jarvis's voice."));
            return;
        }
        lock (_sync)
        {
            if (conn != _conn || !_machine.State.IsActive()) { _ = socket.CloseAsync(); return; }
            _socket = socket;
            _connected = true;
            _ = socket.SendTextAsync(new VoiceClientMessage.BeginTurn(SampleRate, sid, null, null, null, ClearStaleStream: true).Encoded());
            foreach (var chunk in _held) _ = socket.SendBinaryAsync(chunk);
            _held.Clear();
            _heldMs = 0;
            Run(_machine.Handle(VoiceEvent.Connected));
        }
    }

    private void Teardown()
    {
        var s = _socket;
        _socket = null;
        _conn++;
        _connected = false;
        _held.Clear();
        _heldMs = 0;
        _check = null;
        _recognizer?.End();
        _routes.End();
        if (s != null) _ = s.CloseAsync();
    }

    private void Send(string text)
    {
        if (_socket is { } s) _ = s.SendTextAsync(text);
    }

    private long NowMs() => _time.GetUtcNow().ToUnixTimeMilliseconds();

    // ── the mic ────────────────────────────────────────────────────────

    private void OnMicFrame(ReadOnlyMemory<short> frame)
    {
        lock (_sync)
        {
            if (!_machine.State.IsActive()) return;
            var bytes = MemoryMarshal.AsBytes(frame.Span).ToArray();
            var ms = frame.Length * 1000 / SampleRate;
            var amp = Endpointer.PeakAmplitude(bytes);
            InputLevel = amp;
            if (_connected && _socket != null) _ = _socket.SendBinaryAsync(bytes);
            else if (_heldMs + ms <= MaxHeldMs) { _held.Add(bytes); _heldMs += ms; }

            var state = _machine.State;
            if (state == VoiceState.Listening && !_machine.PushToTalk)
            {
                if (_endpointer.Update(amp, ms) == EndpointEvent.EndOfTurn) Run(_machine.Handle(VoiceEvent.EndOfSpeech));
            }
            else if (_machine.BargeInAllowed)
            {
                BargeFrame(frame, amp, ms);
            }
        }
    }

    private void BargeFrame(ReadOnlyMemory<short> frame, double amp, int ms)
    {
        // The canceller is still settling on the reply's first moments: that is echo, learn it.
        if (_player.PlayedMs - _playbackStartedPlayed < BargeInTuning.SettleMs)
        {
            _barge.NoteEcho(amp, ms);
            return;
        }
        if (_cooldown != null)
        {
            if (!_cooldown.Feed(amp >= _barge.Bar, ms)) return;
            _cooldown = null;
        }
        if (_check == null)
        {
            if (!_barge.Feed(amp, ms, learning: true)) return;
            _check = new WordsCheck(Reply, _barge.Bar);
            _player.SetVolume(BargeInTuning.DuckVolume);
            _recognizer?.Begin();
            Log?.Invoke("barge-in check opened");
        }
        _recognizer?.Feed(frame);
        switch (_check.Feed(amp, ms, _recognizer?.TakeLatest()))
        {
            case WordsCheck.Verdict.Interrupt:
                _check = null;
                _recognizer?.End();
                _barge.Reset();
                Run(_machine.Handle(VoiceEvent.BargeIn));
                break;
            case WordsCheck.Verdict.Release:
                CloseCheck();
                break;
            case WordsCheck.Verdict.GiveUp:
                CloseCheck();
                _cooldown = new QuietCooldown();
                break;
        }
    }

    private void CloseCheck()
    {
        _check = null;
        _recognizer?.End();
        _barge.Reset();
        _player.SetVolume(1f);
        Changed?.Invoke();
    }

    /// Test hook and the controller's own recogniser path: a recogniser result arriving between
    /// mic frames.
    internal void RecognizerSaid(string text)
    {
        lock (_sync)
        {
            if (_check == null) return;
            if (_check.Feed(0, 0, text) == WordsCheck.Verdict.Interrupt)
            {
                _check = null;
                _recognizer?.End();
                _barge.Reset();
                Run(_machine.Handle(VoiceEvent.BargeIn));
            }
        }
    }

    // ── the server ─────────────────────────────────────────────────────

    private void OnText(string json)
    {
        if (VoiceServerFrame.Decode(json) is not { } f) return;
        lock (_sync)
        {
            if (_postInterrupt.Drop(f, _time.GetUtcNow())) return;
            switch (f)
            {
                case VoiceServerFrame.Transcript t:
                    UserLine = t.Text;
                    Changed?.Invoke();
                    break;
                case VoiceServerFrame.AssistantText a:
                    Reply.AppendText(a.Text);
                    Run(_machine.Handle(VoiceEvent.ServerOutput));
                    break;
                case VoiceServerFrame.Tool:
                    Run(_machine.Handle(VoiceEvent.ServerOutput));
                    break;
                case VoiceServerFrame.AudioMeta m:
                    _format = m.Format;
                    _rate = m.SampleRate;
                    _segment = Reply.ClaimSegmentTag();
                    _segmentQueuedAt = _player.QueuedMs;
                    _segmentPlayedAt = _player.PlayedMs;
                    _clipStarted = false;
                    Run(_machine.Handle(VoiceEvent.ServerOutput));
                    break;
                case VoiceServerFrame.AudioEnd:
                    _player.EndSegment();
                    Reply.ClipStarted(_segment, (int)(_player.QueuedMs - _segmentQueuedAt), complete: true);
                    break;
                case VoiceServerFrame.EndTurnFrame e:
                    _machine.AwaitingFollowup = e.Followup;
                    Run(_machine.Handle(VoiceEvent.TurnEnded(e.Reason, producedReply: _turnHadAudio || !Reply.IsEmpty)));
                    break;
            }
        }
    }

    private void OnBinary(byte[] data)
    {
        lock (_sync)
        {
            if (_postInterrupt.Active && _postInterrupt.Drop(new VoiceServerFrame.Audio(data), _time.GetUtcNow())) return;
            if (_machine.DiscardingInterruptedTurn) return;
            _player.Enqueue(_format, _rate, data);
            _turnHadAudio = true;
            Reply.ClipStarted(_segment, (int)(_player.QueuedMs - _segmentQueuedAt), complete: false);
            if (!_clipStarted)
            {
                _clipStarted = true;
                if (_machine.State != VoiceState.Speaking)
                {
                    _playbackStartedPlayed = _player.PlayedMs;
                    _barge.Reset();
                }
                Run(_machine.Handle(VoiceEvent.PlaybackStarted));
            }
        }
    }

    /// The karaoke clock: called every ~50 ms while speaking (the Voice tab's render tick).
    public void KaraokeTick()
    {
        lock (_sync)
        {
            if (_segment == null) return;
            Reply.ClipPosition(_segment, (int)(_player.PlayedMs - _segmentPlayedAt));
        }
        Changed?.Invoke();
    }
}
