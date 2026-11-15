using Jarvis.Core.Voice;
using E = Jarvis.Core.Voice.VoiceEffect;
using Ev = Jarvis.Core.Voice.VoiceEvent;

namespace Jarvis.Tests.Voice;

/// The turn FSM, realtime mode (port of VoiceTurnMachineTests.swift; the push-to-talk cases are not ported).
public class VoiceTurnMachineTests
{
    private static VoiceTurnMachine Listening()
    {
        var m = new VoiceTurnMachine();
        m.Handle(Ev.StartRequested);
        m.Handle(Ev.Connected);
        return m;
    }

    private static bool HasShowError(IReadOnlyList<E> effects) => effects.Any(e => e.Kind == VoiceEffectKind.ShowError);

    // Realtime happy path.

    [Fact]
    public void RealtimeWalksIdleToListeningToThinkingToSpeakingAndBack()
    {
        var m = new VoiceTurnMachine();
        Assert.Equal(VoiceState.Idle, m.State);

        var start = m.Handle(Ev.StartRequested);
        Assert.Equal(VoiceState.Connecting, m.State);
        Assert.Contains(E.OpenTransport, start);
        Assert.Contains(E.ClearReply, start);
        Assert.Contains(E.StartMic, start);
        Assert.Contains(E.RestartRecognizer, start);

        var connected = m.Handle(Ev.Connected);
        Assert.Equal(VoiceState.Listening, m.State);
        Assert.DoesNotContain(E.StartMic, connected);

        var ended = m.Handle(Ev.EndOfSpeech);
        Assert.Equal(VoiceState.Thinking, m.State);
        Assert.Contains(E.SendEndTurn, ended);
        Assert.Contains(E.ArmThinkingWatchdog, ended);
        Assert.Contains(E.MarkSpeechEnd, ended);
        Assert.Contains(E.ClearReply, ended);

        m.Handle(Ev.ServerOutput);
        Assert.Equal(VoiceState.Thinking, m.State);

        var playing = m.Handle(Ev.PlaybackStarted);
        Assert.Equal(VoiceState.Speaking, m.State);
        Assert.Contains(E.CancelResume, playing);
        Assert.Contains(E.CancelThinkingWatchdog, playing);

        var drained = m.Handle(Ev.PlaybackDrained);
        Assert.Equal(VoiceState.Thinking, m.State);
        Assert.Equal(new[] { E.CancelResume, E.ArmThinkingWatchdog }, drained);
        Assert.Empty(m.Handle(Ev.ResumeGraceElapsed));
        Assert.Equal(VoiceState.Thinking, m.State);

        var ended2 = m.Handle(Ev.TurnEnded("done", true));
        Assert.Contains(E.ResumeWhenQuiet, ended2);
        Assert.DoesNotContain(E.ScheduleResume, ended2);

        var resumed = m.Handle(Ev.ResumeGraceElapsed);
        Assert.Equal(VoiceState.Listening, m.State);
        Assert.Contains(E.FinalizeSpoken, resumed);
        Assert.Contains(E.RestartRecognizer, resumed);
    }

    [Fact]
    public void StartIsIgnoredWhileASessionIsAlreadyRunning()
    {
        var m = Listening();
        Assert.Empty(m.Handle(Ev.StartRequested));
        Assert.Equal(VoiceState.Listening, m.State);
    }

    [Fact]
    public void ConnectedOutsideConnectingIsIgnored()
    {
        var m = new VoiceTurnMachine();
        Assert.Empty(m.Handle(Ev.Connected));
        Assert.Equal(VoiceState.Idle, m.State);
    }

    [Fact]
    public void EndOfSpeechOnlyFiresFromListening()
    {
        var m = new VoiceTurnMachine();
        m.Handle(Ev.StartRequested);
        Assert.Empty(m.Handle(Ev.EndOfSpeech));
        m.Handle(Ev.Connected);
        m.Handle(Ev.EndOfSpeech);
        Assert.Empty(m.Handle(Ev.EndOfSpeech));
    }

    // Barge-in.

    [Fact]
    public void BargeInIsAllowedWhileSpeaking()
    {
        var m = Listening();
        m.Handle(Ev.EndOfSpeech);
        m.Handle(Ev.PlaybackStarted);
        Assert.True(m.BargeInAllowed);

        var effects = m.Handle(Ev.BargeIn);
        Assert.Equal(VoiceState.Listening, m.State);
        Assert.Contains(E.SendInterrupt, effects);
        Assert.Contains(E.StopPlayback, effects);
        Assert.Contains(E.ResetEndpointer, effects);
        Assert.Contains(E.RestartRecognizer, effects);
    }

