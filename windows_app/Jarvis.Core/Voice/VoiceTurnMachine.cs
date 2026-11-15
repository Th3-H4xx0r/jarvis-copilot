namespace Jarvis.Core.Voice;

// The voice turn FSM. A 1:1 port of ios_app/JarvisCopilot/Copilot/Voice/VoiceTurnMachine.swift,
// realtime mode (the phone's "quality" upload mode is not ported), plus the Mac app's push to talk
// (PushToTalk.swift): hold the talk key and Jarvis listens with the endpointer off, let go and the
// turn is sent, one answer, then it closes. Pure: no timers, no I/O; the controller raises events
// and performs the effects it gets back.

public enum VoiceState { Idle, Connecting, Listening, Thinking, Speaking, Error }

public static class VoiceStateExtensions
{
    /// True while a session is running.
    public static bool IsActive(this VoiceState s) => s != VoiceState.Idle && s != VoiceState.Error;
}

public enum VoiceEventKind
{
    /// The big button, in idle/error.
    StartRequested,
    /// Transport open: the mic can go live.
    Connected,
    /// The endpointer fired, or the user pressed "Done".
    EndOfSpeech,
    /// The server produced something for this turn (text, tool, or audio).
    ServerOutput,
    /// A clip began playing.
    PlaybackStarted,
    /// The playback queue drained.
    PlaybackDrained,
    /// The resume-grace window elapsed with nothing playing.
    ResumeGraceElapsed,
    /// Words over the reply (the words check said so).
    BargeIn,
    /// The user pressed "Interrupt".
    InterruptRequested,
    /// `end_turn` from the server. `ProducedReply` is false when the turn made neither audio nor
    /// reply text: only then is a failure reason surfaced.
    TurnEnded,
    Failed,
    /// The Stop button.
    StopRequested,
    /// A cut-off reply's `end_turn` never came; stop dropping server output.
    InterruptedTurnExpired,
    /// The push-to-talk key has been held long enough (TalkKeyLogic.Start).
    TalkKeyDown,
    /// The push-to-talk key came up after talking (TalkKeyLogic.Send).
    TalkKeyUp,
}

public sealed record VoiceEvent(VoiceEventKind Kind, string Reason = "", bool ProducedReply = false, string Message = "")
{
    public static readonly VoiceEvent StartRequested = new(VoiceEventKind.StartRequested);
    public static readonly VoiceEvent Connected = new(VoiceEventKind.Connected);
    public static readonly VoiceEvent EndOfSpeech = new(VoiceEventKind.EndOfSpeech);
    public static readonly VoiceEvent ServerOutput = new(VoiceEventKind.ServerOutput);
    public static readonly VoiceEvent PlaybackStarted = new(VoiceEventKind.PlaybackStarted);
    public static readonly VoiceEvent PlaybackDrained = new(VoiceEventKind.PlaybackDrained);
    public static readonly VoiceEvent ResumeGraceElapsed = new(VoiceEventKind.ResumeGraceElapsed);
    public static readonly VoiceEvent BargeIn = new(VoiceEventKind.BargeIn);
    public static readonly VoiceEvent InterruptRequested = new(VoiceEventKind.InterruptRequested);
    public static readonly VoiceEvent StopRequested = new(VoiceEventKind.StopRequested);
    public static readonly VoiceEvent InterruptedTurnExpired = new(VoiceEventKind.InterruptedTurnExpired);
    public static readonly VoiceEvent TalkKeyDown = new(VoiceEventKind.TalkKeyDown);
    public static readonly VoiceEvent TalkKeyUp = new(VoiceEventKind.TalkKeyUp);

    public static VoiceEvent TurnEnded(string reason, bool producedReply) =>
        new(VoiceEventKind.TurnEnded, Reason: reason, ProducedReply: producedReply);

    public static VoiceEvent Failed(string message) => new(VoiceEventKind.Failed, Message: message);
}

