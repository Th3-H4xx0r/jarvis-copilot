using Jarvis.Core.Voice;
using Jarvis.Tests.Fakes;
using F = Jarvis.Core.Voice.VoiceServerFrame;

namespace Jarvis.Tests.Voice;

/// The rest of a reply the user cut off is dropped until its own end_turn, or for 10 s at most
/// (VoiceStoreTransport.swift `handle(_:)` while `discardingInterruptedTurn`).
public class PostInterruptFilterTests
{
    private static readonly DateTimeOffset T0 = TestClock.T0;

    [Fact]
    public void PostInterrupt_DropsUntilEndTurnOr10s()
    {
        var f = new PostInterruptFilter();
        Assert.False(f.Drop(new F.AssistantText("Hi."), T0), "nothing is dropped before an interrupt");

        // Cut off: everything the server still sends for that reply is dropped...
        f.Interrupted(T0);
        Assert.True(f.Active);
        Assert.True(f.Drop(new F.AssistantText("And then"), T0.AddSeconds(1)));
        Assert.True(f.Drop(new F.AudioMeta("pcm_s16le", 24000), T0.AddSeconds(1)));
        Assert.True(f.Drop(new F.Audio(new byte[] { 1, 2 }), T0.AddSeconds(1)));
        Assert.True(f.Drop(new F.AudioEnd(), T0.AddSeconds(1)));
        Assert.Equal(4, f.Dropped);
        // ...ready/latency/other are swallowed too, but not counted as reply frames.
        Assert.True(f.Drop(new F.Latency("t", new Dictionary<string, double>()), T0.AddSeconds(1)));
        Assert.Equal(4, f.Dropped);
        // ...until its end_turn, which gets through (it ends the cut-off turn) and ends the dropping.
        Assert.False(f.Drop(new F.EndTurnFrame("interrupt", false), T0.AddSeconds(2)));
        Assert.False(f.Active);
        Assert.False(f.Drop(new F.AssistantText("New answer."), T0.AddSeconds(3)));

        // An end_turn that never comes: dropping gives up after 10 s.
        f.Interrupted(T0.AddSeconds(10));
        Assert.True(f.Drop(new F.AudioEnd(), T0.AddSeconds(10) + PostInterruptFilter.Expiry - TimeSpan.FromMilliseconds(1)));
        Assert.False(f.Drop(new F.AssistantText("Late but real."), T0.AddSeconds(10) + PostInterruptFilter.Expiry));
        Assert.False(f.Active);
    }

    [Fact]
    public void ResetStopsDropping()
    {
        var f = new PostInterruptFilter();
        f.Interrupted(T0);
        f.Reset();
        Assert.False(f.Drop(new F.AssistantText("x"), T0));
    }
}
