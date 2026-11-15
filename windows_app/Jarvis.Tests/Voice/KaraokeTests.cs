using Jarvis.Core.Voice;

namespace Jarvis.Tests.Voice;

/// The karaoke model: plain speech, splitting, segment schedules and the streaming reply highlight
/// (port of VoiceKaraokeTests.swift and VoiceReplyTests.swift).
public class KaraokeTests
{
    // Plan cases.

    [Fact]
    public void Schedule_WeightsPunctuation()
    {
        var s = new VoiceSegment("Hello there, world.", 0);
        s.Schedule(1000);
        Assert.Equal(new[] { 0.0, 206.9, 551.7 }, s.Starts.Select(x => Math.Round(x, 1)));
        s.Advance(300); Assert.Equal(2, s.LocalSpoken);
        s.Advance(100); Assert.Equal(2, s.LocalSpoken);
    }

    [Fact]
    public void SplitForSpeech_MergesShort() => Assert.Equal(
        new[] { "Hi. This is a much longer sentence that goes past forty characters.", "Ok." },
        SpeechText.SplitForSpeech("Hi. This is a much longer sentence that goes past forty characters. Ok."));

    // plainSpeech (must match the server's `_speakable`).

    [Fact]
    public void StripsFencedCodeBlocks() => Assert.Equal("before\n \nafter", SpeechText.PlainSpeech("before\n```\nlet x = 1\n```\nafter"));

    [Fact]
    public void KeepsLinkTextAndDropsTheUrl() => Assert.Equal("see the docs", SpeechText.PlainSpeech("see [the docs](https://x.test/a)"));

    [Fact]
    public void UnwrapsInlineCode() => Assert.Equal("run make test now", SpeechText.PlainSpeech("run `make test` now"));

    [Fact]
    public void StripsHeadingsBlockquotesAndBullets() =>
        Assert.Equal("Title\nquoted\none\ntwo", SpeechText.PlainSpeech("## Title\n> quoted\n- one\n* two"));

    [Fact]
    public void StripsEmphasisMarkers() =>
        Assert.Equal("bold and italic and gone", SpeechText.PlainSpeech("**bold** and _italic_ and ~~gone~~"));

    [Fact]
    public void CollapsesRunsOfBlankLinesAndTrims() => Assert.Equal("a\n\nb", SpeechText.PlainSpeech("  a\n\n\n\nb  "));

    // wordTokens.

    [Fact]
    public void TokenizesOnWhitespaceRuns()
    {
        Assert.Equal(new[] { "hello", "there", "world" }, SpeechText.WordTokens("  hello   there\nworld "));
        Assert.Empty(SpeechText.WordTokens("   "));
    }

    // splitForSpeech.

    [Fact]
    public void SplitsOnSentenceEndsAndNewlines()
    {
        var output = SpeechText.SplitForSpeech("The weather is clear today. Winds are light out of the west. Enjoy it.");
        Assert.Equal(2, output.Count);
        Assert.StartsWith("The weather", output[0]);
    }

    [Fact]
    public void MergesVeryShortFragmentsSoThereIsNoClipPerWord() =>
        Assert.Equal(new[] { "Yes. No. Sure." }, SpeechText.SplitForSpeech("Yes. No. Sure."));

    [Fact]
    public void DropsEmptyFragments() => Assert.Empty(SpeechText.SplitForSpeech("\n\n  \n"));

    [Fact]
    public void EveryWordSurvivesTheSplit()
    {
        const string text = "One sentence here that is quite long indeed. Another one follows it. Third.";
        var joined = string.Join(" ", SpeechText.SplitForSpeech(text));
        Assert.Equal(SpeechText.WordTokens(text), SpeechText.WordTokens(joined));
    }

    // VoiceSegment scheduling.

    [Fact]
    public void ScheduleSpreadsWordsAcrossTheClipStartingAtZero()
    {
        var seg = new VoiceSegment("one two three four", 0);
        seg.Schedule(1000);
        Assert.Equal(1000, seg.DurMs);
        Assert.Equal(4, seg.Starts.Count);
        Assert.Equal(0, seg.Starts[0], 3);
        for (var i = 1; i < seg.Starts.Count; i++)
        {
            Assert.True(seg.Starts[i] > seg.Starts[i - 1]);
            Assert.True(seg.Starts[i] < 1000);
        }
    }

    [Fact]
    public void SentenceEndingWordsTakeLongerThanClauseBreaks()
    {
        var a = new VoiceSegment("aaa. bbb ccc", 0);
        var b = new VoiceSegment("aaa, bbb ccc", 0);
        a.Schedule(1000);
        b.Schedule(1000);
        Assert.True(a.Starts[1] > b.Starts[1]);
    }

    [Fact]
    public void AdvanceIsMonotonicAndNeverStepsBackward()
    {
        var seg = new VoiceSegment("one two three four five", 0);
        seg.Schedule(1000);
        seg.Advance(600);
        var reached = seg.LocalSpoken;
        Assert.True(reached > 0);
        seg.Advance(10);
        Assert.Equal(reached, seg.LocalSpoken);
    }

