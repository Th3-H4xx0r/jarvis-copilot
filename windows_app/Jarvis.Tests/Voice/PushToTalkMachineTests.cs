using Jarvis.Core.Voice;
using static Jarvis.Core.Voice.VoiceEffectKind;

namespace Jarvis.Tests.Voice;

/// Push to talk on the turn machine (restored: the spec requires it).
public class PushToTalkMachineTests
{
    private static IEnumerable<VoiceEffectKind> K(IReadOnlyList<VoiceEffect> fx) => fx.Select(f => f.Kind);

    [Fact]
    public void TalkDown_FromIdle_OpensOneShotWithKeyHeld()
    {
        var m = new VoiceTurnMachine();
        var fx = m.Handle(VoiceEvent.TalkKeyDown);
        Assert.Contains(OpenTransport, K(fx));
        Assert.Contains(StartMic, K(fx));
        Assert.True(m.PushToTalk);
        Assert.True(m.OneShot);
        Assert.Equal(VoiceState.Connecting, m.State);
    }

    [Fact]
    public void EndOfSpeech_WhileHeld_Ignored()
    {
        var m = new VoiceTurnMachine();
        m.Handle(VoiceEvent.TalkKeyDown);
        m.Handle(VoiceEvent.Connected);
        Assert.Empty(m.Handle(VoiceEvent.EndOfSpeech));
        Assert.Equal(VoiceState.Listening, m.State);
    }

    [Fact]
    public void TalkUp_WhileListening_SendsEndTurn()
    {
        var m = new VoiceTurnMachine();
        m.Handle(VoiceEvent.TalkKeyDown);
        m.Handle(VoiceEvent.Connected);
        var fx = m.Handle(VoiceEvent.TalkKeyUp);
        Assert.Contains(SendEndTurn, K(fx));
        Assert.Contains(MarkSpeechEnd, K(fx));
        Assert.Equal(VoiceState.Thinking, m.State);
        Assert.False(m.PushToTalk);
    }

    [Fact]
    public void TalkUp_BeforeConnected_SendsOnConnect()
    {
        var m = new VoiceTurnMachine();
        m.Handle(VoiceEvent.TalkKeyDown);
        Assert.Empty(m.Handle(VoiceEvent.TalkKeyUp));
        Assert.True(m.SendOnConnect);
        var fx = m.Handle(VoiceEvent.Connected);
        Assert.Contains(SendEndTurn, K(fx));
        Assert.Equal(VoiceState.Thinking, m.State);
        Assert.False(m.SendOnConnect);
    }

    [Fact]
    public void TalkUp_WithoutDown_DoesNothing() => Assert.Empty(new VoiceTurnMachine().Handle(VoiceEvent.TalkKeyUp));

    [Fact]
    public void TalkDown_WhileSpeaking_InterruptsAndListens()
    {
        var m = new VoiceTurnMachine();
        m.Handle(VoiceEvent.StartRequested);
        m.Handle(VoiceEvent.Connected);
        m.Handle(VoiceEvent.EndOfSpeech);
        m.Handle(VoiceEvent.PlaybackStarted);
        var fx = m.Handle(VoiceEvent.TalkKeyDown);
        Assert.Contains(SendInterrupt, K(fx));
        Assert.Contains(StopPlayback, K(fx));
        Assert.Equal(VoiceState.Listening, m.State);
        Assert.True(m.DiscardingInterruptedTurn);
    }

    [Fact]
    public void TalkDown_InHandsFreeConversation_StaysAConversation()
    {
        var m = new VoiceTurnMachine();
        m.Handle(VoiceEvent.StartRequested);
        m.Handle(VoiceEvent.Connected);
        m.Handle(VoiceEvent.TalkKeyDown);
        Assert.False(m.OneShot);
        Assert.Contains(SendEndTurn, K(m.Handle(VoiceEvent.TalkKeyUp)));
    }

    [Fact]
    public void OneShot_AfterReplyDrains_Closes()
    {
        var m = new VoiceTurnMachine();
        m.Handle(VoiceEvent.TalkKeyDown);
        m.Handle(VoiceEvent.Connected);
        m.Handle(VoiceEvent.TalkKeyUp);
        m.Handle(VoiceEvent.PlaybackStarted);
        m.Handle(VoiceEvent.TurnEnded("done", true));
        var fx = m.Handle(VoiceEvent.PlaybackDrained);
        Assert.Contains(Teardown, K(fx));
        Assert.Contains(OneShotFinished, K(fx));
        Assert.Equal(VoiceState.Idle, m.State);
    }

    [Fact]
    public void Stop_ClearsKeyState()
    {
        var m = new VoiceTurnMachine();
        m.Handle(VoiceEvent.TalkKeyDown);
        m.Handle(VoiceEvent.TalkKeyUp);
        m.Handle(VoiceEvent.StopRequested);
        Assert.False(m.PushToTalk);
        Assert.False(m.SendOnConnect);
    }
}