    [Fact]
    public void BargeInIsAllowedWhileThinkingOnlyAfterTheServerHasStartedAnswering()
    {
        var m = Listening();
        m.Handle(Ev.EndOfSpeech);
        Assert.False(m.BargeInAllowed);
        Assert.Empty(m.Handle(Ev.BargeIn));
        Assert.Equal(VoiceState.Thinking, m.State);

        m.Handle(Ev.ServerOutput);
        Assert.True(m.BargeInAllowed);
        Assert.NotEmpty(m.Handle(Ev.BargeIn));
        Assert.Equal(VoiceState.Listening, m.State);
    }

    [Fact]
    public void AReplyCutOffMidStreamStaysCutOff()
    {
        var m = Listening();
        m.Handle(Ev.EndOfSpeech);
        m.Handle(Ev.PlaybackStarted);
        m.Handle(Ev.BargeIn);
        Assert.True(m.DiscardingInterruptedTurn);

        Assert.Empty(m.Handle(Ev.ServerOutput));
        Assert.Empty(m.Handle(Ev.PlaybackStarted));
        Assert.Equal(VoiceState.Listening, m.State);

        Assert.Empty(m.Handle(Ev.TurnEnded("", true)));
        Assert.False(m.DiscardingInterruptedTurn);
        Assert.Equal(VoiceState.Listening, m.State);

        m.Handle(Ev.ServerOutput);
        Assert.Equal(VoiceState.Thinking, m.State);
    }

    [Fact]
    public void TheInterruptButtonDropsTheRestOfTheReplyToo()
    {
        var m = Listening();
        m.Handle(Ev.EndOfSpeech);
        m.Handle(Ev.PlaybackStarted);
        m.Handle(Ev.InterruptRequested);
        Assert.True(m.DiscardingInterruptedTurn);
        Assert.Empty(m.Handle(Ev.PlaybackStarted));
        Assert.Equal(VoiceState.Listening, m.State);
    }

    [Fact]
    public void ANewTurnStartedBeforeTheOldEndTurnArrivesSurvivesIt()
    {
        var m = Listening();
        m.Handle(Ev.EndOfSpeech);
        m.Handle(Ev.PlaybackStarted);
        m.Handle(Ev.BargeIn);
        m.Handle(Ev.EndOfSpeech);
        Assert.Equal(VoiceState.Thinking, m.State);

        m.Handle(Ev.TurnEnded("interrupt", true));
        Assert.Equal(VoiceState.Thinking, m.State);
        Assert.True(m.ServerTurnOpen);

        m.Handle(Ev.ServerOutput);
        m.Handle(Ev.PlaybackStarted);
        Assert.Equal(VoiceState.Speaking, m.State);
    }

    [Fact]
    public void NothingIsDroppedWhenTheInterruptedTurnHadAlreadyEnded()
    {
        var m = Listening();
        m.Handle(Ev.EndOfSpeech);
        m.Handle(Ev.PlaybackStarted);
        m.Handle(Ev.TurnEnded("", true));
        m.Handle(Ev.BargeIn);
        Assert.False(m.DiscardingInterruptedTurn);
    }

    [Fact]
    public void DroppingGivesUpIfTheEndTurnNeverComes()
    {
        var m = Listening();
        m.Handle(Ev.EndOfSpeech);
        m.Handle(Ev.PlaybackStarted);
        m.Handle(Ev.BargeIn);
        m.Handle(Ev.InterruptedTurnExpired);
        Assert.False(m.DiscardingInterruptedTurn);
        m.Handle(Ev.ServerOutput);
        Assert.Equal(VoiceState.Thinking, m.State);
    }

    [Fact]
    public void BargeInIsIgnoredWhileListening()
    {
        var m = Listening();
        Assert.False(m.BargeInAllowed);
        Assert.Empty(m.Handle(Ev.BargeIn));
        Assert.Equal(VoiceState.Listening, m.State);
    }

    [Fact]
    public void ANewTurnClearsTheServerOutputFlag()
    {
        var m = Listening();
        m.Handle(Ev.EndOfSpeech);
        m.Handle(Ev.ServerOutput);
        m.Handle(Ev.PlaybackStarted);
        m.Handle(Ev.PlaybackDrained);
        m.Handle(Ev.TurnEnded("done", true));
        m.Handle(Ev.ResumeGraceElapsed);
        m.Handle(Ev.EndOfSpeech);
        Assert.False(m.ServerProducedOutput);
        Assert.False(m.BargeInAllowed);
    }