    [Fact]
    public void AdvanceToTheEndOfTheClipSpeaksEveryWord()
    {
        var seg = new VoiceSegment("one two three", 0);
        seg.Schedule(500);
        seg.Advance(500);
        Assert.Equal(3, seg.LocalSpoken);
    }

    [Fact]
    public void AnEmptySegmentSchedulesNothing()
    {
        var seg = new VoiceSegment("", 7);
        seg.Schedule(1000);
        Assert.Empty(seg.Starts);
        seg.Advance(1000);
        Assert.Equal(0, seg.LocalSpoken);
    }

    // VoiceReply.

    [Fact]
    public void AppendJoinsSegmentsAsThePlainReply()
    {
        var reply = new VoiceReply();
        Assert.Equal(0, reply.Append("The weather is **clear**."));
        Assert.Equal(1, reply.Append("Winds are light."));
        Assert.Equal("The weather is clear.\n\nWinds are light.", reply.Text);
        Assert.Equal(7, reply.TotalWords);
        Assert.Equal(4, reply.Segments[1].WordOffset);
        Assert.False(reply.IsEmpty);
    }

    [Fact]
    public void AChunkThatStripsToNothingAddsNoSegment()
    {
        var reply = new VoiceReply();
        Assert.Null(reply.Append("```\ncode\n```"));
        Assert.Null(reply.Append("   "));
        Assert.Empty(reply.Segments);
        Assert.True(reply.IsEmpty);
    }

    [Fact]
    public void AppendTextIsAppend()
    {
        var reply = new VoiceReply();
        reply.AppendText("one two");
        Assert.Equal(2, reply.TotalWords);
    }

    [Fact]
    public void ResetClearsEverything()
    {
        var reply = new VoiceReply();
        reply.Append("one two");
        reply.ClipStarted(0, 100);
        reply.Reset();
        Assert.Empty(reply.Segments);
        Assert.Equal("", reply.Text);
        Assert.Equal(0, reply.SpokenWords);
        Assert.Equal(0, reply.TotalWords);
        Assert.Equal(-1, reply.CurrentSegment);
    }

    [Fact]
    public void ClaimSegmentTagTakesTheMostRecentUnpairedSegment()
    {
        var reply = new VoiceReply();
        reply.Append("first");
        reply.Append("second");
        Assert.Equal(1, reply.ClaimSegmentTag());
        Assert.Equal(0, reply.ClaimSegmentTag());
        Assert.Null(reply.ClaimSegmentTag());
    }

    [Fact]
    public void ClaimSegmentTagSkipsSegmentsThatAlreadyHaveAudio()
    {
        var reply = new VoiceReply();
        reply.Append("first");
        reply.Append("second");
        reply.AssignAudio(1);
        Assert.Equal(0, reply.ClaimSegmentTag());
    }

    [Fact]
    public void AssignAudioIgnoresAnOutOfRangeIndex()
    {
        var reply = new VoiceReply();
        reply.Append("only");
        reply.AssignAudio(9);
        Assert.Equal(0, reply.ClaimSegmentTag());
    }

    [Fact]
    public void TheHighlightAdvancesWithThePlaybackPosition()
    {
        var reply = new VoiceReply();
        reply.Append("one two three four");
        reply.ClipStarted(0, 1000);
        Assert.Equal(0, reply.SpokenWords);
        reply.ClipPosition(0, 500);
        var mid = reply.SpokenWords;
        Assert.InRange(mid, 2, 3);
        reply.ClipPosition(0, 1000);
        Assert.Equal(4, reply.SpokenWords);
    }

    [Fact]
    public void PositionFollowsTheCurrentClip()
    {
        var reply = new VoiceReply();
        reply.Append("one two three four");
        reply.ClipStarted(0, 1000);
        reply.Position(1000);
        Assert.Equal(4, reply.SpokenWords);
    }

    [Fact]
    public void StartingALaterSegmentMarksEveryEarlierOneFullySpoken()
    {
        var reply = new VoiceReply();
        reply.Append("one two");
        reply.Append("three four");
        reply.Append("five");
        reply.ClipStarted(2, 500);
        Assert.Equal(4, reply.SpokenWords);
    }

    [Fact]
    public void ARepeatClipStartIsAScheduleCorrectionNotARestart()
    {
        var reply = new VoiceReply();
        reply.Append("one two three four five");
        reply.ClipStarted(0, 0);
        reply.ClipPosition(0, 900);
        var progress = reply.SpokenWords;
        Assert.True(progress > 1);
        reply.ClipStarted(0, 2000);
        Assert.Equal(progress, reply.SpokenWords);
    }

    [Fact]
    public void AnUnknownDurationFallsBackToAWordCountEstimate()
    {
        var reply = new VoiceReply();
        reply.Append("one two three");
        reply.ClipStarted(0, 0);
        Assert.Equal(900, reply.Segments[0].DurMs);
    }

