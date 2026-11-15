using Jarvis.Core.Voice;

namespace Jarvis.Tests.Voice;

/// The sound half of barge-in, frame by frame (port of BargeInDetectorTests.swift with the Mac tuning),
/// plus the words check that decides whether a sound over the reply is someone talking.
public class BargeInTests
{
    private const int FrameMs = 100;
    private static double Speech => BargeInTuning.SpeechAmp * 3;
    private static double Echo => BargeInTuning.SpeechAmp / 4;

    // Plan cases.

    [Fact]
    public void BargeIn_EchoRaisesBar()
    {
        var d = new BargeInDetector();
        for (var i = 0; i < 7; i++) d.Feed(0.025, 50, true);
        Assert.Equal(0.0375, d.Bar, 4);
        for (var i = 0; i < 10; i++) Assert.False(d.Feed(0.035, 50, true));
    }

    [Fact]
    public void BargeIn_Sustained350ms_Triggers()
    {
        var d = new BargeInDetector();
        var hits = Enumerable.Range(0, 10).Select(_ => d.Feed(0.05, 50, true)).ToList();
        Assert.Equal(6, hits.IndexOf(true));
    }

    // Ported cases.

    [Fact]
    public void SpeechThatLastsTriggers()
    {
        var detector = new BargeInDetector();
        var fired = false;
        // Ceiling: the Mac's 350 ms is not a whole number of 100 ms frames.
        var frames = (BargeInTuning.SustainMs + FrameMs - 1) / FrameMs;
        for (var i = 0; i < frames; i++) fired = detector.Feed(Speech, FrameMs, true);
        Assert.True(fired);
        Assert.True(detector.LastVoiced);
    }

    [Fact]
    public void ASingleSpikeNeverTriggers()
    {
        var detector = new BargeInDetector();
        Assert.False(detector.Feed(Speech, FrameMs, true));
        for (var i = 0; i < 10; i++) Assert.False(detector.Feed(Echo, FrameMs, true));
    }

    [Fact]
    public void TheReplysOwnEchoRaisesTheBar()
    {
        var detector = new BargeInDetector();
        var loudEcho = BargeInTuning.SpeechAmp * 2;
        for (var i = 0; i < BargeInTuning.EchoWindowMs / FrameMs; i++) detector.NoteEcho(loudEcho, FrameMs);
        Assert.True(detector.Bar > BargeInTuning.SpeechAmp);
        var fired = false;
        for (var i = 0; i < 10; i++) fired = detector.Feed(BargeInTuning.SpeechAmp * 1.1, FrameMs, false) || fired;
        Assert.False(fired);
    }

    [Fact]
    public void NotLearningLeavesTheEchoLevelAlone()
    {
        var detector = new BargeInDetector();
        for (var i = 0; i < 20; i++) detector.Feed(Echo, FrameMs, false);
        Assert.Empty(detector.EchoFrames);
        Assert.Equal(0, detector.EchoFloor);
    }

    [Fact]
    public void ResetForgetsTheWindowAndTheEcho()
    {
        var detector = new BargeInDetector();
        for (var i = 0; i < 5; i++) detector.Feed(Speech, FrameMs, true);
        detector.NoteEcho(Echo, FrameMs);
        detector.Reset();
        Assert.Equal(0, detector.VoicedMs);
        Assert.Empty(detector.EchoFrames);
    }

    [Fact]
    public void AVoicedFrameThatAgesOutWithoutTriggeringBecomesEcho()
    {
        var detector = new BargeInDetector();
        detector.Feed(Speech, FrameMs, true);              // voiced, held out of the echo level for now
        Assert.Empty(detector.EchoFrames);
        for (var i = 0; i < 5; i++) detector.Feed(Echo, FrameMs, true);
        Assert.Contains(detector.EchoFrames, f => f.Amp == Speech);
    }

    // Words check.

    private static VoiceReply ReplySaying(string text)
    {
        var reply = new VoiceReply();
        reply.AppendText(text);
        reply.ForceSpoken(2);
        return reply;
    }

