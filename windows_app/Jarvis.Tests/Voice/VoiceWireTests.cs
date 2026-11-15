using Jarvis.Core.Voice;

namespace Jarvis.Tests.Voice;

/// The `/api/voice/s2s/ws` wire format, both directions (port of VoiceSessionTests.swift's codec cases).
public class VoiceWireTests
{
    // Plan cases.

    [Fact]
    public void BeginTurn_SortedKeys() => Assert.Equal(
        "{\"clear_stale_stream\":true,\"sample_rate\":16000,\"session_id\":\"s1\",\"type\":\"begin_turn\"}",
        new VoiceClientMessage.BeginTurn(16000, "s1", null, null, null, true).Encoded());

    [Fact]
    public void BeginTurn_HarnessDropsModel() => Assert.Equal(
        "{\"harness_id\":\"h1\",\"sample_rate\":16000,\"session_id\":\"s1\",\"type\":\"begin_turn\"}",
        new VoiceClientMessage.BeginTurn(16000, "s1", "m", "p", "h1", false).Encoded());

    [Fact]
    public void EndTurn_Encoded() => Assert.Equal(
        "{\"client_ts\":1700000000000,\"speech_end_ts\":1699999999500,\"text\":\"hi\",\"turn_id\":\"t1\",\"type\":\"end_turn\"}",
        new VoiceClientMessage.EndTurn("hi", 1700000000000, 1699999999500, "t1").Encoded());

    [Fact]
    public void Interrupt_Encoded() =>
        Assert.Equal("{\"heard\":\"Hello there\",\"type\":\"interrupt\"}", new VoiceClientMessage.Interrupt("Hello there").Encoded());

    [Fact]
    public void AudioMeta_Mp3ZeroRateBecomes24k() => Assert.Equal(new VoiceServerFrame.AudioMeta("mp3", 24000),
        VoiceServerFrame.Decode("{\"type\":\"audio_meta\",\"format\":\"mp3\",\"sample_rate\":0}"));

    // Server → client.

    [Fact]
    public void DecodesEveryFrameTheServerSends()
    {
        Assert.Equal(new VoiceServerFrame.Ready(false), VoiceServerFrame.Decode("{\"type\":\"ready\"}"));
        Assert.Equal(new VoiceServerFrame.Ready(true),
            VoiceServerFrame.Decode("{\"type\":\"ready\",\"mode\":\"bridge\",\"clears_stale_stream\":true}"));
        Assert.Equal(new VoiceServerFrame.Transcript("hello"), VoiceServerFrame.Decode("{\"type\":\"transcript\",\"text\":\"hello\"}"));
        Assert.Equal(new VoiceServerFrame.AssistantText("Hi."), VoiceServerFrame.Decode("{\"type\":\"assistant_text\",\"text\":\"Hi.\"}"));
        Assert.Equal(new VoiceServerFrame.Tool("search_web", "started"),
            VoiceServerFrame.Decode("{\"type\":\"tool\",\"name\":\"search_web\",\"status\":\"started\"}"));
        Assert.Equal(new VoiceServerFrame.AudioMeta("mp3", 24000),
            VoiceServerFrame.Decode("{\"type\":\"audio_meta\",\"format\":\"mp3\",\"sample_rate\":24000}"));
        Assert.Equal(new VoiceServerFrame.AudioEnd(), VoiceServerFrame.Decode("{\"type\":\"audio_end\"}"));
        Assert.Equal(new VoiceServerFrame.EndTurnFrame("no_reply", false),
            VoiceServerFrame.Decode("{\"type\":\"end_turn\",\"reason\":\"no_reply\"}"));
        Assert.Equal(new VoiceServerFrame.EndOfSpeech(), VoiceServerFrame.Decode("{\"type\":\"end_of_speech\"}"));
        Assert.Equal(new VoiceServerFrame.EscalationResult("Actually…"),
            VoiceServerFrame.Decode("{\"type\":\"escalation_result\",\"text\":\"Actually…\"}"));
        // The older flat span/ms shape, still accepted.
        Assert.Equal(new VoiceServerFrame.Latency("m-1", new Dictionary<string, double> { ["tts"] = 210 }),
            VoiceServerFrame.Decode("{\"type\":\"latency\",\"turn_id\":\"m-1\",\"span\":\"tts\",\"ms\":210}"));
    }

    [Fact]
    public void LatencySpansMapIsDecoded() => Assert.Equal(
        new VoiceServerFrame.Latency("m-2", new Dictionary<string, double> { ["stt"] = 120, ["llm"] = 840.5 }),
        VoiceServerFrame.Decode("{\"type\":\"latency\",\"turn_id\":\"m-2\",\"spans\":{\"llm\":840.5,\"stt\":120,\"bad\":\"x\"}}"));