    [Fact]
    public void AStalePositionFromTheOutgoingClipIsIgnored()
    {
        var reply = new VoiceReply();
        reply.Append("one two");
        reply.Append("three four five");
        reply.ClipStarted(0, 400);
        reply.ClipStarted(1, 600);
        reply.ClipPosition(1, 5000);
        Assert.Equal(2, reply.SpokenWords);
    }

    [Fact]
    public void PositionsForANonCurrentSegmentAreIgnored()
    {
        var reply = new VoiceReply();
        reply.Append("one two");
        reply.Append("three four");
        reply.ClipStarted(1, 500);
        var before = reply.SpokenWords;
        reply.ClipPosition(0, 400);
        reply.ClipPosition(null, 400);
        reply.ClipPosition(9, 400);
        Assert.Equal(before, reply.SpokenWords);
    }

    [Fact]
    public void ClipStartWithANilOrOutOfRangeTagIsIgnored()
    {
        var reply = new VoiceReply();
        reply.Append("one two");
        reply.ClipStarted(null, 500);
        reply.ClipStarted(7, 500);
        Assert.Equal(-1, reply.CurrentSegment);
        Assert.Equal(0, reply.SpokenWords);
    }

    [Fact]
    public void FinalizeLightsUpTheWordsThePositionStreamNeverReached()
    {
        var reply = new VoiceReply();
        reply.Append("one two three");
        reply.Append("four five");
        reply.ClipStarted(0, 1000);
        Assert.True(reply.SpokenWords < 5);
        reply.FinalizeSpoken();
        Assert.Equal(5, reply.SpokenWords);
        Assert.Equal(reply.TotalWords, reply.SpokenWords);
    }

    [Fact]
    public void AStreamedSegmentsGrowingTotalKeepsTheHighlightMoving()
    {
        var reply = new VoiceReply();
        reply.Append("one two three four five six");
        reply.ClipStarted(0, 300);
        reply.ClipPosition(0, 100);
        var afterFirstChunk = reply.SpokenWords;
        Assert.InRange(afterFirstChunk, 1, 5);
        reply.ClipStarted(0, 1200);
        reply.ClipPosition(0, 1200);
        Assert.Equal(6, reply.SpokenWords);
    }

    // Streaming segments (teleprompter racing ahead).

    private const string Long = "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty";

    [Fact]
    public void APartialDurationDoesNotRaceTheHighlightAhead()
    {
        var reply = new VoiceReply();
        reply.Append(Long);
        reply.ClipStarted(0, 300, complete: false);
        reply.ClipPosition(0, 300);
        Assert.True(reply.SpokenWords <= 2);
        reply.ClipStarted(0, 1200, complete: false);
        reply.ClipPosition(0, 1200);
        Assert.InRange(reply.SpokenWords, 3, 7);
    }

    [Fact]
    public void TheCompleteDurationReschedulesExactly()
    {
        var reply = new VoiceReply();
        reply.Append(Long);
        reply.ClipStarted(0, 300, complete: false);
        reply.ClipStarted(0, 4000, complete: true);
        Assert.Equal(4000, reply.Segments[0].DurMs);
        reply.ClipPosition(0, 2000);
        Assert.InRange(reply.SpokenWords, 8, 14);
        reply.ClipPosition(0, 4000);
        Assert.Equal(20, reply.SpokenWords);
    }

    [Fact]
    public void APartialDurationLongerThanTheEstimateIsTrusted()
    {
        var reply = new VoiceReply();
        reply.Append("one two");
        reply.ClipStarted(0, 1500, complete: false);
        Assert.Equal(1500, reply.Segments[0].DurMs);
    }

    [Fact]
    public void CompletedSegmentsCalibrateTheSpeakingRate()
    {
        var reply = new VoiceReply();
        reply.Append("one two three four five six seven eight nine ten");
        reply.ClipStarted(0, 5000, complete: true);
        reply.Append(Long);
        reply.ClipStarted(1, 100, complete: false);
        Assert.True(reply.Segments[1].DurMs > 20 * 300);
    }

    [Fact]
    public void DefaultBehaviourIsCompleteSoExistingCallersAreUnchanged()
    {
        var reply = new VoiceReply();
        reply.Append("one two three four");
        reply.ClipStarted(0, 1000);
        Assert.Equal(1000, reply.Segments[0].DurMs);
    }

    [Fact]
    public void HeardTextIsTheWordsSpokenSoFarAcrossSegments()
    {
        var reply = new VoiceReply();
        reply.Append("Clear skies this afternoon.");
        reply.Append("Highs around twenty two.");
        Assert.Equal("", reply.HeardText());
        reply.ClipStarted(0, 1000);
        reply.ClipPosition(0, 1000);
        Assert.Equal("Clear skies this afternoon.", reply.HeardText());
        reply.ClipStarted(1, 1000);
        reply.ClipPosition(1, 400);
        var words = reply.HeardText().Split(' ');
        Assert.Equal(reply.SpokenWords, words.Length);
        Assert.True(words.Length > 4);
        Assert.StartsWith("Clear skies this afternoon. Highs", reply.HeardText());
    }
}