public enum VoiceEffectKind
{
    OpenTransport,
    StartMic,
    /// `end_turn` over the socket.
    SendEndTurn,
    SendInterrupt,
    StopPlayback,
    /// Re-arm the on-device recogniser for the next utterance.
    RestartRecognizer,
    AbortRecognizer,
    ScheduleResume,
    /// The server ended the turn: listen again now, unless audio is still on its way to the speaker
    /// (then its drain does it).
    ResumeWhenQuiet,
    CancelResume,
    ArmThinkingWatchdog,
    CancelThinkingWatchdog,
    /// Clear the reply text and karaoke highlight.
    ClearReply,
    /// Light up any words the position stream didn't reach.
    FinalizeSpoken,
    ResetEndpointer,
    /// Invalidate any in-flight per-turn async work.
    NewTurnEpoch,
    /// Note the moment the user stopped talking (latency spans).
    MarkSpeechEnd,
    /// Close the socket and release the mic and audio.
    Teardown,
    /// A one-shot turn has answered and closed itself.
    OneShotFinished,
    ShowError,
}

public sealed record VoiceEffect(VoiceEffectKind Kind, string Message = "")
{
    public static readonly VoiceEffect OpenTransport = new(VoiceEffectKind.OpenTransport);
    public static readonly VoiceEffect StartMic = new(VoiceEffectKind.StartMic);
    public static readonly VoiceEffect SendEndTurn = new(VoiceEffectKind.SendEndTurn);
    public static readonly VoiceEffect SendInterrupt = new(VoiceEffectKind.SendInterrupt);
    public static readonly VoiceEffect StopPlayback = new(VoiceEffectKind.StopPlayback);
    public static readonly VoiceEffect RestartRecognizer = new(VoiceEffectKind.RestartRecognizer);
    public static readonly VoiceEffect AbortRecognizer = new(VoiceEffectKind.AbortRecognizer);
    public static readonly VoiceEffect ScheduleResume = new(VoiceEffectKind.ScheduleResume);
    public static readonly VoiceEffect ResumeWhenQuiet = new(VoiceEffectKind.ResumeWhenQuiet);
    public static readonly VoiceEffect CancelResume = new(VoiceEffectKind.CancelResume);
    public static readonly VoiceEffect ArmThinkingWatchdog = new(VoiceEffectKind.ArmThinkingWatchdog);
    public static readonly VoiceEffect CancelThinkingWatchdog = new(VoiceEffectKind.CancelThinkingWatchdog);
    public static readonly VoiceEffect ClearReply = new(VoiceEffectKind.ClearReply);
    public static readonly VoiceEffect FinalizeSpoken = new(VoiceEffectKind.FinalizeSpoken);
    public static readonly VoiceEffect ResetEndpointer = new(VoiceEffectKind.ResetEndpointer);
    public static readonly VoiceEffect NewTurnEpoch = new(VoiceEffectKind.NewTurnEpoch);
    public static readonly VoiceEffect MarkSpeechEnd = new(VoiceEffectKind.MarkSpeechEnd);
    public static readonly VoiceEffect Teardown = new(VoiceEffectKind.Teardown);
    public static readonly VoiceEffect OneShotFinished = new(VoiceEffectKind.OneShotFinished);

    public static VoiceEffect ShowError(string message) => new(VoiceEffectKind.ShowError, message);
}

public sealed class VoiceTurnMachine
{
    /// The server reports every turn outcome as `end_turn{reason}`; these two mean it failed.
    /// `no_speech`/`empty`/`interrupt` are benign, so we stay silent there.
    public static readonly IReadOnlySet<string> FailureReasons = new HashSet<string> { "error", "no_reply" };

    private static readonly IReadOnlyList<VoiceEffect> None = Array.Empty<VoiceEffect>();