    // Interrupt (the button).

    [Fact]
    public void InterruptFromSpeakingReturnsToListening()
    {
        var m = Listening();
        m.Handle(Ev.EndOfSpeech);
        m.Handle(Ev.PlaybackStarted);

        var effects = m.Handle(Ev.InterruptRequested);
        Assert.Equal(VoiceState.Listening, m.State);
        Assert.Contains(E.SendInterrupt, effects);
        Assert.Contains(E.StopPlayback, effects);
        Assert.Contains(E.NewTurnEpoch, effects);
        Assert.Contains(E.CancelThinkingWatchdog, effects);
    }

    [Fact]
    public void InterruptWorksMidThinkingButNotWhileListeningOrIdle()
    {
        var thinking = Listening();
        thinking.Handle(Ev.EndOfSpeech);
        Assert.NotEmpty(thinking.Handle(Ev.InterruptRequested));

        Assert.Empty(new VoiceTurnMachine().Handle(Ev.InterruptRequested));
        Assert.Empty(Listening().Handle(Ev.InterruptRequested));
    }

    // Cancel / stop.

    [Fact]
    public void StopTearsDownAndReturnsToIdleWithoutFinalizing()
    {
        var m = Listening();
        m.Handle(Ev.EndOfSpeech);
        m.Handle(Ev.PlaybackStarted);

        var effects = m.Handle(Ev.StopRequested);
        Assert.Equal(VoiceState.Idle, m.State);
        Assert.Contains(E.Teardown, effects);
        Assert.Contains(E.StopPlayback, effects);
        Assert.Contains(E.NewTurnEpoch, effects);
        Assert.DoesNotContain(E.ClearReply, effects);
        Assert.DoesNotContain(E.FinalizeSpoken, effects);
    }

    [Fact]
    public void StopFromErrorStaysInErrorSoTheMessageSurvives()
    {
        var m = Listening();
        m.Handle(Ev.Failed("boom"));
        m.Handle(Ev.StopRequested);
        Assert.Equal(VoiceState.Error, m.State);
    }

    [Fact]
    public void ResumeGraceDoesNothingOnceStopped()
    {
        var m = Listening();
        m.Handle(Ev.StopRequested);
        Assert.Empty(m.Handle(Ev.ResumeGraceElapsed));
        Assert.Equal(VoiceState.Idle, m.State);
    }

    // Errors.

    [Fact]
    public void FailureEntersErrorAndTearsDown()
    {
        var m = Listening();
        var effects = m.Handle(Ev.Failed("Could not start voice"));
        Assert.Equal(VoiceState.Error, m.State);
        Assert.Contains(E.ShowError("Could not start voice"), effects);
        Assert.Contains(E.Teardown, effects);
        Assert.Contains(E.StopPlayback, effects);
        Assert.Contains(E.AbortRecognizer, effects);
    }

    [Fact]
    public void ErrorIsRecoverableWithAFreshStart()
    {
        var m = Listening();
        m.Handle(Ev.Failed("boom"));
        var start = m.Handle(Ev.StartRequested);
        Assert.Equal(VoiceState.Connecting, m.State);
        Assert.Contains(E.ClearReply, start);
    }

    [Fact]
    public void AFailedTurnReasonSurfacesAMessageAndKeepsTheConversation()
    {
        var m = Listening();
        m.Handle(Ev.EndOfSpeech);
        var effects = m.Handle(Ev.TurnEnded("no_reply", false));
        Assert.Equal(VoiceState.Thinking, m.State);
        Assert.Contains(E.ShowError("I didn't catch a reply — please try again."), effects);
        Assert.Contains(E.ResumeWhenQuiet, effects);

        var other = Listening();
        other.Handle(Ev.EndOfSpeech);
        Assert.Contains(E.ShowError("Something went wrong — please try again."), other.Handle(Ev.TurnEnded("error", false)));
    }

    [Theory]
    [InlineData("")]
    [InlineData("no_speech")]
    [InlineData("empty")]
    [InlineData("interrupt")]
    [InlineData("ok")]
    public void BenignTurnEndReasonsAreSilent(string reason)
    {
        var m = Listening();
        m.Handle(Ev.EndOfSpeech);
        var effects = m.Handle(Ev.TurnEnded(reason, false));
        Assert.False(HasShowError(effects));
        Assert.Contains(E.ResumeWhenQuiet, effects);
    }

