using Jarvis.Core.Live;

namespace Jarvis.Tests.Live;

public class LiveProtocolTests
{
    [Fact]
    public void Hello_Payload() => Assert.Equal(
        "{\"caps\":{\"audio\":\"stream\",\"codec\":\"pcm16\",\"embed\":\"none\",\"embed_model\":\"\",\"rate\":16000,\"speak\":true,\"stt\":\"none\",\"text\":\"stream\"},\"device_id\":\"d1\",\"device_kind\":\"pc\",\"t\":\"hello\"}",
        LiveClientMessage.Hello("d1", new LiveCaps(), null).Encoded());

    [Fact]
    public void Hello_WithResume() => Assert.Contains("\"resume\":{\"after_seq\":7,\"live_session_id\":\"L1\"}",
        LiveClientMessage.Hello("d1", new LiveCaps(), new LiveResume("L1", 7)).Encoded());

    [Fact]
    public void Seg_And_Bye()
    {
        Assert.Equal("{\"lang\":\"en\",\"local_label\":\"\",\"partial\":false,\"t\":\"seg\",\"text\":\"hi\",\"ts_end_ms\":900,\"ts_start_ms\":100}",
            LiveClientMessage.Seg(100, 900, "hi", "en").Encoded());
        Assert.Equal("{\"t\":\"bye\"}", LiveClientMessage.Bye().Encoded());
    }

    [Fact]
    public void AudioFrame_BigEndianHeader()
    {
        var f = LiveAudioFrame.Encode(1, 0x0102030405, new byte[] { 9 });
        Assert.Equal(new byte[] { 0, 0, 0, 1, 0, 0, 0, 1, 2, 3, 4, 5, 9 }, f);
        var back = LiveAudioFrame.Decode(f)!.Value;
        Assert.Equal(1, back.Seq);
        Assert.Equal(0x0102030405, back.TsMs);
        Assert.Equal(new byte[] { 9 }, back.Payload);
        Assert.Null(LiveAudioFrame.Decode(new byte[5]));
    }

    [Fact]
    public void ServerFrames_DecodeDefensively()
    {
        Assert.Equal("hi", Assert.IsType<LiveServerFrame.Seg>(LiveServerFrame.Decode("{\"t\":\"seg\",\"text\":\"hi\"}")).Segment.Text);
        Assert.Equal(new LiveServerFrame.Partial("", 0, ""), LiveServerFrame.Decode("{\"type\":\"partial\"}"));
        Assert.Equal(new LiveServerFrame.Other("weird"), LiveServerFrame.Decode("{\"t\":\"weird\"}"));
        Assert.Equal(new LiveServerFrame.Other("unparsable"), LiveServerFrame.Decode("nope"));
        Assert.Equal("server", Assert.IsType<LiveServerFrame.Ready>(LiveServerFrame.Decode("{\"t\":\"ready\",\"lane\":\"moon\"}")).Lane);
        Assert.Equal("Live Jarvis reported an error", Assert.IsType<LiveServerFrame.Error>(LiveServerFrame.Decode("{\"t\":\"error\"}")).Message);
    }

    [Fact]
    public void Drop_ResumesWithLastSessionAndSeq()
    {
        var s = new LiveSession();
        Assert.DoesNotContain("resume", s.Hello("d1").Encoded());
        s.Apply(LiveServerFrame.Decode("{\"t\":\"ready\",\"live_session_id\":\"L9\",\"seq\":3}"));
        s.Apply(LiveServerFrame.Decode("{\"t\":\"seg\",\"seq\":5,\"text\":\"a\"}"));
        Assert.Contains("\"resume\":{\"after_seq\":5,\"live_session_id\":\"L9\"}", s.Hello("d1").Encoded());
    }

    [Fact]
    public void Backoff_1_2_4_8_Caps_ResetsOnReady()
    {
        var s = new LiveSession();
        Assert.Equal(new[] { 1, 2, 4, 8, 8 }, Enumerable.Range(0, 5).Select(_ => (int)s.NextDelay().TotalSeconds));
        s.Apply(new LiveServerFrame.Ready("L", "", 0, "server", ""));
        Assert.Equal(1, (int)s.NextDelay().TotalSeconds);
    }

    [Fact]
    public void Speaker_MergeRelabelsRowsAlreadyShown()
    {
        var s = new LiveSession();
        s.Apply(LiveServerFrame.Decode("{\"t\":\"seg\",\"seq\":1,\"speaker_id\":\"spk_2\",\"text\":\"a\"}"));
        s.Apply(LiveServerFrame.Decode("{\"t\":\"seg\",\"seq\":2,\"speaker_id\":\"spk_1\",\"text\":\"b\"}"));
        Assert.Equal("Speaker 2", s.Segments[0].Who);
        s.Apply(LiveServerFrame.Decode("{\"t\":\"speaker\",\"op\":\"merge\",\"speaker_id\":\"spk_1\",\"name\":\"Sam\",\"merged_from\":[\"spk_2\"]}"));
        Assert.All(s.Segments, x => Assert.Equal("spk_1", x.SpeakerId));
        Assert.Equal("Sam", s.Segments[0].Who);
    }

    [Fact]
    public void AudioSeqCountsUp()
    {
        var s = new LiveSession();
        Assert.Equal(0, LiveAudioFrame.Decode(s.NextAudioFrame(10, new byte[2]))!.Value.Seq);
        Assert.Equal(1, LiveAudioFrame.Decode(s.NextAudioFrame(20, new byte[2]))!.Value.Seq);
    }
}