    public VoiceState State { get; private set; } = VoiceState.Idle;
    /// Set as soon as the server produces anything for this turn. Barge-in during "thinking" is only
    /// allowed once this is true.
    public bool ServerProducedOutput { get; private set; }
    /// `end_turn` was sent and the server hasn't answered with its own end of turn yet. While it is
    /// open, playback draining (an acknowledgement, a sentence before a long tool run) must not resume
    /// listening.
    public bool ServerTurnOpen { get; private set; }
    /// The user cut a reply off before the server had finished sending it: everything the server sends
    /// is dropped until that turn's own `end_turn`.
    public bool DiscardingInterruptedTurn { get; private set; }
    /// The server has ended the current turn; once its audio has played there is nothing to wait for.
    public bool ServerTurnDone { get; private set; }
    /// One answer, then stop: where a session would listen again after the reply, it closes instead.
    public bool OneShot { get; set; }
    /// A one-shot turn's server said "On it" and handed the work off: don't close on the ack.
    public bool AwaitingFollowup { get; set; }
    /// This one-shot turn got an answer.
    public bool OneShotAnswered { get; private set; }
    /// This one-shot turn's reply asked him something: listen for that one answer instead of closing.
    public bool ReplyAsks { get; set; }
    /// The talk key is held: he is still talking, so the endpointer's EndOfSpeech is ignored and
    /// the controller doesn't feed it. Letting go sends the turn.
    public bool PushToTalk { get; private set; }
    /// The key came up before the socket opened: send the turn as soon as it does (the audio said
    /// while connecting is held and flushed first).
    public bool SendOnConnect { get; private set; }

    /// Barge-in is allowed while speaking, and while thinking mid-reply once the server has started
    /// answering. A one-shot turn never takes it.
    public bool BargeInAllowed =>
        !OneShot && (State == VoiceState.Speaking || (State == VoiceState.Thinking && ServerProducedOutput));

    private bool TakeTheQuestionsAnswer()
    {
        if (!ReplyAsks || AwaitingFollowup) return false;
        ReplyAsks = false;
        OneShotAnswered = false;
        return true;
    }

    private IReadOnlyList<VoiceEffect> FinishOneShot()
    {
        ReplyAsks = false;
        OneShot = false;
        AwaitingFollowup = false;
        OneShotAnswered = false;
        State = VoiceState.Idle;
        return new[]
        {
            VoiceEffect.CancelResume, VoiceEffect.CancelThinkingWatchdog, VoiceEffect.FinalizeSpoken,
            VoiceEffect.NewTurnEpoch, VoiceEffect.AbortRecognizer, VoiceEffect.Teardown, VoiceEffect.OneShotFinished,
        };
    }

    /// Listening, then thinking: the turn goes to the server.
    private IReadOnlyList<VoiceEffect> EndTurn()
    {
        OneShotAnswered = false;
        ServerProducedOutput = false;
        ServerTurnDone = false;
        State = VoiceState.Thinking;
        ServerTurnOpen = true;
        return new[]
        {
            VoiceEffect.CancelResume, VoiceEffect.ResetEndpointer, VoiceEffect.ClearReply, VoiceEffect.NewTurnEpoch,
            VoiceEffect.MarkSpeechEnd, VoiceEffect.SendEndTurn, VoiceEffect.ArmThinkingWatchdog,
        };
    }