    [Fact]
    public void AFailureReasonIsNotSurfacedWhenTheTurnActuallyProducedAReply()
    {
        var m = Listening();
        m.Handle(Ev.EndOfSpeech);
        Assert.False(HasShowError(m.Handle(Ev.TurnEnded("error", true))));
    }

    [Fact]
    public void TurnEndedWhileIdleOnlyCancelsTheWatchdog() =>
        Assert.Equal(new[] { E.CancelThinkingWatchdog }, new VoiceTurnMachine().Handle(Ev.TurnEnded("error", false)));

    [Fact]
    public void FailureReasonsAreErrorAndNoReply() =>
        Assert.True(VoiceTurnMachine.FailureReasons.SetEquals(new[] { "error", "no_reply" }));

    // Resume rules.

    [Fact]
    public void AnAcknowledgementDoesNotResumeListeningMidTurn()
    {
        var m = new VoiceTurnMachine();
        m.Handle(Ev.StartRequested); m.Handle(Ev.Connected); m.Handle(Ev.EndOfSpeech);
        m.Handle(Ev.ServerOutput); m.Handle(Ev.PlaybackStarted);
        Assert.Equal(VoiceState.Speaking, m.State);
        m.Handle(Ev.PlaybackDrained);
        Assert.Equal(VoiceState.Thinking, m.State);
        Assert.Empty(m.Handle(Ev.ResumeGraceElapsed));
        m.Handle(Ev.ServerOutput); m.Handle(Ev.PlaybackStarted);
        var ended = m.Handle(Ev.TurnEnded("done", true));
        Assert.DoesNotContain(E.ScheduleResume, ended);
        Assert.Equal(VoiceState.Speaking, m.State);
        var drained = m.Handle(Ev.PlaybackDrained);
        Assert.Equal(VoiceState.Listening, m.State);
        Assert.Equal(new[] { E.CancelResume, E.FinalizeSpoken, E.ResetEndpointer, E.RestartRecognizer }, drained);
    }

    [Fact]
    public void AReplyThatHasEndedAndPlayedListensAtOnce()
    {
        var m = Listening();
        m.Handle(Ev.EndOfSpeech);
        m.Handle(Ev.ServerOutput); m.Handle(Ev.PlaybackStarted);
        m.Handle(Ev.TurnEnded("done", true));
        m.Handle(Ev.PlaybackDrained);
        Assert.Equal(VoiceState.Listening, m.State);
    }

    [Fact]
    public void ADrainWithNoServerTurnStillWaitsOutTheGrace()
    {
        var m = Listening();
        m.Handle(Ev.ServerOutput); m.Handle(Ev.PlaybackStarted);
        Assert.Equal(new[] { E.ScheduleResume }, m.Handle(Ev.PlaybackDrained));
        Assert.Equal(VoiceState.Thinking, m.State);
    }

    [Fact]
    public void ANewTurnForgetsThatTheLastOneEnded()
    {
        var m = Listening();
        m.Handle(Ev.EndOfSpeech);
        m.Handle(Ev.TurnEnded("done", true));
        m.Handle(Ev.ResumeGraceElapsed);
        m.Handle(Ev.EndOfSpeech);
        m.Handle(Ev.ServerOutput); m.Handle(Ev.PlaybackStarted);
        Assert.Equal(new[] { E.CancelResume, E.ArmThinkingWatchdog }, m.Handle(Ev.PlaybackDrained));
        Assert.Equal(VoiceState.Thinking, m.State);
    }

    // One-shot.

    private static void OneShotThroughReply(VoiceTurnMachine m)
    {
        m.OneShot = true;
        m.Handle(Ev.StartRequested); m.Handle(Ev.Connected);
        m.Handle(Ev.EndOfSpeech); m.Handle(Ev.ServerOutput); m.Handle(Ev.PlaybackStarted);
        m.Handle(Ev.TurnEnded("done", true));
    }

    [Fact]
    public void OneShotStopsAfterReplyInsteadOfListening()
    {
        var m = new VoiceTurnMachine();
        OneShotThroughReply(m);
        var drained = m.Handle(Ev.PlaybackDrained);
        Assert.Equal(VoiceState.Idle, m.State);
        Assert.Contains(E.Teardown, drained);
        Assert.Contains(E.OneShotFinished, drained);
        Assert.DoesNotContain(E.RestartRecognizer, drained);
        Assert.False(m.OneShot);
    }

