using Jarvis.Core.Voice;

namespace Jarvis.Tests.Voice;

/// Telling the user's words from the reply's own echo (VoiceReplyTests.swift `userWords`).
public class ReplyWordsTests
{
    [Fact]
    public void UserWords_DropsEchoAndFillers()
    {
        var r = new VoiceReply();
        r.AppendText("The weather in Houston is sunny today");
        r.ForceSpoken(3);
        Assert.Equal(new[] { "stop", "please" }, r.UserWords("Houston, stop please uh"));
    }

    [Fact]
    public void WordsTheReplyIsSayingAreItsOwnEcho()
    {
        var reply = new VoiceReply();
        reply.Append("Clear skies over Houston today, with a high of 92.");
        reply.ClipStarted(0, 3000);
        reply.ClipPosition(0, 1500);
        Assert.Empty(reply.UserWords("Skies over Houston. A high of 92"));
        Assert.Equal(new[] { "wait", "stop" }, reply.UserWords("skies over — wait, stop!"));
    }

    [Fact]
    public void FillersAndSingleLettersAreNotWords()
    {
        var reply = new VoiceReply();
        Assert.Empty(reply.UserWords("Uh. Hmm, mm-hmm. A"));
        Assert.Equal(new[] { "jarvis" }, reply.UserWords("Uh, Jarvis"));
    }

    [Fact]
    public void OnlyTheReplyNearThePlayheadCountsAsEcho()
    {
        var reply = new VoiceReply();
        reply.Append("Tomorrow " + string.Join(" ", Enumerable.Repeat("and so on", 30)) + ".");
        reply.ClipStarted(0, 30_000);
        reply.ClipPosition(0, 29_000);
        Assert.Empty(reply.UserWords("and so on"));
        Assert.Equal(new[] { "what", "about", "tomorrow" }, reply.UserWords("what about tomorrow"));
    }

    [Fact]
    public void PlainWordsDropsPunctuationAndApostrophes() =>
        Assert.Equal(new[] { "houston", "mm", "hmm", "dont", "dont" }, VoiceReply.PlainWords("Houston, mm-hmm don't don’t"));
}