    public IReadOnlyList<VoiceEffect> Handle(VoiceEvent e)
    {
        switch (e.Kind)
        {
            case VoiceEventKind.StartRequested:
                if (State.IsActive()) return None;
                OneShotAnswered = false;
                ReplyAsks = false;
                ServerProducedOutput = false;
                DiscardingInterruptedTurn = false;
                ServerTurnDone = false;
                State = VoiceState.Connecting;
                // The mic and the recogniser start with the transport: audio said while connecting is
                // held and sent once the socket is up.
                return new[]
                {
                    VoiceEffect.ClearReply, VoiceEffect.ResetEndpointer, VoiceEffect.NewTurnEpoch, VoiceEffect.StopPlayback,
                    VoiceEffect.OpenTransport, VoiceEffect.StartMic, VoiceEffect.RestartRecognizer,
                };

            case VoiceEventKind.Connected:
                if (State != VoiceState.Connecting) return None;
                State = VoiceState.Listening;
                if (SendOnConnect)
                {
                    SendOnConnect = false;
                    return new[] { VoiceEffect.RestartRecognizer }.Concat(EndTurn()).ToList();
                }
                return new[] { VoiceEffect.RestartRecognizer };

            case VoiceEventKind.TalkKeyDown:
                SendOnConnect = false;
                if (!State.IsActive())
                {
                    // A fresh push-to-talk turn: one answer, then close (the Mac's small voice island).
                    var start = Handle(VoiceEvent.StartRequested);
                    OneShot = true;
                    PushToTalk = true;
                    return start;
                }
                PushToTalk = true;
                if (State is VoiceState.Speaking or VoiceState.Thinking)
                {
                    // Holding the key over a reply is the plainest barge-in there is.
                    DiscardingInterruptedTurn = ServerTurnOpen;
                    ServerTurnOpen = false;
                    State = VoiceState.Listening;
                    return new[]
                    {
                        VoiceEffect.CancelResume, VoiceEffect.CancelThinkingWatchdog, VoiceEffect.NewTurnEpoch, VoiceEffect.SendInterrupt,
                        VoiceEffect.StopPlayback, VoiceEffect.ResetEndpointer, VoiceEffect.AbortRecognizer, VoiceEffect.RestartRecognizer,
                    };
                }
                // Listening or connecting: keep going; the endpointer is off while it is held.
                return new[] { VoiceEffect.CancelResume, VoiceEffect.ResetEndpointer };

            case VoiceEventKind.TalkKeyUp:
                if (!PushToTalk) return None;
                PushToTalk = false;
                if (State == VoiceState.Connecting) { SendOnConnect = true; return None; }
                return State == VoiceState.Listening ? EndTurn() : None;

            case VoiceEventKind.EndOfSpeech:
                if (State != VoiceState.Listening || PushToTalk) return None;
                return EndTurn();

            case VoiceEventKind.ServerOutput:
            {
                if (DiscardingInterruptedTurn) return None;
                ServerProducedOutput = true;
                OneShotAnswered = true;
                var effects = new[] { VoiceEffect.CancelResume, VoiceEffect.CancelThinkingWatchdog };
                if (!State.IsActive()) return effects;
                // Keep the orb off "listening" while the reply is mid-flight; playback flips to speaking.
                if (State != VoiceState.Speaking) State = VoiceState.Thinking;
                return effects;
            }

            case VoiceEventKind.PlaybackStarted:
            {
                if (DiscardingInterruptedTurn) return None;
                OneShotAnswered = true;
                var effects = new[] { VoiceEffect.CancelResume, VoiceEffect.CancelThinkingWatchdog };
                if (State == VoiceState.Idle || State == VoiceState.Error) return effects;
                State = VoiceState.Speaking;
                return effects;
            }

            case VoiceEventKind.PlaybackDrained:
                if (!State.IsActive()) return None;
                if (State == VoiceState.Speaking) State = VoiceState.Thinking;
                // The server is still on this turn: stay in thinking; TurnEnded resumes.
                if (ServerTurnOpen) return new[] { VoiceEffect.CancelResume, VoiceEffect.ArmThinkingWatchdog };
                // The turn is over and its reply has played: listen now.
                if (ServerTurnDone && State == VoiceState.Thinking)
                {
                    if (OneShot && OneShotAnswered && !TakeTheQuestionsAnswer())
                        return AwaitingFollowup ? new[] { VoiceEffect.CancelResume } : FinishOneShot();
                    State = VoiceState.Listening;
                    return new[] { VoiceEffect.CancelResume, VoiceEffect.FinalizeSpoken, VoiceEffect.ResetEndpointer, VoiceEffect.RestartRecognizer };
                }
                return new[] { VoiceEffect.ScheduleResume };

            case VoiceEventKind.ResumeGraceElapsed:
                if (!State.IsActive()) return None;
                // A resume timer left over from before the turn opened must not hand the mic back mid-reply.
                if (ServerTurnOpen) return None;
                if (OneShot && OneShotAnswered && !TakeTheQuestionsAnswer())
                    return AwaitingFollowup ? None : FinishOneShot();
                State = VoiceState.Listening;
                return new[] { VoiceEffect.FinalizeSpoken, VoiceEffect.ResetEndpointer, VoiceEffect.RestartRecognizer };

            case VoiceEventKind.BargeIn:
                if (!BargeInAllowed) return None;
                DiscardingInterruptedTurn = ServerTurnOpen;
                ServerTurnOpen = false;
                State = VoiceState.Listening;
                return new[]
                {
                    VoiceEffect.SendInterrupt, VoiceEffect.StopPlayback, VoiceEffect.CancelResume, VoiceEffect.ResetEndpointer,
                    VoiceEffect.AbortRecognizer, VoiceEffect.RestartRecognizer,
                };

            case VoiceEventKind.InterruptRequested:
                if (State != VoiceState.Speaking && State != VoiceState.Thinking) return None;
                DiscardingInterruptedTurn = ServerTurnOpen;
                ServerTurnOpen = false;
                State = VoiceState.Listening;
                return new[]
                {
                    VoiceEffect.CancelResume, VoiceEffect.CancelThinkingWatchdog, VoiceEffect.NewTurnEpoch, VoiceEffect.SendInterrupt,
                    VoiceEffect.StopPlayback, VoiceEffect.ResetEndpointer, VoiceEffect.AbortRecognizer, VoiceEffect.RestartRecognizer,
                };

            case VoiceEventKind.TurnEnded:
            {
                if (DiscardingInterruptedTurn)
                {
                    // The cut-off turn, over. A question asked since then is a different turn, still open.
                    DiscardingInterruptedTurn = false;
                    return None;
                }
                ServerTurnOpen = false;
                ServerTurnDone = true;
                if (e.ProducedReply) OneShotAnswered = true;
                var effects = new List<VoiceEffect> { VoiceEffect.CancelThinkingWatchdog };
                if (!State.IsActive()) return effects;
                if (FailureReasons.Contains(e.Reason) && !e.ProducedReply)
                {
                    effects.Add(VoiceEffect.ShowError(e.Reason == "no_reply"
                        ? "I didn't catch a reply — please try again."
                        : "Something went wrong — please try again."));
                }
                // Still speaking the reply's tail: PlaybackDrained resumes once the audio is out.
                if (State == VoiceState.Thinking) effects.Add(VoiceEffect.ResumeWhenQuiet);
                else if (State != VoiceState.Speaking) effects.Add(VoiceEffect.ScheduleResume);
                return effects;
            }

            case VoiceEventKind.Failed:
                PushToTalk = false;
                SendOnConnect = false;
                OneShot = false;
                AwaitingFollowup = false;
                ServerTurnOpen = false;
                DiscardingInterruptedTurn = false;
                State = VoiceState.Error;
                return new[]
                {
                    VoiceEffect.CancelResume, VoiceEffect.CancelThinkingWatchdog, VoiceEffect.AbortRecognizer,
                    VoiceEffect.Teardown, VoiceEffect.StopPlayback, VoiceEffect.ShowError(e.Message),
                };

            case VoiceEventKind.StopRequested:
                PushToTalk = false;
                SendOnConnect = false;
                OneShot = false;
                AwaitingFollowup = false;
                ReplyAsks = false;
                ServerTurnOpen = false;
                DiscardingInterruptedTurn = false;
                State = State == VoiceState.Error ? VoiceState.Error : VoiceState.Idle;
                // Keep the reply on screen after Stop: don't erase it and don't finalize it.
                return new[]
                {
                    VoiceEffect.CancelResume, VoiceEffect.CancelThinkingWatchdog, VoiceEffect.NewTurnEpoch,
                    VoiceEffect.AbortRecognizer, VoiceEffect.Teardown, VoiceEffect.StopPlayback,
                };

            case VoiceEventKind.InterruptedTurnExpired:
                DiscardingInterruptedTurn = false;
                return None;

            default:
                return None;
        }
    }
}