    [Fact]
    public void FrameDefaultsMatchTheFlutterClient()
    {
        Assert.Equal(new VoiceServerFrame.AudioMeta("pcm_s16le", 24000), VoiceServerFrame.Decode("{\"type\":\"audio_meta\"}"));
        Assert.Equal(new VoiceServerFrame.Tool("tool", "started"), VoiceServerFrame.Decode("{\"type\":\"tool\"}"));
        Assert.Equal(new VoiceServerFrame.EndTurnFrame("", false), VoiceServerFrame.Decode("{\"type\":\"end_turn\"}"));
        Assert.Equal(new VoiceServerFrame.EndTurnFrame("", true), VoiceServerFrame.Decode("{\"type\":\"end_turn\",\"followup\":true}"));
        Assert.Equal(new VoiceServerFrame.Transcript(""), VoiceServerFrame.Decode("{\"type\":\"transcript\"}"));
    }

    [Fact]
    public void AnUnknownTypeIsCarriedRatherThanDroppedSilently() =>
        Assert.Equal(new VoiceServerFrame.Other("quota_warning"), VoiceServerFrame.Decode("{\"type\":\"quota_warning\"}"));

    [Fact]
    public void NonJsonTextIsRejected()
    {
        Assert.Null(VoiceServerFrame.Decode("not json"));
        Assert.Null(VoiceServerFrame.Decode("[1,2,3]"));
    }

    // Client → server.

    [Fact]
    public void BeginTurnCarriesTheSampleRateAndSessionOnly() => Assert.Equal(
        "{\"sample_rate\":16000,\"session_id\":\"voice-1\",\"type\":\"begin_turn\"}",
        new VoiceClientMessage.BeginTurn(16000, "voice-1", null, null).Encoded());

    [Fact]
    public void BeginTurnCanAskTheServerToClearAStaleStream() => Assert.Equal(
        "{\"clear_stale_stream\":true,\"sample_rate\":16000,\"session_id\":\"voice-1\",\"type\":\"begin_turn\"}",
        new VoiceClientMessage.BeginTurn(16000, "voice-1", null, null, ClearStaleStream: true).Encoded());

    [Fact]
    public void BeginTurnIncludesTheVoiceModelWhenChosen()
    {
        var json = new VoiceClientMessage.BeginTurn(16000, "s", "gpt-5", "openai").Payload();
        Assert.Equal("gpt-5", (string?)json["model"]);
        Assert.Equal("openai", (string?)json["model_provider"]);
    }

    [Fact]
    public void BeginTurnWithTheSingleHarnessKeepsTheModel()
    {
        var json = new VoiceClientMessage.BeginTurn(16000, "s", "gpt-5", "openai", "single").Payload();
        Assert.Equal("single", (string?)json["harness_id"]);
        Assert.Equal("gpt-5", (string?)json["model"]);
    }

    [Fact]
    public void BeginTurnOmitsEmptyFields()
    {
        var json = new VoiceClientMessage.BeginTurn(16000, "", "", null).Payload();
        Assert.False(json.ContainsKey("session_id"));
        Assert.False(json.ContainsKey("model"));
        Assert.False(json.ContainsKey("model_provider"));
    }

    [Fact]
    public void EndTurnCarriesTheLatencyTimestamps()
    {
        var json = new VoiceClientMessage.EndTurn("turn on the lights", 1000, 900, "m-7").Payload();
        Assert.Equal("end_turn", (string?)json["type"]);
        Assert.Equal("turn on the lights", (string?)json["text"]);
        Assert.Equal(1000, (long)json["client_ts"]!);
        Assert.Equal(900, (long)json["speech_end_ts"]!);
        Assert.Equal("m-7", (string?)json["turn_id"]);
    }

    [Fact]
    public void EndTurnWithoutAnOnDeviceTranscriptOmitsText()
    {
        var json = new VoiceClientMessage.EndTurn(null, 5, null, null).Payload();
        Assert.False(json.ContainsKey("text"));
        Assert.False(json.ContainsKey("speech_end_ts"));
        Assert.False(json.ContainsKey("turn_id"));
        Assert.Equal(2, json.Count);
    }

    [Fact]
    public void InterruptCarriesWhatWasHeard()
    {
        Assert.Equal("{\"heard\":\"It will be sunny\",\"type\":\"interrupt\"}", new VoiceClientMessage.Interrupt("It will be sunny").Encoded());
        Assert.Equal("{\"heard\":\"\",\"type\":\"interrupt\"}", new VoiceClientMessage.Interrupt("").Encoded());
        Assert.Equal("{\"type\":\"interrupt\"}", new VoiceClientMessage.Interrupt(null).Encoded());
    }

    [Fact]
    public void EncodedDoesNotEscapeNonAscii() =>
        Assert.Equal("{\"heard\":\"café — ok\",\"type\":\"interrupt\"}", new VoiceClientMessage.Interrupt("café — ok").Encoded());
}