    [Fact]
    public void WordsCheck_NoWordsAfterMinAndQuiet_Releases()
    {
        var check = new WordsCheck(ReplySaying("The weather in Houston is sunny today"));
        var loud = BargeInTuning.SpeechAmp * 2;
        for (var ms = 0; ms < 1200; ms += 50) Assert.Equal(WordsCheck.Verdict.Pending, check.Feed(loud, 50, ""));
        // 1200 ms heard, but the sound is still going: keep listening until it has been quiet 500 ms.
        for (var ms = 50; ms < 500; ms += 50) Assert.Equal(WordsCheck.Verdict.Pending, check.Feed(0.001, 50, ""));
        Assert.Equal(WordsCheck.Verdict.Release, check.Feed(0.001, 50, ""));
        Assert.Equal(1700, check.HeardMs);
    }

    [Fact]
    public void WordsCheck_QuietBeforeTheMinimumStillWaitsForIt()
    {
        var check = new WordsCheck(ReplySaying("The weather in Houston is sunny today"));
        Assert.Equal(WordsCheck.Verdict.Pending, check.Feed(BargeInTuning.SpeechAmp * 2, 200, null));
        for (var ms = 200; ms < 1100; ms += 100) Assert.Equal(WordsCheck.Verdict.Pending, check.Feed(0.001, 100, null));
        Assert.Equal(WordsCheck.Verdict.Release, check.Feed(0.001, 100, null));   // 1200 ms heard, 1000 ms quiet
    }

    [Fact]
    public void WordsCheck_ForeignWords_Interrupts()
    {
        var check = new WordsCheck(ReplySaying("The weather in Houston is sunny today"));
        var loud = BargeInTuning.SpeechAmp * 2;
        Assert.Equal(WordsCheck.Verdict.Pending, check.Feed(loud, 100, null));
        // The reply's own echo, a filler and a stray letter are not him.
        Assert.Equal(WordsCheck.Verdict.Pending, check.Feed(loud, 100, "weather Houston uh a"));
        Assert.Equal(WordsCheck.Verdict.Interrupt, check.Feed(loud, 100, "weather Houston wait"));
        Assert.Equal(new[] { "wait" }, check.Words);
        Assert.Equal("weather Houston wait", check.Heard);
        // Decided: it stays decided.
        Assert.Equal(WordsCheck.Verdict.Interrupt, check.Feed(0.001, 100, ""));
    }

    [Fact]
    public void WordsCheck_ARecogniserUpdateWithNoFrameCountsNoTime()
    {
        var check = new WordsCheck(ReplySaying("The weather in Houston is sunny today"));
        Assert.Equal(WordsCheck.Verdict.Interrupt, check.Feed(0, 0, "hang on"));
        Assert.Equal(0, check.HeardMs);
    }

    [Fact]
    public void WordsCheck_4sNoWords_GivesUp()
    {
        var check = new WordsCheck(ReplySaying("The weather in Houston is sunny today"));
        var loud = BargeInTuning.SpeechAmp * 2;
        for (var ms = 100; ms < BargeInTuning.CheckMaxMs; ms += 100)
            Assert.Equal(WordsCheck.Verdict.Pending, check.Feed(loud, 100, "weather"));
        Assert.Equal(WordsCheck.Verdict.GiveUp, check.Feed(loud, 100, "weather"));
        Assert.Equal(BargeInTuning.CheckMaxMs, check.HeardMs);

        // Then nothing is checked again until the mic has been quiet for CheckQuietMs.
        var cooldown = new QuietCooldown();
        Assert.False(cooldown.Feed(true, 100));
        for (var ms = 100; ms < BargeInTuning.CheckQuietMs; ms += 100) Assert.False(cooldown.Feed(false, 100));
        Assert.False(cooldown.Feed(true, 100));    // the sound came back: the quiet run starts again
        for (var ms = 100; ms < BargeInTuning.CheckQuietMs; ms += 100) Assert.False(cooldown.Feed(false, 100));
        Assert.True(cooldown.Feed(false, 100));
        Assert.True(cooldown.Done);
    }
}