    [Fact]
    public void OneShotWhoseReplyAsksListensForOneMoreAnswer()
    {
        var m = new VoiceTurnMachine();
        OneShotThroughReply(m);
        m.ReplyAsks = true;
        m.Handle(Ev.PlaybackDrained);
        Assert.Equal(VoiceState.Listening, m.State);
        Assert.True(m.OneShot);
        m.Handle(Ev.EndOfSpeech); m.Handle(Ev.ServerOutput); m.Handle(Ev.PlaybackStarted);
        m.Handle(Ev.TurnEnded("done", true));
        var drained = m.Handle(Ev.PlaybackDrained);
        Assert.Equal(VoiceState.Idle, m.State);
        Assert.Contains(E.OneShotFinished, drained);
    }

    [Fact]
    public void OneShotWhoseReplyAsksAlsoListensAfterTheResumeGrace()
    {
        var m = new VoiceTurnMachine { OneShot = true };
        m.Handle(Ev.StartRequested); m.Handle(Ev.Connected); m.Handle(Ev.EndOfSpeech);
        m.Handle(Ev.ServerOutput);
        m.Handle(Ev.TurnEnded("done", true));
        m.ReplyAsks = true;
        m.Handle(Ev.ResumeGraceElapsed);
        Assert.Equal(VoiceState.Listening, m.State);
    }

    [Fact]
    public void OneShotResumeGraceEndsTurn()
    {
        var m = new VoiceTurnMachine { OneShot = true };
        m.Handle(Ev.StartRequested); m.Handle(Ev.Connected); m.Handle(Ev.EndOfSpeech);
        m.Handle(Ev.ServerOutput);
        Assert.Contains(E.ResumeWhenQuiet, m.Handle(Ev.TurnEnded("done", true)));
        var resumed = m.Handle(Ev.ResumeGraceElapsed);
        Assert.Equal(VoiceState.Idle, m.State);
        Assert.Contains(E.OneShotFinished, resumed);
        Assert.Contains(E.Teardown, resumed);
    }

    [Fact]
    public void OneShotWithoutAnAnswerListensAgain()
    {
        var m = new VoiceTurnMachine { OneShot = true };
        m.Handle(Ev.StartRequested); m.Handle(Ev.Connected); m.Handle(Ev.EndOfSpeech);
        m.Handle(Ev.TurnEnded("no_speech", false));
        m.Handle(Ev.ResumeGraceElapsed);
        Assert.Equal(VoiceState.Listening, m.State);
        Assert.True(m.OneShot);
    }

    [Fact]
    public void OneShotWaitsForAHandedOffAnswer()
    {
        var m = new VoiceTurnMachine();
        OneShotThroughReply(m);
        m.AwaitingFollowup = true;
        var drained = m.Handle(Ev.PlaybackDrained);
        Assert.Equal(VoiceState.Thinking, m.State);
        Assert.DoesNotContain(E.Teardown, drained);
        Assert.Empty(m.Handle(Ev.ResumeGraceElapsed));
        m.AwaitingFollowup = false;
        m.Handle(Ev.ServerOutput); m.Handle(Ev.PlaybackStarted);
        Assert.Contains(E.OneShotFinished, m.Handle(Ev.PlaybackDrained));
        Assert.Equal(VoiceState.Idle, m.State);
    }

    [Fact]
    public void NormalRealtimeStillListensAgain()
    {
        var m = new VoiceTurnMachine();
        OneShotThroughReply(m);
        m.OneShot = false;
        m.Handle(Ev.PlaybackDrained);
        Assert.Equal(VoiceState.Listening, m.State);
    }

    [Fact]
    public void OneShotIgnoresBargeIn()
    {
        var m = new VoiceTurnMachine();
        OneShotThroughReply(m);
        Assert.Equal(VoiceState.Speaking, m.State);
        Assert.False(m.BargeInAllowed);
        Assert.Empty(m.Handle(Ev.BargeIn));
        Assert.Equal(VoiceState.Speaking, m.State);
    }

    [Fact]
    public void StopClearsOneShot()
    {
        var m = new VoiceTurnMachine { OneShot = true };
        m.Handle(Ev.StartRequested);
        m.Handle(Ev.StopRequested);
        Assert.False(m.OneShot);
        m.OneShot = true;
        m.Handle(Ev.StartRequested);
        m.Handle(Ev.Failed("boom"));
        Assert.False(m.OneShot);
    }
}
